#!/usr/bin/env bash
# _lib/redact.sh — единая библиотека маскировки секретов (канон redaction v3).
#
# Источник правды для ВСЕХ скиллов, которые пишут вывод серверных команд в файлы
# или показывают его в сессии. Через неё проходит каждая секция снимка
# inventory-scan (dump-snapshot.sh) и вывод удалённых команд rotate-secrets.
#
# Подключение из скрипта скилла:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/../../_lib/redact.sh"   # путь от scripts/ скилла до _lib/
#
# Совместимость: bash 3.2 (macOS), POSIX awk, опционально jq.
#
# ===========================================================================
# ЧТО ИЗМЕНИЛОСЬ В v3 И ПОЧЕМУ (слепая сверка 2026-08-22, ADR-0029)
# ===========================================================================
# v2 строилась на цепочке `sed` и имела два корневых дефекта, а не восемь мелких:
#
#   1. Значение секрета обрывалось на первом пробеле/запятой/кавычке, а имя
#      переменной сверялось ПОДСТРОКОЙ. Отсюда одновременно и утечки (хвост
#      пароля с пробелами, тело многострочного YAML-блока), и уничтожение данных
#      (`KEYBOARD_LAYOUT`, `API_URL` маскировались целиком — снимок становился
#      ложным, а по §4.6 персоны снимок считается источником истины).
#   2. Построчная и JSON-ветки были ДВУМЯ независимыми реализациями с двумя
#      чёрными списками. Они разошлись по `signature`, `requirepass`, SQL
#      `PASSWORD '…'` и двоеточию, и рассинхрон ниоткуда не был виден.
#
# v3 отвечает на оба корня структурно, а не заплатками:
#
#   * ОДНО ЯДРО ПРАВИЛ (`_redact_core`, единственный проход awk). Оно знает
#     контекст: границу значения определяют кавычки и синтаксис, а не «первый
#     пробел»; имя разбирается на СЕГМЕНТЫ (`_`, `-`, `.`, граница camelCase), и
#     секрет-слово должно совпасть с сегментом целиком.
#   * У JSON-ветки БОЛЬШЕ НЕТ СВОИХ РЕГУЛЯРОК. `redact_json_deep` использует jq
#     только как структурный обход: вынимает все строки документа (значения и
#     ИМЕНА КЛЮЧЕЙ), прогоняет их через то же ядро и возвращает обратно. Ветки
#     не могут разойтись — расходиться нечему.
#
# Границы, принятые осознанно (не забытые):
#   * `-p` не покрывается: он неотличим от `docker run -p 8080:80`, и правило
#     уничтожало бы карту портов. Пароли через `-p` ловятся именем (`--password`)
#     и значением (префиксы токенов).
#   * Белый список имён (`*_URL`, `*_HOST`, `*_VERSION`, …) снимает подозрение
#     только с ИМЕНИ. Секрет внутри такого значения по-прежнему ловится по
#     значению: `DATABASE_URL=postgres://u:pass@h` маскируется правилом креды-в-URL.
#   * Вложенный JSON внутри JSON-строки (`"{\"password\":\"x\"}"`) разбирается
#     как текст, а не как структура: экранированные кавычки не открывают контекст.
#     Такой секрет ловится только по значению. Известный предел, не дефект.
# ===========================================================================

# --- ЕДИНЫЙ СЛОВАРЬ ИМЁН (обе ветки читают отсюда; второго списка НЕТ) -------
# Секрет-слово должно совпасть с СЕГМЕНТОМ имени целиком: `KEY` ловит
# `AWS_ACCESS_KEY_ID` и `authToken`, но не `KEYBOARD` и не `MONKEY`.
REDACT_SECRET_WORDS='token,tokens,key,keys,secret,secrets,password,passwords,passwd,pass,passphrase,credential,credentials,apikey,auth,authorization,privkey,signature,salt,session,cookie,dsn,jwt,pat'

