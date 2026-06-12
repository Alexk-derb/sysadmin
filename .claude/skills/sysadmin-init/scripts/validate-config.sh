#!/usr/bin/env bash
# validate-config.sh — валидация конфигов агента по JSON Schema (ADR-0013: ДВА файла).
#
# После расщепления (ADR-0013) конфиг — это ДВА файла с разными схемами:
#   • agent-config.json (МОЗГ агента, живёт в sysadmin/) ← agent-config.schema.json
#   • infra-config.json (КАРТА инфры, живёт в папке проекта) ← infra-config.schema.json
#
# Использование:
#   validate-config.sh                                   # авто-поиск обоих файлов
#   validate-config.sh /path/to/agent-config.json        # валидировать ОДИН файл
#                                                         # (тип схемы — по имени файла)
#   validate-config.sh /path/agent-config.json /path/infra-config.json
#                                                         # явные пути к обоим draft-файлам
#   validate-config.sh --agent  /path/agent-config-draft.json   # явно: agent-схема
#   validate-config.sh --infra  /path/infra-config-draft.json   # явно: infra-схема
#
# Тип схемы для одиночного файла определяется по имени:
#   *agent-config*  → agent-config.schema.json
#   *infra-config*  → infra-config.schema.json
#   *sysadmin-config* (legacy всё-в-одном) → проверяется как infra-схема + предупреждение.
#
# Возврат:
#   0 — все переданные файлы валидны.
#   1 — хотя бы один файл не валиден (или не найден).
#   2 — нет утилит для валидации (jq не установлен).
#
# Способы валидации каждого файла:
#   1) check-jsonschema (предпочтительный) — если установлен.
#   2) jq-fallback — минимальная проверка обязательных полей и enum'ов.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSADMIN_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
AGENT_SCHEMA="$SYSADMIN_ROOT/agent-config.schema.json"
INFRA_SCHEMA="$SYSADMIN_ROOT/infra-config.schema.json"

# ──────────────────────────────────────────────────────────────────────────
# Определить «вид» файла по имени: agent | infra | legacy
_kind_by_name() {
    case "$1" in
        *agent-config*)    echo "agent" ;;
        *infra-config*)    echo "infra" ;;
        *sysadmin-config*) echo "legacy" ;;
        *)                 echo "unknown" ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────
# validate_agent FILE — валидация файла МОЗГА по agent-config.schema.json
validate_agent() {
    local cfg="$1"
    [ -f "$cfg" ] || { echo "ERROR: $cfg не существует"; return 1; }
    [ -f "$AGENT_SCHEMA" ] || { echo "ERROR: схема $AGENT_SCHEMA не найдена"; return 1; }

    if command -v check-jsonschema >/dev/null 2>&1; then
        check-jsonschema --schemafile "$AGENT_SCHEMA" "$cfg"
        return $?
    fi

    echo "(i) check-jsonschema не установлен — jq-проверка agent-config ($cfg)."
    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: jq не установлен. brew install jq (macOS) или apt-get install jq (Linux)."
        return 2
    fi

    # Обязательные поля верхнего уровня
    local field
    for field in version operator projects default_project; do
        if ! jq -e --arg f "$field" 'has($f)' "$cfg" >/dev/null 2>&1; then
            echo "FAIL [agent]: отсутствует обязательное поле .$field"
            return 1
        fi
    done

    # version === "1.0"
    local ver; ver=$(jq -r '.version' "$cfg")
    [ "$ver" = "1.0" ] || { echo "FAIL [agent]: version = $ver, ожидалось \"1.0\""; return 1; }

    # operator.name / operator.timezone — непустые
    local op_name op_tz op_lang
    op_name=$(jq -r '.operator.name // ""' "$cfg")
    [ -z "$op_name" ] && { echo "FAIL [agent]: operator.name пуст"; return 1; }
    op_tz=$(jq -r '.operator.timezone // ""' "$cfg")
    [ -z "$op_tz" ] && { echo "FAIL [agent]: operator.timezone пуст"; return 1; }
    # operator.language ∈ {ru, en}
    op_lang=$(jq -r '.operator.language // ""' "$cfg")
    case "$op_lang" in
        ru|en) ;;
        *) echo "FAIL [agent]: operator.language = $op_lang, ожидалось ru или en"; return 1 ;;
    esac

    # secrets.manager (если блок есть) — из enum
    if jq -e 'has("secrets")' "$cfg" >/dev/null 2>&1; then
        local mgr; mgr=$(jq -r '.secrets.manager // ""' "$cfg")
        case "$mgr" in
            keychain|bitwarden|1password|pass|keepassxc) ;;
            other)
                local mgr_name; mgr_name=$(jq -r '.secrets.manager_name // ""' "$cfg")
                [ -z "$mgr_name" ] && { echo "FAIL [agent]: secrets.manager=other без secrets.manager_name"; return 1; }
                ;;
            *) echo "FAIL [agent]: secrets.manager = $mgr, ожидалось keychain|bitwarden|1password|pass|keepassxc|other"; return 1 ;;
        esac
    fi

    # projects — непустой массив, каждый с id+infra_root
    local plen; plen=$(jq -r '.projects | length' "$cfg" 2>/dev/null)
    [ -z "$plen" ] && plen=0
    if [ "$plen" -lt 1 ]; then
        echo "FAIL [agent]: projects — пустой массив, должен содержать ≥ 1 проект"
        return 1
    fi
    local i val
    for i in $(seq 0 $((plen - 1))); do
        for field in id infra_root; do
            val=$(jq -r ".projects[$i].$field // \"\"" "$cfg")
            [ -z "$val" ] && { echo "FAIL [agent]: .projects[$i].$field пуст или отсутствует"; return 1; }
        done
    done

    # default_project совпадает с одним из projects[].id
    local def; def=$(jq -r '.default_project // ""' "$cfg")
    [ -z "$def" ] && { echo "FAIL [agent]: default_project пуст"; return 1; }
    local match; match=$(jq -r --arg id "$def" 'any(.projects[]?; .id == $id)' "$cfg")
    [ "$match" = "true" ] || { echo "FAIL [agent]: default_project='$def' не найден среди projects[].id"; return 1; }

    echo "PASS [agent]: jq-fallback подтвердил минимальные требования agent-config."
    return 0
}

