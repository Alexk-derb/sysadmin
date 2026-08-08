#!/usr/bin/env bash
# .claude/skills/inventory-scan/scripts/dump-snapshot.sh
#
# Bundled-копия v2 dump-скрипта инвентаризации сервера. Снимает read-only снимок
# состояния: контейнеры, compose-файлы, сети, тома, ресурсы хоста, cron, nginx,
# TLS-сертификаты, host-scripts, .env (redacted), systemd-юниты, доступные апдейты.
#
# БЕЗОПАСНОСТЬ (redaction v2): секреты в env контейнеров (docker inspect) и в
# .env-файлах хоста маскируются ДО записи на диск — KEY=value с секрет-именами
# и креды в URL (scheme://user:pass@host) заменяются на <REDACTED>. Имена
# переменных сохраняются для аудита. См. meta.txt (redaction_applied) и
# references/dump-snapshot-quirks.md.
#
# Использование:
#   bash dump-snapshot.sh <SERVER> [DATE] [INVENTORY_DIR]
#
# SERVER — обязательный параметр (защита от случайного захода на чужой сервер):
#   user@host  или  SSH-алиас из ~/.ssh/config  или  `local`.
#
# Примеры:
#   bash dump-snapshot.sh local                          # локальная машина (без SSH)
#   bash dump-snapshot.sh root@<your-server-ip>          # по IP
#   bash dump-snapshot.sh prod                           # SSH-алиас из ~/.ssh/config
#   bash dump-snapshot.sh root@10.0.0.1 2026-01-01       # произвольный сервер и дата
#   bash dump-snapshot.sh prod today /tmp/inv            # альтернативный INVENTORY_DIR
#
# Создаёт ~20 файлов в ${INVENTORY_DIR}/hosts/<HOST_DIR>/snapshots/<DATE>/
# (containers, networks, volumes — плюс варианты по каждому демону `.<tag>.txt`;
#  host-resources, crontab, nginx-sites, tls-certs, host-scripts-list,
#  host-scripts-content, host-env-redacted, cron-d-content, systemd-enabled,
#  systemd-timers, watchers, compose-files, docker-endpoints.txt,
#  containers-summary.json, meta.txt).
#
# v3 (2026-08-08): снимаются ВСЕ Docker-демоны хоста, а не только активный контекст;
# сырой `docker inspect` в снимок больше не переносится — вместо него проекция белого
# списка полей (scripts/summary-filter.jq). Причины — в SKILL.md, раздел Failed Attempts.

set -euo pipefail

# SERVER — обязательный аргумент. Без него — fail-fast с подсказкой,
# чтобы оператор случайно не пошёл на чужой сервер.
if [ "$#" -lt 1 ]; then
    echo "ERROR: SERVER не задан." >&2
    echo "Использование: bash dump-snapshot.sh <SERVER> [DATE] [INVENTORY_DIR]" >&2
    echo "  SERVER — user@host / SSH-алиас / 'local'." >&2
    exit 2
fi

SERVER="$1"
DATE="${2:-$(date +%Y-%m-%d)}"
INVENTORY_DIR="${3:-${INVENTORY_DIR:-inventory}}"

# === Определение имени хоста для пути ===
# Канон имени папки хоста — из infra-config.json servers[].alias; его передаёт
# SKILL через env HOST_DIR (Шаг 2). Без override выводим из SSH-target как
# fallback, НО это риск раздвоить inventory: алиас `hoster` дал бы `prod-hoster`,
# а записанный хост — `prod-198.51.100.7` (находка /retro 2026-06-14). Поэтому при
# расхождении канона и выведенного — громко предупреждаем и берём канон.
if [ "$SERVER" = "local" ]; then
    # hostname -s есть не везде (Git Bash на Windows, часть BSD) — под `set -e` это
    # роняло весь скрипт ещё до первого шага. Деградируем по цепочке до 'unknown'.
    _hn="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
    DERIVED_HOST_DIR="local-${_hn}"
else
    # user@1.2.3.4 -> prod-1.2.3.4 | user@hostname -> prod-hostname | ssh-alias -> prod-ssh-alias
    DERIVED_HOST_DIR="prod-${SERVER#*@}"
