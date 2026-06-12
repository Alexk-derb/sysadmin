#!/usr/bin/env bash
# 01-pre-migration-backup.sh — обязательный бэкап перед миграцией.
#
# БЕЗ ЭТОГО СКРИПТА МИГРАЦИЯ НЕ НАЧИНАЕТСЯ. Создаёт три типа страховки:
#   1. Логический дамп всех БД (pg_dumpall)
#   2. tar архив всех Docker volumes
#   3. Запись в restic offsite repository
#
# Использование:
#   bash 01-pre-migration-backup.sh user@old.vps.com            # бэкап источника
#   bash 01-pre-migration-backup.sh user@new.vps.com target     # бэкап ЦЕЛЕВОГО
#
# Второй аргумент — суффикс тега (по умолчанию пусто → тег pre-migration;
# «target» → тег pre-migration-target). Бэкап целевого обязателен перед первой
# записью на него: именно он спасает при перепутанном направлении.
#
# На выходе:
#   /backup/pre-migration-YYYYMMDD-HHMMSS/full.sql.gz          (если есть postgres)
#   /backup/pre-migration-YYYYMMDD-HHMMSS/docker-volumes.tar.gz
#   restic snapshot с тегом pre-migration[-target]
#
# Если на сервере нет контейнера postgres или нет restic — соответствующий шаг
# пропускается С ЯВНЫМ СООБЩЕНИЕМ (на свежем целевом это норма), скрипт не падает.
# «Нечего бэкапить» должно быть доказано выводом, а не предположением.

set -euo pipefail

SERVER="${1:-}"
TAG_SUFFIX="${2:-}"
if [ -z "$SERVER" ]; then
    echo "Использование: $0 user@server [target]"
    exit 2
fi

TAG="pre-migration${TAG_SUFFIX:+-$TAG_SUFFIX}"
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/backup/${TAG}-${TS}"

echo "=== Бэкап ($TAG): $SERVER → $BACKUP_DIR ==="

# 1. Создать директорию на удалённом сервере
ssh "$SERVER" "mkdir -p '$BACKUP_DIR'"

# 2. Логический дамп всех БД (pg_dumpall работает с любым клиентом, ловит роли)
echo "[1/3] pg_dumpall..."
ssh "$SERVER" "
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx postgres; then
        docker exec postgres pg_dumpall -U postgres | gzip > '$BACKUP_DIR/full.sql.gz'
        ls -lh '$BACKUP_DIR/full.sql.gz'
    else
        echo 'ПРОПУСК: контейнер postgres не найден (docker ps выше по тексту) —'
        echo 'на свежем целевом это норма; на боевом источнике это ПОВОД ОСТАНОВИТЬСЯ.'
        docker ps --format '{{.Names}}' 2>/dev/null || true
    fi
"

# 3. tar архив всех Docker volumes
echo "[2/3] tar volumes..."
ssh "$SERVER" "
    if [ -d /var/lib/docker/volumes ] && [ -n \"\$(ls -A /var/lib/docker/volumes 2>/dev/null)\" ]; then
        tar czf '$BACKUP_DIR/docker-volumes.tar.gz' /var/lib/docker/volumes/
        ls -lh '$BACKUP_DIR/docker-volumes.tar.gz'
    else
        echo 'ПРОПУСК: /var/lib/docker/volumes пуст или отсутствует — фиксирую фактом:'
        ls -la /var/lib/docker/volumes 2>&1 || true
    fi
"

# 4. restic backup с тегом
echo "[3/3] restic backup..."
ssh "$SERVER" "
    if command -v restic >/dev/null 2>&1; then
        restic backup '$BACKUP_DIR' --tag '$TAG' --tag '$TS'
        restic snapshots --tag '$TAG' --json | tail -3
    else
        echo 'ПРОПУСК: restic не установлен на этом сервере — offsite-копии НЕ будет.'
        echo 'Для источника это блокер (бэкап обязан быть offsite); для целевого — приемлемо.'
    fi
"

echo "=== Бэкап готов: $BACKUP_DIR (тег: $TAG) ==="
echo ""
echo "Проверка целостности (test restore на staging):"
echo "  restic restore latest --target /tmp/test-restore --tag $TAG"
echo ""
echo "Если staging нет — минимум проверь что архив не битый:"
echo "  ssh $SERVER 'gunzip -t $BACKUP_DIR/full.sql.gz && tar tzf $BACKUP_DIR/docker-volumes.tar.gz | head -5'"
