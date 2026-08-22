#!/usr/bin/env bash
# Проверяет схему реестра применений фильтра (todos/filter-log.md, ADR-0028).
#
# Реестр — знаменатель критерия отмены ступени. Без проверки схемы он вырождается
# в памятку: строка «чем подтверждено» размывается, число находок перестаёт
# восстанавливаться, а исход пишется свободным текстом. Проверяется то, что
# проверяемо машиной; полноту самоотчёта git доказать не может — это названный предел.
#
# Использование: validate-filter-log.sh [--root <путь>] [--file <путь>]

set -u

ROOT=""
FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT="$2"; shift 2 ;;
        --file) FILE="$2"; shift 2 ;;
        *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$FILE" ]; then
    [ -z "$ROOT" ] && ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
    FILE="$ROOT/todos/filter-log.md"
fi

if [ ! -f "$FILE" ]; then
    echo "✅ реестра нет ($FILE) — проверять нечего" >&2
    exit 0
fi

# Настоящий репозиторий для сверки хешей — независимо от того, откуда читается файл.
GITROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"

FAILS=0
fail() { echo "  ❌ $1" >&2; FAILS=$((FAILS+1)); }

echo "── validate-filter-log ─────────────────────────────" >&2
echo "файл: $FILE" >&2

# Строки записей: начинаются с даты в таблице.
ROWS="$(grep -nE '^\| *[0-9]{4}-[0-9]{2}-[0-9]{2} *\|' "$FILE" || true)"

if [ -z "$ROWS" ]; then
    echo "  ⚠️  записей нет — реестр пуст, счётчики должны быть нулевыми" >&2
fi

while IFS= read -r row; do
    [ -z "$row" ] && continue
    LN="${row%%:*}"
    LINE="${row#*:}"

    # 9 полей => 10 разделителей у строки вида | a | b | ... |
    NF="$(printf '%s' "$LINE" | awk -F'|' '{print NF-2}')"
    if [ "$NF" != "9" ]; then
        fail "строка $LN: полей $NF, схема требует 9 (дата, предмет, запуск, ревизия, начат, записан, исход, отчёт, доказательство)"
        continue
    fi

    REV="$(printf '%s' "$LINE" | awk -F'|' '{print $5}' | tr -d ' `')"
    OUTCOME="$(printf '%s' "$LINE" | awk -F'|' '{print $8}' | sed 's/^ *//; s/ *$//')"
    PROOF="$(printf '%s' "$LINE" | awk -F'|' '{print $10}' | sed 's/^ *//; s/ *$//')"

    # Ревизия — полный hash, а не сокращение: короткий не даёт однозначной привязки.
    # Ревизия — полный hash, а не сокращение: короткий не даёт однозначной привязки.
    if ! printf '%s' "$REV" | grep -qE '^[0-9a-f]{40}$'; then
        fail "строка $LN: ревизия «$REV» не 40-значный hash"
    elif [ -n "$GITROOT" ]; then
        # Ревизия обязана существовать: выдуманный hash — выдуманные данные (C.2).
        # Проверяется по НАСТОЯЩЕМУ репозиторию: при запуске из хука файл читается
        # из временного staged-снимка, где git-репозитория нет вовсе.
        if ! git -C "$GITROOT" cat-file -e "${REV}^{commit}" 2>/dev/null; then
            fail "строка $LN: коммита $REV нет в репозитории"
        fi
    fi

    # Исход — ровно из перечня; свободный текст запрещён.
    case "$OUTCOME" in
        clean) ;;
        blocking\(*\)) ;;
        aborted\(*\)) ;;
        skipped\(*\)) ;;
        *) fail "строка $LN: исход «$OUTCOME» вне перечня clean | blocking(K) | aborted(причина) | skipped(причина)" ;;
    esac

    # Число находок обязано восстанавливаться из доказательства: K точек с запятой + 1
    # даёт нижнюю оценку перечисленных пунктов. Проверяется не «красиво», а «есть ли K пунктов».
    case "$OUTCOME" in
        blocking\(*\))
            K="$(printf '%s' "$OUTCOME" | tr -dc '0-9')"
            ITEMS="$(printf '%s' "$PROOF" | awk -F';' '{print NF}')"
            if [ -z "$K" ] || [ "$K" -lt 1 ] 2>/dev/null; then
                fail "строка $LN: blocking без числа находок"
            elif [ "$ITEMS" -lt "$K" ] 2>/dev/null; then
                fail "строка $LN: заявлено находок $K, а в доказательстве перечислено $ITEMS — число не восстанавливается"
            fi
            ;;
        clean)
            [ "$PROOF" = "—" ] || [ -n "$PROOF" ] || fail "строка $LN: чистый исход без указания, чем проверено"
            ;;
    esac
done <<EOF
$ROWS
EOF

# Счётчики обязаны присутствовать явно: «сколько осталось до отмены» не должно
# высчитываться читателем в уме.
grep -q 'distinct_subjects' "$FILE" || fail "нет счётчика distinct_subjects"
grep -q 'clean_subjects'    "$FILE" || fail "нет счётчика clean_subjects"

echo "────────────────────────────────────────────────────" >&2
if [ "$FAILS" -eq 0 ]; then
    echo "PASS — реестр соответствует схеме." >&2
    exit 0
fi
echo "FAIL — нарушений схемы: $FAILS." >&2
exit 1