fi
if [ -n "${HOST_DIR:-}" ]; then
    [ "$HOST_DIR" != "$DERIVED_HOST_DIR" ] && \
        echo "  [i] HOST_DIR из config='${HOST_DIR}' ≠ выведенного из SSH-target='${DERIVED_HOST_DIR}' — беру канон из config (не плодим второй каталог inventory)."
else
    HOST_DIR="$DERIVED_HOST_DIR"
fi

SNAPSHOT_DIR="${INVENTORY_DIR}/hosts/${HOST_DIR}/snapshots/${DATE}"

echo "======================================================"
echo "dump-snapshot.sh — снимок сервера (bundled v2)"
echo "Сервер:        ${SERVER}"
echo "Хост-dir:      ${HOST_DIR}"
echo "Inventory dir: ${INVENTORY_DIR}"
echo "Папка снимка:  ${SNAPSHOT_DIR}"
echo "======================================================"

# === Блок проверки предусловий ===
echo ""
echo "Проверка предусловий..."

if [ "$SERVER" = "local" ]; then
    # Локальный режим — без SSH
    if ! command -v docker &>/dev/null; then
        echo ""
        echo "ОШИБКА: Docker не найден на локальной машине."
        echo "Установи Docker: https://docs.docker.com/engine/install/"
        exit 1
    fi
    echo "  [OK] Docker доступен локально"
    echo "  [OK] Режим: локальный (без SSH)"
    run_cmd() { eval "$1"; }
else
    # Удалённый режим — через SSH

    # 1. Проверка SSH-доступа
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$SERVER" 'echo ok' >/dev/null 2>&1; then
        echo ""
        echo "ОШИБКА: Не удалось подключиться к ${SERVER} по SSH."
        echo ""
        echo "Проверь:"
        echo "  1. Сервер включён и доступен по сети"
        echo "  2. SSH-ключ настроен: ssh-copy-id ${SERVER}"
        echo "  3. Нет блокировки по firewall (порт 22 открыт)"
        echo "  4. Правильный пользователь в адресе (root@...)"
        exit 1
    fi
    echo "  [OK] SSH-доступ к ${SERVER} есть"

    # 2. Проверка Docker на сервере
    if ! ssh -o ConnectTimeout=10 "$SERVER" 'command -v docker' >/dev/null 2>&1; then
        echo ""
        echo "ОШИБКА: Docker не найден на сервере ${SERVER}."
        echo "Docker не установлен — снимок контейнеров невозможен."
        echo "Установи Docker: https://docs.docker.com/engine/install/"
        exit 1
    fi
    echo "  [OK] Docker найден на сервере"

    # 3. Проверка версии bash на сервере (мягкое предупреждение)
    REMOTE_BASH_VER=$(ssh -o ConnectTimeout=10 "$SERVER" \
        'bash --version 2>/dev/null | head -1 | grep -oE "version [0-9]+" | grep -oE "[0-9]+"' \
        2>/dev/null || echo "0")
    if [ "${REMOTE_BASH_VER:-0}" -lt 4 ] 2>/dev/null; then
        echo "  [WARN] bash < 4 на сервере (версия: ${REMOTE_BASH_VER}). Скрипт продолжит."
    else
        echo "  [OK] bash >= 4 на сервере"
    fi

    echo "  [OK] Предусловия пройдены. Режим: SSH"
    # Опции против засорения снимка stderr'ом самого ssh-клиента (баг до v1.4.3):
    #   LogLevel=ERROR   — глушит WARNING/INFO ssh-клиента (post-quantum warning,
    #                      «ControlSocket ... already exists», болтовню мультиплексора),
    #                      но пропускает ERROR/FATAL — реальные сбои соединения видны.
    #   ControlMaster=no — для этих коротких одноразовых команд не используем
    #                      мультиплексирование оператора (ControlMaster auto в его
    #                      ~/.ssh/config даёт «mux_client_request_session»,
    #                      «Connection reset by peer» в stderr на OpenSSH 9.x / Windows).
    # stderr самой удалённой команды это НЕ трогает — он отделяется в run_remote.
    run_cmd() { ssh -o ConnectTimeout=10 -o LogLevel=ERROR -o ControlMaster=no "$SERVER" "$1"; }
fi

# === Создаём папку снимка ===
mkdir -p "$SNAPSHOT_DIR"

