---
name: inventory-scan
description: |
  Read-only инвентаризация сервера: dump-snapshot.sh → 9 текстовых документов в inventory/
  (services, networks, volumes, databases, domains, cron, host-scripts, automations, server)
  + до 5 mermaid-диаграмм в inventory/diagrams/ (topology, services-network, domains-routing,
  vpn-architecture, automations). Сравнение с прошлым inventory с выделением drift'ов. Green Zone.
  Триггеры: «инвентаризация», «снять снимок сервера», «что у меня на сервере», «обновить inventory»,
  «обнови схемы инфры», «отрисуй диаграмму», «scan server», «inventory drift», «refresh inventory».
  НЕ для изменений на сервере (это cleanup-existing-server и др.); НЕ для аудита безопасности
  (audit-security).
allowed-tools: Bash, Read, Edit, Write
---

<role>
Я снимаю полный снимок реального состояния сервера, генерирую или обновляю текстовый
inventory и выделяю drift'ы между документацией и реальностью. Я работаю в Green Zone —
только чтение, никаких изменений на сервере.
</role>

<context>
Что предполагается:
- SSH-доступ к серверу настроен (агентский ключ, BatchMode=yes работает)
- Docker установлен и работает на сервере
- Структура `inventory/hosts/<host>/` существует или будет создана при первом запуске

Что НЕ предполагается:
- Mock-сервер или dry-run — скилл нужен для реального снимка реальности
- Изменение состояния сервера — это Yellow/Red Zone, для них есть другие скиллы
  (cleanup-existing-server, deploy-service)
- Наличие свежего бэкапа — скилл read-only, бэкапы не нужны
</context>

<goals>
После выполнения:
- Snapshot создан в `inventory/hosts/<host>/snapshots/YYYY-MM-DD/`
- Snapshot содержит все ожидаемые файлы (containers, networks, volumes, host-resources,
  crontab, nginx-sites, tls-certs, host-scripts-content, host-env-redacted, cron-d-content,
  systemd-enabled, systemd-timers, watchers, compose-files, containers-summary.json,
  docker-endpoints.txt,
  health-flags) — проверяется по непустоте ключевых, не по суммарному размеру
- 9 inventory-документов в `inventory/hosts/<host>/` обновлены или созданы из шаблона
  (`automations.md` — только при наличии хоть одной автоматизации)
- Drift между inventory и реальностью явно обозначен в `drift-report.md` свежего snapshot
- Honest unknown применён везде, где данные отсутствуют (`? уточнить` или `нет данных` —
  никаких выдуманных значений)
</goals>

# Параметры

| Параметр | Default | Описание |
|----------|---------|----------|
| `SSH_HOST` | (обязательный) | SSH-target — `user@<your-server-ip>`, SSH-алиас из `~/.ssh/config` или `local` (без SSH) |
| `INVENTORY_DIR` | `inventory` | Корневая папка inventory (относительно репо) |
| `SNAPSHOT_DATE` | `$(date +%Y-%m-%d)` | Дата снимка (формат YYYY-MM-DD) |
| `RETENTION_SNAPSHOTS` | `10` | Сколько последних snapshots оставлять |

# Процедура

## Шаг 1. Pre-check

Проверяю предусловия одной командой:

```bash
# SSH-доступ
ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_HOST" 'echo ok' || {
  echo "ОШИБКА: SSH-доступ к $SSH_HOST не настроен"; exit 1; }

# Существующий inventory
mkdir -p "$INVENTORY_DIR/hosts/"

# Конкурентный лок (P22): два одновременных скана пишут в одни файлы → гонка.
# Атомарно через mkdir (НЕ -p: падает, если каталог уже есть). Зависший лок
# старше 30 мин (предыдущий скан упал) снимаем как stale.
LOCK="$INVENTORY_DIR/.scan.lock"
[ -d "$LOCK" ] && find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null | grep -q . && {
  echo "→ лок старше 30 мин — снимаю как зависший (stale)."; rm -rf "$LOCK"; }
if mkdir "$LOCK" 2>/dev/null; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "$LOCK/started_at" 2>/dev/null
  echo "→ лок inventory-scan взят: $LOCK"
else
  echo "СТОП: уже идёт inventory-scan (лок $LOCK, начат $(cat "$LOCK/started_at" 2>/dev/null || echo '?'))."
  echo "      Дождись его завершения. Если уверен, что скан не идёт — сними лок: rm -rf \"$LOCK\"."
  exit 1
fi
```

