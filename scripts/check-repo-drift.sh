#!/usr/bin/env bash
# check-repo-drift.sh — обнаружение расхождений между копиями репозиториев агента.
#
# Зачем: мозг (`sysadmin/`) и папки инфры оператора живут копиями на нескольких машинах и
# синхронизируются вручную. Ручная синхронизация тихо отстаёт: 2026-08-19 копия infra-spb на
# сервере оказалась «ahead 1, behind 17», и обнаружилось это случайно, а до того та же беда
# дважды попадала в todos оператора. Отставший inventory опаснее отсутствующего: агент
# рассуждает по позавчерашней карте и не знает об этом.
#
# Что делает: для мозга и каждого проекта из agent-config.json выполняет `git fetch` (только
# чтение!) и печатает, на сколько копия отстала и опередила свой remote, есть ли несохранённые
# правки. НИЧЕГО НЕ СЛИВАЕТ И НЕ КОММИТИТ — по замыслу: слияние inventory требует понимания
# смысла (два описания одного сервера конфликтуют содержанием, а не текстом), поэтому решение
# остаётся за человеком, а автоматизируется только обнаружение.
#
# Использование:
#   bash scripts/check-repo-drift.sh              # мозг + все проекты из agent-config.json
#   bash scripts/check-repo-drift.sh --no-fetch   # без сети: только уже известное состояние
#   bash scripts/check-repo-drift.sh /путь/к/репо # проверить конкретный каталог
#
# Код возврата:
#   0 — все проверенные копии в ногу и без несохранённых правок;
#   1 — где-то расхождение, несохранённые правки или состояние выяснить не удалось;
#   2 — ошибка запуска (нет git, нет конфига и не передан путь).
#
# Отказ объявляется громко: если fetch не прошёл (нет сети, нет ключа, remote недоступен),
# строка помечается «состояние неизвестно», а не выдаётся за «в ногу».

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
DO_FETCH=1
TARGETS=()

for arg in "$@"; do
    case "$arg" in
        --no-fetch) DO_FETCH=0 ;;
        -h|--help)  sed -n '2,28p' "${BASH_SOURCE[0]:-$0}"; exit 0 ;;
        *)          TARGETS+=("$arg") ;;
    esac
done

command -v git >/dev/null 2>&1 || { echo "check-repo-drift: git не найден" >&2; exit 2; }

# Собираем список проверяемых каталогов: аргументы либо мозг + projects[] из конфига.
if [ "${#TARGETS[@]}" -eq 0 ]; then
    TARGETS+=("$ROOT")
    cfg="$ROOT/agent-config.json"
    if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
        while IFS= read -r p; do
            # На Windows jq отдаёт строки с CR — без обрезки путь становится несуществующим,
            # и проверка молча рапортует «каталога нет» для существующей папки.
            p="${p%$'\r'}"
            [ -n "$p" ] && TARGETS+=("$p")
        done < <(jq -r '.projects[]?.infra_root // empty' "$cfg")
    elif [ ! -f "$cfg" ]; then
        echo "check-repo-drift: нет $cfg — проверяю только мозг. Путь можно передать аргументом." >&2
    fi
fi

DRIFT=0

# Тихий и неинтерактивный fetch: висящий запрос пароля хуже, чем честное «не удалось».
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=10}"

# Выравнивается только имя копии (оно из ASCII). Остальное идёт свободным текстом:
# printf считает БАЙТЫ, и кириллица в колонке ломает ширину — выравнивание врало бы.
printf '%-26s %s\n' "КОПИЯ" "СОСТОЯНИЕ · ПРАВКИ"
printf '%s\n' "──────────────────────────────────────────────────────────────────────────"

for dir in "${TARGETS[@]}"; do
    name="$(basename "$dir")"

    if [ ! -d "$dir" ]; then
        printf '%-26s %s\n' "$name" "каталога нет · $dir"
        DRIFT=1; continue
    fi
    if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
        printf '%-26s %s\n' "$name" "не git-репозиторий"
        DRIFT=1; continue
    fi

    dirty_n="$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$dirty_n" -gt 0 ]; then
        dirty="несохранённых: $dirty_n"
        DRIFT=1
    else
        dirty="чисто"
    fi

    branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
    if [ -z "$upstream" ]; then
        printf '%-26s %s\n' "$name" "нет upstream ($branch) · $dirty"
        DRIFT=1; continue
    fi

    fetch_failed=0
    if [ "$DO_FETCH" -eq 1 ]; then
        git -C "$dir" fetch --quiet 2>/dev/null || fetch_failed=1
    fi

    counts="$(git -C "$dir" rev-list --left-right --count "HEAD...$upstream" 2>/dev/null)"
    ahead="$(printf '%s' "$counts" | awk '{print $1}')"
    behind="$(printf '%s' "$counts" | awk '{print $2}')"
    ahead="${ahead:-?}"; behind="${behind:-?}"

    if [ "$fetch_failed" -eq 1 ]; then
        # Данные устарели ровно настолько, насколько давно был последний успешный fetch.
        state="состояние неизвестно"
        DRIFT=1
    elif [ "$ahead" = "0" ] && [ "$behind" = "0" ]; then
        state="в ногу"
    else
        state="отстал $behind, впереди $ahead"
        DRIFT=1
    fi

    printf '%-26s %s\n' "$name" "$state · $dirty"
done

printf '%s\n' "──────────────────────────────────────────────────────────────────────────"
if [ "$DRIFT" -eq 0 ]; then
    echo "Расхождений нет."
else
    echo "Есть расхождения. Слияние НЕ выполняется автоматически — разбирай вручную:"
    echo "  git -C <копия> log --oneline HEAD..@{u}   # что не забрано"
    echo "  git -C <копия> log --oneline @{u}..HEAD   # что не отдано"
    echo "  git -C <копия> pull --ff-only             # безопасно, если расхождение одностороннее"
fi
exit "$DRIFT"