# === Redaction секретов в снимке ===
# Любой dump может случайно уйти в коммит, bug-report или бэкап. Маскируем
# секреты ДО записи на диск — а не надеемся только на .gitignore (последний
# рубеж, не основная защита).
#
# Закрываем ДВА паттерна, оба зафиксированы в references/dump-snapshot-quirks.md:
#   1. KEY=value   — env-переменные вида OPENROUTER_API_KEY=sk-or-v1-...
#   2. url://user:pass@host — пароль внутри connection-string (postgres://, redis://, amqp://...)
#
# Без жёсткой зависимости от jq (его часто нет на macOS/Git-for-Windows у
# оператора, через которого проходит snapshot — см. инцидент Windows-портабельности).
# Если jq есть — используем его для structurally-aware redaction .Config.Env;
# если нет — построчный fallback на sed/grep, работающий везде. Защита не
# должна зависеть от того, что доустановил оператор.

REDACTION_VERSION="v2"

# Функции маскировки redact_stream / redact_json_with_jq живут в единой
# библиотеке _lib/redact.sh (канон redaction v2) — её же используют
# rotate-secrets и другие скиллы. Не дублируем код: при изменении паттернов
# правится ОДНО место. Если библиотека не найдена — fail-fast: молча писать
# снимок без маскировки нельзя (приоритет №1 — секреты не утекают).
DUMP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REDACT_LIB="$DUMP_SCRIPT_DIR/../../_lib/redact.sh"
if [ -f "$REDACT_LIB" ]; then
    # shellcheck source=/dev/null
    source "$REDACT_LIB"
else
    echo "ERROR: библиотека маскировки не найдена: $REDACT_LIB" >&2
    echo "Снимок БЕЗ redaction создавать запрещено. Запускай скрипт из репо sysadmin/" >&2
    echo "(bash .claude/skills/inventory-scan/scripts/dump-snapshot.sh ...)." >&2
    exit 2
fi

if command -v jq &>/dev/null; then
    REDACTION_TOOL="jq"
else
    REDACTION_TOOL="sed-fallback"
fi

# === Вспомогательная функция записи секции ===
# run_remote <имя_файла> <команда>
#
# КАЖДАЯ секция проходит через redact_stream ДО записи на диск. Раньше
# redaction применялся только к containers-inspect.json и host-env-redacted.txt,
# а остальные секции (crontab, host-scripts-content, nginx-sites) писались
# сырыми — и секрет в query-string cron-задачи утекал открытым текстом
# (граблекейс srv-main). Теперь redaction — общий рубеж для всех run_remote,
# а meta.txt:redaction_applied=true перестаёт вводить в заблуждение.
run_remote() {
    local label="$1"
    local cmd="$2"
    local outfile="${SNAPSHOT_DIR}/${label}"
    local errfile="${SNAPSHOT_DIR}/${label}.stderr.log"
    echo "  -> ${label}..."

    # Разделяем потоки (fix v1.4.3): stdout (данные команды) → файл снимка,
    # stderr (диагностика удалённой команды) → отдельный *.stderr.log рядом.
    # Раньше было `run_cmd ... 2>&1 | redact_stream`, и stderr самого ssh-клиента
    # (mux_client_request_session, post-quantum warning, ControlSocket...) попадал
    # ПРЯМО в файл снимка — ломая идемпотентность (следующий скан собирал его же).
    # Теперь ssh-шум заглушён в run_cmd (LogLevel/ControlMaster), а stderr — отделён.
    # ОБА потока проходят redact_stream: stderr тоже может содержать секреты
    # (например, ошибка с connection-string) — секреты маскируются везде (приоритет №1).
    local err_raw
    err_raw="$(mktemp)"
    if ! run_cmd "$cmd" 2>"$err_raw" | redact_stream > "$outfile"; then
        echo "     ПРЕДУПРЕЖДЕНИЕ: не удалось выполнить ${label}"
        echo "ERROR: ${cmd}" >> "$outfile"
    fi
    # stderr пишем рядом, но только если он непустой — не плодим мусорные файлы.
    if [ -s "$err_raw" ]; then
        redact_stream < "$err_raw" > "$errfile"
    fi
    rm -f "$err_raw"
}

