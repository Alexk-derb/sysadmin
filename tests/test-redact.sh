#!/usr/bin/env bash
# tests/test-redact.sh — тесты библиотеки маскировки _lib/redact.sh.
#
# Зачем: 2026-08-08 снимок inventory-scan унёс в файл реальные секреты dev-стека —
# ключ `sb_secret_…` внутри многострочного YAML-значения env и приватный TLS-ключ в
# аргументах entrypoint. Маска их не увидела: она смотрела на ИМЯ переменной и работала
# построчно. Набор ниже фиксирует этот класс отказа, чтобы он не вернулся.
#
# Главное правило набора: «gitleaks чист» доказательством НЕ считается. Приманки здесь —
# opaque-маркеры, которых нет ни в одном правиле сканеров; если маркер дожил до вывода,
# значит утекло бы и всё остальное.
#
# Запуск:  bash tests/test-redact.sh
# Код возврата: 0 — все прошли, 1 — есть падения.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/.claude/skills/_lib/redact.sh"

PASS=0; FAIL=0
# Opaque-приманка: ни один сканер секретов её не знает. Утечкой считаем сам факт,
# что она дожила до вывода.
CANARY="CANARY_7f3d9a2b4e6c8d0f_DO_NOT_LEAK"

ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# leaked <описание> <вывод> — приманка обязана отсутствовать.
# ПУСТОЙ вывод успехом НЕ считается: иначе отсутствующая или упавшая функция даёт
# ложное «ok» (поймано на первом же прогоне этого набора — функции ещё не было,
# а проверки «проходили»). Отказ проверки должен быть громким.
leaked(){
  if [ -z "$2" ]; then bad "$1 — пустой вывод, проверка не состоялась"; return; fi
  case "$2" in *"$CANARY"*) bad "$1 — приманка утекла";; *) ok "$1";; esac
}
# have <имя функции> — проверка, что проверяемое вообще существует
have(){ if declare -F "$1" >/dev/null 2>&1; then ok "функция $1 определена"; else bad "функция $1 НЕ определена"; return 1; fi; }
# kept <описание> <вывод> <подстрока> — данные обязаны сохраниться (не переусердствовали)
kept(){ case "$2" in *"$3"*) ok "$1";; *) bad "$1 — потеряны данные: $3";; esac; }

echo "== redact_stream: базовые случаи (регрессия существующего поведения)"
out=$(printf 'API_TOKEN=%s\n' "$CANARY" | redact_stream);            leaked "KEY=value" "$out"
out=$(printf 'postgres://user:%s@host/db\n' "$CANARY" | redact_stream); leaked "креды в URL" "$out"
out=$(printf 'curl "https://x/y?secret=%s&a=1"\n' "$CANARY" | redact_stream); leaked "секрет в query" "$out"
out=$(printf "ALTER USER u WITH PASSWORD '%s';\n" "$CANARY" | redact_stream); leaked "SQL-пароль" "$out"
out=$(printf 'AKIA%s\n' "IOSFODNN7EXAMPLE" | redact_stream);          kept "AWS-ключ маскирован" "$out" "<REDACTED>"

echo "== redact_stream: класс отказа 2026-08-08"
# 1) Ключ Supabase нового формата. Имя переменной безобидное, '=' есть, но секрет-слова нет.
out=$(printf 'kong_config: "apikey == %s"\n' "sb_secret_${CANARY}" | redact_stream)
leaked "sb_secret_ по значению (не по имени переменной)" "$out"
# 2) Приватный ключ PEM, многострочный — построчный sed его не видит в принципе.
# Тело ключа синтетическое (приманка), но заголовок PEM настоящий, иначе тест не проверял бы
# то, что встретится в реальном снимке. gitleaks:allow глушит РОВНО эти две строки-фикстуры —
# правило private-key остаётся включённым везде, включая остальной файл.
out=$(printf -- '-----BEGIN PRIVATE KEY-----\nMIIEvQIBADAN%s\n-----END PRIVATE KEY-----\n' "$CANARY" | redact_stream) # gitleaks:allow
leaked "многострочный PEM" "$out"
# 3) PEM в одну строку (как внутри JSON, где переводы строк экранированы).
out=$(printf -- '{"Entrypoint":["sh","-c","-----BEGIN PRIVATE KEY-----\\n%s\\n-----END PRIVATE KEY-----"]}\n' "$CANARY" | redact_stream) # gitleaks:allow
leaked "PEM внутри JSON-строки" "$out"

