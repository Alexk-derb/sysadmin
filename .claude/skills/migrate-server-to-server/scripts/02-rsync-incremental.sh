#!/usr/bin/env bash
# 02-rsync-incremental.sh — инкрементальный rsync Docker-volumes между серверами.
#
# Стратегия 3 шагов:
#   День 1: первый полный rsync (старые сервисы ещё работают, ~много данных)
#   День 2: второй rsync (только delta, обычно секунды-минуты)
#   День 3: cutover — stop старых → финальный delta → start новых → DNS switch
#
# Использование:
#   bash 02-rsync-incremental.sh user@old.vps.com user@new.vps.com [день1|день2|cutover]
#
# Скрипт идемпотентен — каждый запуск даёт текущий delta, можно прогонять
# несколько раз подряд без вреда.
#
# 🔴 БЕЗОПАСНОСТЬ: фазы день2/cutover используют rsync --delete — на приёмнике
# будет удалено всё, чего нет на источнике. Перепутанное направление = уничтожение
# боевого сервера. Поэтому скрипт:
#   1) показывает hostname обоих серверов и требует подтвердить направление;
#   2) для фаз с --delete требует type-to-confirm строку, а не слепой Enter.

set -euo pipefail

OLD_SERVER="${1:-}"
NEW_SERVER="${2:-}"
PHASE="${3:-день1}"

if [ -z "$OLD_SERVER" ] || [ -z "$NEW_SERVER" ]; then
    echo "Использование: $0 user@old.vps.com user@new.vps.com [день1|день2|cutover]"
    exit 2
fi

# --- Сверка направления (все фазы) -------------------------------------------
# Показываем живые доказательства роли каждого хоста, чтобы перепутанные местами
# аргументы были видны ДО первой записи на приёмник.
echo "=== СВЕРКА НАПРАВЛЕНИЯ ==="
echo "ИСТОЧНИК (читаем):  $OLD_SERVER"
ssh "$OLD_SERVER" 'echo "  hostname: $(hostname)"; echo "  контейнеры: $(docker ps --format "{{.Names}}" 2>/dev/null | tr "\n" " " | cut -c1-200)"' || {
    echo "Не удалось опросить источник $OLD_SERVER — STOP"; exit 1; }
echo "ПРИЁМНИК (пишем, --delete сотрёт лишнее): $NEW_SERVER"
ssh "$NEW_SERVER" 'echo "  hostname: $(hostname)"; echo "  контейнеры: $(docker ps --format "{{.Names}}" 2>/dev/null | tr "\n" " " | cut -c1-200)"' || {
    echo "Не удалось опросить приёмник $NEW_SERVER — STOP"; exit 1; }
echo ""
echo "Проверь глазами: данные потекут $OLD_SERVER → $NEW_SERVER."
printf 'Если направление верное, введи слово НАПРАВЛЕНИЕ-ВЕРНОЕ: '
read -r DIRECTION_CONFIRM
if [ "$DIRECTION_CONFIRM" != "НАПРАВЛЕНИЕ-ВЕРНОЕ" ]; then
    echo "Подтверждение не получено — STOP (введено: '$DIRECTION_CONFIRM')"
    exit 1
fi

# --- Type-to-confirm для фаз с --delete ---------------------------------------
confirm_delete_phase() {
    local phase_name="$1"
    echo ""
    echo "🔴 RED ZONE: фаза '$phase_name' использует rsync --delete."
    echo "На приёмнике $NEW_SERVER будет УДАЛЕНО всё в /var/lib/docker/volumes/,"
    echo "чего нет на источнике $OLD_SERVER. Откат — только из бэкапа приёмника."
    printf 'Введи подтверждение (подтверждаю rsync --delete на %s, бэкап целевого проверен): ' "$NEW_SERVER"
    read -r DELETE_CONFIRM
    if [ "$DELETE_CONFIRM" != "подтверждаю rsync --delete на $NEW_SERVER, бэкап целевого проверен" ]; then
        echo "Type-to-confirm не совпал — STOP"
        exit 1
    fi
}

LINK_DEST=""
if [ "$PHASE" != "день1" ]; then
    # Для день2/cutover используем предыдущий снапшот для hardlink dedupe
    PREV=$(ssh "$NEW_SERVER" "ls -d /var/lib/docker/volumes.snapshot-* 2>/dev/null | tail -1" || true)
    if [ -n "$PREV" ]; then
        LINK_DEST="--link-dest=$PREV"
    fi
fi

echo "=== Rsync ($PHASE): $OLD_SERVER → $NEW_SERVER ==="

case "$PHASE" in
    день1)
        echo "[Полный rsync — может занять часы для больших volumes]"
        rsync -avz --progress \
            --rsync-path="sudo rsync" \
            "$OLD_SERVER":/var/lib/docker/volumes/ \
            "$NEW_SERVER":/var/lib/docker/volumes/
        ;;
    день2)
        confirm_delete_phase "день2"
        echo "[Delta rsync — обычно секунды-минуты]"
        # shellcheck disable=SC2086
        # ($LINK_DEST раскрывается в "--link-dest=/path" — должно быть split на 1 аргумент)
        rsync -avz --progress --delete $LINK_DEST \
            --rsync-path="sudo rsync" \
            "$OLD_SERVER":/var/lib/docker/volumes/ \
            "$NEW_SERVER":/var/lib/docker/volumes/
        ;;
    cutover)
        confirm_delete_phase "cutover"
        echo "[Финальный rsync с предварительным stop сервисов на старом]"
        echo "ВНИМАНИЕ: этот шаг останавливает сервисы на старом сервере ($OLD_SERVER)."
        printf 'Подтверди готовность к downtime словом ГОТОВ: '
        read -r DOWNTIME_CONFIRM
        if [ "$DOWNTIME_CONFIRM" != "ГОТОВ" ]; then
            echo "Подтверждение не получено — STOP"
            exit 1
        fi

        # Stop сервисов на старом — НЕ down, чтобы был быстрый откат
        ssh "$OLD_SERVER" "
            for compose in /opt/*/docker-compose.yml; do
                cd \$(dirname \$compose) && docker compose stop || true
            done
        "

        # Финальный delta
        # shellcheck disable=SC2086
        rsync -avz --progress --delete $LINK_DEST \
            --rsync-path="sudo rsync" \
            "$OLD_SERVER":/var/lib/docker/volumes/ \
            "$NEW_SERVER":/var/lib/docker/volumes/

        echo ""
        echo "=== Финальный rsync завершён ==="
        echo "Следующий шаг — bash 03-cutover.sh $NEW_SERVER"
        ;;
    *)
        echo "Неизвестная фаза: $PHASE"
        echo "Допустимо: день1 / день2 / cutover"
        exit 2
        ;;
esac

echo "=== Готово ($PHASE) ==="