# === Обнаружение Docker-демонов (v3) ===
#
# Грабля 2026-08-08: скрипт звал `docker` в активном контексте пользователя, а им был
# `rootless` — и боевой стек в снимок не попадал ВООБЩЕ. Снимки за разные даты при этом
# оказывались сняты с разных демонов и стали несопоставимы.
#
# Контекст Docker — клиентская запись, а НЕ перечень демонов. Поэтому перечисляем
# фактически отвечающие сокеты плюс endpoint'ы контекстов, а различаем по daemon ID.
# ID берётся из `docker info` и хранится в data-root (`engine-id`): при клонировании
# data-root два разных демона дадут одинаковый ID. Поэтому совпадение ID — повод
# пометить КОЛЛИЗИЮ, а не молча выбросить endpoint.
echo "  -> обнаружение Docker-демонов..."
ENDPOINTS_RAW="$( { run_cmd "
    set +e
    { echo unix:///var/run/docker.sock
      ls /run/user/*/docker.sock 2>/dev/null | sed 's|^|unix://|'
      docker context ls --format '{{.DockerEndpoint}}' 2>/dev/null
    } | grep -v '^\$' | sort -u
    true" 2>/dev/null; } || true )"

# tag|endpoint|daemon_id|status
DAEMONS=""
SEEN_IDS=""
for ep in $ENDPOINTS_RAW; do
    case "$ep" in
        *"/run/user/"*) tag="rootless" ;;
        *"/var/run/docker.sock") tag="default" ;;
        *) tag="$(printf '%s' "$ep" | tr -c 'A-Za-z0-9' '-' | sed 's/^-*//; s/-*$//' | cut -c1-24)" ;;
    esac
    # `|| true` обязателен: под `set -e` присваивание из недоступного демона
    # роняло весь снимок ещё на этапе обнаружения (поймано локальным прогоном).
    did="$( { run_cmd "DOCKER_HOST='$ep' docker info --format '{{.ID}}' 2>/dev/null" 2>/dev/null || true; } | tr -d '\r' | head -1)"
    if [ -z "$did" ]; then
        DAEMONS="${DAEMONS}${tag}|${ep}||unreachable
"
        continue
    fi
    status="ok"
    case " $SEEN_IDS " in *" $did "*) status="duplicate-id" ;; esac
    SEEN_IDS="$SEEN_IDS $did"
    DAEMONS="${DAEMONS}${tag}|${ep}|${did}|${status}
"
done

{
  echo "# endpoint'ы Docker, найденные на хосте (v3)"
  echo "# tag|endpoint|daemon_id|status"
  echo "# status: ok — снимаем; duplicate-id — тот же daemon ID, что у предыдущего"
  echo "#         (возможна коллизия engine-id при клонировании data-root);"
  echo "#         unreachable — сокет есть, но демон не ответил (нет прав или не запущен)."
  printf '%s' "$DAEMONS"
} | redact_stream > "${SNAPSHOT_DIR}/docker-endpoints.txt"

DAEMON_OK_COUNT=$(printf '%s' "$DAEMONS" | grep -c '|ok$' || true)
[ -z "$DAEMON_OK_COUNT" ] && DAEMON_OK_COUNT=0
if [ "$DAEMON_OK_COUNT" -eq 0 ]; then
    echo "     ПРЕДУПРЕЖДЕНИЕ: ни один Docker-демон не ответил — секции контейнеров будут пустыми."
fi
echo "     найдено endpoint'ов: $(printf '%s' "$DAEMONS" | grep -c '|' || true), снимаем с: ${DAEMON_OK_COUNT}"

# docker_each <файл-суффикс> <команда с $DH вместо docker>
# Прогоняет команду по каждому доступному демону, складывая результат в
# <label>.<tag>.<ext> и дополнительно в общий <label> с шапкой демона.
docker_each() {
    local label="$1" ext="$2" cmd="$3"
    local combined="${SNAPSHOT_DIR}/${label}.${ext}"
    : > "$combined"
    printf '%s' "$DAEMONS" | while IFS='|' read -r tag ep did status; do
        [ "$status" = "ok" ] || continue
        local out="${SNAPSHOT_DIR}/${label}.${tag}.${ext}"
        run_cmd "DOCKER_HOST='$ep' $cmd" 2>/dev/null | redact_stream > "$out"
        {
          echo "=== демон ${tag} (${ep}, id=${did}) ==="
          cat "$out"
          echo
        } >> "$combined"
    done
}

