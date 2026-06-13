---
name: sysadmin-init
description: |
  Интерактивная настройка/перенастройка агента-сисадмина под проект: создаёт ДВА конфига —
  agent-config.json (мозг: оператор, язык, менеджер паролей, реестр проектов) в корне sysadmin/
  и infra-config.json (карта: серверы, мониторинг-стек, бэкапы, Telegram, VPN-блок) в папке проекта,
  оба с валидацией по своим JSON Schema (ADR-0013).
  Режимы: первичный setup (нет конфига → интервью), идемпотентный no-op (конфиг есть → подсказка),
  --reconfigure (показывает текущее, спрашивает что менять), миграция legacy sysadmin-config.json
  (старый всё-в-одном → расщепление на два файла).
  Триггеры: «настрой агента», «первый запуск», «init agent», «/sysadmin-init», «хочу как у Василия»,
  «перенастрой конфиг», «поменять язык агента», «переключить менеджер паролей».
  НЕ для знакомства с агентом (sysadmin-meet); НЕ для настройки серверов (bootstrap-new-server).
allowed-tools: AskUserQuestion, Bash, Read, Write, Edit, WebSearch
---

<role>
Я провожу интерактивную первичную настройку и перенастройку агента-сисадмина под проект
оператора. На выходе — ДВА конфига (ADR-0013):

- **`agent-config.json`** (МОЗГ агента) — в корне публичного репо `sysadmin/`. Содержит
  оператора (имя, язык, таймзона), менеджер паролей, реестр проектов-инфраструктур
  (`projects[]`) и какой из них активен по умолчанию (`default_project`), мета-онбоардинг.
- **`infra-config.json`** (КАРТА инфры) — в папке проекта (`infra_root`), рядом с
  `inventory/`, `knowledge/`, `decisions/`. Содержит серверы, мониторинг, бэкапы,
  Telegram, VPN, опциональное оглавление `map`.

Оба валидны по своим JSON Schema (`agent-config.schema.json`, `infra-config.schema.json`).
Без них часть скиллов агента, требующих контекст оператора (install-monitoring-stack,
setup-backups, audit-security, setup-secrets-vault и другие, читающие конфиг),
останавливаются с понятным сообщением «запусти /sysadmin-init». Я — единственный
официальный путь создания, обновления и миграции этих конфигов.

Стиль общения — сеньор-ментор: на «ты», по-русски, простыми словами. Перед сложным
техническим вопросом (менеджер паролей, мониторинг, бэкапы) даю мини-урок и рекомендацию,
чтобы оператор-вайбкодер мог ответить «давай как ты советуешь» и двинуться дальше.
</role>

<context>
Когда меня вызывают:
- Оператор только что склонировал репо `infra` и пытается работать с агентом → Cold Start
  в персоне (раздел 7.1) указал на меня.
- Оператор хочет поменять что-то в существующем конфиге (новый сервер, смена менеджера
  паролей, переезд на другой Telegram-бот) — флаг `--reconfigure`.
- Срабатывает триггер из description («настрой агента», «перенастрой конфиг» и т.п.).

Что я предполагаю:
- `agent-config.schema.json` и `infra-config.schema.json` уже существуют в корне репо
  (созданы планом расщепления ADR-0013).
- На машине оператора есть `jq` (≥ 1.6) — иначе скажу установить.
- Желательно `check-jsonschema` — но я работаю и без него (fallback на минимальную
  валидацию через jq).
- У оператора есть `~/.ssh/config` (если нет — спрошу алиас вручную).

Что я НЕ делаю:
- Не создаю секреты (токены, пароли) — это `setup-secrets-vault`. Я только записываю
  ИНДЕКС: какой менеджер паролей, какой бот, без значений токенов.
- Не настраиваю SSH-доступ к серверу (это `bootstrap-new-server`).
- Не ставлю мониторинг (это `install-monitoring-stack`). Я только записываю в конфиг
  желание оператора — потом отдельный скилл это разворачивает.
- Не добавляю серверы в `inventory/` (это делает `inventory-scan`).
- Не делаю multi-server в v1.0 — поддерживаю один сервер, остальные оператор добавит
  вручную в `servers[]` (схема это разрешает).
- Не делаю multi-project в v1.0 — интервью заводит ОДИН проект в `projects[]` +
  `default_project` = его id. Дополнительные проекты оператор добавит вручную в
  `agent-config.json` (схема разрешает массив `projects[]` любой длины ≥ 1).
</context>

<goals>
После выполнения должно стать TRUE:
- В корне `sysadmin/` лежит валидный `agent-config.json` (мозг), проверенный
  `check-jsonschema` по `agent-config.schema.json` (или jq-fallback).
- В папке проекта (`infra_root`) лежит валидный `infra-config.json` (карта),
  проверенный по `infra-config.schema.json` (или jq-fallback).
- Оба конфига отражают реальные ответы оператора (не плейсхолдеры из `example.json`).
- При повторном запуске без флага → `no-op` + подсказка про `--reconfigure`.
- При запуске с `--reconfigure` → по каждому ключу показываю текущее значение и спрашиваю
  «оставить или поменять».
- Если найден старый `sysadmin-config.json` (всё-в-одном) — предлагаю миграцию:
  расщепить на два новых файла, старый сохранить как `.bak`.
- Оператор знает, что делать дальше — какие скиллы запускать в каком порядке.
- Старые версии файлов (если были) сохранены как `<имя>.bak.YYYYMMDD-HHMMSS`.
</goals>

# Режимы работы

| Режим | Команда | Поведение |
|-------|---------|-----------|
| Первичный setup | `/sysadmin-init` | Конфигов нет → интервью → пишу agent-config.json (мозг) + infra-config.json (карта) |
| Идемпотентный no-op | `/sysadmin-init` | Оба конфига уже есть → «уже настроено, для перенастройки — `/sysadmin-init --reconfigure`» → выход 0 |
| Перенастройка | `/sysadmin-init --reconfigure` | Конфиги есть → показываю текущие значения → по каждому ключу «оставить или поменять» |
| Миграция legacy | `/sysadmin-init` (детект) | Найден старый `sysadmin-config.json` (всё-в-одном) → предлагаю расщепить на два новых файла |

# Процедура

## Шаг 0: Pre-check (5 секунд, без вопросов оператору)

### Шаг 0.0: Гейт окружения — ПЕРВЫМ ДЕЛОМ, до всего остального

**Зачем:** весь этот скилл стоит на `bash` и `jq`. На нативном Windows Claude Code
использует bash только если установлен Git for Windows; `jq` не входит в Git for
Windows вообще и ставится отдельно. Если этого не проверить ЯВНО — машинерия молча
падает на середине, а я (агент) начинаю импровизировать руками и создаю суррогаты
(мёртвый `infra.md` вместо нормальной папки `infra/` с `sysadmin-config.json`).
Это реальный инцидент (2026-05-24), ради него этот гейт и появился.

```bash
# Гейт: bash есть (раз скрипт исполняется), проверяем/доустанавливаем jq.
# Определяем корень репо ОДНИМ способом — через locate_sysadmin_root из find-config.sh
# (он кросс-платформенный: понимает /home/..., /c/Users/... и C:\Users\... в bridge-файле).
# Это единый источник истины; не дублируем grep-regex в скилле.

# Шаг А: найти find-config.sh. Пробуем относительный путь от скилла, затем — типичные
# локации репо. Если не нашли — сообщаем и STOP (без helper'ов работать нельзя).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || SCRIPT_DIR="$(pwd)"
LIB=""
for cand in \
    "$SCRIPT_DIR/../../_lib" \
    "./.claude/skills/_lib" \
    "../sysadmin/.claude/skills/_lib" \
    "$HOME/sysadmin/.claude/skills/_lib"; do
    [ -f "$cand/find-config.sh" ] && { LIB="$(cd "$cand" && pwd)"; break; }
done
if [ -z "$LIB" ]; then
    echo "Не нашёл общие helper'ы (.claude/skills/_lib/). Запусти /sysadmin-init из"
    echo "папки sysadmin/ или укажи путь к репо. Без helper'ов настройка невозможна."
    exit 1
fi

# Шаг Б: гейт окружения (bash+jq) — ПЕРВЫМ, до любой работы с конфигом.
source "$LIB/ensure-local-env.sh"
ensure_local_env || exit 1   # STOP если окружение непригодно — НЕ продолжаю импровизацией

# Шаг В: корень репо для последующих шагов (схема, шаблоны, скрипты).
source "$LIB/find-config.sh"
locate_sysadmin_root || SYSADMIN_ROOT="$(cd "$LIB/../../.." && pwd)"
```