echo "== redact_json_deep: секрет вне .Env (Args / Entrypoint / Labels / Healthcheck)"
have redact_json_deep || true
if command -v jq >/dev/null 2>&1 && declare -F redact_json_deep >/dev/null 2>&1; then
  j(){ printf '%s' "$1" | redact_json_deep; }
  out=$(j "$(printf '[{"Args":["--token=%s"]}]' "$CANARY")");                       leaked "Args" "$out"
  out=$(j "$(printf '[{"Config":{"Entrypoint":["sh","-c","echo %s"]}}]' "sb_secret_$CANARY")"); leaked "Entrypoint" "$out"
  out=$(j "$(printf '[{"Config":{"Labels":{"note":"%s"}}}]' "sb_secret_$CANARY")"); leaked "Labels" "$out"
  out=$(j "$(printf '[{"Config":{"Healthcheck":{"Test":["CMD-SHELL","curl -H Authorization:Bearer_%s"]}}}]' "sb_secret_$CANARY")"); leaked "Healthcheck.Test" "$out"
  out=$(j "$(printf '[{"HostConfig":{"LogConfig":{"Config":{"url":"https://u:%s@h"}}}}]' "$CANARY")"); leaked "LogConfig" "$out"
  # не переусердствовали: полезные поля на месте и JSON остался валидным
  out=$(j "$(printf '[{"Name":"/app","Config":{"Image":"nginx:1.27","Env":["API_TOKEN=%s"]}}]' "$CANARY")")
  leaked "Env внутри глубокой маскировки" "$out"
  kept  "имя контейнера сохранено" "$out" '"/app"'
  kept  "образ сохранён" "$out" 'nginx:1.27'
  if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then ok "JSON остался валидным"; else bad "JSON сломан"; fi
else
  echo "  (пропущено: jq не установлен)"
fi

echo "== fail-closed: без jq глубокая маскировка не притворяется успешной"
if command -v jq >/dev/null 2>&1; then
  out=$(printf '[{"Args":["%s"]}]' "$CANARY" | PATH=/nonexistent redact_json_deep 2>/dev/null; echo "rc=$?")
  case "$out" in *"rc=0"*) bad "без jq вернулся успех — должен быть ненулевой код";; *) ok "без jq ненулевой код возврата";; esac
fi

# ---------------------------------------------------------------------------
# Дефекты, найденные слепой сверкой 2026-08-22 (задание
# todos/2026-08-22-redact-defects-TASK.md). Каждый блок ниже писался ПАДАЮЩИМ на
# ревизии b56f931 и обязан краснеть, если соответствующее правило сломать.
# ---------------------------------------------------------------------------

# nlines <описание> <вывод> <ожидаемое число строк>
nlines(){
  local n; n=$(printf '%s\n' "$2" | grep -c '')
  if [ "$n" = "$3" ]; then ok "$1"; else bad "$1 — строк $n, ожидалось $3"; fi
}

echo "== A1: значение не обрывается на пробеле, запятой, кавычке"
out=$(printf 'password: hunter2 %s\n' "$CANARY" | redact_stream)
leaked "A1 незакавыченное YAML-значение до конца строки" "$out"
out=$(printf 'DB_PASSWORD="my %s phrase"\n' "$CANARY" | redact_stream)
leaked "A1 значение в двойных кавычках целиком" "$out"
out=$(printf "DB_PASSWORD='my %s phrase'\n" "$CANARY" | redact_stream)
leaked "A1 значение в одинарных кавычках целиком" "$out"
out=$(printf 'POSTGRES_PASSWORD=p4ss,%s,tail\n' "$CANARY" | redact_stream)
leaked "A1 значение с запятыми" "$out"
# Многострочный YAML-блок: маскировался знак '|', тело блока уходило целиком.
# Ровно этим путём в 2026-08-08 утёк sb_secret_.
out=$(printf 'service_key: |\n  %s\n  %s\nimage: nginx:1.27\n' "$CANARY" "$CANARY" | redact_stream)
leaked "A1 тело многострочного YAML-блока" "$out"
kept  "A1 соседний ключ после блока сохранён" "$out" 'nginx:1.27'

