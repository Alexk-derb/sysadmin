#!/usr/bin/env bash
# validate-private-knowledge.sh — целостность графа приватного knowledge (ADR-0018).
#
# Использование: bash validate-private-knowledge.sh "$INFRA/knowledge"
#
# Проверки:
#   1. frontmatter заметок lessons/ и patterns/: обязательные ключи
#      (title, type, domain, date, status) + допустимые значения type/status;
#   2. битые [[wiki-ссылки]] по всем md-файлам knowledge/ (кроме _templates);
#   3. сироты индекса: заметка без строки в 00-index.md;
#   4. WARN: заметка > 80 строк (возможно, не атом — стоит поделить).
#
# Выход: 0 = PASS, 1 = FAIL (есть ошибки), 2 = неверный вызов.
# Совместимость: bash 3.2 (macOS) — без ассоциативных массивов; пути с пробелами — ок.

set -u

KDIR="${1:-}"
if [ -z "$KDIR" ]; then
  echo "Использование: $0 <путь к knowledge/>"
  exit 2
fi
if [ ! -d "$KDIR" ]; then
  echo "FAIL: каталог не найден: $KDIR"
  exit 2
fi

INDEX="$KDIR/00-index.md"
ERR=0
WARN=0

# --- 1 + 4. frontmatter и размер атомарных заметок --------------------------
while IFS= read -r f; do
  [ -z "$f" ] && continue

  if ! head -1 "$f" | grep -q '^---$'; then
    echo "ERROR: $f — нет frontmatter (первая строка не '---')"
    ERR=$((ERR + 1))
    continue
  fi

  fm=$(awk '/^---$/{n++; next} n==1{print} n>=2{exit}' "$f")

  for key in title type domain date status; do
    if ! printf '%s\n' "$fm" | grep -q "^${key}:"; then
      echo "ERROR: $f — нет обязательного ключа '${key}:'"
      ERR=$((ERR + 1))
    fi
  done

  if ! printf '%s\n' "$fm" | grep -Eq '^type: (lesson|pattern)[[:space:]]*$'; then
    echo "ERROR: $f — type не из словаря (lesson | pattern)"
    ERR=$((ERR + 1))
  fi
  if ! printf '%s\n' "$fm" | grep -Eq '^status: (active|superseded)[[:space:]]*$'; then
    echo "ERROR: $f — status не из словаря (active | superseded)"
    ERR=$((ERR + 1))
  fi

  lines=$(wc -l < "$f" | tr -d ' ')
  if [ "$lines" -gt 80 ]; then
    echo "WARN: $f — ${lines} строк (> ~80: возможно, заметка не атомарна)"
    WARN=$((WARN + 1))
  fi
done < <(find "$KDIR/lessons" "$KDIR/patterns" -name "*.md" -type f 2>/dev/null)

# --- 2. битые [[wiki-ссылки]] ------------------------------------------------
while IFS= read -r f; do
  [ -z "$f" ] && continue
  while IFS= read -r link; do
    [ -z "$link" ] && continue
    if [ ! -f "$KDIR/lessons/$link.md" ] && [ ! -f "$KDIR/patterns/$link.md" ] \
       && [ ! -f "$KDIR/$link.md" ]; then
      echo "ERROR: $f — битая ссылка [[${link}]]"
      ERR=$((ERR + 1))
    fi
  done < <(grep -o '\[\[[^]|]*' "$f" 2>/dev/null | sed 's/^\[\[//' | sort -u)
done < <(find "$KDIR" -name "*.md" -type f -not -path "*/_templates/*")

# --- 3. сироты индекса --------------------------------------------------------
if [ -f "$INDEX" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    slug=$(basename "$f" .md)
    if ! grep -q "\[\[${slug}\]\]" "$INDEX"; then
      echo "ERROR: ${slug} — заметка есть, строки в 00-index.md нет (потеряна для старта задачи)"
      ERR=$((ERR + 1))
    fi
  done < <(find "$KDIR/lessons" "$KDIR/patterns" -name "*.md" -type f 2>/dev/null)
else
  echo "ERROR: нет индекса $INDEX — вход в граф отсутствует"
  ERR=$((ERR + 1))
fi

# --- итог ---------------------------------------------------------------------
echo ""
if [ "$ERR" -eq 0 ]; then
  echo "PASS: граф целостен (ошибок 0, предупреждений ${WARN})"
  exit 0
else
  echo "FAIL: ошибок ${ERR}, предупреждений ${WARN}"
  exit 1
fi