**Если гейт вернул exit 1 (jq не поставился или нет bash):** STOP. Сообщаю оператору
ровно ту инструкцию, которую напечатал гейт (про winget/brew/apt или ручную установку
+ перезапуск сессии). **NEVER** обходить отсутствие jq «ручной сборкой JSON» — это путь
к суррогату `infra.md`. Запрет C.9 персоны имеет приоритет над желанием «всё-таки помочь».

> **⚠️ Важно про bash-блоки.** Claude Code может исполнять каждый ```bash-блок этого
> скилла в ОТДЕЛЬНОМ процессе — тогда переменные (`$LIB`, `$SYSADMIN_ROOT`, `$WORKDIR`,
> `$AGENT_PATH`, `$INFRA_CONFIG_PATH`) и `PATH` между блоками **теряются**. Поэтому: **(1)** старайся держать
> работу одного раунда в одном блоке; **(2)** в начале каждого блока, который использует
> helper'ы или jq, повтори мини-bootstrap (найти `$LIB` тем же циклом + `source
> "$LIB/find-config.sh"`). `source find-config.sh`/`ensure-local-env.sh` при каждом вызове
> сам дописывает `~/.sysadmin/bin` в `PATH` — поэтому скачанный jq виден и в новом процессе.
> Скачанный jq лежит в `~/.sysadmin/bin/jq` постоянно (не в temp), так что переживает и
> смену процесса, и перезапуск сессии — нужно лишь заново добавить папку в PATH, что и
> делает source helper'а.

### Шаг 0.1: Поиск конфигов (ДВА файла, ADR-0013)

**Важно про два файла и их места:**
- `agent-config.json` (МОЗГ) живёт в корне публичного репо `sysadmin/` — `$SYSADMIN_ROOT/agent-config.json`. Это «дом агента»: одно известное место, без перебора.
- `infra-config.json` (КАРТА) живёт в папке проекта (`infra_root` из реестра `projects[]`).

Алгоритм поиска — тот же что в Cold Start Protocol персоны (см. `references/cold-start.md`):
основной путь — `find_brain_config` читает мозг → `resolve_active_project` достаёт активный
проект → его `infra-config.json`. Перебор по типичным путям остаётся **только fallback**
(новый пользователь / старая установка до миграции).

Используй общий helper `_lib/find-config.sh` (уже подключён в Шаге 0.0). `$SYSADMIN_ROOT`
уже определён в Шаге 0.0 через `locate_sysadmin_root` (кросс-платформенно).

```bash
# $SYSADMIN_ROOT, find_brain_config, resolve_active_project, find_sysadmin_config —
# доступны из Шага 0.0 (там же source find-config.sh).

# 1) Есть ли уже МОЗГ (новый формат)?
BRAIN_PATH=""; BRAIN_EXISTS=false
INFRA_PATH=""; INFRA_CONFIG_PATH=""; INFRA_EXISTS=false
if find_brain_config; then
    BRAIN_PATH="$BRAIN_CONFIG"; BRAIN_EXISTS=true
    if resolve_active_project ""; then
        INFRA_PATH="$ACTIVE_INFRA_ROOT"
        INFRA_CONFIG_PATH="$ACTIVE_INFRA_CONFIG"
        INFRA_EXISTS=true
    fi
fi

# 2) Детект LEGACY всё-в-одном (sysadmin-config.json) — только если мозга ещё нет.
#    Перебираем те же типичные места, что и find-config.sh, но именно старое имя.
LEGACY_PATH=""
if [ "$BRAIN_EXISTS" != "true" ]; then
    for cand in \
        "./sysadmin-config.json" \
        "../infra/sysadmin-config.json" \
        "$HOME/infra/sysadmin-config.json" \
        "$HOME/work/infra/sysadmin-config.json" \
        "$HOME/projects/infra/sysadmin-config.json" \
        "${INFRA_DIR:-/dev/null}/sysadmin-config.json"; do
        if [ -f "$cand" ] && jq empty "$cand" >/dev/null 2>&1; then
            LEGACY_PATH="$(cd "$(dirname "$cand")" && pwd)/$(basename "$cand")"
            break
        fi
    done
fi

# 3) Идемпотентный выход без правок: оба новых файла на месте, флага нет.
if [ "$BRAIN_EXISTS" = "true" ] && [ "$INFRA_EXISTS" = "true" ] && [ "$ARG" != "--reconfigure" ]; then
    echo "Уже настроено:"
    echo "  мозг:  $BRAIN_PATH (operator/projects/default_project)"
    echo "  карта: $INFRA_CONFIG_PATH (servers/monitoring/backups)"
    echo "Для перенастройки запусти /sysadmin-init --reconfigure"
    exit 0
fi

# 4) Найден legacy и нового мозга нет → предлагаю МИГРАЦИЮ (см. Шаг 0.2).
#    Флаг MIGRATE=true сигналит дальнейшим шагам идти веткой миграции, а не интервью.
MIGRATE=false
if [ "$BRAIN_EXISTS" != "true" ] && [ -n "$LEGACY_PATH" ]; then
    MIGRATE=true
    echo "Обнаружен старый конфиг (всё-в-одном): $LEGACY_PATH"
    echo "Предложу расщепить его на два новых файла (agent-config + infra-config)."
fi

# jq уже гарантирован гейтом Шага 0.0. check-jsonschema — опционален.
command -v check-jsonschema >/dev/null \
  || echo "WARN: check-jsonschema не установлен. Будет fallback-валидация на jq."

# Единый временный каталог на всю сессию скилла. mktemp -d работает в Git Bash,
# WSL, macOS и Linux — в отличие от хардкода /tmp/ (на нативном Windows его нет,
# а в MINGW он мапится непредсказуемо). Чистим в конце (Шаг 10/11) или при отмене.
WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t sysadmin)"
[ -d "$WORKDIR" ] || { echo "ERROR: не удалось создать временный каталог"; exit 1; }

# Автодетект инфраструктуры (один JSON со всеми defaults)
bash "$SYSADMIN_ROOT/.claude/skills/sysadmin-init/scripts/detect-defaults.sh" > "$WORKDIR/sysadmin-defaults.json"
# Содержимое: { "ssh_aliases": [...], "os": "Darwin", "docker": true, "jq_version": "1.7", ... }
```

**Все дальнейшие временные файлы скилла — внутри `$WORKDIR`** (не `/tmp/`):
draft-конфиги `$WORKDIR/agent-config-draft.json` и `$WORKDIR/infra-config-draft.json`,
промежуточные `$WORKDIR/x`. Это и есть портируемость на Windows-Git-Bash.

**Если мозга нет (первичный setup):**
- В Раунде 1.5 (проект + путь к infra/) — спрашиваю id/title проекта и куда положить будущий `infra/`.
- На Шаге 10 (запись): `agent-config.json` → `$SYSADMIN_ROOT/agent-config.json`;
  `infra-config.json` → `$INFRA_PATH/infra-config.json`, где `$INFRA_PATH` — `infra_root`
  из Раунда 1.5 с раскрытым tilde.
- Если папка `$INFRA_PATH` не существует — сначала `mkdir -p "$INFRA_PATH"` (это безопасно,
  мы только создаём пустую папку под конфиг и будущий inventory).

### Шаг 0.2: Ветка миграции legacy (если `MIGRATE=true`)

Если на Шаге 0.1 найден старый `sysadmin-config.json` (всё-в-одном) и нового мозга ещё нет —
предлагаю расщепить. Через `AskUserQuestion` (radio): «Мигрировать сейчас» / «Не сейчас (выйти)».

**Правило раскладки полей при миграции:**

| Поле в старом `sysadmin-config.json` | Куда уезжает |
|---|---|
| `operator.name`, `operator.timezone` | `agent-config.operator` |
| `language` | `agent-config.operator.language` |
| `secrets.*` | `agent-config.secrets` |
| `meta.*` (онбоардинг) | `agent-config.meta` |
| `infrastructure.root_path` | `agent-config.projects[0].infra_root` |
| `monitoring`, `backups`, `notifications`, `servers`, `vpn`, `map` | `infra-config.*` |

```bash
# Расщепление legacy → два draft'а. $LEGACY_PATH из Шага 0.1.
AGENT_DRAFT="$WORKDIR/agent-config-draft.json"
INFRA_DRAFT="$WORKDIR/infra-config-draft.json"

