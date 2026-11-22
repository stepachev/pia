#!/bin/bash
# Установщик pia (macOS). Идемпотентный: повторный запуск ставит только недостающее.
#   ./install.sh            — установить (если уже стоит — только сообщит)
#   ./install.sh --check    — ничего не менять, показать, что было бы сделано
#   ./install.sh --update   — обновить код (git pull), зависимости и пересобрать окно (службу не перезапускает)
#   ./install.sh --render ПАПКА — только сгенерировать plist из шаблонов в ПАПКУ
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
UID_=$(id -u)
DRY=0; UPDATE=0; RENDER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check|--dry-run) DRY=1 ;;
    --update) UPDATE=1 ;;
    --render) RENDER="${2:-}"; shift ;;
    -h|--help) sed -n 2,7p "$0"; exit 0 ;;
    *) echo "неизвестный параметр: $1"; exit 2 ;;
  esac
  shift
done

ok()   { printf '  ✓ %s\n' "$*"; }
todo() { printf '  → %s\n' "$*"; }
warn() { printf '  ⚠ %s\n' "$*"; }
step() { printf '\n%s\n' "$*"; }
die()  { printf '  ✗ %s\n' "$*"; exit 1; }
# do: в режиме --check только сообщает; иначе выполняет
do_() { if [ "$DRY" = 1 ]; then todo "(проверка) было бы: $*"; return 0; fi; "$@"; }

# Рантайм pia: копия Node с именем «pia» внутри pia.app (его кладёт mac-app/build.sh). Служба, CLI и работяги запускаются им —
# в Терминале, Мониторинге и Системных настройках видно «pia», а не «node». Нет бандла (окно не собрано) — обычный Node.
runtime() {
  if [ -x "$HOME/Applications/pia.app/Contents/MacOS/pia" ]; then echo "$HOME/Applications/pia.app/Contents/MacOS/pia"; else echo "$HOME/.local/share/pi-node/current/bin/node"; fi
}
write_wrapper() {  # $1 — файл, $2 — аргументы после agent.mjs
  # Предохранитель (только для pia): единственный аргумент — существующий .mjs/.js/.cjs — запускаем рантаймом как node, в чат не шлём
  GUARD=""
  if [ -z "$2" ]; then GUARD='case "$#:$1" in 1:*.mjs|1:*.js|1:*.cjs) if [ -f "$1" ]; then echo "pia: запуск скрипта рантаймом pia" >&2; exec "$R" "$@"; fi;; esac'; fi
  cat > "$1" <<WRAP
#!/bin/sh
export NODE_NO_WARNINGS=1
export PATH="\$HOME/.pi-agent/runtime-bin:\$PATH"
R="\$HOME/Applications/pia.app/Contents/MacOS/pia"
[ -x "\$R" ] || R="\$HOME/.local/share/pi-node/current/bin/node"
$GUARD
exec "\$R" "\$HOME/.pi-agent/agent.mjs" $2"\$@"
WRAP
  chmod +x "$1"
}
render_plists() {  # $1 — папка назначения
  mkdir -p "$1"
  for n in server chat; do
    sed -e "s|__HOME__|$HOME|g" -e "s|__RUNTIME__|$(runtime)|g" "$ROOT/launchd/com.pi-agent.$n.plist.template" > "$1/com.pi-agent.$n.plist" || return 1
  done
}
if [ -n "$RENDER" ]; then render_plists "$RENDER" && echo "plist сгенерированы в $RENDER"; exit $?; fi

LAB="$HOME/Library/LaunchAgents"
NODE_DIR="$HOME/.local/share/pi-node"
NODE="$NODE_DIR/current/bin/node"
BIN="$HOME/.local/bin"
APP="$HOME/Applications/pia.app"
loaded() { launchctl print "gui/$UID_/$1" >/dev/null 2>&1; }

echo "pia — установка"
[ "$DRY" = 1 ] && echo "(режим проверки: ничего не меняется)"

