#!/bin/zsh
# Сборка pia.app: swift build (SDK 26.5 — в SDK 27 у Command Line Tools нет плагина SwiftUIMacros для @State),
# бандл, значок, подпись постоянным самоподписанным сертификатом «pia local signing» (права macOS не сбрасываются),
# установка в ~/Applications/pia.app + автозапуск (~/Library/LaunchAgents/com.pi-agent.chat.plist, из ../launchd/com.pi-agent.chat.plist.template).  Запуск: ./build.sh [--no-install]
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
cp $BIN $APP/Contents/MacOS/PiaChat
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
# подпись: постоянная личность из signing/pia-signing.keychain-db; если её нет — ad-hoc (права будут сбрасываться)
KC=$PWD/signing/pia-signing.keychain-db
PW=$(signing_password || true)
if [ -f "$KC" ] && [ -n "$PW" ] && security unlock-keychain -p "$PW" "$KC" 2>/dev/null; then
  ID=$(security find-identity -p codesigning "$KC" | awk '/pia local signing/{print $2; exit}')
  codesign --force --options runtime --entitlements Resources/pia.entitlements --keychain "$KC" -s "$ID" -i com.pi-agent.chat $APP
else
  echo "нет signing/pia-signing.keychain-db — подписываю ad-hoc"
  codesign --force --options runtime --entitlements Resources/pia.entitlements -s - -i com.pi-agent.chat $APP
fi
codesign -dvv $APP 2>&1 | grep -E "Identifier|Authority|Signature" || true
codesign -d -r- $APP 2>&1 | tail -1
if [ "$1" != "--no-install" ]; then
  # автозапуск: LaunchAgent com.pi-agent.chat (при входе — в фоне без окна, --hidden; при падении — перезапуск)
  AGENT=~/Library/LaunchAgents/com.pi-agent.chat.plist
  launchctl bootout gui/$(id -u)/com.pi-agent.chat 2>/dev/null || true
  pkill -x PiaChat 2>/dev/null && sleep 0.5 || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/pia.app
  ditto $APP ~/Applications/pia.app
  LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  $LSR -u $PWD/$APP 2>/dev/null || true; $LSR -f ~/Applications/pia.app || true
  TPL=${0:A:h}/../launchd/com.pi-agent.chat.plist.template
  [ -f "$TPL" ] || { echo "нет шаблона $TPL"; exit 1; }
  mkdir -p ~/Library/LaunchAgents
  sed "s|__HOME__|$HOME|g" "$TPL" > $AGENT
  launchctl bootstrap gui/$(id -u) $AGENT
  echo "установлено: ~/Applications/pia.app (работает в фоне; окно — двойное нажатие правого Shift, pia://show, open -a pia)"
fi