Если SSH не настроен — стоп, без выдумывания «возможно, ключ ниже». Прошу оператора
проверить ключ и повторить. **Лок держится до Шага 7** (снимается в конце или при отмене —
освобождаю `rm -rf "$LOCK"`, чтобы не заблокировать следующий скан).

## Шаг 2. Запуск dump-snapshot.sh

**Каноничное имя папки хоста — из `infra-config.json` `servers[].alias`**, не из
SSH-аргумента: иначе алиас `hoster` создаст `prod-hoster` вместо записанного
`prod-198.51.100.7` и раздвоит inventory (находка /retro 2026-06-14). Резолвлю канон и
передаю в скрипт через env `HOST_DIR` — при расхождении с SSH-target скрипт громко
предупредит и возьмёт канон:

```bash
INFRA="$(dirname "$INVENTORY_DIR")"
HOST_DIR="$(jq -r '.servers[0].alias // empty' "$INFRA/infra-config.json" 2>/dev/null)"
export HOST_DIR   # пусто → скрипт выведет из SSH-target (fallback)
bash scripts/dump-snapshot.sh "$SSH_HOST" "$SNAPSHOT_DATE" "$INVENTORY_DIR"
```

Скрипт собирает (через single-shot SSH с timeout 10c):

- Список контейнеров по КАЖДОМУ Docker-демону (`containers.txt` — объединённый,
  `containers.<tag>.txt` — по демонам) и безопасная проекция полей
  (`containers-summary.json`, schema 1). Карта демонов — `docker-endpoints.txt`
- Список compose-файлов (`compose-files.txt`)
- Docker-сети и volumes (`networks.txt`, `volumes.txt`)
- Ресурсы хоста — uptime, память, диск, открытые порты, доступные APT-обновления
  (`host-resources.txt`)
- Crontab + `/etc/cron.d/*` (`crontab.txt`, `cron-d-content.txt`)
- nginx-конфиг через `nginx -T` (`nginx-sites.txt`)
- TLS-сертификаты (letsencrypt + acme.sh) — **даты валидности** через `openssl x509`
  (`tls-certs.txt`); openssl бежит по обоим источникам (фикс /retro)
- Список и содержимое host-скриптов в `/opt/*.sh` (`host-scripts-list.txt`,
  `host-scripts-content.txt`)
- Структура .env-файлов на хосте (имена переменных, значения redacted)
  (`host-env-redacted.txt`)
- Включённые systemd-юниты (`systemd-enabled.txt`)
- systemd-таймеры оператора — расписание наравне с cron на Ubuntu 24.04 (`systemd-timers.txt`)
- Скрипты-наблюдатели — долгоживущие процессы inotify/fswatch/watchdog,
  слушающие события, а не запускаемые по расписанию (`watchers.txt`)
- Готовая сводка здоровья хоста (`health-flags.txt`) — swap%, disk%, loadavg,
  exited-контейнеры, OOM-коды 137, число отложенных apt/security-обновлений
- Метаданные снимка (`meta.txt`)

**Verify по СОДЕРЖАНИЮ, не по суммарному размеру.** Малый сервер даёт снимок <1 МБ — это
норма, а не сбой (порог «≥1 МБ» давал false-negative на валидном снимке 324 КБ — находка
/retro). Проверяю непустоту ключевых файлов и парсинг JSON:

```bash
SNAPSHOT_DIR="$INVENTORY_DIR/hosts/$HOST_DIR/snapshots/$SNAPSHOT_DATE"
ok=1
for f in containers.txt networks.txt host-resources.txt; do
  [ -s "$SNAPSHOT_DIR/$f" ] || { echo "ОШИБКА: пустой ключевой файл $f"; ok=0; }
done
jq -e '.schema_version and (.containers|type=="array")' "$SNAPSHOT_DIR/containers-summary.json" >/dev/null 2>&1 \
  || { echo "ОШИБКА: containers-summary.json не парсится или без схемы"; ok=0; }
# Демоны: снимок обязан честно перечислить endpoint'ы. Ни одного `ok` — это не
# «пустой сервер», а отказ сбора: разбираться, а не считать снимок валидным.
grep -q '|ok$' "$SNAPSHOT_DIR/docker-endpoints.txt" 2>/dev/null \
  || { echo "ОШИБКА: ни один Docker-демон не отдал данные (см. docker-endpoints.txt)"; ok=0; }
[ "$ok" = 1 ] || { echo "ОШИБКА: snapshot неполный"; exit 1; }
```