# ── 1. система ──
step "1. Система"
[ "$(uname -s)" = Darwin ] || die "нужен macOS"
MACV=$(sw_vers -productVersion); MAJOR=${MACV%%.*}
[ "$MAJOR" -ge 13 ] 2>/dev/null || die "macOS $MACV слишком старая (нужна 13+)"
ARCH=$(uname -m)
ok "macOS $MACV, $ARCH"
[ "$ROOT" = "$HOME/.pi-agent" ] || die "репозиторий должен лежать в ~/.pi-agent (сейчас $ROOT). Выполни: git clone https://github.com/stepachev/pia.git ~/.pi-agent"

if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
  if [ "$DRY" = 1 ]; then todo "нет Command Line Tools — запустил бы xcode-select --install"; else
    xcode-select --install 2>/dev/null
    echo "  ⏳ Открылось окно установки Command Line Tools. Дождись окончания установки и запусти ./install.sh снова."
    exit 1
  fi
else
  ok "Command Line Tools установлены"
fi
SDKOK=0
for c in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk \
         /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk; do
  [ -d "$c" ] && { SDKOK=1; ok "SDK для окна: ${c##*/}"; break; }
done
[ "$SDKOK" = 1 ] || warn "нет SDK MacOSX 26.x (в SDK 27 сборка окна падает на @State). Терминальный pia заработает, окно — после установки Xcode или CLT с SDK 26"

# ── уже установлено? ──
if [ "$UPDATE" = 0 ] && [ -f "$ROOT/node_modules/.package-lock.json" ] && [ -x "$NODE" ] && [ -x "$BIN/pia" ] \
   && loaded com.pi-agent.server && [ -d "$APP" ] && [ -x "$APP/Contents/MacOS/pia-app" ] && loaded com.pi-agent.chat; then
  step "pia уже установлено"
  ok "служба com.pi-agent.server и окно com.pi-agent.chat работают"
  ALREADY=1
else
  ALREADY=0
fi

if [ "$ALREADY" = 0 ]; then
# ── 2. Node ──
step "2. Node.js"
if [ -x "$NODE" ]; then
  ok "есть: $("$NODE" -v)"
