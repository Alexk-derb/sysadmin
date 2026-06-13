#!/usr/bin/env bash
# write-configs.sh — финальная запись ОБОИХ конфигов на место + FINAL CHECK (Шаги 10/10.5).
#
# Вызывается ТОЛЬКО после того, как оператор подтвердил превью («Да, сохранить»).
# Берёт два draft'а из $WORKDIR, вычисляет целевые пути, делает backup существующих
# версий, кладёт файлы и проверяет, что они РЕАЛЬНО на диске и валидны по схемам.
#
# Использование:
#   write-configs.sh <workdir> <sysadmin_root> [<legacy_path_для_миграции>]
#
# Логика путей:
#   мозг  → <sysadmin_root>/agent-config.json
#   карта → <infra_root>/infra-config.json, где infra_root = projects[0].infra_root
#           из draft'а мозга (tilde раскрывается, путь нормализуется в абсолютный и
#           переписывается обратно в draft — реестр не привязан к cwd).
#
# Поведение:
#   • существующие agent-config.json / infra-config.json → backup `.bak.YYYYMMDD-HHMMSS`;
#   • <legacy_path> (если передан и существует) → переименовывается в `.bak.TS` (путь к откату);
#   • FINAL CHECK: оба файла существуют + проходят validate-config.sh. Иначе — ГРОМКИЙ
#     отказ (C.9: не притворяться «готово», не импровизировать суррогат).
#
# Возврат: 0 — оба файла записаны и валидны; 1 — ошибка (нет аргументов / не создалась
#   папка инфры / запись провалилась / файл не прошёл валидацию).

set -u

WORKDIR="${1:-}"
SYSADMIN_ROOT="${2:-}"
LEGACY_PATH="${3:-}"

[ -n "$WORKDIR" ] && [ -n "$SYSADMIN_ROOT" ] \
    || { echo "ERROR: usage: write-configs.sh <workdir> <sysadmin_root> [<legacy_path>]" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq не найден" >&2; exit 1; }

AGENT_DRAFT="$WORKDIR/agent-config-draft.json"
INFRA_DRAFT="$WORKDIR/infra-config-draft.json"
for f in "$AGENT_DRAFT" "$INFRA_DRAFT"; do
    [ -f "$f" ] || { echo "ERROR: нет draft'а: $f (сборка Шага 8 не выполнена?)" >&2; exit 1; }
done
VALIDATOR="$SYSADMIN_ROOT/.claude/skills/sysadmin-init/scripts/validate-config.sh"

# 1) Целевой путь мозга — всегда корень sysadmin/.
AGENT_PATH="$SYSADMIN_ROOT/agent-config.json"

# 2) Целевой путь карты — папка проекта (infra_root из draft'а мозга).
INFRA_ROOT_RAW="$(jq -r '.projects[0].infra_root' "$AGENT_DRAFT")"
INFRA_ROOT="${INFRA_ROOT_RAW/#\~/$HOME}"   # tilde без eval
mkdir -p "$INFRA_ROOT" || {
    echo "ERROR: не удалось создать папку инфры: $INFRA_ROOT (опечатка? нет прав?). Повтори Раунд 1.5." >&2
    exit 1
}
[ -d "$INFRA_ROOT" ] || { echo "ERROR: $INFRA_ROOT — не директория" >&2; exit 1; }
INFRA_CONFIG_PATH="$INFRA_ROOT/infra-config.json"

# Нормализую infra_root в мозге до абсолютного пути.
ABS_ROOT="$(cd "$INFRA_ROOT" && pwd)"
jq --arg r "$ABS_ROOT" '.projects[0].infra_root=$r' "$AGENT_DRAFT" > "$WORKDIR/.wc.tmp" && mv "$WORKDIR/.wc.tmp" "$AGENT_DRAFT"

# 3) Backup существующих версий (для --reconfigure и миграции).
TS="$(date +%Y%m%d-%H%M%S)"
[ -f "$AGENT_PATH" ]        && cp "$AGENT_PATH"        "$AGENT_PATH.bak.$TS"
[ -f "$INFRA_CONFIG_PATH" ] && cp "$INFRA_CONFIG_PATH" "$INFRA_CONFIG_PATH.bak.$TS"
# Миграция: старый всё-в-одном переименовываем в .bak (не удаляем — путь к откату).
if [ -n "$LEGACY_PATH" ] && [ -f "$LEGACY_PATH" ]; then
    mv "$LEGACY_PATH" "$LEGACY_PATH.bak.$TS"
    echo "→ Старый конфиг сохранён как $LEGACY_PATH.bak.$TS (можно удалить позже)."
fi

# 4) Запись обоих файлов.
mv "$AGENT_DRAFT" "$AGENT_PATH"
mv "$INFRA_DRAFT" "$INFRA_CONFIG_PATH"

# 5) FINAL CHECK — оба файла РЕАЛЬНО на диске (C.9: молчаливый сбой записи недопустим).
for f in "$AGENT_PATH" "$INFRA_CONFIG_PATH"; do
    [ -f "$f" ] || {
        echo "ОШИБКА: конфиг НЕ записан — файла нет по пути $f." >&2
        echo "Это сбой записи (права? путь? диск?). НЕ создаю суррогат вручную (C.9)." >&2
        echo "Покажи вывод: ls -la \"$(dirname "$f")\" — разберёмся." >&2
        exit 1
    }
done
# 6) Оба валидны по своим схемам (validate-config.sh разведёт по имени файла).
if [ -f "$VALIDATOR" ]; then
    bash "$VALIDATOR" "$AGENT_PATH" "$INFRA_CONFIG_PATH" || {
        echo "ОШИБКА: файл(ы) записан(ы), но не проходит(ят) валидацию: $AGENT_PATH , $INFRA_CONFIG_PATH" >&2
        exit 1
    }
fi

# Экспорт путей для дальнейших шагов (если скрипт вызван через source).
export AGENT_PATH INFRA_CONFIG_PATH
echo "✅ записаны и проверены:"
echo "   мозг:  $AGENT_PATH"
echo "   карта: $INFRA_CONFIG_PATH"
