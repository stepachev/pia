#!/bin/zsh
# Сборка pia.app: swift build (SDK 26.5 — в SDK 27 у Command Line Tools нет плагина SwiftUIMacros для @State),
# бандл, значок, подпись постоянным самоподписанным сертификатом «pia local signing» (права macOS не сбрасываются),
# рантайм pia (копия Node в Contents/MacOS/pia, подписана вместе с бандлом),
# установка в ~/Applications/pia.app; службы server и chat — внутри бандла (Contents/Library/LaunchAgents, из ../launchd/*.plist.template), регистрация SMAppService.  Запуск: ./build.sh [--no-install]
set -e
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
if [ -x "$NODE_SRC" ]; then
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
  [ -x $APP/Contents/MacOS/pia ] && codesign --force --entitlements Resources/pia.entitlements --keychain "$KC" -s "$ID" -i com.pi-agent.chat $APP/Contents/MacOS/pia
  codesign --force --options runtime --entitlements Resources/pia.entitlements --keychain "$KC" -s "$ID" -i com.pi-agent.chat $APP
else
  echo "нет signing/pia-signing.keychain-db — подписываю ad-hoc"
  [ -x $APP/Contents/MacOS/pia ] && codesign --force --entitlements Resources/pia.entitlements -s - -i com.pi-agent.chat $APP/Contents/MacOS/pia
  codesign --force --options runtime --entitlements Resources/pia.entitlements -s - -i com.pi-agent.chat $APP
fi
codesign -dvv $APP 2>&1 | grep -E "Identifier|Authority|Signature" || true
codesign -d -r- $APP 2>&1 | tail -1
if [ "$1" != "--no-install" ]; then
  # Установка: старые службы (~/Library/LaunchAgents/com.pi-agent.*.plist, схема до SMAppService) выгружаются и уходят в бэкап,
  # окно и службы ставятся из бандла и регистрируются через SMAppService (pia-app --register-only; потом окно делает это само при запуске).
  U=$(id -u); OLD=~/Library/LaunchAgents; BK=~/.pi-agent/backups/legacy-agents-$(date +%Y%m%d-%H%M%S)
  for L in chat server memory; do
    if [ -f $OLD/com.pi-agent.$L.plist ]; then mkdir -p $BK; launchctl bootout gui/$U/com.pi-agent.$L 2>/dev/null || true; mv $OLD/com.pi-agent.$L.plist $BK/; fi
  done
  [ -d "$BK" ] && echo "старые plist перенесены в $BK"
  ~/Applications/pia.app/Contents/MacOS/pia-app --unregister >/dev/null 2>&1 || true
  pkill -x pia-app 2>/dev/null && sleep 0.5 || true
  pkill -x PiaChat 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/pia.app
  ditto $APP ~/Applications/pia.app
  LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  $LSR -u $PWD/$APP 2>/dev/null || true; $LSR -f ~/Applications/pia.app || true
  ~/Applications/pia.app/Contents/MacOS/pia-app --register-only
  # служба chat (окно) должна подняться сама: ждём до 15 с; если launchd не запустил (статус 78) — перерегистрация и kickstart
  up() { for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do pgrep -x pia-app >/dev/null && return 0; sleep 1; done; return 1; }
  if ! up; then
    echo "окно не поднялось службой — перерегистрация"
    ~/Applications/pia.app/Contents/MacOS/pia-app --unregister >/dev/null 2>&1 || true; sleep 2
    ~/Applications/pia.app/Contents/MacOS/pia-app --register-only
    up || launchctl kickstart -k gui/$U/com.pi-agent.chat 2>/dev/null || true
    up && echo "окно запущено службой" || echo "⚠ окно не поднялось: launchctl print gui/$U/com.pi-agent.chat"
  fi
  echo "установлено: ~/Applications/pia.app (службы server и chat — в бандле, через SMAppService; окно — двойной правый Option/Shift, pia://show, open -a pia)"
fi