# Раскрываем infra_root: из legacy берём infrastructure.root_path (резолвим от каталога legacy).
RAW_ROOT="$(jq -r '.infrastructure.root_path // empty' "$LEGACY_PATH")"
[ -z "$RAW_ROOT" ] && RAW_ROOT="$(cd "$(dirname "$LEGACY_PATH")" && pwd)"  # сам каталог legacy
INFRA_PATH="$(resolve_infra_path "$RAW_ROOT" "$LEGACY_PATH")" || INFRA_PATH="${RAW_ROOT/#\~/$HOME}"

# id проекта генерируем из alias первого сервера (или "main-server").
PROJ_ID="$(jq -r '(.servers[0].alias // "main-server")
  | ascii_downcase | gsub("[^a-z0-9-]";"-") | gsub("^-+|-+$";"")' "$LEGACY_PATH")"
[ -z "$PROJ_ID" ] && PROJ_ID="main-server"
PROJ_TITLE="$(jq -r '.servers[0].domain // "Основной проект"' "$LEGACY_PATH")"

# agent-config draft: operator + language + secrets + meta + projects[] + default_project.
jq --arg id "$PROJ_ID" --arg title "$PROJ_TITLE" --arg root "$INFRA_PATH" '
  {
    "$schema": "./agent-config.schema.json",
    version: "1.0",
    operator: {
      name: (.operator.name // "Оператор"),
      language: (.language // "ru"),
      timezone: (.operator.timezone // "UTC")
    },
    secrets: (.secrets // {manager:"keychain"}),
    projects: [ { id: $id, title: $title, infra_root: $root } ],
    default_project: $id,
    interaction: {},
    meta: (.meta // {onboarding_completed:false, onboarding_completed_at:null})
  }' "$LEGACY_PATH" > "$AGENT_DRAFT"

# infra-config draft: всё инфра-центричное, БЕЗ агент-полей и БЕЗ infrastructure.
jq '
  {
    "$schema": "./infra-config.schema.json",
    version: "1.0"
  }
  + (if .map then {map: .map} else {} end)
  + { monitoring: (.monitoring // {enabled:false}) }
  + { backups: (.backups // {enabled:false}) }
  + { notifications: (.notifications // {telegram:{enabled:false}}) }
  + { servers: (.servers // []) }
  + (if .vpn then {vpn: .vpn} else {} end)
' "$LEGACY_PATH" > "$INFRA_DRAFT"
```

После сборки draft'ов миграция идёт сразу на **Шаг 9 (валидация обоих)** → **Шаг 10
(превью + запись обоих)**, минуя интервью. На Шаге 10 старый `sysadmin-config.json`
переименовывается в `sysadmin-config.json.bak.YYYYMMDD-HHMMSS` (см. Шаг 10).

## Шаг 1: Приветствие (3-4 строки, дружелюбно)

> «Привет! Я помогу настроить агента под твой проект. Соберу базовый паспорт оператора:
> язык общения, менеджер паролей, какой у тебя сервер, что включено из мониторинга и
> бэкапов, куда слать алерты. Итог — ДВА файла: `agent-config.json` (мой мозг — кто ты,
> язык, твои проекты) в папке `sysadmin/`, и `infra-config.json` (карта сервера —
> мониторинг, бэкапы, домены) в твоей приватной папке инфры. Это займёт 3-5 минут. Если
> по какому-то вопросу не уверен — пиши «давай как ты советуешь», я подставлю разумные
> значения.»

## Шаг 2: Раунд 1 — Имя, язык, таймзона (простые вопросы, без обёртки)

Использую `AskUserQuestion` для типизированных вопросов (все три → блок
`operator` в `agent-config.json`):
- `operator.name` (text, default — `$USER` из `$WORKDIR/sysadmin-defaults.json`).
- `operator.language` (radio: `ru` / `en`, default `ru`).
- `operator.timezone` (text, default — системный из `date +%Z` или `Europe/Moscow`).

Эти три вопроса — без сеньор-обёртки, потому что оператор и так знает свои имя и язык.

## Шаг 2.5: Раунд 1.5 — Проект и путь к папке инфры (СЕНЬОР-ОБЁРТКА)

**Когда задавать:** сразу после Раунда 1, **до** Раунда 2. Без этого
ответа последующие раунды зависают: сервер/мониторинг/бэкапы пишутся
в `infra-config.json`, но агент не знает, в какую папку его положить и куда писать
`inventory/`, `decisions/`, `knowledge/`.

**Что заполняем** (реестр проектов `projects[]` в `agent-config.json` + `default_project`):
- `projects[0].id` — короткий машинный идентификатор (kebab-case, regex `^[a-z0-9][a-z0-9-]*$`).
  Если оператор не предлагает — генерирую из имени сервера/проекта (напр. `main-server`).
- `projects[0].title` — человекочитаемое название (опционально, для удобства).
- `projects[0].infra_root` — путь к папке инфры этого проекта (раньше это было
  `infrastructure.root_path`). **Рекомендуется абсолютный путь** — реестр в мозге не
  привязан к cwd. Tilde раскрывается.
- `default_project` = `projects[0].id` (в v1.0 один проект).

**Дефолт `infra_root`:** `../infra` (папка-сосед относительно `sysadmin/`) — если оператор
работает в родительской папке, где рядом лежат `sysadmin/` и `infra/`. Лучше — абсолютный
путь к этой папке.

**Краткая обёртка** (полная сеньор-обёртка из 6 шагов с мини-уроком,
таблицами, валидацией ответа и обработкой опечаток — `references/wizard-flow.md` §«Раунд 1.5»):

> «`sysadmin/` — публичный мозг агента, тут лежит `agent-config.json`. Твоя инфра (карта
> серверов, ADR, инциденты) — приватная и отдельная папка, в ней лежит `infra-config.json`.
> Мозг знает про твои проекты через реестр `projects[]` — каждый проект указывает на свою
> папку. Дай проекту короткое имя (напр. `main-server`) и скажи, где папка инфры. Если
> только склонировал — пиши `../infra` или «как советуешь». Если уже есть готовая папка —
> указывай реальный путь.»

`infra_root` записываю **как ввёл оператор** (с tilde — резолвер сам раскроет; абсолютный
путь предпочтительнее). Если родитель пути существует, но самой папки нет — нормально
(создам на Шаге 10). Если родителя нет — повторяю вопрос (опечатка). `id` валидирую по
regex; если ответ оператора не подходит — нормализую (`ascii_downcase`, замена не-`[a-z0-9-]`
на `-`) и показываю, что записал.

## Шаг 3: Раунд 2 — Менеджер паролей (СЕНЬОР-ОБЁРТКА)

**Поля:** `secrets.manager` (enum: `keychain` / `bitwarden` / `1password` /
`pass` / `keepassxc` / `other`), для `other` — также `secrets.manager_name`
и `secrets.cli_available`.
**Дефолт:** по OS — `keychain` для macOS, `pass` для Linux.

**Краткая обёртка** (полная — `references/wizard-flow.md` §«Раунд 2»
с мини-уроком про принцип «секреты не в репо», таблицей плюсов/минусов
и обоснованием по OS):

> «Менеджер паролей — где хранить токены/ключи (НЕ `.env`!). Принцип
> репо — только указатели «пароль от X — смотри Keychain под именем Y».
> Если macOS — `keychain` (встроен). Если Linux — `pass` (минимум
> зависимостей) или `bitwarden` (синхронизация между машинами).
> Если пользуешься другим (Kaspersky, Dashlane, NordPass, браузерный) —
> выбери «другой», разберёмся вместе. Можешь ответить «как советуешь».»

Вопрос через `AskUserQuestion` — варианты: известные менеджеры + «Другой
(назову свой)». Записываю в `secrets.manager`.

### Ветка «Другой менеджер» (manager=other) — research CLI + честный выбор

Если оператор выбрал «Другой» или назвал менеджер не из списка:

1. **Спрашиваю имя** менеджера → пишу в `secrets.manager_name` (например
   «Kaspersky Password Manager»).
2. **Провожу ресёрч** (WebSearch): есть ли у этого менеджера CLI, через который
   программа может читать секреты (запрос вида «<имя> password manager CLI
   command line export»). Не выдумываю ответ — если не нашёл достоверно, считаю
   «CLI нет/неизвестен».
3. **Объясняю расклад честно** (сеньор-обёртка), два сценария:

   **Есть CLI** → «У <имя> есть CLI `<команда>`. Тогда я смогу доставать секреты
   автоматически. Записываю `cli_available: true`. На шаге `/setup-secrets-vault`
   настроим.»

   **Нет CLI** (типично для Kaspersky/браузерных) → честно:
   > «У <имя> нет CLI, через который я мог бы доставать пароли автоматически.
   > Это значит: каждый раз, когда понадобится секрет, **ты будешь сам открывать
   > <имя>, копировать пароль и присылать мне** — медленно и неудобно при частых
   > операциях (деплой, бэкапы, ротация).
   >
   > Альтернатива: менеджер, с которым я умею работать сам — например **Bitwarden**
   > (мощный, бесплатный, кроссплатформенный — Windows/Mac/Linux, есть CLI `bw`).
   > Можешь продолжать хранить пароли в <имя> для личного, а для инфраструктуры
   > завести Bitwarden — тогда я буду автономным.
   >
   > Решай сам: **(а)** остаюсь на <имя>, секреты передаёшь руками (пишу
   > `cli_available: false`); **(б)** перехожу на Bitwarden (меняю `manager` на
   > `bitwarden`). Что выбираешь?»

4. Записываю по выбору: либо `manager=other` + `manager_name` + `cli_available`,
   либо `manager=bitwarden` (если оператор согласился перейти).

**Для известных менеджеров** (keychain/bitwarden/1password/pass/keepassxc) —
`cli_available: true` (у всех есть CLI), `manager_name` не нужен.

Подсказка после записи: «Реальные значения паролей сюда не пишу — они появятся
в выбранном менеджере, когда запустишь `/setup-secrets-vault`. Если CLI нет —
я буду указывать, где взять пароль руками, а не доставать его сам.»

## Шаг 4: Раунд 3 — Сервер (servers[])

Если в `$WORKDIR/sysadmin-defaults.json` поле `ssh_aliases` непустое — предлагаю выбор из
найденных алиасов через `AskUserQuestion` (radio). Если пустое — спрашиваю вручную.

Поля для одного сервера (v1.0):
- `alias` — короткое имя для inventory (default = выбранный `ssh_alias`).
- `ssh_alias` — алиас из `~/.ssh/config` (или вручную).
- `role` (radio: `production` / `staging` / `test` / `personal`).
- `domain` — основной домен сервера (опционально, можно пропустить).

**v1.0 поддерживает один сервер.** Если оператор спрашивает про второй — отвечаю:
«В v1.0 поддерживается один сервер через интервью. Multi-server отложено в v1.x — пока
добавишь второй сервер вручную в `servers[]`, схема разрешает массив любой длины ≥ 1.»

## Шаг 5: Раунд 4 — Мониторинг (СЕНЬОР-ОБЁРТКА)

**Поля:** `monitoring.enabled` (bool), при включённом — `monitoring.stack`
(массив компонентов из enum) и `monitoring.panel_domain` (hostname).

**Краткая обёртка** (полная — `references/wizard-flow.md` §«Раунд 4»
с мини-уроком про три слоя мониторинга, обоснованием отказа от
Prometheus+Grafana и таблицей вариантов):

> «Мониторинг — глаза агента. Три варианта:
> — Не ставить (тестовый сервер).
> — Базовый: uptime-kuma + beszel (uptime + метрики, ~80 МБ RAM).
> — Полный (★): + dozzle (логи) + dockge (управление) + diun (обновления
>   образов), ~150 МБ RAM. Для production рекомендую полный.»

Если выбрал «полный» или «базовый» → записываю `monitoring.enabled = true`
и `monitoring.stack`. Если включён → спрашиваю `panel_domain` (поддомен
для админ-панели, например `sysadmin.example.com`). Валидация: формат
hostname (regex `^[a-z0-9.-]+$`).

## Шаг 6: Раунд 5 — Бэкапы (СЕНЬОР-ОБЁРТКА)

**Поля:** `backups.enabled` (bool), при включённом — `backups.destination`
(enum), `backups.retention` (объект), для webdav-destination'ов также
`backups.rclone_remote`.

**Краткая обёртка** (полная — `references/wizard-flow.md` §«Раунд 5»
с мини-уроком про правило 3-2-1, таблицей destination'ов с плюсами/минусами,
обоснованием выбора по объёму и геолокации):

> «Бэкап — страховка от ошибок. Без него `rm -rf`/неудачное обновление —
> лотерея. Используем `restic` (шифрование + инкременты). Destination'ы:
> `yandex-disk-webdav` (1 ТБ бесплатно, для РФ-операторов рекомендация),
> `s3`/`b2` (международные, платные), `nextcloud-webdav` (свой
> self-hosted), `local` (НЕ выбирай — теряешь данные и бэкап при отказе
> диска).»

Если включил → спрашиваю:
- `backups.destination` (radio из enum схемы).
- `backups.rclone_remote` (если destination — webdav-вариант): имя
  remote'а в `~/.config/rclone/rclone.conf` (например `yandex-disk`).
  Валидация: regex `^[a-zA-Z][a-zA-Z0-9_-]+$`.
- `backups.retention` (text, default `7d-4w-6m` — 7 дней, 4 недели,
  6 месяцев). Подсказка: «Стандарт индустрии. Можешь оставить или ввести
  свой формат `Nd-Nw-Nm-Ny`.»

## Шаг 7: Раунд 6 — Telegram (ЛЁГКАЯ ОБЁРТКА)

> **1. Контекст.** Telegram — самый простой канал алертов: бесплатно, нативное приложение,
> не требует подписок и SMTP-сервера. Если включён — Uptime-Kuma и cron-jobs бэкапа шлют
> сюда уведомления при падении/успехе.
> **2. Рекомендация.** Если ставишь мониторинг или бэкапы — включай. Без них толку мало.

Если включил:
- `notifications.telegram.bot_username` — имя бота без `@` (валидация regex
  `^[a-zA-Z][a-zA-Z0-9_]{4,31}$`). Подсказка: «Создай бота через @BotFather в Telegram,
  получишь токен и username.»
- `notifications.telegram.chat_type` (radio: `personal` / `channel`).

Подсказка после записи: «Реальный токен бота сохрани в выбранном менеджере паролей
(`secrets.manager` = `{ВЫБРАННОЕ}`), сюда он не записывается. Скилл `/setup-secrets-vault`
поможет это сделать.»

## Шаг 7.5: Раунд 6.5 — VPN-подсистема (ЛЁГКАЯ ОБЁРТКА)

> **1. Контекст.** Если ты планируешь использовать сервер для обхода блокировок РФ
> (свой VPN-узел, серверный прокси для бота, чтобы он мог ходить в Anthropic/OpenAI API) —
> я могу подготовить секцию `vpn` в конфиге. Конкретные значения (URL панели, пароль) будут
> записаны автоматически при первом запуске `/setup-vpn-panel`. Здесь — только флаги.
> **2. Рекомендация.** Если есть РФ-сервер и нужны нейросети — включай.
> Если просто VPS для статического сайта — пропускай (значение по умолчанию `enabled: false`).

Вопрос (AskUserQuestion, header «VPN»):
- `Да, готовлю секцию` — записать в конфиг блок `vpn.enabled=false`, поля заготовлены
  под автозапись скиллами VPN-блока. Готовность к `/setup-vpn-panel`.
- `Пока нет` — секция `vpn` не добавляется. При первом запуске `/setup-vpn-panel`
  оператора попросят перезапустить `/sysadmin-init --reconfigure` для добавления.

Если включил:
- `vpn.enabled = false` (булевый флаг включения; меняется автоматически при первом
  успешном запуске `/setup-vpn-panel`).
- `vpn.panel_url = null` (заполнится автоматически).
- `vpn.panel_web_base_path = null` (заполнится автоматически).
- `vpn.server_proxy_enabled = false` (флаг для `/setup-server-proxy`).
- `vpn.upstream_kind = "none"` (выбирается при `/configure-vpn-routing`:
  `subscription`/`self-foreign`/`mixed`).
- `vpn.default_reality_dest = "www.cloudflare.com"` (default для VLESS+Reality
  serverName на загр.VPS; меняется параметром при `/setup-vpn-panel`).

Подсказка после записи: «Секция готова. Когда захочешь поднять VPN — `@sysadmin
поставь VPN-панель на свой сервер`, агент запустит `/setup-vpn-panel` и сам
заполнит поля.»

## Шаг 8: Сборка ДВУХ JSON во временные файлы

Собираю **два** draft'а из двух skeleton'ов:
- `$WORKDIR/agent-config-draft.json` ← `templates/agent-config-skeleton.json` (мозг).
- `$WORKDIR/infra-config-draft.json` ← `templates/infra-config-skeleton.json` (карта).

В каждом подменяю `__FILL__` через `jq` на реальные значения и доливаю опциональные
блоки только если оператор включил соответствующую подсистему.

**Раскладка ответов по двум файлам:**

| Ответ оператора | Файл | Поле |
|---|---|---|
| имя / язык / таймзона (Раунд 1) | agent | `operator.name` / `operator.language` / `operator.timezone` |
| менеджер паролей (Раунд 2) | agent | `secrets.*` |
| проект: id/title/infra_root (Раунд 1.5) | agent | `projects[0].*` + `default_project` |
| сервер (Раунд 3) | infra | `servers[0].*` |
| мониторинг (Раунд 4) | infra | `monitoring.*` |
| бэкапы (Раунд 5) | infra | `backups.*` |
| Telegram (Раунд 6) | infra | `notifications.telegram.*` |
| VPN (Раунд 6.5) | infra | `vpn.*` |

### 8.1 Сборка мозга (`agent-config-draft.json`)

**Блок `secrets`:** всегда пишу `secrets.manager`. Для известных менеджеров добавляю
`secrets.cli_available = true`. Для `manager=other` — обязательно `secrets.manager_name`
(имя из ответа) и `secrets.cli_available` (результат ресёрча CLI из Раунда 2).

**Блок `projects` + `default_project`:** один проект из Раунда 1.5.

```bash
AGENT_DRAFT="$WORKDIR/agent-config-draft.json"
cp "$SYSADMIN_ROOT/.claude/skills/sysadmin-init/templates/agent-config-skeleton.json" "$AGENT_DRAFT"

# operator
jq --arg n "$NAME" --arg l "$LANG" --arg tz "$TIMEZONE" \
   '.operator.name=$n | .operator.language=$l | .operator.timezone=$tz' \
   "$AGENT_DRAFT" > "$WORKDIR/x" && mv "$WORKDIR/x" "$AGENT_DRAFT"

# secrets. Для известных менеджеров CLI есть всегда → cli_available=true.
# Для other — значение из ресёрча Раунда 2 (true если нашёл CLI, иначе false).
case "$MANAGER" in
    keychain|bitwarden|1password|pass|keepassxc) CLI_AVAILABLE=true ;;
    other) : ;;  # CLI_AVAILABLE уже задан в Раунде 2 по результату ресёрча
esac
jq --arg m "$MANAGER" --argjson cli "$CLI_AVAILABLE" \
   '.secrets.manager=$m | .secrets.cli_available=$cli' "$AGENT_DRAFT" > "$WORKDIR/x" && mv "$WORKDIR/x" "$AGENT_DRAFT"
[ "$MANAGER" = "other" ] && { jq --arg mn "$MANAGER_NAME" '.secrets.manager_name=$mn' "$AGENT_DRAFT" > "$WORKDIR/x" && mv "$WORKDIR/x" "$AGENT_DRAFT"; }

# projects[0] из Раунда 1.5 + default_project. $PROJ_TITLE опционален.
jq --arg id "$PROJ_ID" --arg title "$PROJ_TITLE" --arg root "$PROJ_INFRA_ROOT" '
    .projects[0].id=$id
  | (if $title=="" then .projects[0]|=del(.title) else .projects[0].title=$title end)
  | .projects[0].infra_root=$root
  | .default_project=$id' "$AGENT_DRAFT" > "$WORKDIR/x" && mv "$WORKDIR/x" "$AGENT_DRAFT"
```

**Блок `meta` (мозг).** Skeleton мозга уже содержит `meta` со значениями по умолчанию
(`onboarding_completed: false`, `onboarding_completed_at: null`). Финальное значение
установит вопрос про знакомство в Шаге 10. На первичном setup стартует как `false`.
В режиме `--reconfigure` блок `meta` **не трогается** — сохраняется текущее состояние
из существующего `agent-config.json`. Если оператор однажды поставил `true` — оно так и
останется.

### 8.2 Сборка карты (`infra-config-draft.json`)

```bash
INFRA_DRAFT="$WORKDIR/infra-config-draft.json"
cp "$SYSADMIN_ROOT/.claude/skills/sysadmin-init/templates/infra-config-skeleton.json" "$INFRA_DRAFT"

# servers[0] из Раунда 3 (минимум alias/ssh_alias/role; domain опционально).
jq --arg a "$SRV_ALIAS" --arg s "$SRV_SSH" --arg r "$SRV_ROLE" \
   '.servers = [{alias:$a, ssh_alias:$s, role:$r}]' "$INFRA_DRAFT" > "$WORKDIR/x" && mv "$WORKDIR/x" "$INFRA_DRAFT"
[ -n "$SRV_DOMAIN" ] && { jq --arg d "$SRV_DOMAIN" '.servers[0].domain=$d' "$INFRA_DRAFT" > "$WORKDIR/x" && mv "$WORKDIR/x" "$INFRA_DRAFT"; }

# monitoring / backups / notifications / vpn — доливаю опциональные поля
# только при enabled=true (см. Раунды 4-6.5). Пример для мониторинга:
if [ "$MON_ENABLED" = "true" ]; then
    jq --argjson stack "$MON_STACK_JSON" --arg pd "$MON_PANEL_DOMAIN" \
       '.monitoring={enabled:true, stack:$stack, panel_domain:$pd}' \
       "$INFRA_DRAFT" > "$WORKDIR/x" && mv "$WORKDIR/x" "$INFRA_DRAFT"
fi
# ... аналогично backups (destination/retention/rclone_remote),
#     notifications.telegram (bot_username/chat_type), vpn (блок целиком).
```

**Важно:** `infra-config.json` НЕ содержит ни `operator`, ни `language`, ни `secrets`,
ни `infrastructure.root_path` — всё это уехало в мозг (ADR-0013). Если по ошибке потока
интервью в `$INFRA_DRAFT` оказались агент-поля — это баг сборки; убираю их (`jq 'del(...)'`)
до валидации, иначе схема `infra-config` (additionalProperties:false) отвергнет файл.

## Шаг 9: Валидация перед сохранением (ОБА файла)

`validate-config.sh` определяет схему по имени файла: `*agent-config*` → agent-схема,
`*infra-config*` → infra-схема. Валидирую оба draft'а.

```bash
VALIDATOR="$SYSADMIN_ROOT/.claude/skills/sysadmin-init/scripts/validate-config.sh"
# Можно одним вызовом с двумя путями (скрипт сам разведёт по схемам):
bash "$VALIDATOR" "$AGENT_DRAFT" "$INFRA_DRAFT" || {
    echo "Конфиг не прошёл валидацию (см. вывод выше: какой файл, какое поле)."
    echo "Что делаем — исправить вручную или вернуться в нужный раунд?"
    exit 2
}
```

Если ошибка — STOP. Показываю оператору конкретный файл, поле и причину (вывод
`check-jsonschema` содержит указатель типа `.servers[0].ssh_alias must be string`, а
jq-fallback печатает `FAIL [agent]` / `FAIL [infra]` с пометкой какого файла касается).
Спрашиваю: «исправить вручную или вернуться в раунд X?»

## Шаг 10: Превью + подтверждение (ОБА файла)

```bash
echo "Мозг (agent-config.json → $SYSADMIN_ROOT/):"
jq '.' "$AGENT_DRAFT"
echo "Карта (infra-config.json → папка проекта):"
jq '.' "$INFRA_DRAFT"
```

Спрашиваю «всё верно?» через `AskUserQuestion` (radio: «Да, сохранить» / «Вернуться в
раунд X» / «Отмена»).

Если «Да»:
```bash
# 1) ЦЕЛЕВОЙ ПУТЬ МОЗГА — всегда корень sysadmin/.
AGENT_PATH="$SYSADMIN_ROOT/agent-config.json"

# 2) ЦЕЛЕВОЙ ПУТЬ КАРТЫ — папка проекта (infra_root из мозга-draft).
INFRA_ROOT_RAW=$(jq -r '.projects[0].infra_root' "$AGENT_DRAFT")
INFRA_ROOT="${INFRA_ROOT_RAW/#\~/$HOME}"   # tilde без eval
# Создаю ПАПКУ инфры если её нет (именно директорию — не файл!)
mkdir -p "$INFRA_ROOT" || {
    echo "ERROR: не удалось создать папку инфры: $INFRA_ROOT"
    echo "Проверь путь (опечатка? нет прав?) и повтори Раунд 1.5."
    exit 1
}
[ -d "$INFRA_ROOT" ] || { echo "ERROR: $INFRA_ROOT — не директория"; exit 1; }
INFRA_CONFIG_PATH="$INFRA_ROOT/infra-config.json"

# Нормализую infra_root в мозге до абсолютного пути (реестр не привязан к cwd).
ABS_ROOT="$(cd "$INFRA_ROOT" && pwd)"
jq --arg r "$ABS_ROOT" '.projects[0].infra_root=$r' "$AGENT_DRAFT" > "$WORKDIR/x" && mv "$WORKDIR/x" "$AGENT_DRAFT"

# 3) Backup существующих версий, если есть (для --reconfigure и миграции).
TS="$(date +%Y%m%d-%H%M%S)"
[ -f "$AGENT_PATH" ]        && cp "$AGENT_PATH"        "$AGENT_PATH.bak.$TS"
[ -f "$INFRA_CONFIG_PATH" ] && cp "$INFRA_CONFIG_PATH" "$INFRA_CONFIG_PATH.bak.$TS"
# Миграция: старый всё-в-одном переименовываем в .bak (не удаляем — путь к откату).
if [ "${MIGRATE:-false}" = "true" ] && [ -n "${LEGACY_PATH:-}" ] && [ -f "$LEGACY_PATH" ]; then
    mv "$LEGACY_PATH" "$LEGACY_PATH.bak.$TS"
    echo "→ Старый конфиг сохранён как $LEGACY_PATH.bak.$TS (можно удалить позже)."
fi

# 4) Запись обоих файлов.
mv "$AGENT_DRAFT" "$AGENT_PATH"
mv "$INFRA_DRAFT" "$INFRA_CONFIG_PATH"
```

### Шаг 10.4: выездной bridge-указатель (`@sysadmin` из любой папки)

**Зачем:** чтобы агента можно было звать `@sysadmin` из чужого проекта, в `~/.claude/agents/`
кладётся тонкий указатель с абсолютным путём к `sysadmin/`. Его читают `find-config.sh`
(находит `$SYSADMIN_ROOT`) и сам агент (идёт за ядром). Под 2.0 (ADR-0015) ядро персоны —
в `CLAUDE.md`, поэтому bridge ведёт именно туда. Создаю при работе внутри `sysadmin/` (когда
`$SYSADMIN_ROOT` известен); существующий bridge перезаписываю свежим путём.

```bash
BRIDGE_DIR="$HOME/.claude/agents"
BRIDGE="$BRIDGE_DIR/sysadmin.md"
mkdir -p "$BRIDGE_DIR" || echo "WARN: не создать $BRIDGE_DIR — bridge пропускаю, @sysadmin из чужих папок будет недоступен."
if [ -d "$BRIDGE_DIR" ]; then
  cat > "$BRIDGE" <<EOF
---
name: sysadmin
description: Агент-сисадмин персональной инфраструктуры (выездной указатель). Полная персона — в CLAUDE.md репозитория sysadmin/.
model: inherit
---

# Sysadmin Agent — выездной указатель (bridge, ADR-0015)

Ядро персоны (ценности, конституция, три зоны, протоколы) живёт в \`CLAUDE.md\` репозитория
sysadmin/ по пути:

**\`$SYSADMIN_ROOT/\`**

При вызове \`@sysadmin\` из любой папки: прочитай \`$SYSADMIN_ROOT/CLAUDE.md\` — это ядро;
детальные протоколы — в \`$SYSADMIN_ROOT/.claude/agents/references/\`. Инструменты не
ограничиваю (наследую от родителя, включая Skill для запуска скиллов).
EOF
  echo "✅ bridge-указатель записан: $BRIDGE (путь к мозгу: $SYSADMIN_ROOT)"
fi
```

### Шаг 10.5: FINAL CHECK — ОБА конфига РЕАЛЬНО на диске и валидны

**Зачем:** без этой проверки скилл может напечатать «Готово», когда запись на самом деле
провалилась (нет прав, битый путь, упал `mv`) — и оператор остаётся без конфига, думая что
всё хорошо. Именно так и рождается ощущение «агент сказал что всё работает, а ничего нет».
**NEVER печатать «Готово» без прохождения этого блока.**

```bash
VALIDATOR="$SYSADMIN_ROOT/.claude/skills/sysadmin-init/scripts/validate-config.sh"

# 1. Оба файла физически существуют по целевым путям
for f in "$AGENT_PATH" "$INFRA_CONFIG_PATH"; do
    [ -f "$f" ] || {
        echo "ОШИБКА: конфиг НЕ записан — файла нет по пути $f."
        echo "Это сбой записи (права? путь? диск?). НЕ создаю суррогат вручную (C.9)."
        echo "Покажи мне вывод: ls -la \"$(dirname "$f")\" — разберёмся."
        exit 1
    }
done
# 2. Оба валидны по своим схемам (validate-config.sh сам разведёт по имени файла)
bash "$VALIDATOR" "$AGENT_PATH" "$INFRA_CONFIG_PATH" || {
    echo "ОШИБКА: файл(ы) записан(ы), но не проходит(ят) валидацию."
    echo "Пути: $AGENT_PATH , $INFRA_CONFIG_PATH"
    exit 1
}
# 3. Чистим временный каталог — только теперь, когда запись подтверждена
rm -rf "$WORKDIR"
```

### Шаг 10.6: Самопроверка «всё реально работает» + честный вердикт

**Зачем (принцип «не смог — скажи прямо»):** мало записать конфиги — нужно убедиться,
что вся связка пригодна к работе (bash+jq, оба конфига валидны, папка инфры есть,
bridge-файл на месте). Прогоняю `self-test-setup.sh`. Он печатает либо «✅ проверено»,
либо понятный новичку вердикт «настройка не завершена, свяжись с разработчиком агента» и
возвращает 1. **«Готово» говорю ТОЛЬКО при rc=0.** Если rc=1 — не притворяюсь, что всё
хорошо: передаю оператору ровно тот вердикт, что напечатал скрипт.

```bash
# Мини-bootstrap на случай, если этот блок — отдельный процесс и $LIB потерялся.
if [ -z "${LIB:-}" ] || [ ! -f "$LIB/self-test-setup.sh" ]; then
    for cand in "./.claude/skills/_lib" "../sysadmin/.claude/skills/_lib" "$HOME/sysadmin/.claude/skills/_lib"; do
        [ -f "$cand/self-test-setup.sh" ] && { LIB="$(cd "$cand" && pwd)"; break; }
    done
fi
[ -z "${SYSADMIN_ROOT:-}" ] && SYSADMIN_ROOT="$(cd "$LIB/../../.." && pwd)"

source "$LIB/self-test-setup.sh"
# Передаю ОБА файла: мозг ($1) и карту активного проекта ($3). Папку инфры self-test
# берёт из projects[].infra_root мозга (ADR-0013).
if self_test_setup "$AGENT_PATH" "$SYSADMIN_ROOT" "$INFRA_CONFIG_PATH"; then
    echo ""
    echo "Готово. Оба конфига записаны и полностью проверены:"
    echo "  мозг:  $AGENT_PATH"
    echo "  карта: $INFRA_CONFIG_PATH"

    # --- Активация версионируемого pre-commit hook репо sysadmin ----------
    # Хук .githooks/pre-commit блокирует коммит при рассинхроне персоны
    # (выжимка sysadmin.md ↔ references/). Он версионируется в репо, но
    # core.hooksPath нужно включить ОДИН раз на машине — делаем это здесь,
    # идемпотентно. Не валим init, если что-то не так с git (опциональная фича).
    if [ -d "$SYSADMIN_ROOT/.git" ] && [ -f "$SYSADMIN_ROOT/.githooks/pre-commit" ]; then
        if [ "$(git -C "$SYSADMIN_ROOT" config core.hooksPath 2>/dev/null)" != ".githooks" ]; then
            git -C "$SYSADMIN_ROOT" config core.hooksPath .githooks 2>/dev/null \
                && echo "→ pre-commit hook активирован (core.hooksPath=.githooks): защита персоны от рассинхрона." \
                || echo "⚠️  не удалось включить core.hooksPath — пропускаю (необязательная фича)."
        fi
    fi
    # дальше — Шаг 11 (подсказки по следующим шагам)
else
    # self_test_setup уже напечатал честный вердикт с инструкцией «свяжись с разработчиком».
    # НЕ печатаю «Готово», НЕ перехожу к Шагу 11, НЕ предлагаю запускать другие скиллы —
    # система не готова. Останавливаюсь здесь.
    exit 1
fi
```

Если «Вернуться» — перезапускаю нужный раунд, остальные ответы сохраняю.
Если «Отмена» — `rm -rf "$WORKDIR"`, ничего не пишу ни в `sysadmin/`, ни в папку инфры.

### Onboarding-флаг — спрашиваю про знакомство

После записи конфига — короткий вопрос про знакомство с агентом. Это нужно, чтобы
агент не приставал к оператору с напоминаниями про `/sysadmin-meet`, если оператор
уже знаком (или просто не хочет учиться).

Через `AskUserQuestion` (radio):

> Один последний вопрос. Ты знаком с агентом — проходил ли скилл-знакомство
> `/sysadmin-meet` (~20 минут на простом языке про то, что это вообще, как
> работает, что умеет)?
>
> 1. **Да, я уже знаком** — отмечу onboarding пройденным, агент не будет напоминать.
> 2. **Нет, но хочу пройти позже** — оставлю напоминание, агент будет мягко
>    подсказывать про /sysadmin-meet при каждом разговоре. Когда пройдёшь
>    знакомство (или скажешь «не хочу учиться») — напоминания выключатся.
> 3. **Запустить /sysadmin-meet прямо сейчас** — рекомендую, если впервые видишь
>    агента. Я завершусь, ты запустишь /sysadmin-meet, в конце знакомства
>    попадёшь обратно ко мне на финал.

Действия по ответу:

```bash
# Вариант 1: уже знаком → ставлю флаг true в МОЗГЕ (.meta живёт в agent-config.json).
tmp=$(mktemp) && jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.meta.onboarding_completed = true | .meta.onboarding_completed_at = $ts' \
    "$AGENT_PATH" > "$tmp" && mv "$tmp" "$AGENT_PATH"
echo "Понял, отметил знакомство пройденным. Агент не будет напоминать."

# Вариант 2: позже → флаг остаётся false (он и так false из шаблона)
echo "Хорошо, оставил напоминание. Запусти /sysadmin-meet когда будет 20 минут."

# Вариант 3: сейчас → выхожу с просьбой запустить /sysadmin-meet
echo "Отлично. Запусти /sysadmin-meet — я уже сохранил конфиг, он не пропадёт."
echo "В конце знакомства тебе предложат вернуться к выбору следующих шагов."
exit 0
```

Если ответ — Вариант 3, скилл выходит здесь, не показывая Шаг 11. Шаг 11 покажется
после прохождения /sysadmin-meet, когда оператор вернётся в этот скилл (логика —
в Шаге 8 скилла /sysadmin-meet, который сам ставит флаг и направляет дальше).

## Шаг 11: Финал — подсказки по следующим шагам

Вывожу адаптированный список скиллов в зависимости от ответов оператора:

```
Создано ДВА конфига (ADR-0013):
  • мозг агента:  {AGENT_PATH}            (в sysadmin/ — кто ты, язык, реестр проектов)
  • карта инфры:  {INFRA_CONFIG_PATH}     (в папке проекта — серверы, мониторинг, бэкапы)

Где работать дальше: открывай Claude Code в РОДИТЕЛЬСКОЙ папке — той, где
рядом лежат sysadmin/ (мой мозг) и папка инфры (твои данные). Это самое удобное
место: оба репо видны сразу. Я найду мозг сразу (он в sysadmin/), а карту — через
реестр projects[] в мозге, без перебора. Технически вызывать @sysadmin можно из
любой папки — я подхвачу конфиги по алгоритму Cold Start (см. references/cold-start.md).

Что дальше — пошагово:

1. [Если inventory/hosts/ пуст] Запусти /bootstrap-new-server для базовой настройки
   SSH/UFW/fail2ban/Docker/git+gitleaks на сервере {server.alias}.

2. [Всегда] Если менеджер паролей ({secrets.manager}) ещё не настроен — запусти
   /setup-secrets-vault. Он создаст структуру ключей в выбранном менеджере и шаблон
   индекса в inventory/shared/access.md.

3. [Если monitoring.enabled=true] Запусти /install-monitoring-stack — развернёт
   {monitoring.stack} на {monitoring.panel_domain} с общей Basic Auth.

4. [Если backups.enabled=true] Запусти /setup-backups — настроит restic с
   destination={backups.destination} и retention={backups.retention}, добавит cron
   и алерты в Telegram (если notifications.telegram.enabled=true).

5. [Всегда] Запусти /audit-security для прохода по чек-листу (UFW/SSH/fail2ban/secrets).
```

# Режим --reconfigure

В `--reconfigure` текущие значения читаю из ДВУХ файлов: агент-поля из `$BRAIN_PATH`
(`agent-config.json`), инфра-поля из `$INFRA_CONFIG_PATH` (`infra-config.json`). Оба пути
гарантированно непустые после Шага 0.1 (find_brain_config + resolve_active_project).

Псевдокод одного раунда (пример — менеджер паролей, агент-поле):

```bash
current_value=$(jq -r '.secrets.manager' "$BRAIN_PATH")
echo "Сейчас: secrets.manager = $current_value"
# AskUserQuestion: "Оставить как есть? [y=да / n=задать вопросы заново]"
# если "n": запустить тот же раунд, что в первичном setup
# если "y" или Enter: оставить current_value
```

```bash
# Пример инфра-поля (сервер) — читаю из карты:
current_role=$(jq -r '.servers[0].role' "$INFRA_CONFIG_PATH")
echo "Сейчас: servers[0].role = $current_role"
```

Прохожу по всем раундам. Где брать «текущее»: Раунд 1 (operator), 1.5 (projects[0]),
2 (secrets) — из `$BRAIN_PATH`; Раунды 3-6.5 (servers/monitoring/backups/notifications/vpn)
— из `$INFRA_CONFIG_PATH`. После последнего — Шаги 8 (сборка обоих draft'ов),
9 (валидация обоих), 10 (превью + backup существующих + mv обоих), 10.5 (FINAL CHECK
обоих), 10.6 (самопроверка + честный вердикт), 11 (финал). Самопроверка обязательна
и в `--reconfigure` — после правок оба конфига тоже должны остаться рабочими.

**Важно в --reconfigure:** блок `meta` мозга и уже выставленные VPN-поля
(`panel_url`, `panel_web_base_path` — их заполняют VPN-скиллы) НЕ затираю — переношу
текущие значения из существующих файлов в draft перед записью.

# Failed Attempts (грабли, на которых я учился)

1. **«Спросил у оператора, какой у него SSH-алиас, не глянув `~/.ssh/config`».**
   Урок: `detect-defaults.sh` ВСЕГДА выполняется первым. Не задавай вопрос, на который
   можно ответить чтением системного файла.
2. **«Записал конфиг без валидации, оператор исправил руками одно поле, скилл
   `setup-backups` потом падает на `null` в `rclone_remote`».** Урок: ВСЕГДА
   `check-jsonschema` (или fallback на jq) ПЕРЕД `mv` в финальное место.
3. **«--reconfigure перезаписал конфиг, оператор хочет вернуть как было».** Урок:
   ВСЕГДА делать backup `<имя>.bak.YYYYMMDD-HHMMSS` перед записью КАЖДОГО из двух
   файлов (`agent-config.json`, `infra-config.json`). Хранить последние 3 backup,
   чистить старшие (отдельная задача).
4. **«Глубокая вложенность вопросов „если выбрал A, спрашиваю A.1, A.2, A.3, и для
   каждого ещё подвопрос“».** Урок: максимум 2 уровня вложенности. Третий уровень —
   отложить в `--reconfigure` или ручную правку.
5. **«check-jsonschema не установлен, скилл упал на финале с „command not found“».**
   Урок: pre-check (Шаг 0) проверяет наличие, при отсутствии — WARN не FAIL, fallback
   на jq-валидацию через `validate-config.sh` (там обработка обоих случаев).
6. **«Пользователь на Windows прошёл настройку, остался с мёртвым `infra.md` в текущей
   папке вместо папки `infra/` с `sysadmin-config.json`» (инцидент 2026-05-24).** Причина:
   `jq` не входит в Git for Windows, старый pre-check делал `exit 1` на середине, а
   агент (LLM), видя упавший скрипт, импровизировал и собрал суррогат руками. Уроки:
   (а) гейт окружения `ensure-local-env.sh` ДОУСТАНАВЛИВАЕТ jq, а не просто падает;
   (б) FINAL CHECK (Шаг 10.5) ловит «записал, но файла нет»;
   (в) запрет C.9 в персоне делает создание суррогата конституционным нарушением.
   Главный системный урок: **молчаливый `exit 1` в bash = приглашение LLM
   импровизировать**. Любой отказ должен быть ГРОМКИМ и с явной командой «STOP, не чини сам».

# Граничные случаи

- **Найден старый `sysadmin-config.json` (всё-в-одном), нового мозга нет.** Поведение:
  предлагаю миграцию (Шаг 0.2) — расщепляю на `agent-config.json` + `infra-config.json`,
  старый переименовываю в `.bak`. Раскладка полей — по таблице в Шаге 0.2. Если оператор
  отказался («Не сейчас») — выход 0, ничего не трогаю.
- **Конфиг есть, но повреждён (валидный JSON, не валиден по схеме).** Поведение: при
  запуске без флага → STOP с сообщением «конфиг повреждён, проблема в поле X (в каком
  файле — agent-config или infra-config). Запусти `/sysadmin-init --reconfigure`». При
  `--reconfigure` → принудительно стартую с defaults из текущих файлов (что прочиталось)
  + интервью по битым полям.
- **Оператор прервал интервью на середине (Ctrl-C).** Поведение: ничего не пишу
  в конфиг. Draft лежал в `$WORKDIR` (`mktemp -d`) — он эфемерный, при следующем
  запуске начинаю интервью заново. Это сознательный выбор: state в `mktemp` ненадёжен
  между сессиями (ОС может вычистить временный каталог), поэтому `--continue` в v1.0
  не обещаю.
- **Оператор на нативном Windows без Git for Windows (нет bash).** Claude Code в этом
  случае исполняет команды через PowerShell — bash-скрипты скилла не запускаются вообще.
  Гейт Шага 0.0 (`ensure-local-env.sh`) этого не поймает, потому что сам написан на bash
  и не стартует. Симптом: команды скилла «молчат» или выдают PowerShell-ошибки. Реакция:
  если вижу, что Bash-инструмент не исполняет bash (вывод похож на PowerShell) — STOP и
  даю инструкцию поставить Git for Windows (`winget install --id Git.Git -e`) + перезапуск
  сессии. См. блок `_bash_manual_hint` в `_lib/ensure-local-env.sh`.
- **jq не установлен (частый случай на Windows-Git-Bash).** Гейт Шага 0.0 пытается
  доустановить через winget/brew/apt; при неудаче — STOP с ручной инструкцией. NEVER
  собирать конфиг «руками без jq» — это путь к суррогату `infra.md` (C.9 персоны).
- **`~/.ssh/config` пуст или отсутствует.** Поведение: `detect-defaults.sh` вернёт
  пустой массив `ssh_aliases: []` — пропускаю автодетект, спрашиваю алиас вручную.
- **Оператор хочет multi-server.** Ответ: «В v1.0 поддерживается один сервер через
  интервью. Multi-server отложено в v1.x — добавишь второй сервер вручную в
  `servers[]` (в `infra-config.json`), схема разрешает массив любой длины ≥ 1.»
- **Оператор хочет несколько проектов-инфраструктур (multi-project).** Ответ: «В v1.0
  интервью заводит один проект в `projects[]`. Дополнительные проекты добавишь вручную в
  `agent-config.json` — допиши элемент в `projects[]` (id/title/infra_root), при желании
  смени `default_project`. Схема разрешает массив любой длины ≥ 1.»
- **Оператор отвечает на сеньор-вопрос „давай как ты советуешь“.** Это легитимный
  ответ — применяю рекомендацию из шага 4 обёртки и перехожу к следующему раунду.

# Важные правила

- **АБСОЛЮТНЫЙ ЗАПРЕТ записывать в конфиг данные, которых не подтвердил оператор.**
  Если автодетект нашёл что-то — предлагаю, оператор подтверждает.
- **Никаких выдуманных доменов, ботов, токенов в шаблонах.** Если оператор пропустил
  поле — оставляю значение по умолчанию из схемы (`example.com`, `bot_username`
  опционален при `enabled=false`).
- **Тон — на «ты», по-русски, партнёрский.** Не «Вы», не «вы», не на английском.
- **Сеньор-обёртка применяется только к 3 сложным вопросам.** Простые вопросы (имя,
  язык, ssh_alias из найденных) — без обёртки, чтобы не утомлять оператора.
- **Никаких нарративных вставок «Василий сказал...».** Только императив, без рассказов.