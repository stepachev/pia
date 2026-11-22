#!/bin/bash
# Удаление pia: службы, окно, команды. ~/.pi-agent, память и вход к провайдеру НЕ удаляются.
set -u
UID_=$(id -u)
echo "pia — удаление"
"$HOME/Applications/pia.app/Contents/MacOS/pia-app" --unregister >/dev/null 2>&1
for L in com.pi-agent.chat com.pi-agent.server com.pi-agent.memory; do
  launchctl bootout "gui/$UID_/$L" 2>/dev/null
  rm -f "$HOME/Library/LaunchAgents/$L.plist"
  echo "  ✓ $L выгружена и удалена"
done
pkill -x pia-app; pkill -x PiaChat 2>/dev/null
rm -rf "$HOME/Applications/pia.app" && echo "  ✓ ~/Applications/pia.app удалено"
rm -f "$HOME/.local/bin/pia" "$HOME/.local/bin/pia-login" && echo "  ✓ команды pia и pia-login удалены"
cat <<'MSG'

Не тронуто: ~/.pi-agent (код, память pia/память, история), ~/.pi/agent/auth.json, Node в ~/.local/share/pi-node,
запись «pia-signing» в Связке ключей и mac-app/signing.
Удалить полностью (необратимо, память пропадёт):
  rm -rf ~/.pi-agent
  security delete-generic-password -s pia-signing
MSG
