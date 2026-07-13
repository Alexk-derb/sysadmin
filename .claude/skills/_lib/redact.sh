#!/usr/bin/env bash
# _lib/redact.sh — единая библиотека маскировки секретов (канон redaction v2).
#
# Источник правды для ВСЕХ скиллов, которые пишут вывод серверных команд в файлы
# или показывают его в сессии. Исторически функции жили в
# inventory-scan/scripts/dump-snapshot.sh; вынесены сюда, чтобы rotate-secrets
# (и будущие скиллы) переиспользовали их, а не копировали (задача 0.2 плана
# рефакторинга, D2).
#
# Подключение из скрипта скилла:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/../../_lib/redact.sh"   # путь от scripts/ скилла до _lib/
#
# Совместимость: bash 3.2 (macOS), без зависимостей кроме sed -E; jq — опционален
# (redact_json_with_jq сама сообщает о неудаче ненулевым кодом).

# Построчная маскировка (fallback и для не-JSON секций). Stdin -> stdout.
redact_stream() {
    # 1. KEY=value, где секрет-слово (TOKEN/KEY/SECRET/PASSWORD/PASS/API/CREDENTIAL)
    #    стоит ГДЕ УГОДНО в имени переменной (не только в конце). Так ловятся и
    #    AWS_ACCESS_KEY_ID=, и API_TOKEN_PROD=, а не только *_KEY=/*_TOKEN=.
    #    (выровнено с логикой jq-пути redact_json_with_jq, где секрет-слово тоже
    #    матчится в любом месте имени до '=').
    # 2. credentials в URL: scheme://user:pass@host -> scheme://user:<REDACTED>@host
    # 3. секрет в query-string URL: ?secret=...&token=... -> ?secret=<REDACTED>
    #    (граблекейс srv-main: cron-задача с curl "...?secret=<секрет>..." утекала
    #    открытым текстом в crontab.txt — KEY=value и url:pass@ её не ловили).
    # 4. AWS access key ID по ЗНАЧЕНИЮ: AKIA/ASIA + 16 символов [A-Z0-9]. Имя
    #    переменной AWS_ACCESS_KEY_ID ловится правилом 1, но голый AKIA... в логе
    #    или нестандартной обёртке — нет; правило 4 ловит сам идентификатор.
    # 5. SQL-пароли в выводе/ошибках БД (добавлено для rotate-secrets): psql/mysql
    #    при синтаксической ошибке эхо-ят весь statement, включая
    #    ALTER USER ... WITH PASSWORD '...' / IDENTIFIED BY '...' — правила 1-4
    #    их не ловят (нет '=' после слова PASSWORD).
    # 6. redis requirepass в выводе/эхо команд CONFIG SET requirepass <pw>.
    sed -E \
        -e 's/("?[A-Za-z0-9_]*(TOKEN|KEY|SECRET|PASSWORD|PASS|API|CREDENTIAL)[A-Za-z0-9_]*"?[[:space:]]*[=:][[:space:]]*"?)[^"[:space:],}]+/\1<REDACTED>/Ig' \
        -e 's#(([A-Za-z][A-Za-z0-9+.-]*)://[^:@/[:space:]]+:)[^@/[:space:]]+@#\1<REDACTED>@#g' \
        -e 's/([?&](secret|token|key|password|passwd|access_token|api_key|apikey|sig|signature)=)[^&"'"'"'[:space:]]+/\1<REDACTED>/Ig' \
        -e 's/(AKIA|ASIA)[A-Z0-9]{16}/<REDACTED>/g' \
        -e "s/(PASSWORD[[:space:]]+')[^']*(')/\1<REDACTED>\2/Ig" \
        -e "s/(IDENTIFIED[[:space:]]+BY[[:space:]]+')[^']*(')/\1<REDACTED>\2/Ig" \
        -e 's/(requirepass[[:space:]]+)[^[:space:]"]+/\1<REDACTED>/Ig'
}

# Маскировка JSON через jq, если он доступен: значения .Config.Env и .Env,
# чей ключ матчит секрет-паттерн, заменяются на KEY=<REDACTED> (имя ключа
# сохраняется для аудита). Возвращает ненулевой код, если jq не справился —
# тогда вызывающий код падает в построчный fallback.
#
# ВАЖНО: один лишь jq НЕ ловит пароль внутри URL (DATABASE_URL=postgres://u:pass@host)
# — имя переменной не матчит секрет-паттерн, и строка остаётся нетронутой
# (проверено тестом: пароль утекал). Поэтому ПОСЛЕ структурной маскировки
# прогоняем вывод jq через тот же URL-паттерн, что и построчный fallback.
redact_json_with_jq() {
    jq '
      def redact_env:
        if . == null then .
        else map(
          if test("^[^=]*(TOKEN|KEY|SECRET|PASSWORD|PASS|API)[^=]*=" ; "i")
          then sub("=.*"; "=<REDACTED>")
          else .
          end
        )
        end;
      (.. | objects | select(has("Env")) | .Env) |= redact_env
    ' 2>/dev/null \
    | sed -E "s#(([A-Za-z][A-Za-z0-9+.-]*)://[^:@/[:space:]]+:)[^@/[:space:]\"]+@#\1<REDACTED>@#g"
}
