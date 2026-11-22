#!/bin/zsh
# Сборка pia.app: swift build (SDK 26.5 — в SDK 27 у Command Line Tools нет плагина SwiftUIMacros для @State),
# бандл, значок, подпись постоянным самоподписанным сертификатом «pia local signing» (права macOS не сбрасываются),
# рантайм pia (копия Node в Contents/MacOS/pia, подписана вместе с бандлом),
# установка в ~/Applications/pia.app; службы server и chat — внутри бандла (Contents/Library/LaunchAgents, из ../launchd/*.plist.template), регистрация SMAppService.  Запуск: ./build.sh [--no-install] [--full]
# По умолчанию установка трогает только окно (pia-app, ресурсы, подпись бандла) и службу chat; рантайм Contents/MacOS/pia и служба server
# остаются как есть (pid сервера не меняется). --full — заменить бандл целиком и перерегистрировать обе службы (сервер перезапустится).
set -e
FULL=0; NOINST=0
for a in "$@"; do case $a in --full) FULL=1;; --no-install) NOINST=1;; esac; done
cd "${0:A:h}"
# SDK: берём 26.5, иначе любой 26.x (в CLT с SDK 27 swift build падает на @State); Xcode.app — запасной путь
SDK=""
for c in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk \
         /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk; do
  [ -d "$c" ] && { SDK=$c; break; }
done
[ -n "$SDK" ] || { echo "нет подходящего SDK (нужен MacOSX 26.x или Xcode) — окно не собрать"; [ "$1" = "--check-password" ] || exit 1; }
# пароль связки подписи: Связка ключей macOS (служба pia-signing) -> переменная PIA_SIGNING_PASSWORD -> файл signing/keychain.pw (вне git)
signing_password() {
  security find-generic-password -s pia-signing -a pia -w 2>/dev/null && return 0
  [ -n "$PIA_SIGNING_PASSWORD" ] && { printf '%s' "$PIA_SIGNING_PASSWORD"; return 0; }
  [ -f "$PWD/signing/keychain.pw" ] && { cat "$PWD/signing/keychain.pw"; return 0; }
  return 1
}
if [ "$1" = "--check-password" ]; then
  KC=$PWD/signing/pia-signing.keychain-db
  [ -f "$KC" ] || { echo "нет связки подписи"; exit 1; }
  PW=$(signing_password) || { echo "пароль связки не найден"; exit 1; }
  security unlock-keychain -p "$PW" "$KC" 2>/dev/null && echo "пароль подходит" || { echo "пароль не подходит"; exit 1; }
  security find-identity -p codesigning "$KC" | grep -q "pia local signing" && echo "сертификат найден" || { echo "сертификата нет"; exit 1; }
  exit 0