# === Заголовочный файл meta.txt ===
echo "  -> meta.txt..."
cat > "${SNAPSHOT_DIR}/meta.txt" <<METATXT
snapshot_date: ${DATE}
snapshot_time: $(date -u +%Y-%m-%dT%H:%M:%SZ)
server: ${SERVER}
host_dir: ${HOST_DIR}
inventory_dir: ${INVENTORY_DIR}
taken_by: $(whoami)
script_version: bundled-v2
redaction_applied: true
redaction_version: ${REDACTION_VERSION}
redaction_tool: ${REDACTION_TOOL}
METATXT

# === 17 контентных файлов снимка (16 + health-flags.txt) ===

# 1. Список контейнеров — по КАЖДОМУ демону (v3)
echo "  -> containers.txt (по каждому демону)..."
docker_each "containers" "txt" \
    "docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"

# 2. containers-summary.json — ПРОЕКЦИЯ полей, а не сырой inspect (v3, schema 1).
#
#    Почему больше не пишем сырой `docker inspect`: маскировка как последняя линия
#    обороны — это растущий чёрный список. 2026-08-08 сквозь неё прошли ключ
#    `sb_secret_` внутри многострочного значения и приватный TLS-ключ в
#    `Args`/`Entrypoint`. Секрет может лежать и в `Labels`, и в `Healthcheck.Test`,
#    и в `LogConfig`. Поэтому в снимок попадает только БЕЛЫЙ СПИСОК полей, а поля,
#    куда пользователь кладёт произвольные строки и команды, не переносятся вовсе.
#
#    Значения переменных окружения не сохраняются НИКОГДА — только имена (для аудита
#    состава). Результат дополнительно проходит redact_json_deep — как страховка от
#    приманки в имени контейнера, имени переменной или пути монтирования.
#
#    FAIL-CLOSED: без jq проекция невозможна (sed не умеет надёжно проецировать JSON),
#    поэтому файл не создаётся, а в snapshot кладётся явная отметка отказа. Молча
#    писать сырьё нельзя — именно так и утекают секреты.
echo "  -> containers-summary.json (проекция полей, schema 1)..."
if [ "$REDACTION_TOOL" != "jq" ]; then
    echo "ОТКАЗ: jq недоступен — проекция containers-summary.json не выполнена." \
        > "${SNAPSHOT_DIR}/containers-summary.SKIPPED.txt"
    echo "     ПРЕДУПРЕЖДЕНИЕ: jq нет — containers-summary.json НЕ создан (fail-closed)."
else
    # Фильтр вынесен в отдельный файл: его же применяет tests/test-inventory-scan.sh,
    # чтобы проверяемое и работающее не разъезжались.
    SUMMARY_FILTER="${DUMP_SCRIPT_DIR}/summary-filter.jq"
    if [ ! -f "$SUMMARY_FILTER" ]; then
        echo "ОШИБКА: не найден $SUMMARY_FILTER — проекция невозможна." >&2
        exit 2
    fi
    : > "${SNAPSHOT_DIR}/containers-summary.json.parts"
    printf '%s' "$DAEMONS" | while IFS='|' read -r tag ep did status; do
        [ "$status" = "ok" ] || continue
        raw=$(run_cmd "DOCKER_HOST='$ep' sh -c 'docker ps -a -q | xargs -r docker inspect' 2>/dev/null || echo '[]'" 2>/dev/null || echo '[]')
        printf '%s' "$raw" \
          | jq -f "$SUMMARY_FILTER" 2>/dev/null \
          | jq --arg d "$tag" --arg id "$did" --arg ep "$ep" \
               'map(. + {daemon: $d, daemon_id: $id, endpoint: $ep})' 2>/dev/null \
          | redact_json_deep >> "${SNAPSHOT_DIR}/containers-summary.json.parts"
    done
    # склеиваем массивы демонов в один документ со схемой
    jq -s '{schema_version: 1, containers: (add // [])}' \
        "${SNAPSHOT_DIR}/containers-summary.json.parts" \
        > "${SNAPSHOT_DIR}/containers-summary.json" 2>/dev/null \
      || echo '{"schema_version":1,"containers":[]}' > "${SNAPSHOT_DIR}/containers-summary.json"
    rm -f "${SNAPSHOT_DIR}/containers-summary.json.parts"
fi

# 3. Список compose-файлов на сервере
run_remote "compose-files.txt" \
    "find /opt -name 'docker-compose.yml' -o -name 'docker-compose.yaml' 2>/dev/null | sort"

