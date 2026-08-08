#!/usr/bin/env bash
# tests/test-inventory-scan.sh — тесты проекции снимка inventory-scan.
#
# Проверяется summary-filter.jq — тот самый файл, который применяет dump-snapshot.sh
# (не копия, иначе проверяемое и работающее разъедутся).
#
# Зачем: 2026-08-08 снимок нёс сырой `docker inspect`, и вместе с ним в файл ушли ключ
# `sb_secret_` из многострочного значения env и приватный TLS-ключ из Entrypoint.
# Вывод сессии: маскировка не может быть последней линией обороны — поля, куда
# пользователь кладёт произвольные строки, не должны попадать в снимок ВООБЩЕ.
#
# Приманки ниже — opaque-маркеры, которых нет в правилах сканеров секретов. «gitleaks
# чист» доказательством не считается.
#
# Запуск:  bash tests/test-inventory-scan.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILTER="$ROOT/.claude/skills/inventory-scan/scripts/summary-filter.jq"
# shellcheck source=/dev/null
source "$ROOT/.claude/skills/_lib/redact.sh"

PASS=0; FAIL=0
CANARY="CANARY_7f3d9a2b4e6c8d0f_DO_NOT_LEAK"
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "jq не установлен — тест не может состояться (fail-closed)"; exit 1
fi
[ -f "$FILTER" ] || { echo "FAIL: не найден $FILTER"; exit 1; }

# Синтетический inspect: приманка разложена во ВСЕ поля, где реально прятались секреты.
INPUT=$(cat <<JSON
[{
  "Name": "/app",
  "Image": "sha256:deadbeef",
  "Created": "2026-08-08T10:00:00Z",
  "Args": ["--opaque-flag=$CANARY"],
  "State": {"Status":"running","Health":{"Status":"healthy"},"ExitCode":0,"StartedAt":"2026-08-08T10:00:01Z"},
  "HostConfig": {
    "RestartPolicy": {"Name":"unless-stopped"},
    "LogConfig": {"Config": {"note": "$CANARY"}}
  },
  "Config": {
    "Image": "nginx:1.27",
    "Cmd": ["sh","-c","echo $CANARY"],
    "Entrypoint": ["sh","-c","-----BEGIN PRIVATE KEY-----\\n$CANARY\\n-----END PRIVATE KEY-----"],
    "Labels": {"note": "$CANARY"},
    "Healthcheck": {"Test": ["CMD-SHELL","echo $CANARY"]},
    "Env": ["API_TOKEN=$CANARY","PGDATA=/var/lib/postgresql/data"]
  },
  "NetworkSettings": {"Networks": {"net1": {"IPAddress":"172.18.0.5"}}, "Ports": {}},
  "Mounts": [{"Type":"bind","Source":"/data/db","Destination":"/var/lib/postgresql/data","RW":true}]
}]
JSON
)

OUT=$(printf '%s' "$INPUT" | jq -f "$FILTER" | redact_json_deep)

echo "== приманка не должна пережить проекцию"
if [ -z "$OUT" ]; then bad "пустой вывод — проверка не состоялась"; else
  case "$OUT" in *"$CANARY"*) bad "приманка утекла в containers-summary";; *) ok "приманки нет ни в одном поле";; esac
fi

echo "== поля, куда пользователь кладёт произвольные строки, не переносятся вовсе"
for f in Args Cmd Entrypoint Labels Healthcheck LogConfig; do
  if printf '%s' "$OUT" | jq -e "..|objects|has(\"$f\")" >/dev/null 2>&1; then
    bad "поле $f попало в проекцию"
  else
    ok "поле $f отсутствует в проекции"
  fi
done

echo "== значения переменных окружения не сохраняются, имена — да"
names=$(printf '%s' "$OUT" | jq -r '.[0].EnvNames | join(",")')
case "$names" in *API_TOKEN*) ok "имя переменной сохранено (API_TOKEN)";; *) bad "имена переменных потеряны: $names";; esac
case "$OUT" in *"API_TOKEN=$CANARY"*) bad "значение переменной утекло";; *) ok "значение переменной не сохранено";; esac

echo "== полезные данные на месте (не переусердствовали)"
chk(){ v=$(printf '%s' "$OUT" | jq -r "$2"); if [ "$v" = "$3" ]; then ok "$1 = $3"; else bad "$1: ожидали '$3', получили '$v'"; fi; }
chk "имя контейнера"      '.[0].Name'                 'app'
chk "образ"               '.[0].Image'                'nginx:1.27'
chk "digest"              '.[0].ImageDigest'          'sha256:deadbeef'
chk "статус"              '.[0].State.Status'         'running'
chk "health"              '.[0].State.Health'         'healthy'
chk "restart policy"      '.[0].RestartPolicy'        'unless-stopped'
chk "сеть"                '.[0].Networks[0].network'  'net1'
chk "ip"                  '.[0].Networks[0].ip'       '172.18.0.5'
chk "mount source"        '.[0].Mounts[0].Source'     '/data/db'

echo "== диверсия: набор обязан ЛОВИТЬ дырявый фильтр"
# Без этой проверки набор бесполезен: первая редакция теста «проходила» даже на фильтре,
# который тащил Args, потому что приманка вида --token=… гасилась маскировкой. Приманка
# теперь opaque, а здесь мы убеждаемся, что дырявый фильтр действительно ловится.
LEAKY=$(printf '%s' "$INPUT" | jq '[.[] | {Name, Args, Labels: .Config.Labels}]' | redact_json_deep)
case "$LEAKY" in
  *"$CANARY"*) ok "дырявый фильтр приманку пропускает — проверка работоспособна";;
  *) bad "даже дырявый фильтр «чист» — набор ничего не доказывает";;
esac

echo "== результат остаётся валидным JSON"
if printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then ok "JSON валиден"; else bad "JSON сломан"; fi

echo
echo "Итого: прошло $PASS, упало $FAIL"
[ "$FAIL" -eq 0 ]