Где `$HOST_DIR` = канон из `infra-config.json` (`prod-<ip>` для удалённых или
`local-<hostname>` для локальной машины).

## Шаг 3. Сравнение с существующим inventory

Две независимые оси сравнения — **не смешивать** (находка /retro: их смешение даёт
«мнимый drift», когда снимок просто старее обновлённого inventory):

**Ось A — что изменилось на сервере** (снимок-к-снимку, стабильный источник
`containers-summary.json`, НЕ grep по рукописному `services.md`). **Сравнивать только
в пределах одного демона** — иначе смена активного контекста выглядит как исчезновение
всех сервисов (грабля 2026-08-08):

```bash
HOSTD="$INVENTORY_DIR/hosts/$HOST_DIR"
PREV="$(ls -1d "$HOSTD/snapshots"/*/ 2>/dev/null | sort | tail -2 | head -1)"
diff <(jq -r '.containers[] | "\(.daemon)\t\(.Name)"' "$PREV/containers-summary.json" 2>/dev/null | sort) \
     <(jq -r '.containers[] | "\(.daemon)\t\(.Name)"' "$SNAPSHOT_DIR/containers-summary.json" | sort)
```

**Ось B — что не задокументировано** (реальность ↔ `services.md`). `services.md` ведёт
контейнеры **таблицей** `| имя | … |`, поэтому проверяю присутствие каждого имени как
ячейки, а не паттерном `container_name:` (его в формате нет — давал ложный drift на все
контейнеры):

```bash
for name in $(jq -r '.containers[].Name' "$SNAPSHOT_DIR/containers-summary.json"); do
  grep -qE "^\| *$name *\|" "$HOSTD/services.md" || echo "drift+ (не задокументирован): $name"
done
```

**Тома** сверяю по ИМЕНАМ (`docker volume ls` — часть `volumes.txt` ДО строки `---`),
не по `docker system df` (волатильные относительные даты `3 weeks ago` дают шум-diff).

Drift-категории: **drift+** (есть в реальности, нет в inventory) / **drift-** (есть в
inventory, нет в реальности) / **drift~** (расхождение полей — порт, образ, статус).

Результат — `$SNAPSHOT_DIR/drift-report.md`. Нет drift'ов — пишу «drift'ов не найдено,
inventory синхронен». **Мнимый drift** (снимок старее, чем уже обновлённый inventory)
помечаю отдельно как объяснённый, не как реальное расхождение.

## Шаг 4. Обновление 9 inventory-документов

Для каждого документа (services / networks / volumes / databases / domains / cron /
host-scripts / automations / server):

- Если документ существует — `Edit` правлю изменённые строки, добавляю пометку
  `<!-- snapshot YYYY-MM-DD: было X, стало Y -->` рядом со старым значением
- Если не существует — генерирую из `templates/inventory-doc-template.md`,
  подставляю данные из snapshot

Никогда не переписываю файл с нуля — теряется история ручных правок и комментариев
оператора.

**`automations.md` — сводная витрина (генерируется только при наличии автоматизаций).**
Это «оглавление всего, что работает само». Колонки: `name | trigger | schedule | runs |
touches | log | status`. Агрегирую данные из четырёх источников:

- `crontab.txt` / `cron-d-content.txt` → trigger `cron`
- `systemd-timers.txt` → trigger `systemd-timer` (расписание из `list-timers`, что
  запускается — из парного `*.service` юнита)
- `watchers.txt` → trigger `watcher` (событие, не расписание)
- `host-scripts-content.txt` → чем pipeline/скрипт занят (для колонки `touches`)

Колонка `touches` — главная: что автоматизация трогает (БД из `databases.md`, сервис
из `services.md`, внешний API — Telegram/RSS/Claude). Это **источник связей** для
диаграммы `automations.mmd`. Не дублирую `cron.md`/`host-scripts.md` слово в слово —
агрегирую и осмысляю. Если автоматизаций на сервере нет — документ не создаю.