# ──────────────────────────────────────────────────────────────────────────
# validate_infra FILE — валидация файла КАРТЫ по infra-config.schema.json
validate_infra() {
    local cfg="$1"
    [ -f "$cfg" ] || { echo "ERROR: $cfg не существует"; return 1; }
    [ -f "$INFRA_SCHEMA" ] || { echo "ERROR: схема $INFRA_SCHEMA не найдена"; return 1; }

    if command -v check-jsonschema >/dev/null 2>&1; then
        check-jsonschema --schemafile "$INFRA_SCHEMA" "$cfg"
        return $?
    fi

    echo "(i) check-jsonschema не установлен — jq-проверка infra-config ($cfg)."
    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: jq не установлен. brew install jq (macOS) или apt-get install jq (Linux)."
        return 2
    fi

    # Обязательные поля верхнего уровня
    local field
    for field in version monitoring backups notifications servers; do
        if ! jq -e --arg f "$field" 'has($f)' "$cfg" >/dev/null 2>&1; then
            echo "FAIL [infra]: отсутствует обязательное поле .$field"
            return 1
        fi
    done

    # version === "1.0"
    local ver; ver=$(jq -r '.version' "$cfg")
    [ "$ver" = "1.0" ] || { echo "FAIL [infra]: version = $ver, ожидалось \"1.0\""; return 1; }

    # *.enabled — boolean
    local path type
    for path in '.monitoring.enabled' '.backups.enabled' '.notifications.telegram.enabled'; do
        type=$(jq -r "$path | type" "$cfg" 2>/dev/null)
        [ "$type" = "boolean" ] || { echo "FAIL [infra]: $path должен быть boolean, найден $type"; return 1; }
    done

    # servers — непустой массив, каждый с alias/ssh_alias/role
    local slen; slen=$(jq -r '.servers | length' "$cfg")
    if [ "$slen" -lt 1 ]; then
        echo "FAIL [infra]: servers — пустой массив, должен содержать ≥ 1 сервер"
        return 1
    fi
    local i val
    for i in $(seq 0 $((slen - 1))); do
        for field in alias ssh_alias role; do
            val=$(jq -r ".servers[$i].$field // \"\"" "$cfg")
            [ -z "$val" ] && { echo "FAIL [infra]: .servers[$i].$field пуст или отсутствует"; return 1; }
        done
    done

    echo "PASS [infra]: jq-fallback подтвердил минимальные требования infra-config."
    return 0
}

# ──────────────────────────────────────────────────────────────────────────
# Диспетчер по аргументам.

RC=0

if [ "$#" -eq 0 ]; then
    # Авто-поиск обоих файлов через общий helper.
    source "$SYSADMIN_ROOT/.claude/skills/_lib/find-config.sh"

    # 1) Мозг — agent-config.json
    if find_brain_config; then
        echo "→ Валидация мозга: $BRAIN_CONFIG"
        validate_agent "$BRAIN_CONFIG" || RC=1
        # 2) Карта активного проекта — infra-config.json
        if resolve_active_project ""; then
            echo "→ Валидация инфры: $ACTIVE_INFRA_CONFIG"
            validate_infra "$ACTIVE_INFRA_CONFIG" || RC=1
        else
            echo "ERROR: не удалось разрешить активный проект (infra-config.json не найден)."
            RC=1
        fi
    else
        # Мозга нет — может, старая установка (legacy всё-в-одном) или первый запуск.
        find_sysadmin_config strict   # exit 1 если совсем ничего нет
        echo "→ Валидация конфига: $CONFIG"
        case "$(_kind_by_name "$CONFIG")" in
            agent) validate_agent "$CONFIG" || RC=1 ;;
            *)     validate_infra "$CONFIG" || RC=1 ;;
        esac
    fi
    exit $RC
fi

# Явный режим: --agent FILE / --infra FILE
case "$1" in
    --agent) shift; validate_agent "$1"; exit $? ;;
    --infra) shift; validate_infra "$1"; exit $? ;;
esac

# Позиционные пути: один или два файла, тип — по имени.
for cfg in "$@"; do
    kind="$(_kind_by_name "$cfg")"
    echo "→ Валидация ($kind): $cfg"
    case "$kind" in
        agent)  validate_agent "$cfg" || RC=1 ;;
        infra)  validate_infra "$cfg" || RC=1 ;;
        legacy)
            echo "WARN: $cfg — старый формат sysadmin-config.json (всё-в-одном)."
            echo "      Проверяю как infra-схему; рекомендую миграцию через /sysadmin-init."
            validate_infra "$cfg" || RC=1
            ;;
        *)
            echo "WARN: не распознал тип '$cfg' по имени. Пробую обе схемы — пройдёт хотя бы одна?"
            if validate_agent "$cfg" >/dev/null 2>&1; then
                echo "  → валиден как agent-config."
            elif validate_infra "$cfg" >/dev/null 2>&1; then
                echo "  → валиден как infra-config."
            else
                echo "FAIL: $cfg не валиден ни по agent-, ни по infra-схеме."
                RC=1
            fi
            ;;
    esac
done

exit $RC
