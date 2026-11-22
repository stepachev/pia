#!/bin/bash
# Ручное сохранение кода pia в репозиторий GitHub (белый список в .gitignore).
cd "$HOME/.pi-agent" || exit 1
mkdir -p launchd
git add -A
PAT='sk-ant|sk-[A-Za-z0-9]{10}|ghp_|gho_|github_pat_|xoxb|BEGIN [A-Z ]*PRIVATE KEY|password|пароль|api_key|apiKey|secret|@gmail\.com'
# личные шаблоны — в файле вне git (по строке на шаблон)
EXTRA="$HOME/.pi-agent/secrets/save-patterns.txt"
[ -f "$EXTRA" ] && PAT="$PAT|$(grep -v '^[[:space:]]*$' "$EXTRA" | paste -sd'|' -)"
HITS=$(git diff --cached --name-only --diff-filter=AM -z | xargs -0 -I{} git diff --cached -U0 -- {} ":(exclude)save.sh" ":(exclude)install.sh" ":(exclude)uninstall.sh" ":(exclude)mac-app/build.sh" 2>/dev/null | grep -E '^\+[^+]' | grep -iE "$PAT" | cut -c1-120)
if [ -n "$HITS" ]; then
  git reset -q
  echo "СТОП: похоже на секрет в добавляемых строках, ничего не сохранено:"; echo "$HITS"; exit 1
fi
if git diff --cached --quiet; then echo "изменений нет"; exit 0; fi
N=$(git diff --cached --name-only | wc -l | tr -d ' ')
git commit -q -m "сохранение $(date '+%Y-%m-%d %H:%M')" || exit 1
if git push -q origin main 2>&1; then echo "сохранено: файлов изменено $N"; else echo "закоммичено локально, но push не удался"; exit 1; fi