# Хвостовой сегмент из этого списка снимает подозрение с имени: такие поля
# держат адреса, пути и версии — то, ради чего снимок и снимается. Проверяется
# только ПОСЛЕДНИЙ сегмент: `API_KEY_V2` остаётся секретом.
#
# `id` в списке НЕТ намеренно: `AWS_ACCESS_KEY_ID` — имя, которое маска обязана
# ловить (проверяется тестом). Идентификатор сессии или ключа лучше замаскировать
# лишний раз, чем потерять настоящий секрет.
REDACT_SAFE_WORDS='url,uri,urls,host,hostname,hosts,port,ports,path,paths,file,files,filename,dir,directory,version,layout,type,types,mode,algo,algorithm,enabled,disabled,timeout,ttl,length,size,count,format,scheme,method,domain,name,names,user,username,owner,group,label,labels,image,tag,region,zone,bucket,endpoint,driver,provider,strategy,rotation,interval,retries,limit,level,status,state,date,time,expiry,expires,issuer,audience,subject,header,prefix,suffix,pattern,required,optional,policy,source,target'

# Ядро маскировки. Аргумент: 1 — режим одной строки (без машин состояний
# многострочного PEM и YAML-блока), гарантирует ровно одну строку вывода на
# строку входа. Этого требует JSON-ветка: там каждая строка документа —
# самостоятельное значение, и сдвиг на одну строку испортил бы весь документ.
_redact_core() {
    awk -v SINGLE="${1:-0}" \
        -v SECRET_WORDS="$REDACT_SECRET_WORDS" \
        -v SAFE_WORDS="$REDACT_SAFE_WORDS" '
function rep(s, n,   i, o) { o = ""; for (i = 0; i < n; i++) o = o s; return o }

# Регистронезависимый вид слова: password -> [pP][aA][sS][sS][wW][oO][rR][dD].
# awk не имеет флага "i", а нам нужен один и тот же список слов для обеих веток.
function ci(w,   i, c, u, l, o) {
    o = ""
    for (i = 1; i <= length(w); i++) {
        c = substr(w, i, 1); u = toupper(c); l = tolower(c)
        if (u != l) o = o "[" l u "]"; else o = o c
    }
    return o
}
function cia(list,   n, arr, i, o) {
    n = split(list, arr, ",")
    o = ""
    for (i = 1; i <= n; i++) o = o (i > 1 ? "|" : "") ci(arr[i])
    return "(" o ")"
}

# Заменяет ВСЕ совпадения с re, сохраняя ту часть совпадения, которая подошла
# под headre (голова правила: имя параметра, схема URL, флаг). headre = "" —
# совпадение затирается целиком.
function mask_tail(s, re, headre, repl,   out, m, pre, hl, guard) {
    out = ""; guard = 0
    while (match(s, re)) {
        if (++guard > 2000) break
        pre = substr(s, 1, RSTART - 1)
        m   = substr(s, RSTART, RLENGTH)
        s   = substr(s, RSTART + RLENGTH)
        hl = 0
        if (headre != "" && match(m, headre) && RSTART == 1) hl = RLENGTH
        out = out pre substr(m, 1, hl) repl
    }
    return out s
}

# Разделяет camelCase границей сегмента: authToken -> auth_Token.
function split_camel(s,   i, c, p, o) {
    o = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (i > 1) { p = substr(s, i - 1, 1); if (c ~ /[A-Z]/ && p ~ /[a-z0-9]/) o = o "_" }
        o = o c
    }
    return o
}

# Имя — секрет? Сегменты, а не подстрока: иначе KEYBOARD_LAYOUT и MONKEY_MODE
# уезжают в снимок как <REDACTED>, и инвентарь становится ложным (дефект B2).
function is_secret(nm,   t, parts, n, i) {
    if (nm == "") return 0
    t = tolower(split_camel(nm))
    n = split(t, parts, /[^a-z0-9]+/)
    if (n == 0) return 0
    if (parts[n] in SAFE) return 0
    for (i = 1; i <= n; i++) if (parts[i] in SECRET) return 1
    return 0
}

# Индекс ближайшей НЕэкранированной кавычки q, начиная с i; 0 — не найдена.
function find_close(s, i, q,   c) {
    while (i <= length(s)) {
        c = substr(s, i, 1)
        if (c == "\\") { i += 2; continue }
        if (c == q) return i
        i++
    }
    return 0
}