else
  MAJ=${PIA_NODE_MAJOR:-22}
  case "$ARCH" in arm64) NA=arm64 ;; x86_64) NA=x64 ;; *) die "неизвестная архитектура $ARCH" ;; esac
  if [ "$DRY" = 1 ]; then todo "скачал бы официальный Node $MAJ LTS ($NA) с nodejs.org в $NODE_DIR"; else
    BASE="https://nodejs.org/dist/latest-v$MAJ.x"
    SUMS=$(curl -fsSL --max-time 60 "$BASE/SHASUMS256.txt") || die "не удалось получить $BASE/SHASUMS256.txt (нет интернета?)"
    LINE=$(printf '%s\n' "$SUMS" | grep "darwin-$NA.tar.gz" | head -1)
    FILE=${LINE##* }; SUM=${LINE%% *}; NAME=${FILE%.tar.gz}
    [ -n "$FILE" ] || die "не нашёл сборку Node для darwin-$NA"
    TMP=$(mktemp -d)
    curl -fsSL --max-time 900 -o "$TMP/$FILE" "$BASE/$FILE" || die "не удалось скачать $FILE"
    [ "$(shasum -a 256 "$TMP/$FILE" | awk '{print $1}')" = "$SUM" ] || die "контрольная сумма $FILE не совпала"
    mkdir -p "$NODE_DIR"
    tar -xzf "$TMP/$FILE" -C "$NODE_DIR" || die "не распаковался $FILE"
    rm -rf "$TMP"
    ln -sfn "$NODE_DIR/$NAME" "$NODE_DIR/current"
    ok "Node установлен: $("$NODE" -v)"
  fi
fi
mkdir -p "$BIN"
for t in node npm npx; do
  [ -e "$BIN/$t" ] || { [ "$DRY" = 1 ] && todo "ссылка $BIN/$t" || ln -s "$NODE_DIR/current/bin/$t" "$BIN/$t"; }
done

# ── 3. зависимости ──
step "3. Зависимости (npm)"
export PATH="$NODE_DIR/current/bin:$PATH"
if [ "$UPDATE" = 1 ]; then
  if [ -d "$ROOT/.git" ]; then do_ git -C "$ROOT" pull --ff-only && ok "код обновлён"; fi
fi
if [ -f "$ROOT/node_modules/.package-lock.json" ] && [ "$UPDATE" = 0 ]; then
  ok "node_modules на месте"
else
  if [ "$DRY" = 1 ]; then todo "npm ci в ~/.pi-agent"; else
    if [ -f "$ROOT/package-lock.json" ]; then (cd "$ROOT" && timeout 900 npm ci --no-audit --no-fund >/dev/null 2>&1) || (cd "$ROOT" && timeout 900 npm install --no-audit --no-fund >/dev/null 2>&1) || die "npm не справился (см. npm install в ~/.pi-agent)"
    else (cd "$ROOT" && timeout 900 npm install --no-audit --no-fund >/dev/null 2>&1) || die "npm install не удался"; fi
    ok "зависимости установлены"
  fi
fi
mkdir -p "$ROOT/pia" 2>/dev/null
# пути в mcp.json могут быть прописаны под другого владельца — подставляем свой дом
OLD_HOME=$(grep -oE -m1 '/Users/[^/"]+' "$ROOT/mcp.json" 2>/dev/null | head -1)
if [ -n "$OLD_HOME" ] && [ "$OLD_HOME" != "$HOME" ]; then
  if [ "$DRY" = 1 ]; then todo "поправил бы пути в mcp.json на $HOME"; else
    sed -i '' "s|$OLD_HOME/|$HOME/|g" "$ROOT/mcp.json" && git -C "$ROOT" update-index --skip-worktree mcp.json 2>/dev/null
    ok "mcp.json: пути под $HOME"
  fi
fi

# ── 4. команда pia ──
step "4. Команда pia"
# обёртки запускают рантайм из pia.app (имя процесса «pia»); обновляются и у тех, у кого стояли старые (с node)
if [ -x "$BIN/pia" ] && grep -q 'runtime-bin' "$BIN/pia" && grep -q 'запуск скрипта' "$BIN/pia" && [ -x "$BIN/pia-login" ] && grep -q 'runtime-bin' "$BIN/pia-login"; then ok "$BIN/pia и pia-login на месте"; else
  if [ "$DRY" = 1 ]; then todo "создал бы $BIN/pia и $BIN/pia-login"; else
    # pia-login = то же меню выбора провайдера, что и `pia login` (agent.mjs → login.mjs); тот же ~/.pi/agent/auth.json
    write_wrapper "$BIN/pia" ""; write_wrapper "$BIN/pia-login" "login "
    ok "созданы $BIN/pia и $BIN/pia-login (pia-login открывает выбор провайдера)"
  fi
fi
if grep -qs '\.local/bin' "$HOME/.zshrc"; then ok "~/.local/bin уже в PATH (.zshrc)"; else
  if [ "$DRY" = 1 ]; then todo "добавил бы ~/.local/bin в PATH в ~/.zshrc"; else
    printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.zshrc"; ok "~/.local/bin добавлен в PATH (.zshrc; открой новое окно терминала)"
  fi
fi

# ── 5. окно и рантайм ──
step "5. Окно pia.app и рантайм pia"
SIGN="$ROOT/mac-app/signing"; KC="$SIGN/pia-signing.keychain-db"
if [ -f "$KC" ]; then ok "сертификат подписи есть"; else
  if [ "$DRY" = 1 ]; then todo "создал бы сертификат «pia local signing» и отдельную связку ключей (пароль — в Связке ключей macOS, служба pia-signing)"; else
    mkdir -p "$SIGN" && chmod 700 "$SIGN"
    PW=$(openssl rand -hex 16)
    ( cd "$SIGN" && cat > cert.cnf <<'CNF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN = pia local signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
      openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout key.pem -out cert.pem -config cert.cnf >/dev/null 2>&1 &&
      { openssl pkcs12 -export -inkey key.pem -in cert.pem -out pia.p12 -passout "pass:$PW" 2>/dev/null ||
        openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out pia.p12 -passout "pass:$PW" 2>/dev/null; } &&
      security add-generic-password -U -s pia-signing -a pia -w "$PW" &&
      security create-keychain -p "$PW" pia-signing.keychain-db &&
      security unlock-keychain -p "$PW" pia-signing.keychain-db &&
      security import pia.p12 -k pia-signing.keychain-db -P "$PW" -T /usr/bin/codesign >/dev/null &&
      security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" pia-signing.keychain-db >/dev/null 2>&1 &&
      rm -f key.pem pia.p12
    ) && ok "сертификат создан (пароль связки — в Связке ключей macOS)" || warn "сертификат не создан — окно подпишется ad-hoc (права macOS придётся выдавать после каждой сборки)"
    unset PW
  fi
fi
if [ -d "$APP" ] && [ -x "$APP/Contents/MacOS/pia-app" ] && loaded com.pi-agent.chat && [ "$UPDATE" = 0 ]; then ok "pia.app установлено, агент окна загружен"; else
  if [ "$SDKOK" = 0 ]; then warn "окно пропущено (нет SDK)"; elif [ "$DRY" = 1 ]; then todo "собрал бы окно (mac-app/build.sh) и поставил в ~/Applications/pia.app"; else
    echo "  … сборка окна (несколько минут)"
    if (cd "$ROOT/mac-app" && timeout 1500 ./build.sh >"$ROOT/mac-app/build.log" 2>&1); then ok "окно собрано и установлено (~/Applications/pia.app)"; else
      warn "окно не собралось — см. ~/.pi-agent/mac-app/build.log; терминальный pia работает"
    fi
  fi
fi
# ── 6. службы ──
step "6. Службы (внутри pia.app, SMAppService)"
# Службы server и chat лежат в pia.app/Contents/Library/LaunchAgents и регистрируются через SMAppService (их ставит build.sh;
# окно при каждом запуске перепроверяет). Память запускается изнутри службы server раз в 30 минут. В «Объектах входа» — одна строка «pia».
if [ -x "$APP/Contents/MacOS/pia-app" ]; then
  for L in com.pi-agent.server com.pi-agent.chat; do
    loaded $L && ok "$L загружена" || { do_ "$APP/Contents/MacOS/pia-app" --register-only >/dev/null; loaded $L && ok "$L зарегистрирована" || warn "$L не загрузилась: открой Системные настройки → Основные → Объекты входа и включи «pia»"; }
  done
else
  warn "pia.app не собрано — служба недоступна (нужен SDK 26.x; см. выше)"
fi
# старые plist предыдущих версий (~/Library/LaunchAgents/com.pi-agent.*.plist) build.sh переносит в ~/.pi-agent/backups/legacy-agents-*

fi  # ALREADY=0

# ── итог ──
step "Вход и разрешения"
AUTHF="$HOME/.pi/agent/auth.json"
if [ -s "$AUTHF" ] && grep -q '"anthropic"' "$AUTHF"; then
  ok "вход к провайдеру выполнен"; NEEDLOGIN=0
else
  NEEDLOGIN=1
  warn "нет входа к провайдеру модели. Выполни одну команду:   pia-login"
  echo "      (откроется браузер; потом запусти pia). Другой провайдер: pia-login openai — см. README"
fi
if [ "$ALREADY" = 0 ]; then
  # разрешения macOS выдаются в самом окне pia: мастер «Разрешения» — по одному, с пояснением, зачем каждое
  echo "  Откройте pia — она сама проведёт по разрешениям macOS (по одному, с пояснениями)."
  echo "      Открыть: Spotlight (⌘ Пробел) → pia, или команда: open -a pia"
  echo "      Мастер потом снова: команда /разрешения в окне pia или open pia://permissions"
  [ "$DRY" = 0 ] && [ -d "$APP" ] && open "pia://show" 2>/dev/null
else
  echo "  Обновить: ./install.sh --update    Удалить: ./uninstall.sh"
fi
echo
echo "Готово."