fi
SDKROOT=$SDK timeout 1200 swift build -c release
BIN=$(SDKROOT=$SDK swift build -c release --show-bin-path)/PiaChat
APP=build/pia.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN $APP/Contents/MacOS/pia-app   # исполняемый файл окна — pia-app: нигде не светится «PiaChat»
cp Resources/Info.plist $APP/Contents/Info.plist
# значок из Resources/icon-source.png
if [ ! -f build/AppIcon.icns ] || [ Resources/icon-source.png -nt build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset; mkdir -p build/AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/icon-source.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    s2=$((s*2)); sips -z $s2 $s2 Resources/icon-source.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
# службы launchd внутри бандла (SMAppService): macOS покажет их в «Объектах входа» одной строкой «pia» со значком приложения.
# Пути ~/.pi-agent в plist абсолютные (нельзя $HOME) — подставляются для текущего пользователя до подписи.
mkdir -p $APP/Contents/Library/LaunchAgents
for n in server chat; do
  sed "s|__HOME__|$HOME|g" ../launchd/com.pi-agent.$n.plist.template > $APP/Contents/Library/LaunchAgents/com.pi-agent.$n.plist
done
# рантайм: копия Node под именем «pia» внутри бандла. Служба, CLI и работяги запускаются этим бинарём, поэтому в Терминале
# («прервет процесс pia»), Мониторинге системы и Системных настройках (Запись экрана, Доступ к диску) вместо «node» видно «pia».
# Берётся тот Node, с которым стоят node_modules: PIA_NODE, иначе ~/.local/share/pi-node/current/bin/node, иначе node из PATH.
NODE_SRC=${PIA_NODE:-}
[ -x "$NODE_SRC" ] || NODE_SRC=$HOME/.local/share/pi-node/current/bin/node
[ -x "$NODE_SRC" ] || NODE_SRC=$(command -v node || true)
INST=~/Applications/pia.app
REUSE_RT=0
if [ "$FULL" != 1 ] && [ "$NOINST" != 1 ] && [ -x "$INST/Contents/MacOS/pia" ] && [ -x "$NODE_SRC" ]; then
  # рантайм не менялся? сравниваем установленный (без подписи) с исходным Node
  NS=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$NODE_SRC")
  T=$(mktemp); cp "$INST/Contents/MacOS/pia" $T; codesign --remove-signature $T 2>/dev/null
  cmp -s $T "$NS" && REUSE_RT=1; rm -f $T
fi
if [ "$REUSE_RT" = 1 ]; then
  cp -p "$INST/Contents/MacOS/pia" $APP/Contents/MacOS/pia   # тот же файл с той же подписью: cdhash рантайма не меняется
  echo "рантайм не менялся — оставлен как есть"
elif [ -x "$NODE_SRC" ]; then
  NODE_SRC=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$NODE_SRC")
  cp -f "$NODE_SRC" $APP/Contents/MacOS/pia
  chmod 755 $APP/Contents/MacOS/pia
  echo "рантайм: $NODE_SRC ($($APP/Contents/MacOS/pia -v)) → pia.app/Contents/MacOS/pia"
else
  echo "⚠ node не найден — рантайм pia в бандл не положен (служба будет работать через обычный node)"
fi
# подпись: постоянная личность из signing/pia-signing.keychain-db; если её нет — ad-hoc (права будут сбрасываться).
# Рантайм подписывается отдельно (codesign --deep не используем), тем же идентификатором и сертификатом, затем бандл.
# Без hardened runtime у рантайма: Node'у нужен JIT, а подпись самоподписанная — нотаризации всё равно нет.
KC=$PWD/signing/pia-signing.keychain-db
PW=$(signing_password || true)
if [ -f "$KC" ] && [ -n "$PW" ] && security unlock-keychain -p "$PW" "$KC" 2>/dev/null; then
  ID=$(security find-identity -p codesigning "$KC" | awk '/pia local signing/{print $2; exit}')
  [ "$REUSE_RT" = 1 ] || { [ -x $APP/Contents/MacOS/pia ] && codesign --force --entitlements Resources/pia.entitlements --keychain "$KC" -s "$ID" -i com.pi-agent.chat $APP/Contents/MacOS/pia; }
  codesign --force --options runtime --entitlements Resources/pia.entitlements --keychain "$KC" -s "$ID" -i com.pi-agent.chat $APP
else
  echo "нет signing/pia-signing.keychain-db — подписываю ad-hoc"
  [ "$REUSE_RT" = 1 ] || { [ -x $APP/Contents/MacOS/pia ] && codesign --force --entitlements Resources/pia.entitlements -s - -i com.pi-agent.chat $APP/Contents/MacOS/pia; }
  codesign --force --options runtime --entitlements Resources/pia.entitlements -s - -i com.pi-agent.chat $APP
fi
codesign -dvv $APP 2>&1 | grep -E "Identifier|Authority|Signature" || true
codesign -d -r- $APP 2>&1 | tail -1
if [ "$NOINST" != 1 ]; then
  U=$(id -u); OLD=~/Library/LaunchAgents; BK=~/.pi-agent/backups/legacy-agents-$(date +%Y%m%d-%H%M%S)
  for L in chat server memory; do
    if [ -f $OLD/com.pi-agent.$L.plist ]; then mkdir -p $BK; launchctl bootout gui/$U/com.pi-agent.$L 2>/dev/null || true; mv $OLD/com.pi-agent.$L.plist $BK/; fi
  done
  [ -d "$BK" ] && echo "старые plist перенесены в $BK"
  LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  I=~/Applications/pia.app
  SP=$I/Contents/Library/LaunchAgents/com.pi-agent.server.plist
  # сервер трогаем только при --full, если бандла нет, рантайм поменялся или изменился plist сервера
  if [ "$FULL" = 1 ] || [ ! -d "$I" ] || [ "$REUSE_RT" != 1 ] || ! cmp -s $APP/Contents/Library/LaunchAgents/com.pi-agent.server.plist "$SP"; then
    echo "полная установка: бандл целиком, обе службы (сервер перезапустится)"
    $I/Contents/MacOS/pia-app --unregister >/dev/null 2>&1 || true
    pkill -x pia-app 2>/dev/null && sleep 0.5 || true
    pkill -x PiaChat 2>/dev/null || true
    mkdir -p ~/Applications
    rm -rf $I
    ditto $APP $I
    $LSR -u $PWD/$APP 2>/dev/null || true; $LSR -f $I || true
    $I/Contents/MacOS/pia-app --register-only
  else
    echo "установка только окна: сервер и рантайм не трогаются"
    launchctl bootout gui/$U/com.pi-agent.chat 2>/dev/null || true
    pkill -x pia-app 2>/dev/null && sleep 0.5 || true
    # копируем только изменившееся; Contents/MacOS/pia не трогаем
    (cd $APP && find Contents -type f ! -path Contents/MacOS/pia) | while read f; do
      cmp -s "$APP/$f" "$I/$f" 2>/dev/null || { mkdir -p "$(dirname "$I/$f")"; cp -p "$APP/$f" "$I/$f"; }
    done
    $LSR -f $I || true
    codesign -v --deep --strict $I 2>&1 && echo "подпись бандла валидна" || echo "⚠ подпись бандла не проходит проверку"
    $I/Contents/MacOS/pia-app --register-only chat
  fi
  # окно (служба chat): ждём до 15 с; kickstart; при статусе 78/-9/LWCR — bootout + register chat + kickstart
  up() { for i in $(seq 15); do pgrep -x pia-app >/dev/null && return 0; sleep 1; done; return 1; }
  up || launchctl kickstart -k gui/$U/com.pi-agent.chat 2>/dev/null || true
  if ! up; then
    echo "окно не поднялось — bootout + регистрация chat + kickstart"
    launchctl bootout gui/$U/com.pi-agent.chat 2>/dev/null || true
    $I/Contents/MacOS/pia-app --unregister chat >/dev/null 2>&1 || true; sleep 1
    $I/Contents/MacOS/pia-app --register-only chat
    launchctl kickstart -k gui/$U/com.pi-agent.chat 2>/dev/null || true
    up && echo "окно запущено службой" || echo "⚠ окно не поднялось: launchctl print gui/$U/com.pi-agent.chat"
  fi
  echo "pia-app: $(pgrep -x pia-app | wc -l | tr -d ' ') процесс(ов)"
  echo "установлено: ~/Applications/pia.app (по умолчанию обновляется только окно; --full — и сервер)"
fi