## Шаг 4.5. Mermaid-диаграммы инфраструктуры

После обновления текстовых документов inventory — обновить визуальные mermaid-диаграммы в `$INFRA/inventory/diagrams/`.

**Шаблоны** (5 файлов) лежат в публичном репо: `<sysadmin-root>/.claude/skills/inventory-scan/templates/diagrams/`.

**Алгоритм:**

```bash
DIAGRAMS_DIR="$INFRA/inventory/diagrams"
TEMPLATES_DIR="<SYSADMIN_ROOT>/.claude/skills/inventory-scan/templates/diagrams"

mkdir -p "$DIAGRAMS_DIR"

# Если папка пустая (первый запуск) — копирую все шаблоны
if [ -z "$(ls -A "$DIAGRAMS_DIR" 2>/dev/null)" ]; then
    cp "$TEMPLATES_DIR"/*.mmd "$DIAGRAMS_DIR/"
    cp "$TEMPLATES_DIR/README.md" "$DIAGRAMS_DIR/"
fi
```

**Что обновляется в каждой диаграмме** (использую `Edit`, не переписываю целиком):

1. **`topology.mmd`** — высокоуровневая карта. Источник: `services.md` (группы), `domains.md` (внешние домены), `server.md` (имя хоста, провайдер, IP). Группа `automations` появляется **только при непустом `automations.md`** — показываю факт наличия + 1-2 ключевые связи (например, pipeline → Postgres, pipeline → Telegram), без детализации триггеров (детали — в `automations.mmd`).
2. **`services-network.mmd`** — Docker-сети + контейнеры + порты. Источник: `networks.md` + `services.md` (колонки «Порт» и «Сеть»).
3. **`domains-routing.mmd`** — домен → nginx → upstream. Источник: `domains.md` + nginx-конфиги из snapshot (`nginx-sites.txt`).
4. **`vpn-architecture.mmd`** — **только если** `vpn.enabled: true` в `infra-config.json`. Иначе удалить файл из `diagrams/` (если был от прошлого запуска). Источник: `infra-config.json` секция vpn + `services.md` (3x-ui контейнер) + `networks.md` (mixed inbound если есть).
5. **`automations.mmd`** — **только если** на сервере есть хоть одна автоматизация (непустой `automations.md`). Иначе удалить файл из `diagrams/` (если был от прошлого запуска) — по образцу `vpn-architecture.mmd`. Показывает три колонки: триггеры (cron/timer/watcher/manual) → автоматизации → что трогают (БД/сервисы/внешние API). Пунктир `-.запускает.->` от триггера к автоматизации, сплошная `-->` к тому, что трогает. Источник: `automations.md` (колонка `touches` даёт связи) + `cron.md` + `host-scripts.md` + `systemd-timers.txt` + `watchers.txt`.

**Правила:**

- Все плейсхолдеры `<...>` из шаблона должны быть заменены на реальные значения. Если данных нет — `<? уточнить>` (видно что незаполнено).
- Стили (`classDef`) не трогать — единый визуальный язык.
- Не удалять `%%` комментарии в начале файла — они нужны будущим читателям.
- В конце каждой диаграммы — комментарий `%% Last updated: YYYY-MM-DD by /inventory-scan`.

**Проверка валидности:** если установлен `mmdc` (mermaid CLI) — запустить `mmdc -i diagrams/<file>.mmd -o /tmp/test.svg` для каждой обновлённой диаграммы, убедиться что синтаксис валидный. Если `mmdc` не установлен — пропустить, только предупредить оператора одной строкой.

**Поведение при первом запуске на сервере с уже существующим хаосом** (через `cleanup-existing-server`): шаблоны копируются с плейсхолдерами, заполняются настолько, насколько inventory заполнен. Дозаполнение — при следующих прогонах после `cleanup`.

## Шаг 5. Honest unknown — везде

Если данные не получены (snapshot-файл пустой, syntax error, поле отсутствует) —
ставлю `? уточнить` или `нет данных`. **NEVER** выдумываю правдоподобные значения.

Это правило перекрывает любые другие — лучше пустое поле, чем красивая ложь.
Подробнее — `references/dump-snapshot-quirks.md` (известные баги и их симптомы).

