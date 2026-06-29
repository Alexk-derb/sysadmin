#!/usr/bin/env bash
# reconfigure-write.sh — безопасное применение ТОЧЕЧНЫХ изменений к существующему конфигу
# (режим --reconfigure), БЕЗ пересборки из skeleton.
#
# ЗАЧЕМ (ADR-0019): assemble-configs.sh рассчитан на ПЕРВИЧНЫЙ setup (v1.0: один проект,
# один сервер) — он копирует skeleton и заполняет projects[0]/servers[0]. Если гонять его
# на --reconfigure, он ЗАТИРАЕТ всё, что не пересоздаёт: доп. проекты в мозге (projects[1+]),
# доп. серверы (servers[1+]) и опц. блоки карты, не переданные флагами (vpn, map). Реальный
# инцидент: правка одного флага backups затёрла бы второй проект и блок vpn.
#
# Этот скрипт патчит ТЕКУЩИЙ конфиг jq-фильтром (только изменённые ключи), всё остальное
# сохраняется как есть. Backup → jq-патч → валидация штатным validate-config.sh → write
# или ГРОМКИЙ откат (C.9: при невалидности конфиг НЕ трогаем, суррогат не пишем).
#
# Использование:
#   reconfigure-write.sh <agent|infra> <config_path> <jq_filter>
#     <agent|infra>  — какой схемой валидировать (мозг или карта).
#     <config_path>  — путь к РЕАЛЬНОМУ конфигу, который патчим на месте.
#     <jq_filter>    — выражение jq, применяемое к текущему конфигу. Меняет ТОЛЬКО нужные
#                      ключи, например: '.backups = {enabled:true, destination:"remote-sftp",
#                      remote_host:"host:/path", retention:{daily:7,weekly:4,monthly:6}}'
#                      или для мозга: '(.projects[] | select(.id=="proj")).title = "Новое"'
# Возврат: 0 — пропатчено, валидно, записано (печатает путь .bak); 1 — ошибка/невалидно (откат).
set -uo pipefail

KIND="${1:-}"; CFG="${2:-}"; FILTER="${3:-}"
case "$KIND" in agent|infra) : ;; *) echo "STOP: первый аргумент — agent|infra (получено '$KIND')" >&2; exit 1 ;; esac
[ -n "$CFG" ] && [ -f "$CFG" ] || { echo "STOP: нет конфига: $CFG" >&2; exit 1; }
[ -n "$FILTER" ] || { echo "STOP: пустой jq-фильтр" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "STOP: нет jq" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/validate-config.sh"
[ -f "$VALIDATOR" ] || { echo "STOP: не найден validate-config.sh рядом" >&2; exit 1; }

ts="$(date -u +%Y%m%d-%H%M%S)"
draft="${CFG}.reconf.${ts}.tmp"

if ! jq "$FILTER" "$CFG" > "$draft" 2>"${draft}.err"; then
    echo "STOP: jq-фильтр не применился — конфиг НЕ изменён:" >&2
    cat "${draft}.err" >&2; rm -f "$draft" "${draft}.err"; exit 1
fi
rm -f "${draft}.err"

if ! bash "$VALIDATOR" "--$KIND" "$draft"; then
    echo "STOP: патч не прошёл валидацию по схеме — конфиг НЕ изменён (C.9)." >&2
    rm -f "$draft"; exit 1
fi

cp "$CFG" "${CFG}.bak.${ts}"
mv "$draft" "$CFG"
echo "OK: $CFG пропатчен и валиден (.bak: ${CFG}.bak.${ts})"
