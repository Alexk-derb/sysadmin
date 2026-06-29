#!/usr/bin/env bash
# assemble-configs.sh — сборка ДВУХ draft-конфигов из ответов интервью (Шаг 8 скилла).
#
# Читает ответы оператора из ПЕРЕМЕННЫХ ОКРУЖЕНИЯ (агент выставляет их по ответам
# AskUserQuestion из Раундов 1–6.5), берёт два skeleton'а и доливает значения.
# На выходе — $WORKDIR/agent-config-draft.json (мозг) + infra-config-draft.json (карта).
# Дальше скилл идёт на Шаг 9 (валидация) → Шаг 10 (превью + запись).
#
# Использование:
#   NAME=... LANG=ru TIMEZONE=... MANAGER=keychain PROJ_ID=... PROJ_INFRA_ROOT=... \
#   SRV_ALIAS=... SRV_SSH=... SRV_ROLE=production \
#   [MON_ENABLED=true MON_STACK_JSON='["uptime-kuma","beszel"]' MON_PANEL_DOMAIN=...] \
#   [BACKUPS_ENABLED=true BACKUPS_DESTINATION=yandex-disk-webdav \
#     BACKUPS_RETENTION_JSON='{"daily":7,"weekly":4,"monthly":6}' BACKUPS_RCLONE_REMOTE=yandex-disk \
#     BACKUPS_REMOTE_HOST=iiservertim:/backup/srv-spb-restic] \
#   [TG_ENABLED=true TG_BOT_USERNAME=mybot TG_CHAT_TYPE=personal] \
#   [VPN_ENABLED=true [VPN_REALITY_DEST=www.cloudflare.com]] \
#   assemble-configs.sh <workdir> [<sysadmin_root>]
#
# Контракт переменных (мозг): NAME, LANG(ru|en), TIMEZONE, MANAGER(enum),
#   CLI_AVAILABLE(true|false; для известных менеджеров выставляется автоматически),
#   MANAGER_NAME(для manager=other), PROJ_ID, PROJ_TITLE(опц., ""→без title), PROJ_INFRA_ROOT.
# Контракт переменных (карта): SRV_ALIAS, SRV_SSH, SRV_ROLE(enum), SRV_DOMAIN(опц.),
#   MON_*, BACKUPS_* (retention — ОБЪЕКТ {daily,weekly,monthly}, НЕ строка!), TG_*, VPN_*.
#
# Возврат: 0 — оба draft'а собраны; 1 — нет аргументов / нет jq / не хватает обязательного поля.

set -u

WORKDIR="${1:-}"
SYSADMIN_ROOT="${2:-${SYSADMIN_ROOT:-}}"

[ -n "$WORKDIR" ] || { echo "ERROR: usage: assemble-configs.sh <workdir> [<sysadmin_root>]" >&2; exit 1; }
[ -d "$WORKDIR" ] || { echo "ERROR: нет каталога WORKDIR: $WORKDIR" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq не найден" >&2; exit 1; }

# Корень репо — для skeleton'ов. Если не передан/не задан — выводим от расположения скрипта.
if [ -z "$SYSADMIN_ROOT" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    SYSADMIN_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
fi
TPL="$SYSADMIN_ROOT/.claude/skills/sysadmin-init/templates"
[ -f "$TPL/agent-config-skeleton.json" ] || { echo "ERROR: не найден skeleton мозга: $TPL/agent-config-skeleton.json" >&2; exit 1; }

# Проверка обязательных полей (раньше тихих jq-падений).
for v in NAME LANG TIMEZONE MANAGER PROJ_ID PROJ_INFRA_ROOT SRV_ALIAS SRV_SSH SRV_ROLE; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || { echo "ERROR: не задана обязательная переменная окружения: $v" >&2; exit 1; }
done

AGENT_DRAFT="$WORKDIR/agent-config-draft.json"
INFRA_DRAFT="$WORKDIR/infra-config-draft.json"
_x="$WORKDIR/.assemble.tmp"
_apply() { mv "$_x" "$1"; }   # $1 = целевой draft

# ── Мозг (agent-config-draft.json) ────────────────────────────────────────────
cp "$TPL/agent-config-skeleton.json" "$AGENT_DRAFT"

# operator
jq --arg n "$NAME" --arg l "$LANG" --arg tz "$TIMEZONE" \
   '.operator.name=$n | .operator.language=$l | .operator.timezone=$tz' \
   "$AGENT_DRAFT" > "$_x" && _apply "$AGENT_DRAFT"

# secrets: для известных менеджеров CLI есть всегда → cli_available=true; для other — из ресёрча.
case "$MANAGER" in
    keychain|bitwarden|1password|pass|keepassxc) CLI_AVAILABLE=true ;;
    other) CLI_AVAILABLE="${CLI_AVAILABLE:-false}" ;;
    *) echo "ERROR: неизвестный MANAGER='$MANAGER' (не из enum схемы)" >&2; exit 1 ;;
esac
jq --arg m "$MANAGER" --argjson cli "$CLI_AVAILABLE" \
   '.secrets.manager=$m | .secrets.cli_available=$cli' "$AGENT_DRAFT" > "$_x" && _apply "$AGENT_DRAFT"
