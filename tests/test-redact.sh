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

echo
echo "Итого: прошло $PASS, упало $FAIL"
[ "$FAIL" -eq 0 ]