# Состояние «внутри двойных кавычек» после прохода по тексту t.
function qstate(t, st,   i, c) {
    i = 1
    while (i <= length(t)) {
        c = substr(t, i, 1)
        if (c == "\\") { i += 2; continue }
        if (c == "\"") st = 1 - st
        i++
    }
    return st
}

function indent(s,   i, c, n) {
    n = 0
    for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == " " || c == "\t") n++; else break }
    return n
}

# Проход по присваиваниям NAME=value / "NAME": value. Границу значения задаёт
# контекст, а не первый пробел (дефект A1) — и он же не даёт съесть остаток
# JSON-строки или сломать документ (дефект B3).
function scan_names(s,   out, rest, m, pre, nm, sep, nq, instr, c, j, val, tail, guard) {
    out = ""; rest = s; instr = 0; guard = 0
    while (match(rest, ASSIGN)) {
        if (++guard > 2000) break
        pre  = substr(rest, 1, RSTART - 1)
        m    = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        instr = qstate(pre m, instr)
        out = out pre m

        sep = substr(m, length(m), 1)
        nm  = substr(m, 1, length(m) - 1)
        sub(/[ \t]+$/, "", nm)
        nq = 0
        if (length(nm) > 1 && substr(nm, 1, 1) == "\"" && substr(nm, length(nm), 1) == "\"") {
            nq = 1; nm = substr(nm, 2, length(nm) - 2)
        } else { sub(/^"/, "", nm); sub(/"$/, "", nm) }

        if (!is_secret(nm)) continue

        while (substr(rest, 1, 1) == " " || substr(rest, 1, 1) == "\t") {
            out = out substr(rest, 1, 1); rest = substr(rest, 2)
        }
        c = substr(rest, 1, 1)
        if (c == "") break
        # Значение-контейнер не трогаем: маска структуры сломала бы документ,
        # а строки внутри разбираются своими именами и правилами по значению.
        if (c == "{" || c == "[") continue

        if (c == "\"" && !instr) {
            j = find_close(rest, 2, "\"")
            if (j > 0) { out = out "\"" R "\""; rest = substr(rest, j + 1); continue }
            out = out "\"" R; rest = ""; break
        }
        if (c == "'"'"'" && !instr) {
            j = find_close(rest, 2, "'"'"'")
            if (j > 0) { out = out "'"'"'" R "'"'"'"; rest = substr(rest, j + 1); continue }
            out = out "'"'"'" R; rest = ""; break
        }
        # Внутри JSON-строки значение кончается закрывающей кавычкой — только это
        # и удерживает `"Env":["API_TOKEN=x","IMAGE=nginx"]` от потери соседей.
        if (instr) {
            j = find_close(rest, 1, "\"")
            if (j > 0) { out = out R; rest = substr(rest, j); continue }
            out = out R; rest = ""; break
        }
        # Голый литерал JSON (null / число / true): заменяем СТРОКОЙ, иначе
        # документ перестаёт разбираться.
        if (nq && sep == ":") {
            match(rest, /^[^,}\]]*/)
            val = substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1)
            tail = ""
            while (val != "" && (substr(val, length(val), 1) == " " || substr(val, length(val), 1) == "\t")) {
                tail = substr(val, length(val), 1) tail; val = substr(val, 1, length(val) - 1)
            }
            out = out "\"" R "\"" tail
            continue
        }
        # Блочный скаляр YAML: тело лежит на следующих строках. Раньше
        # маскировался только знак `|`, а тело уходило целиком — так в 2026-08-08
        # утёк sb_secret_.
        if (!SINGLE && rest ~ /^[|>][0-9]*[+-]?[ \t]*$/) {
            out = out R; rest = ""; inyaml = 1; yamlind = curind; break
        }
        # Незакавыченное значение идёт до конца строки — так устроены и env, и
        # YAML-скаляр. Обрыв на пробеле оставлял хвост пароля в снимке.
        out = out R; rest = ""; break
    }
    return out rest
}