if [ "$MANAGER" = "other" ]; then
    jq --arg mn "${MANAGER_NAME:-}" '.secrets.manager_name=$mn' "$AGENT_DRAFT" > "$_x" && _apply "$AGENT_DRAFT"
fi

# projects[0] + default_project ($PROJ_TITLE опционален: ""→удалить ключ title)
jq --arg id "$PROJ_ID" --arg title "${PROJ_TITLE:-}" --arg root "$PROJ_INFRA_ROOT" '
    .projects[0].id=$id
  | (if $title=="" then .projects[0]|=del(.title) else .projects[0].title=$title end)
  | .projects[0].infra_root=$root
  | .default_project=$id' "$AGENT_DRAFT" > "$_x" && _apply "$AGENT_DRAFT"
# meta остаётся из skeleton (onboarding_completed:false). Финал ставит вопрос про знакомство.

# ── Карта (infra-config-draft.json) ───────────────────────────────────────────
cp "$TPL/infra-config-skeleton.json" "$INFRA_DRAFT"

case "$SRV_ROLE" in production|staging|test|personal) : ;;
    *) echo "ERROR: SRV_ROLE='$SRV_ROLE' не из enum (production/staging/test/personal)" >&2; exit 1 ;; esac
jq --arg a "$SRV_ALIAS" --arg s "$SRV_SSH" --arg r "$SRV_ROLE" \
   '.servers=[{alias:$a, ssh_alias:$s, role:$r}]' "$INFRA_DRAFT" > "$_x" && _apply "$INFRA_DRAFT"
[ -n "${SRV_DOMAIN:-}" ] && { jq --arg d "$SRV_DOMAIN" '.servers[0].domain=$d' "$INFRA_DRAFT" > "$_x" && _apply "$INFRA_DRAFT"; }

# monitoring (только при enabled=true)
if [ "${MON_ENABLED:-false}" = "true" ]; then
    jq --argjson stack "${MON_STACK_JSON:-[]}" --arg pd "${MON_PANEL_DOMAIN:-}" \
       '.monitoring={enabled:true, stack:$stack, panel_domain:$pd}' "$INFRA_DRAFT" > "$_x" && _apply "$INFRA_DRAFT"
fi

# backups (только при enabled=true). retention — ОБЪЕКТ {daily,weekly,monthly}.
if [ "${BACKUPS_ENABLED:-false}" = "true" ]; then
    # Дефолт retention задаём отдельной строкой: фигурные скобки внутри ${var:-...}
    # ломают разбор параметра (первая } закрывает выражение раньше времени).
    _ret="${BACKUPS_RETENTION_JSON:-}"
    [ -z "$_ret" ] && _ret='{"daily":7,"weekly":4,"monthly":6}'
    jq --arg dest "${BACKUPS_DESTINATION:-}" --argjson ret "$_ret" \
       '.backups={enabled:true, destination:$dest, retention:$ret}' "$INFRA_DRAFT" > "$_x" && _apply "$INFRA_DRAFT"
    # rclone_remote — для webdav-destination'ов.
    [ -n "${BACKUPS_RCLONE_REMOTE:-}" ] && { jq --arg rr "$BACKUPS_RCLONE_REMOTE" \
        '.backups.rclone_remote=$rr' "$INFRA_DRAFT" > "$_x" && _apply "$INFRA_DRAFT"; }
    # remote_host — указатель на сервер-приёмник для destination=remote-sftp (опц., без секретов).
    [ -n "${BACKUPS_REMOTE_HOST:-}" ] && { jq --arg rh "$BACKUPS_REMOTE_HOST" \
        '.backups.remote_host=$rh' "$INFRA_DRAFT" > "$_x" && _apply "$INFRA_DRAFT"; }
fi

# notifications.telegram (только при enabled=true)
if [ "${TG_ENABLED:-false}" = "true" ]; then
    jq --arg bu "${TG_BOT_USERNAME:-}" --arg ct "${TG_CHAT_TYPE:-personal}" \
       '.notifications.telegram={enabled:true, bot_username:$bu, chat_type:$ct}' "$INFRA_DRAFT" > "$_x" && _apply "$INFRA_DRAFT"
fi

# vpn (только если оператор готовит секцию). Значения-флаги; конкретику впишут VPN-скиллы.
if [ "${VPN_ENABLED:-false}" = "true" ]; then
    jq --arg rd "${VPN_REALITY_DEST:-www.cloudflare.com}" '.vpn={
        enabled:false, panel_url:null, panel_web_base_path:null,
        server_proxy_enabled:false, upstream_kind:"none", default_reality_dest:$rd
      }' "$INFRA_DRAFT" > "$_x" && _apply "$INFRA_DRAFT"
fi

# Страховка ADR-0013: в карте не должно быть агент-полей (если просочились — убрать).
jq 'del(.operator, .language, .secrets, .infrastructure)' "$INFRA_DRAFT" > "$_x" && _apply "$INFRA_DRAFT"

rm -f "$_x"
echo "→ собраны draft'ы: $AGENT_DRAFT , $INFRA_DRAFT"