echo "== A2: непрозрачные токены по значению"
out=$(printf 'Authorization: Bearer ghp_%s\n' "$CANARY" | redact_stream);   leaked "A2 GitHub ghp_ в заголовке" "$out"
out=$(printf 'x github_pat_%s y\n' "$CANARY" | redact_stream);              leaked "A2 GitHub fine-grained PAT" "$out"
out=$(printf 'x glpat-%s y\n' "$CANARY" | redact_stream);                   leaked "A2 GitLab glpat-" "$out"
out=$(printf 'x sk-ant-api03-%s y\n' "$CANARY" | redact_stream);            leaked "A2 Anthropic sk-ant-" "$out"
out=$(printf 'x AIza%s y\n' "$CANARY" | redact_stream);                     leaked "A2 Google AIza" "$out"
out=$(printf 'x xoxp-%s y\n' "$CANARY" | redact_stream);                    leaked "A2 Slack xoxp-" "$out"
out=$(printf 'BOT=1234567890:%s\n' "$CANARY" | redact_stream);              leaked "A2 токен Telegram" "$out"
out=$(printf 'machine github.com login bot password %s\n' "$CANARY" | redact_stream); leaked "A2 .netrc" "$out"
out=$(printf 'db.example.com:5432:app:appuser:%s\n' "$CANARY" | redact_stream);       leaked "A2 .pgpass" "$out"
out=$(printf 'admin:$apr1$abcd$%s\n' "$CANARY" | redact_stream);            leaked "A2 хеш htpasswd" "$out"
out=$(printf '{"auths":{"h":{"auth":"%s"}}}\n' "$CANARY" | redact_stream);  leaked "A2 auth в docker config.json" "$out"

echo "== A3: учётные данные во флагах командной строки"
out=$(printf 'curl -u deploy:%s https://x\n' "$CANARY" | redact_stream);    leaked "A3 curl -u user:pass" "$out"
out=$(printf 'redis-cli -a %s ping\n' "$CANARY" | redact_stream);           leaked "A3 redis-cli -a" "$out"
out=$(printf 'tool --password %s\n' "$CANARY" | redact_stream);             leaked "A3 --password VALUE" "$out"
out=$(printf 'tool --token=%s\n' "$CANARY" | redact_stream);                leaked "A3 --token=VALUE" "$out"