function scrub(s) {
    s = mask_tail(s, PEM1,    "",         "<REDACTED-PRIVATE-KEY>")
    s = mask_tail(s, JWT,     "",         "<REDACTED-JWT>")
    s = mask_tail(s, SBKEY,   "",         R)
    s = mask_tail(s, TOKPFX,  TOKBOUND,   R)
    s = mask_tail(s, AWSK,    "",         R)
    s = mask_tail(s, TGTOK,   TGHEAD,     R)
    s = mask_tail(s, URLCRED, URLHEAD,    R "@")
    s = mask_tail(s, QUERY,   QHEAD,      R)
    s = mask_tail(s, SQLQ,    SQLHEAD,    R Q)
    s = mask_tail(s, SQLBY,   SQLBYHEAD,  R Q)
    s = mask_tail(s, REQP,    REQPHEAD,   R)
    s = mask_tail(s, BEAR,    BEARHEAD,   R)
    s = mask_tail(s, FLAGV,   FLAGHEAD,   R)
    s = mask_tail(s, USERF,   USERFHEAD,  R)
    if (s ~ REDISCTX) s = mask_tail(s, REDISA, REDISAHEAD, R)
    if (s ~ NETRCCTX) s = mask_tail(s, NETRCPW, NETRCPWHEAD, R)
    if (s ~ PGPASS)   s = mask_tail(s, PGPASS, PGPASSHEAD, R)
    s = mask_tail(s, CRYPTH, CRYPTHHEAD, R)
    return scan_names(s)
}