# 4. Docker-сети — по каждому демону (v3)
echo "  -> networks.txt (по каждому демону)..."
docker_each "networks" "txt" \
    "docker network ls; echo '---'; docker network ls -q | xargs -r docker network inspect --format '{{.Name}}: {{.IPAM.Config}}' 2>/dev/null"

# 5. Docker-тома — по каждому демону (v3)
echo "  -> volumes.txt (по каждому демону)..."
docker_each "volumes" "txt" \
    "docker volume ls; echo '---'; docker system df -v 2>/dev/null"

# 6. Ресурсы хоста (uptime, память, диск, порты, обновления APT)
run_remote "host-resources.txt" \
    "echo '=== uptime ===' && uptime && echo '=== память ===' && free -h && echo '=== диск ===' && df -h && echo '=== открытые порты ===' && (ss -tulpn 2>/dev/null || netstat -tulpn 2>/dev/null || echo 'ss/netstat не найден') && echo '=== доступные обновления APT ===' && (apt list --upgradable 2>/dev/null | head -50 || echo 'apt не найден')"

# 7. Cron-задачи
run_remote "crontab.txt" \
    "echo '=== crontab root ===' && (crontab -l 2>/dev/null || echo 'пусто') && echo '=== /etc/cron.d/ ===' && (ls -la /etc/cron.d/ 2>/dev/null || echo 'пусто') && (cat /etc/cron.d/* 2>/dev/null || echo 'пусто')"

# 8. Nginx-конфигурация
run_remote "nginx-sites.txt" \
    "nginx -T 2>/dev/null || (echo '--- sites-enabled ---' && ls -la /etc/nginx/sites-enabled/ 2>/dev/null && cat /etc/nginx/sites-enabled/* 2>/dev/null) || echo 'nginx не найден'"

