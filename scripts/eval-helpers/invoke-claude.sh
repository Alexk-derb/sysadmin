#!/usr/bin/env bash
# invoke-claude.sh — один вызов claude -p для определения подходящего скилла.
#
# Использование:
#   ./invoke-claude.sh "<фраза оператора>"
#
# Вывод (stdout, одна строка):
#   <skill-name>|<cost-usd>|<duration-ms>
#   где skill-name — имя скилла (без префикса /) или "none"; cost — стоимость
#   в USD как число с точкой; duration — wall-clock мс.
#
# В случае ошибки (timeout, claude отвалился, не распарсился ответ) — выход 1,
# stderr с диагностикой.
#
# Запускать строго из корня репо sysadmin/ — иначе claude не увидит локальные
# скиллы.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 \"<phrase>\"" >&2
    exit 2
fi

phrase="$1"

# Проверка инструментов
command -v claude >/dev/null 2>&1 || { echo "error: claude CLI not in PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1     || { echo "error: jq not installed" >&2; exit 1; }

# Перечень РЕАЛЬНЫХ имён скиллов из репо. Критично: headless `claude -p` НЕ
# подгружает локальные скиллы проекта в контекст диспетчера, поэтому без явного
# списка модель ВЫДУМЫВАЕТ правдоподобные, но несуществующие имена (например
# «security-audit» вместо «audit-security», «install-3xui-panel» вместо
# «setup-vpn-panel»). Передаём закрытый список имён директорий .claude/skills/
# (где есть SKILL.md; _lib не скилл) — модель обязана выбрать точное имя из него.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILLS_DIR="$REPO_ROOT/.claude/skills"
skill_list=$(find "$SKILLS_DIR" -maxdepth 2 -name SKILL.md -exec dirname {} \; \
    | xargs -n1 basename | sort | paste -sd ', ' -)
if [[ -z "$skill_list" ]]; then
    echo "error: не найдено ни одного SKILL.md в $SKILLS_DIR" >&2
    exit 1
fi

# Жёсткий системный промпт. Цель: модель отвечает ровно одной строкой,
# содержащей "SKILL: <name>" или "SKILL: none". Парсим эту строку из
# поля .result JSON-ответа. Имя ОБЯЗАНО быть точно из переданного списка.
system_prompt="Ты диспетчер скиллов агента-сисадмина для репо sysadmin/. Доступные скиллы (выбирай ТОЛЬКО из этого закрытого списка, копируй имя ДОСЛОВНО, не придумывай и не перефразируй): ${skill_list}. На фразу оператора выбери ровно один скилл из этого списка, который должен быть активирован. Если ни один не подходит семантически — ответь \"SKILL: none\". Если подошли бы несколько — выбери самый точный по доминирующему намерению. Не выполняй ничего, не вызывай инструменты, не объясняй выбор. Ответ строго одной строкой формата: SKILL: <точное-имя-из-списка> (или SKILL: none). Никакого markdown, никакого текста до и после."

# Вызов headless, без сохранения сессии. Игнорируем stdin, чтобы не висеть.
response=$(claude -p "$phrase" \
    --output-format json \
    --no-session-persistence \
    --disable-slash-commands \
    --append-system-prompt "$system_prompt" \
    </dev/null 2>/dev/null) || {
        echo "error: claude -p failed for phrase: $phrase" >&2
        exit 1
    }

# Извлекаем поля. .result — строка модели, .total_cost_usd — стоимость,
# .duration_ms — wall-clock.
result=$(echo "$response" | jq -r '.result // ""')
cost=$(echo "$response"   | jq -r '.total_cost_usd // 0')
duration=$(echo "$response" | jq -r '.duration_ms // 0')

# Парсим "SKILL: <name>". Принимаем варианты с пробелами вокруг :.
skill=$(echo "$result" | grep -oE 'SKILL[[:space:]]*:[[:space:]]*[a-zA-Z0-9_-]+' | head -1 | sed -E 's/SKILL[[:space:]]*:[[:space:]]*//')

if [[ -z "$skill" ]]; then
    echo "error: could not parse SKILL: <name> from response: $result" >&2
    exit 1
fi

# Если модель ответила «несколько через запятую» вопреки промпту —
# возьмём первый. Грубо, но в edge-cases видно по полю result в логе.
echo "$skill|$cost|$duration"