BEGIN {
    n = split(SECRET_WORDS, a, ","); for (i = 1; i <= n; i++) SECRET[a[i]] = 1
    n = split(SAFE_WORDS,   a, ","); for (i = 1; i <= n; i++) SAFE[a[i]] = 1
    R = "<REDACTED>"
    Q = sprintf("%c", 39)          # одинарная кавычка: внутри awk-программы её нет
    TC  = "[A-Za-z0-9_-]"          # символ непрозрачного токена
    NOTC = "[^A-Za-z0-9_-]"
    D   = "[0-9]"

    ASSIGN = "\"?[A-Za-z0-9_.-]+\"?[ \t]*[=:]"

    # PEM: суффикс после "PRIVATE KEY" обязателен — иначе PGP-блок
    # (`-----BEGIN PGP PRIVATE KEY BLOCK-----`) проходил насквозь (дефект A4).
    PEMB = "-----BEGIN [A-Za-z0-9 ]*PRIVATE KEY[A-Za-z0-9 ]*-----"
    PEME = "-----END [A-Za-z0-9 ]*PRIVATE KEY[A-Za-z0-9 ]*-----"
    PEM1 = PEMB ".*" PEME
    # Блок начинается ТОЛЬКО строкой-маркером целиком. Сообщение об ошибке nginx
    # с тем же литералом внутри кавычек больше не переводит маску в режим
    # «глотаю всё до конца потока» (дефект B1).
    PEMONLY = "^[ \t]*" PEMB "[ \t]*$"
    # Тело ключа: одиночный токен без пробелов, заголовок PEM или пустая строка.
    # Любая другая строка означает, что блок оборвался, — она сохраняется.
    KEYBODY = "^[ \t]*([A-Za-z0-9+/=_-]+|(Proc-Type|DEK-Info|Comment|Version|Subject):.*)?[ \t]*$"

    JWT   = "eyJ" TC "+\\.eyJ" TC "+\\." TC "*"
    SBKEY = "sb_(secret|publishable)_" rep(TC, 8) TC "*"

    # Непрозрачные токены по ЗНАЧЕНИЮ: имя переменной бывает безобидным, а сам
    # токен формы не имеет (дефект A2).
    TOKBOUND = "(^|" NOTC ")"
    TOKPFX = TOKBOUND "(gh[pousr]_|github_pat_|glpat-|gldt-|glrt-|glsoat-|sk-ant-|sk-proj-|sk-|xox[abeprs]-|dckr_pat_|npm_|hf_|shpat_|shpss_|sbp_|pypi-|AIza|SG\\.|[a-z]k_(live|test)_)" rep(TC, 16) TC "*"
    AWSK  = "(AKIA|ASIA|AGPA|AROA|AIDA|ANPA|ANVA|ABIA|ACCA)" rep("[A-Z0-9]", 16)
    TGTOK = TOKBOUND rep(D, 8) D "*:" rep(TC, 30) TC "*"
    TGHEAD = TOKBOUND rep(D, 8) D "*:"

    URLCRED = "[A-Za-z][A-Za-z0-9+.-]*://[^:@/[:space:]\"]+:[^@/[:space:]\"]+@"
    URLHEAD = "[A-Za-z][A-Za-z0-9+.-]*://[^:@/[:space:]\"]+:"

    QUERY = "[?&]" cia("secret,token,key,password,passwd,access_token,refresh_token,api_key,apikey,sig,signature,auth,authorization,session,credential") "=[^&\"" Q "[:space:]]+"
    QHEAD = "[?&][A-Za-z_]+="

    SQLQ      = cia("password") "[[:space:]]+" Q "[^" Q "]*" Q
    SQLHEAD   = cia("password") "[[:space:]]+" Q
    SQLBY     = cia("identified") "[[:space:]]+" cia("by") "[[:space:]]+" Q "[^" Q "]*" Q
    SQLBYHEAD = cia("identified") "[[:space:]]+" cia("by") "[[:space:]]+" Q

    # Значение после ключевого слова или флага: закавыченное целиком либо голый
    # токен. Двойная кавычка в голый вариант НЕ входит — иначе правило съедает
    # закрывающую кавычку JSON-строки и документ перестаёт разбираться. Поймано
    # сверкой двух веток на одном корпусе, а не рассуждением.
    VAL = "(\"[^\"]*\"|" Q "[^" Q "]*" Q "|[^[:space:]\"" Q "]+)"

    REQP     = cia("requirepass") "[[:space:]]+" VAL
    REQPHEAD = cia("requirepass") "[[:space:]]+"
    BEAR     = cia("bearer") "[[:space:]]+" VAL
    BEARHEAD = cia("bearer") "[[:space:]]+"

    # Учётные данные во флагах: такие строки попадают в снимок из Cmd
    # контейнеров, healthcheck и host-скриптов (дефект A3). `-p` намеренно НЕ
    # покрывается — он неотличим от публикации портов.
    FLAGV    = "--" cia("password,passwd,token,secret,api-key,apikey,auth,access-token,private-key,credential,pass") "[[:space:]]+" VAL
    FLAGHEAD = "--[A-Za-z-]+[[:space:]]+"
    USERF     = "(^|[[:space:]])(-[uU]|--" ci("user") ")[[:space:]]+[^[:space:]:\"]+:[^[:space:]\"]+"
    USERFHEAD = "(^|[[:space:]])(-[uU]|--" ci("user") ")[[:space:]]+[^[:space:]:\"]+:"
    REDISCTX   = ci("redis")
    REDISA     = "(^|[[:space:]])-a[[:space:]]+" VAL
    REDISAHEAD = "(^|[[:space:]])-a[[:space:]]+"

    NETRCCTX    = "(^|[[:space:]])" cia("machine,login") "[[:space:]]"
    NETRCPW     = cia("password,passwd") "[[:space:]]+" VAL
    NETRCPWHEAD = cia("password,passwd") "[[:space:]]+"
    PGPASS     = "^\"?[^:[:space:]]+:[0-9*]+:[^:]*:[^:]*:[^[:space:]\"]+"
    PGPASSHEAD = "^\"?[^:[:space:]]+:[0-9*]+:[^:]*:[^:]*:"
    CRYPTH     = "\\$(apr1|1|5|6|2[abxy])\\$[^[:space:]:\"]*"
    CRYPTHHEAD = "\\$(apr1|1|5|6|2[abxy])\\$"

    inkey = 0; inyaml = 0; yamlind = 0; curind = 0; warned = 0
}

{
    if (!SINGLE && inkey) {
        if ($0 ~ PEME)   { inkey = 0; next }
        if ($0 ~ KEYBODY) next
        # Блок оборвался (усечённый вывод, чужой текст сразу за ключом). Тело
        # уже замаскировано, а ЭТА строка и всё после неё сохраняются: молчаливая
        # потеря остатка потока при коде возврата ноль запрещена.
        inkey = 0
        if (!warned) {
            warned = 1
            print "redact: незакрытый блок PRIVATE KEY — тело замаскировано, остальные строки сохранены" > "/dev/stderr"
        }
    }
    if (!SINGLE && inyaml) {
        if ($0 ~ /^[ \t]*$/) next
        if (indent($0) > yamlind) next
        inyaml = 0
    }
    if (!SINGLE && $0 ~ PEMONLY) { print "<REDACTED-PRIVATE-KEY>"; inkey = 1; next }
    curind = indent($0)
    print scrub($0)
}