# 9. TLS-сертификаты и их СРОКИ ВАЛИДНОСТИ через openssl — и letsencrypt, и acme.sh.
#    Фикс /retro 2026-06-14: раньше openssl бежал только по /etc/letsencrypt/live, а
#    для acme.sh была лишь `ls -la` (даты ФАЙЛОВ, не сертификатов) — на acme.sh-хостах
#    срок истечения не считался вообще, хотя description обещает «даты валидности».
#    Теперь openssl x509 -enddate прогоняется по обоим источникам. set +e — против
#    спецсимволов в путях (фикс v2).
run_remote "tls-certs.txt" \
    "set +e
     echo '=== letsencrypt (/etc/letsencrypt/live) ==='
     find /etc/letsencrypt/live -name 'cert.pem' 2>/dev/null | while read f; do echo \"--- \$f ---\"; openssl x509 -in \"\$f\" -noout -subject -dates 2>/dev/null; done
     echo '=== acme.sh (~/.acme.sh/*/fullchain.cer) ==='
     for f in ~/.acme.sh/*/fullchain.cer; do [ -f \"\$f\" ] || continue; echo \"--- \$f ---\"; openssl x509 -in \"\$f\" -noout -subject -enddate 2>/dev/null; done
     true"

# 10. Список хостовых скриптов (метаданные, без содержимого)
#     set +e + true: пустые glob'ы (/opt/*.yml, /root/bin/) дают ls ненулевой
#     код, и под set -o pipefail вся секция ложно помечалась как failed
#     (граблекейс srv-main: данные собирались, но в конец файла дописывался
#     'ERROR: ...'). Honest-status: секция падает только при реальной ошибке.
#     v3: раньше секция смотрела ТОЛЬКО в /opt/*.sh, /usr/local/{bin,sbin}/*.sh и
#     /root/bin — то есть на уровень выше реальных мест. Грабля 2026-08-08: на хосте
#     оказалось 16 скриптов, вызываемых таймерами, из /opt/backup/ и /opt/*/ops/, а
#     inventory числил один. Теперь список строится от того, что РЕАЛЬНО запускается:
#     обход ExecStart включённых service/timer/path-юнитов с разворачиванием обёрток
#     вида `/bin/bash -lc '/path/script.sh'`. Прежние каталоги оставлены как дополнение
#     (скрипт может лежать и без юнита — например, вызываться из другого скрипта).
# shellcheck disable=SC2016
run_remote "host-scripts-list.txt" \
    'set +e
     echo "=== цели ExecStart включённых юнитов (service/timer/path) ==="
     units=$(systemctl list-unit-files --type=service --type=timer --type=path --state=enabled --no-legend 2>/dev/null | awk "{print \$1}")
     for u in $units; do
       case "$u" in
         systemd-*|sys-*|snap*|apt-*|man-db*|logrotate*|fstrim*|e2scrub*|xfs_scrub*|fwupd*|motd*|dpkg*|plocate*|update-notifier*|anacron*|chrony*|ua-*|ubuntu*|unattended*|sysstat*|apport*|mdadm*|mdcheck*|mdmonitor*|console-setup*|keyboard-setup*|grub*|kdump*|finalrd*|dmesg*|setvtrgb*|pollinate*|open-vm-tools*|gpu-manager*|netplan*|containerd*|docker*|ssh*|cron*|dbus*|polkit*|apparmor*) continue ;;
       esac
       svc="${u%.timer}"; svc="${svc%.path}"
       case "$svc" in *.service) ;; *) svc="$svc.service" ;; esac
       line=$(systemctl cat "$svc" 2>/dev/null | grep -m1 "^ExecStart=" | sed "s/^ExecStart=//")
       [ -z "$line" ] && continue
       # разворачиваем обёртки: берём первый абсолютный путь, не являющийся интерпретатором
       target=""
       for tok in $(printf "%s" "$line" | tr -d "\047\042"); do
         case "$tok" in
           /bin/bash|/bin/sh|/usr/bin/bash|/usr/bin/sh|/usr/bin/env|/usr/bin/python3|/usr/bin/python) continue ;;
           -*) continue ;;
           /*) target="$tok"; break ;;
         esac
       done
       [ -z "$target" ] && target="$line"
       if [ -e "$target" ]; then
         printf "%-34s %s\n" "$svc" "$(stat -c "%a %U:%G %10s %n" "$target" 2>/dev/null)"
       else
         printf "%-34s ЦЕЛЬ НЕ НАЙДЕНА: %s\n" "$svc" "$target"
       fi
     done
     echo
     echo "=== дополнительно: типовые каталоги ==="
     ls -la /opt/*.sh /opt/*.py /opt/*.yml 2>/dev/null
     ls -la /usr/local/bin/*.sh /usr/local/sbin/*.sh 2>/dev/null
     ls -la /root/bin/ 2>/dev/null
     true'

# 11. Содержимое хостовых скриптов в /opt (.sh)
# shellcheck disable=SC2016
# (single-quoted heredoc намеренный — переменные раскрываются на стороне сервера)
run_remote "host-scripts-content.txt" \
    'for f in /opt/*.sh; do
  [ -f "$f" ] || continue
  echo "=== $f ==="
  echo "--- metadata ---"
  stat -c "%a %U:%G %s bytes modified %y" "$f"
  echo "--- content ---"
  cat "$f"
  echo ""
done'

# 12. Структура .env файлов на хосте (имена переменных, значения redacted)
# shellcheck disable=SC2016
run_remote "host-env-redacted.txt" \
    'for f in /opt/*.env; do
  [ -f "$f" ] || continue
  echo "=== $f ==="
  echo "--- metadata ---"
  stat -c "%a %U:%G %s bytes modified %y" "$f"
  echo "--- variable names (values redacted) ---"
  # Маскируем значение после = целиком. Дополнительно ловим креды в URL
  # (postgres://user:pass@host), если значение само по себе не было скрыто
  # выше — на случай многострочных значений или нестандартного синтаксиса.
  sed -E \
    -e "s/=.*/=<HIDDEN>/" \
    -e "s#(([A-Za-z][A-Za-z0-9+.-]*)://[^:@/[:space:]]+:)[^@/[:space:]]+@#\1<REDACTED>@#g" "$f"
  echo ""
done'

# 13. Содержимое /etc/cron.d/ и периодических директорий
# shellcheck disable=SC2016
run_remote "cron-d-content.txt" \
    'for f in /etc/cron.d/* /etc/cron.daily/* /etc/cron.hourly/* /etc/cron.weekly/* /etc/cron.monthly/*; do
  [ -f "$f" ] || continue
  echo "=== $f ==="
  cat "$f"
  echo ""
done'

# 14. Включённые systemd-юниты (без штатных system-юнитов)
run_remote "systemd-enabled.txt" \
    "systemctl list-unit-files --type=service --state=enabled 2>/dev/null | grep -vE '^(UNIT|[0-9]+ unit|systemd-|sys-|snap\\.)' | head -50"