echo "== A4: PEM-блоки с суффиксом (PGP … PRIVATE KEY BLOCK)"
out=$(printf -- '-----BEGIN PGP PRIVATE KEY BLOCK-----\nlQOYBGXaBc0BCADHt7t7%s\n-----END PGP PRIVATE KEY BLOCK-----\n' "$CANARY" | redact_stream) # gitleaks:allow
leaked "A4 многострочный PGP-блок" "$out"
out=$(printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIE%s\n-----END RSA PRIVATE KEY-----\n' "$CANARY" | redact_stream) # gitleaks:allow
leaked "A4 многострочный RSA-ключ" "$out"

echo "== B1: незакрытый PEM-блок НЕ съедает остаток потока"
in6=$(printf '%s\n' 'nginx: [emerg] PEM_read_bio_PrivateKey() failed, expected "-----BEGIN PRIVATE KEY-----"' \
                    'CONTAINER ID   IMAGE          PORTS' \
                    'a1b2c3d4e5f6   postgres:16    0.0.0.0:5432->5432/tcp' \
                    'network: proxy-corridor  subnet 172.28.0.0/16' \
                    'volume: pgdata 42G' \
                    'cron: 0 3 * * * /opt/backup.sh')
out=$(printf '%s\n' "$in6" | redact_stream 2>/dev/null)
nlines "B1 шесть строк на входе — шесть на выходе" "$out" 6
kept   "B1 таблица docker ps сохранена" "$out" 'postgres:16'
# Сама строка-триггер тоже обязана уцелеть: в ней нет ключа, это сообщение об
# ошибке. Без этой проверки мутант «искать маркер подстрокой» набор не замечал —
# число строк сходилось, а первая строка молча подменялась маркером.
kept   "B1 сообщение nginx сохранено"  "$out" 'PEM_read_bio_PrivateKey'
kept   "B1 сеть сохранена"              "$out" 'proxy-corridor'
kept   "B1 cron сохранён"               "$out" '/opt/backup.sh'
# Оборванный настоящий ключ: тело не утекает, но следующая секция выживает.
out=$(printf -- '-----BEGIN PRIVATE KEY-----\nMIIEvQIBADAN%s\nCONTAINER ID   IMAGE\nvolume: pgdata 42G\n' "$CANARY" | redact_stream 2>/dev/null) # gitleaks:allow
leaked "B1 тело оборванного ключа не утекло" "$out"
kept   "B1 секция после оборванного ключа сохранена" "$out" 'pgdata 42G'

echo "== B2: имя сверяется по границам сегмента, а не подстрокой"
out=$(printf '%s\n' 'KEYBOARD_LAYOUT=us' 'MONKEY_MODE=on' 'API_URL=https://api.example.com/v1' \
                    'DATABASE_HOST=db.internal' 'IMAGE_VERSION=1.27.3' | redact_stream)
kept "B2 KEYBOARD_LAYOUT не тронут" "$out" 'KEYBOARD_LAYOUT=us'
kept "B2 MONKEY_MODE не тронут"     "$out" 'MONKEY_MODE=on'
kept "B2 API_URL не тронут"         "$out" 'API_URL=https://api.example.com/v1'
kept "B2 DATABASE_HOST не тронут"   "$out" 'DATABASE_HOST=db.internal'
kept "B2 IMAGE_VERSION не тронут"   "$out" 'IMAGE_VERSION=1.27.3'
# Имена с секрет-словом И безопасным хвостом: здесь работает уже не граница
# сегмента, а белый список. Без этих случаев его поломка набором не замечалась
# (мутационный контроль), то есть правило числилось покрытым напрасно.
out=$(printf '%s\n' 'SECRET_KEY_FILE=/run/secrets/app' 'TOKEN_URL=https://auth.example.com/token' \
                    'SESSION_TIMEOUT=30' 'PRIVATE_KEY_PATH=/etc/ssl/private/app.pem' | redact_stream)
kept "B2 SECRET_KEY_FILE — путь сохранён"   "$out" '/run/secrets/app'
kept "B2 TOKEN_URL — адрес сохранён"        "$out" 'https://auth.example.com/token'
kept "B2 SESSION_TIMEOUT — число сохранено" "$out" 'SESSION_TIMEOUT=30'
kept "B2 PRIVATE_KEY_PATH — путь сохранён"  "$out" '/etc/ssl/private/app.pem'
# Сужение не должно ослабить маскировку: настоящие имена по-прежнему ловятся.
out=$(printf '%s\n' "AWS_ACCESS_KEY_ID=$CANARY" | redact_stream);   leaked "B2 AWS_ACCESS_KEY_ID всё ещё ловится" "$out"
out=$(printf '%s\n' "API_TOKEN_PROD=$CANARY" | redact_stream);      leaked "B2 API_TOKEN_PROD всё ещё ловится" "$out"
out=$(printf '%s\n' "{\"authToken\":\"$CANARY\"}" | redact_stream); leaked "B2 camelCase authToken ловится" "$out"
out=$(printf '%s\n' "x-api-key: $CANARY" | redact_stream);          leaked "B2 заголовок x-api-key ловится" "$out"
# Пароль в URL по-прежнему ловится, хотя имя в whitelist.
out=$(printf 'DATABASE_URL=postgres://u:%s@h/db\n' "$CANARY" | redact_stream)
leaked "B2 пароль в DATABASE_URL ловится значением" "$out"

echo "== B2-bis: имя БЕЗ разделителей (находка сверки 2026-08-22)"
# Граница сегмента ловила `DB_PASSWORD`, но не `DBPASSWORD`: склеенные заглавные
# не дают ни разделителя, ни перехода регистра, и весь идентификатор оказывался
# ОДНИМ сегментом, не совпадающим ни с одним секрет-словом. Класс A — секрет
# уходит наружу; такие имена обычны в бытовых compose-файлах и env-скриптах.
for nm in AUTHTOKEN DBPASSWORD ACCESSTOKEN MYSECRET AWSSECRETKEY DBPASS DBPASSWD SSHKEY GPGKEY db1password db1pass; do
  out=$(printf '%s=%s\n' "$nm" "$CANARY" | redact_stream);        leaked "B2-bis построчный: $nm" "$out"
  out=$(printf '{"%s":"%s"}' "$nm" "$CANARY" | redact_json_deep); leaked "B2-bis глубокий:   $nm" "$out"
done
# Сужение не должно вернуться: имена-омонимы по-прежнему целы.
out=$(printf '%s\n' 'KEYBOARD_DEVICE=/dev/input/event0' 'PASSENGER_COUNT=4' 'PATH=/usr/bin:/bin' \
                    'DATAPATH_ROOT=/srv/data' 'TOKENIZER_PATH=/opt/m.model' | redact_stream)
kept "B2-bis KEYBOARD_DEVICE не тронут" "$out" '/dev/input/event0'
kept "B2-bis PASSENGER_COUNT не тронут" "$out" 'PASSENGER_COUNT=4'
kept "B2-bis PATH не тронут"            "$out" '/usr/bin:/bin'
kept "B2-bis DATAPATH_ROOT не тронут"   "$out" '/srv/data'
kept "B2-bis TOKENIZER_PATH не тронут"  "$out" '/opt/m.model'

echo "== B3: построчный путь не ломает валидность JSON"
if command -v jq >/dev/null 2>&1; then
  out=$(printf '%s\n' '{"Keys": null, "ApiVersion": "1.41"}' | redact_stream)
  if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then ok "B3 JSON остался валиден"; else bad "B3 JSON сломан: $out"; fi
  kept "B3 ApiVersion не съеден как секрет" "$out" '1.41'
  # Закавыченное значение маскируется РОВНО внутри кавычек: и документ остаётся
  # разбираемым, и соседние поля живы. Проверка на точность, а не на секретность.
  out=$(printf '%s\n' "{\"password\": \"$CANARY\", \"image\": \"nginx:1.27\"}" | redact_stream)
  leaked "B3 закавыченное значение замаскировано" "$out"
  kept   "B3 соседнее поле после кавычек сохранено" "$out" 'nginx:1.27'
  if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then ok "B3 JSON с закавыченным значением валиден"; else bad "B3 JSON с закавыченным значением сломан: $out"; fi
  out=$(printf '%s\n' "{\"Env\":[\"API_TOKEN=$CANARY\",\"IMAGE=nginx:1.27\"]}" | redact_stream)
  leaked "B3 секрет в массиве Env замаскирован" "$out"
  kept   "B3 соседний элемент массива сохранён" "$out" 'nginx:1.27'
  if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then ok "B3 JSON с массивом Env валиден"; else bad "B3 JSON с массивом Env сломан: $out"; fi
fi

echo "== A5: секрет в ИМЕНИ ключа JSON"
if command -v jq >/dev/null 2>&1; then
  # Приманка в ИМЕНИ отличается от приманки в значении. Одинаковые — и проверка
  # ложно зеленеет: имя чинится заодно, потому что попало в карту замен как
  # значение (мутационный контроль поймал именно это).
  KEYCANARY="CANARY_ONLY_IN_KEY_1a2b3c4d5e6f_DO_NOT_LEAK"
  out=$(printf '{"sb_secret_%s":"public","safe":"sb_secret_%s"}' "$KEYCANARY" "$CANARY" | redact_json_deep)
  leaked "A5 значение по-прежнему маскируется" "$out"
  case "$out" in *"$KEYCANARY"*) bad "A5 имя ключа тоже маскируется — приманка утекла";; *) ok "A5 имя ключа тоже маскируется";; esac
  # Маскировка имён СХЛОПЫВАЕТ разные ключи в один: два `sb_secret_*` дают два
  # `<REDACTED>`, и объект молча теряет запись целиком — вместе со значением.
  # Это тот же класс «данные уничтожаются», ради которого затевалась v3.
  out=$(printf '{"sb_secret_AAAAAAAAAAAA":"one","sb_secret_BBBBBBBBBBBB":"two","keep":"me"}' | redact_json_deep)
  n=$(printf '%s' "$out" | jq 'length' 2>/dev/null)
  if [ "$n" = "3" ]; then ok "A5 три ключа остались тремя"; else bad "A5 ключей $n, ожидалось 3 — записи схлопнулись: $out"; fi
  kept "A5 значение схлопнутого ключа сохранено" "$out" '"one"'
  kept "A5 второе значение сохранено"            "$out" '"two"'
  # Различитель обязан быть устойчив к порядку ключей: иначе diff двух снимков
  # одного и того же объекта покажет артефактное различие, а оператор прочитает
  # его как реальное изменение инфраструктуры. Ложный инвентарь — то, против чего
  # затевалась v3 (находка сверки 2026-08-22).
  o1=$(printf '{"sb_secret_AAAAAAAAAAAA":"a","sb_secret_BBBBBBBBBBBB":"b"}' | redact_json_deep | jq -S .)
  o2=$(printf '{"sb_secret_BBBBBBBBBBBB":"b","sb_secret_AAAAAAAAAAAA":"a"}' | redact_json_deep | jq -S .)
  if [ -n "$o1" ] && [ "$o1" = "$o2" ]; then ok "A5 различитель устойчив к порядку ключей"
  else bad "A5 различитель зависит от порядка ключей: [$o1] vs [$o2]"; fi
  if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then ok "A5 JSON остался валиден"; else bad "A5 JSON сломан"; fi