END {
    if (inkey && !warned) {
        print "redact: поток оборвался внутри блока PRIVATE KEY — тело замаскировано" > "/dev/stderr"
    }
}
'
}

# Построчная маскировка (основной путь для всех не-JSON секций). Stdin -> stdout.
redact_stream() { _redact_core 0; }

# Глубокая маскировка JSON. jq здесь — ТОЛЬКО структурный обход: он вынимает все
# строки документа, включая ИМЕНА КЛЮЧЕЙ (секрет в имени ключа раньше проходил
# насквозь — дефект A5), отдаёт их тому же ядру и возвращает результат на место.
# Своих регулярок у этой ветки нет: расходиться с построчной ей нечем (дефект A6).
#
# FAIL-CLOSED: без jq возвращает 3 и НИЧЕГО не печатает; любой сбой обхода — 4.
# Подменять структурную обработку построчным sed нельзя — он не умеет надёжно
# проецировать JSON и может отдать половину документа. Вызывающий обязан считать
# ненулевой код отказом, а не поводом писать сырьё.
#
# Это страховка, а не основной механизм: снимок не должен нести сырой
# `docker inspect` вообще (см. containers-summary.json в inventory-scan, ADR-0025).
redact_json_deep() {
    command -v jq >/dev/null 2>&1 || return 3
    local doc tmpd rc no nr
    doc="$(cat)" || return 4
    [ -n "$doc" ] || return 4
    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/redact.XXXXXX")" || return 4

    # Все строки документа: имена ключей на любой глубине + все строковые
    # значения. @json даёт по одной строке на значение и переживает переводы
    # строк внутри значения (они остаются экранированными).
    if ! printf '%s' "$doc" | jq -r '
            ([paths[] | select(type == "string")] + [.. | strings]) | unique | .[] | @json
        ' > "$tmpd/orig" 2>/dev/null; then
        rm -rf "$tmpd"; return 4
    fi
    if ! _redact_core 1 < "$tmpd/orig" > "$tmpd/red" 2>/dev/null; then
        rm -rf "$tmpd"; return 4
    fi
    # Соответствие строк 1:1 — обязательное условие: сдвиг сделал бы карту
    # замен ложной, а документ — тихо неверным.
    no=$(wc -l < "$tmpd/orig" | tr -d ' '); nr=$(wc -l < "$tmpd/red" | tr -d ' ')
    if [ "$no" != "$nr" ]; then rm -rf "$tmpd"; return 4; fi

    printf '%s' "$doc" | jq --slurpfile O "$tmpd/orig" --slurpfile R "$tmpd/red" '
        def rmap($m):
          if   type == "object" then with_entries(.key |= ($m[.] // .) | .value |= rmap($m))
          elif type == "array"  then map(rmap($m))
          elif type == "string" then ($m[.] // .)
          else . end;
        (reduce range(0; ($O | length)) as $i ({}; .[$O[$i]] = $R[$i])) as $map
        | rmap($map)
    ' 2>/dev/null
    rc=$?
    rm -rf "$tmpd"
    return $rc
}

# Устаревший путь: маскирует только массивы .Env (структурно слеп к .Args,
# .Entrypoint, .Labels, .Healthcheck — ради этого и появился redact_json_deep).
# Сохранён как совместимость для внешних потребителей библиотеки; в снимке
# используется redact_json_deep.
#
# Контракт: 3 — нет jq, 4 — jq не разобрал вход или вход пуст, 0 — успех. Раньше
# контракт держался ИСКЛЮЧИТЕЛЬНО на `set -o pipefail` вызывающего: код возврата
# брался у хвостового sed, и битый JSON давал ноль при пустом выводе (дефект B4).
# Теперь результат jq проверяется до печати, и откат вызывающего действительно
# срабатывает.
redact_json_with_jq() {
    command -v jq >/dev/null 2>&1 || return 3
    local out
    out="$(jq '
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
    ' 2>/dev/null)" || return 4
    [ -n "$out" ] || return 4
    printf '%s\n' "$out" | _redact_core 0
}