# 15. systemd-таймеры (расписание наравне с cron на Ubuntu 24.04) — таблица
#     активных таймеров + содержимое *.timer-юнитов оператора (без штатной
#     системной обвязки). set +e: на хостах без systemd / с урезанным systemctl
#     вызов не должен ронять снимок (граблекейс tls-certs).
run_remote "systemd-timers.txt" \
    "set +e
     echo '=== list-timers (активные) ==='
     systemctl list-timers --all --no-pager 2>/dev/null || echo 'нет данных (systemctl недоступен)'
     echo
     echo '=== *.timer-юниты оператора (без штатных system-) ==='
     timers=\$(systemctl list-unit-files --type=timer --no-pager 2>/dev/null \\
       | awk '{print \$1}' \\
       | grep -E '\\.timer\$' \\
       | grep -vE '^(systemd-|sys-|snap\\.|snapd\\.|apt-|man-db|logrotate|fstrim|e2scrub|fwupd|motd|dpkg|plocate|update-notifier|anacron|chrony-|chronyd|mdadm-|mdcheck|mdmonitor|ua-timer|ua_|ubuntu-advantage|raid-check|btrfs|smartd)' )
     if [ -z \"\$timers\" ]; then
       echo 'пусто (нет таймеров оператора)'
     else
       for t in \$timers; do
         echo \"--- \$t ---\"
         systemctl cat \"\$t\" 2>/dev/null || echo '(не удалось прочитать юнит)'
         echo
       done
     fi
     true"

# 16. Скрипты-наблюдатели (watchers) — долгоживущие процессы, слушающие события
#     файловой системы (inotify/fswatch/python-watchdog), в отличие от запуска
#     по расписанию.
#     ВАЖНО (граблекейс srv-main): НЕ ловим hardware watchdog (watchdogd,
#     /usr/sbin/watchdog) — это демон слежения за зависанием ядра, а не
#     наблюдатель за файлами; иначе на карте появляется фантомная «автоматизация».
#     Паттерн сужен до настоящих file-watcher'ов; голый 'watchdog' исключён,
#     оставлен 'watchmedo' (CLI python-watchdog) и второй grep отсекает
#     hardware-демон по полному пути.
#     set +e: ps/grep на пустом наборе возвращают ненулевой код — это не ошибка.
run_remote "watchers.txt" \
    "set +e
     echo '=== процессы-наблюдатели (event-driven, file-watch) ==='
     out=\$(ps -eo comm,args 2>/dev/null \\
       | grep -E 'inotifywait|inotifywatch|fswatch|watchmedo' \\
       | grep -vE 'grep|/usr/sbin/watchdog|\\bwatchdogd\\b')
     if [ -z \"\$out\" ]; then
       echo 'пусто (file-watcher'\\''ов не найдено)'
     else
       echo \"\$out\"
     fi
     true"

# 17. Health-flags — готовая сводка здоровья хоста (находка /retro 2026-06-14:
#     агент не должен грепать swap/disk/exited вручную из сырья). Агрегируем
#     на сервере в один проход; Шаг 7 SKILL презентует это как есть.
run_remote "health-flags.txt" \
    "set +e
     free | awk '/Swap:/{t=\$2;u=\$3; if(t>0) print \"swap_used_pct=\" int(u*100/t); else print \"swap_used_pct=0 (swap off)\"}'
     df -P / | awk 'NR==2{print \"root_used_pct=\" \$5}'
     uptime | grep -oE 'load average.*' | sed 's/load average://; s/^/loadavg=/'
     echo \"exited_containers=\$(docker ps -aq --filter status=exited 2>/dev/null | wc -l | tr -d ' ')\"
     echo \"oom137_containers=\$(docker ps -a --filter exited=137 --format '{{.Names}}' 2>/dev/null | tr '\\n' ' ')\"
     echo \"apt_upgradable=\$(LC_ALL=C apt list --upgradable 2>/dev/null | grep -c upgradable)\"
     echo \"apt_security=\$(LC_ALL=C apt list --upgradable 2>/dev/null | grep -ci security)\"
     true"

# === Итог ===
FILE_COUNT=$(find "$SNAPSHOT_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')
echo ""
echo "======================================================"
echo "Снимок сохранён в ${SNAPSHOT_DIR}"
echo "Файлов: ${FILE_COUNT}"
echo "======================================================"