fi

echo "== A7: глубокая ветка маскирует значение по ИМЕНИ КЛЮЧА"
if command -v jq >/dev/null 2>&1; then
  # Дыра, существовавшая и в v2: строки документа вынимались и маскировались
  # ПООДИНОЧКЕ, связь «имя ключа → значение» терялась, и самая очевидная форма
  # секрета в JSON — {"DB_PASSWORD":"..."} — проходила насквозь. Построчный путь
  # её ловил, глубокий нет; согласованность веток проверялась на строках, где
  # присваивание лежит ВНУТРИ одной строки, и потому дыру не показывала.
  for k in DB_PASSWORD API_TOKEN authToken DBPASSWORD sshkey 'x-api-key'; do
    out=$(printf '{"%s":"%s","Image":"nginx:1.27"}' "$k" "$CANARY" | redact_json_deep)
    leaked "A7 значение под ключом $k" "$out"
    kept   "A7 соседнее поле при ключе $k" "$out" 'nginx:1.27'
  done
  # Не переусердствовали: безопасные имена ключей значения не теряют.
  out=$(printf '{"Name":"/app","Image":"nginx:1.27","EnvNames":["API_TOKEN"],"daemon_id":"abc123","SESSION_TIMEOUT":30}' | redact_json_deep)
  kept "A7 Name сохранено"            "$out" '"/app"'
  kept "A7 Image сохранён"            "$out" 'nginx:1.27'
  kept "A7 EnvNames сохранены"        "$out" 'API_TOKEN'
  kept "A7 daemon_id сохранён"        "$out" 'abc123'
  kept "A7 SESSION_TIMEOUT сохранён"  "$out" '30'
  # Контейнер под секретным именем не подменяется целиком: структура остаётся,
  # внутренние ключи судятся сами по себе.
  out=$(printf '{"secrets":{"Image":"nginx:1.27","token":"%s"}}' "$CANARY" | redact_json_deep)
  leaked "A7 секрет внутри контейнера замаскирован" "$out"
  kept   "A7 структура контейнера сохранена"        "$out" 'nginx:1.27'