## Шаг 6. Cleanup старых snapshots

```bash
# Оставляем последние RETENTION_SNAPSHOTS, остальные удаляем
find "$INVENTORY_DIR/hosts/<host>/snapshots/" -mindepth 1 -maxdepth 1 -type d \
  | sort -r | tail -n +$((RETENTION_SNAPSHOTS+1)) | xargs -r rm -rf
```

Сортировка по имени (snapshots датированы), не по `-mtime` — `find -mtime +N` округляет
вниз до целых дней (типичная грабля при чистке временных файлов).

## Шаг 7. Отчёт оператору

Формирую короткий отчёт в чат:
- Дата и путь нового snapshot
- **Сводка здоровья из `health-flags.txt`** — подаю готовое (swap%, disk%, loadavg,
  exited-контейнеры, OOM-137, отложенные apt/security-обновления), не грепаю сырьё руками
- **Enforcement `automations.md`:** если в снимке есть автоматизации (непустые cron/
  systemd-timers/watchers), а `inventory/hosts/$HOST_DIR/automations.md` отсутствует —
  отдельной строкой «автоматизации есть, витрина не создана → нужен Шаг 4»
- Список drift'ов (если найдены) — с категориями + / - / ~; мнимый drift помечен отдельно
- Список изменённых inventory-документов
- **Список обновлённых mermaid-диаграмм** (`diagrams/topology.mmd`, и т.д.). Если первая инвентаризация и диаграммы созданы с нуля — отметить «созданы из шаблонов». Если есть автоматизации — отдельной строкой отметить `diagrams/automations.mmd` и группу `automations` в `topology.mmd`; если автоматизаций нет — отметить, что диаграмма автоматизаций не создана (нет данных).
- Рекомендации, если нужно: что ещё проверить вручную

Освобождаю конкурентный лок (взят на Шаге 1) — иначе следующий скан упрётся в «уже идёт»:

```bash
rm -rf "$LOCK"   # $INVENTORY_DIR/.scan.lock — снять в конце ИЛИ при любой отмене/ошибке
```

# Failed Attempts (граблекейс)

- **«tls-certs.txt syntax error»** — известный баг dump-snapshot v1, в v2 исправлен
  через `set +e` вокруг openssl-вызова. Симптом: tls-certs.txt пустой или содержит
  «openssl: unknown option». Лечение: убедиться, что используется bundled
  `scripts/dump-snapshot.sh` (v2), а не старый из `~/scripts/`.
- **«SSH-alias из ~/.ssh/config не работает в bash sandbox»** — sandbox запускает bash
  без загрузки пользовательской конфигурации SSH. Лечение: использовать прямой
  `user@host` вместо алиаса, ключ через `-i` если нужен явный.
- **«find -mtime +N округляет вниз»** — `find -mtime +1` найдёт файлы старше **2 дней**,
  а не 1. Для retention снимков использовать сортировку по имени, не -mtime.
- **«python-regex редакция не покрывает все паттерны»** — `host-env-redacted.txt`
  маскирует только `=value`, но в URL вида `postgres://user:pass@host` пароль
  виден. Лечение: добавлять новые regex-паттерны при обнаружении (см.
  `references/dump-snapshot-quirks.md`).
- **«ложный drift на все контейнеры»** — ИСПРАВЛЕНО (находка /retro 2026-06-14). Симптом:
  Шаг 3 грепал `container_name:` по `services.md`, а тот ведёт контейнеры таблицей
  `| имя | … |` → diff показывал «20 недокументированных». Лечение: ось A — снимок-к-снимку
  по `containers-summary.json`; ось B — таблично-aware проверка имени в `services.md`.
- **«TLS-expiry не считается на acme.sh-хостах»** — ИСПРАВЛЕНО (находка /retro 2026-06-14).
  Симптом: `tls-certs.txt` содержал только `ls -la` (даты файлов), хотя description обещает
  «даты валидности». Причина: openssl бежал только по `/etc/letsencrypt/live`. Лечение:
  `openssl x509 -enddate` теперь и по `~/.acme.sh/*/fullchain.cer`.
- **«HOST_DIR из SSH-аргумента раздваивал inventory»** — ИСПРАВЛЕНО (находка /retro
  2026-06-14). Симптом: алиас `hoster` → папка `prod-hoster` вместо записанной
  `prod-198.51.100.7`. Лечение: канон из `infra-config.json` `servers[].alias` через env
  `HOST_DIR`; при расхождении с SSH-target скрипт громко предупреждает и берёт канон.
- **«verify заваливал валидный малый снимок»** — ИСПРАВЛЕНО (находка /retro 2026-06-14).
  Симптом: порог «размер ≥1 МБ» — false-negative на снимке 324 КБ. Лечение: проверка
  непустоты ключевых файлов + парсинг `containers-summary.json` через jq, не суммарный размер.
- **«снимок видел только один Docker-демон»** — ИСПРАВЛЕНО (v3, находка 2026-08-08).
  Симптом: `docker ps` шёл в активном контексте пользователя (`rootless`), и боевой стек
  в снимок не попадал ВООБЩЕ; снимки за разные даты оказывались сняты с разных демонов и
  становились несопоставимы. Лечение: перечисление отвечающих сокетов + endpoint'ов
  контекстов, различение по daemon ID, `docker-endpoints.txt` с явной отметкой
  `unreachable`/`duplicate-id`, файлы по демонам (`containers.<tag>.txt`).
- **«секреты в сыром inspect»** — ИСПРАВЛЕНО ИНАЧЕ (v3). Маскировка как последняя линия
  обороны — растущий чёрный список: 2026-08-08 сквозь неё прошли ключ `sb_secret_` из
  многострочного значения env и приватный TLS-ключ из `Args`/`Entrypoint`. Теперь сырой
  `docker inspect` в снимок не переносится вообще: пишется проекция белого списка полей
  (`containers-summary.json`, фильтр `scripts/summary-filter.jq`), значения переменных
  окружения не сохраняются никогда — только имена. Без `jq` проекция не выполняется
  (fail-closed), вместо неё кладётся `containers-summary.SKIPPED.txt`. Проверяется
  `tests/test-inventory-scan.sh` (приманка — opaque-маркер; «gitleaks чист» доказательством
  не считается).
- **«host-скрипты искались не там»** — ИСПРАВЛЕНО (v3). Симптом: список строился по
  `/opt/*.sh`, `/usr/local/{bin,sbin}/*.sh`, `/root/bin/`, а реальные 16 скриптов лежали в
  `/opt/backup/` и `/opt/*/ops/` — inventory числил один. Лечение: обход `ExecStart`
  включённых service/timer/path-юнитов с разворачиванием обёрток `/bin/bash -lc '…'`;
  прежние каталоги оставлены как дополнение.
- **«секреты в containers-inspect.json»** — ИСПРАВЛЕНО (redaction v1). Скрипт
  маскирует env-секреты (`KEY=value` и креды в URL) **до записи на диск** —
  не полагаясь только на `.gitignore`. Метки в `meta.txt`: `redaction_applied: true`.
  Подробности — `references/dump-snapshot-quirks.md`. gitleaks по этому файлу больше
  не должен находить реальных секретов; имена переменных (`*_API_KEY=<REDACTED>`)
  остаются для аудита.

# Граничные случаи

- **Сервер недоступен (down)** — скилл валит с явной ошибкой ещё на Pre-check, не
  генерирует пустой snapshot
- **Disk full на сервере** — некоторые секции snapshot частично собраны, отчёт явно
  говорит «частичный snapshot, причина: disk full». В drift-report не доверяем
  частичным данным
- **Контейнер в restart loop** — попадает в snapshot со статусом `Restarting (N)`,
  в drift-report помечается отдельно как «требует внимания»
- **Несколько серверов** — переключаются параметром `SSH_HOST`. Не запускать
  одновременно (нет locking) — снимки будут вперемешку
- **Локальный режим (`SSH_HOST=local`)** — собирает данные с локальной машины через
  `eval`, не SSH. Полезно для разработки или mock-инфраструктуры

# Bundled resources

- `scripts/dump-snapshot.sh` — основной dump-скрипт (v2, копия из
  `scripts/inventory/dump-snapshot.sh` проекта-носителя)
- `templates/inventory-doc-template.md` — общий шаблон inventory-документа
- `references/dump-snapshot-quirks.md` — известные баги, симптомы, обходы