fi

echo "== A6: обе ветки согласованы на одном входе"
if command -v jq >/dev/null 2>&1; then
  # Один корпус — два пути. Расхождение чёрных списков (signature, requirepass,
  # SQL PASSWORD, двоеточие) обнаруживается здесь, а не в снимке на проде.
  corpus_case(){
    local desc="$1" line="$2" o1 o2
    o1=$(printf '%s\n' "$line" | redact_stream)
    o2=$(printf '%s' "$line" | jq -R . | redact_json_deep)
    leaked "A6 построчный: $desc" "$o1"
    leaked "A6 глубокий:   $desc" "$o2"
  }
  corpus_case "signature в query"   "https://x.invalid/cb?signature=$CANARY"
  corpus_case "sig в query"         "https://x.invalid/cb?sig=$CANARY"
  corpus_case "requirepass"         "CONFIG SET requirepass $CANARY"
  corpus_case "SQL PASSWORD"        "ALTER USER u WITH PASSWORD '$CANARY';"
  corpus_case "IDENTIFIED BY"       "CREATE USER u IDENTIFIED BY '$CANARY';"
  corpus_case "секрет-слово с ':'"  "api_key: $CANARY"
  corpus_case "флаг --password"     "tool --password $CANARY"
  corpus_case "curl -u"             "curl -u deploy:$CANARY https://x"
  corpus_case "ghp_-токен"          "Authorization: Bearer ghp_$CANARY"
  corpus_case "AWS-ключ по значению" "AKIAIOSFODNN7EXAMPLE"
fi

echo "== B4: redact_json_with_jq честна на битом входе"
if command -v jq >/dev/null 2>&1; then
  # `set +o pipefail` — не придирка, а слабейшая среда вызывающего: контракт
  # «ненулевой код на битом входе» держался ИСКЛЮЧИТЕЛЬНО на pipefail в чужом
  # скрипте. Под этим набором pipefail включён (строка 16), и проверка без явного
  # отключения проходила при полностью сломанном контракте — ложный зелёный.
  out=$(set +o pipefail; printf 'not json {{{' | redact_json_with_jq 2>/dev/null; echo "rc=$?")
  case "$out" in *"rc=0"*) bad "B4 битый JSON дал код возврата 0 вопреки контракту";; *) ok "B4 битый JSON — ненулевой код возврата";; esac
  case "$out" in "rc="*) ok "B4 на битом входе ничего не напечатано";; *) bad "B4 на битом входе напечатано лишнее";; esac
  out=$(set +o pipefail; printf '' | redact_json_with_jq 2>/dev/null; echo "rc=$?")
  case "$out" in *"rc=0"*) bad "B4 пустой вход дал код возврата 0";; *) ok "B4 пустой вход — ненулевой код возврата";; esac
  out=$(set +o pipefail; printf '{"Config":{"Env":["API_TOKEN=%s"]}}' "$CANARY" | redact_json_with_jq; echo "rc=$?")
  leaked "B4 на исправном входе маскирует" "$out"
  case "$out" in *"rc=0"*) ok "B4 на исправном входе код возврата 0";; *) bad "B4 на исправном входе ненулевой код";; esac
  # Мусор в хвосте: jq успевает напечатать первый документ и падает. Проверка
  # «вывод непустой» такой отказ не видит — его ловит только код возврата самого
  # jq. Частичный результат нельзя выдавать за успешный.
  out=$(set +o pipefail; printf '{"Config":{"Env":["API_TOKEN=%s"]}} мусор' "$CANARY" | redact_json_with_jq 2>/dev/null; echo "rc=$?")
  case "$out" in *"rc=0"*) bad "B4 частичный разбор выдан за успех";; *) ok "B4 мусор в хвосте — ненулевой код возврата";; esac
fi

echo
echo "Итого: прошло $PASS, упало $FAIL"
[ "$FAIL" -eq 0 ]
