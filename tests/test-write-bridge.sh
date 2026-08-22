#!/usr/bin/env bash
# tests/test-write-bridge.sh — тесты генератора выездного указателя _lib/write-bridge.sh.
#
# Зачем: 2026-08-18 выяснилось, что helper рапортует успех при провалившейся записи —
# печатает «✅ bridge-указатель записан» и возвращает 0, оставляя файл нулевого размера.
# Отдельно он принимал относительный и несуществующий путь к мозгу и уносил его в указатель.
# Класс отказа — «сторож всегда зелёный»: установка выглядит удавшейся, а @sysadmin из чужих
# папок не работает, и обнаруживается это много позже.
#
# Главное правило набора: проверяем не только «получилось», но и «при отказе честно сказано
# об отказе». Тест успеха без парного теста отказа ничего не доказывает — он зелёный и на
# сломанной версии.
#
# Две грабли, на которые набор наступил при написании и которые здесь намеренно обойдены:
#   • счётчики нельзя менять внутри подоболочки `( … )` — инкременты теряются, и набор
#     рапортует «0 падений» вообще ничего не проверив;
#   • отсутствие строки проверяется через `! grep -qF`, а НЕ через `grep -qv`: последний
#     инвертирует построчно и на многострочном выводе зелен, даже когда строка есть.
#
# Запуск:  bash tests/test-write-bridge.sh
# Код возврата: 0 — все прошли, 1 — есть падения.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Проверяемый файл можно подменить — это нужно мутационной проверке (набор обязан краснеть
# на намеренно испорченных версиях helper). По умолчанию проверяется штатный.
WRITE_BRIDGE_LIB="${WRITE_BRIDGE_LIB:-$ROOT/.claude/skills/_lib/write-bridge.sh}"
# Читатель указателя подменяется отдельно: мутационная проверка обязана портить и его —
# половина контракта живёт там (диверсант сверки 2026-08-20, круг 4).
FIND_CONFIG_LIB="${FIND_CONFIG_LIB:-$ROOT/.claude/skills/_lib/find-config.sh}"
# Самопроверка установки подменяется отдельно: её вердикт — последний рубеж перед тем, как
# оператор уйдёт работать, и он уже был ложно-зелёным (сверка круга 9).
SELF_TEST_LIB="${SELF_TEST_LIB:-$ROOT/.claude/skills/_lib/self-test-setup.sh}"
# shellcheck source=/dev/null
source "$WRITE_BRIDGE_LIB"

PASS=0; FAIL=0; SKIP=0
SUCCESS_MARK="bridge-указатель записан"
HOME_ORIG="$HOME"

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s (%s)\n' "$1" "$2"; }

# check <код-возврата-условия> <описание>
check() { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi; }

TMPROOT="$(mktemp -d)"
cleanup() { chmod -R u+rwX "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"; HOME="$HOME_ORIG"; }
trap cleanup EXIT

# Каждый кейс работает в собственном HOME, чтобы не трогать настоящий ~/.claude.
use_home() { HOME="$TMPROOT/home-$1"; mkdir -p "$HOME"; export HOME; }
bridge_file() { printf '%s' "$HOME/.claude/agents/sysadmin.md"; }

# Корень мозга — каталог с CLAUDE.md: указатель ведёт именно на ядро, и helper обязан
# отвергать каталоги без него (находка сверки 2026-08-20).
BRAIN="$TMPROOT/brain"; mkdir -p "$BRAIN/.claude/skills"; : > "$BRAIN/CLAUDE.md"; : > "$BRAIN/.sysadmin-root"

echo "== 1. Успешная запись"
use_home ok
out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
f="$(bridge_file)"
[ "$rc" -eq 0 ]; check $? "успешная запись: код возврата 0"
[ -s "$f" ]; check $? "файл создан и непустой"
grep -qF "$BRAIN/CLAUDE.md" "$f"; check $? "внутри путь к ядру"
grep -qE '^name: sysadmin$' "$f"; check $? "frontmatter содержит name: sysadmin"
# Без description файл не является определением агента: поле обязательно по контракту
# Claude Code, а его пропажа не ломает ни одного другого теста (диверсант сверки 2026-08-20).
grep -qE '^description: .+' "$f"; check $? "frontmatter содержит непустой description"
grep -qx 'model: inherit' "$f"; check $? "model ровно inherit (а не сломанный YAML вроде [inherit)"
grep -qF "Скиллы сам указатель не переносит" "$f"; check $? "граница про скиллы описана"
grep -qF -- "--add-dir" "$f"; check $? "назван рабочий способ получить скиллы"
# Структура frontmatter, а не только его строки: диверсант сверки 2026-08-20 — подменить
# первый разделитель `---`. Все построчные grep остаются зелёными, а определение агента
# перестаёт быть валидным. Поэтому проверяются оба разделителя и их позиции.
[ "$(head -1 "$f")" = "---" ]; check $? "первая строка — разделитель frontmatter"
[ "$(sed -n '2,20p' "$f" | grep -cx -- '---')" -eq 1 ]; check $? "закрывающий разделитель ровно один"
printf '%s' "$out" | grep -qF "$SUCCESS_MARK"; check $? "напечатана строка успеха"

echo "== 2. Отказ записи объявляется отказом (не ложный успех)"
use_home deny
mkdir -p "$HOME/.claude/agents"
chmod 500 "$HOME/.claude/agents" 2>/dev/null
if touch "$HOME/.claude/agents/.probe" 2>/dev/null; then
    # Среда не соблюдает права (Windows/git-bash, запуск от root) — кейс ничего не проверяет
    # и должен быть громко пропущен, а не молча зелёным.
    rm -f "$HOME/.claude/agents/.probe"
    chmod 700 "$HOME/.claude/agents" 2>/dev/null
    skip "каталог недоступен для записи" "среда не соблюдает права"
else
    out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
    chmod 700 "$HOME/.claude/agents" 2>/dev/null
    [ "$rc" -ne 0 ]; check $? "код возврата не ноль"
    if printf '%s' "$out" | grep -qF "$SUCCESS_MARK"; then bad "строка успеха НЕ должна печататься"; else ok "строка успеха не напечатана"; fi
    [ ! -s "$(bridge_file)" ]; check $? "битый файл не оставлен"
fi

echo "== 2б. Отказ записи, воспроизводимый на любой ОС"
# Права соблюдаются не везде, поэтому отказ записи моделируем подменой самой записи:
# внутри helper вызывается `cat > "$tmp"`, и заглушка гарантирует ненулевой код возврата.
use_home denyfn
cat() { return 1; }
out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
unset -f cat
[ "$rc" -ne 0 ]; check $? "код возврата не ноль"
if printf '%s' "$out" | grep -qF "$SUCCESS_MARK"; then bad "напечатан успех при провалившейся записи"; else ok "строка успеха не напечатана"; fi
# Проверяется и ПРИЧИНА: если отказ записи не останавливает работу, тот же ненулевой код
# вернёт следующая защита, но сообщение будет о другом — оператор пойдёт чинить не то.
printf '%s' "$out" | grep -qF "не удалось записать временный файл"; check $? "причина отказа названа верно"
# И ровно одна причина: если отказ записи не прерывает работу, следом отработает постусловие
# и добавит вторую жалобу о том же событии. Две причины на один отказ — признак, что защита
# не остановила выполнение.
if printf '%s' "$out" | grep -qF "временный файл не проходит проверку указателя"; then bad "к отказу приписана вторая, ложная причина"; else ok "причина отказа ровно одна"; fi
[ ! -e "$(bridge_file)" ]; check $? "битый файл не оставлен"
if ls "$HOME/.claude/agents/".sysadmin-bridge.* >/dev/null 2>&1; then bad "временный файл остался"; else ok "временный файл убран"; fi

echo "== 2в. Каталог агентов занят файлом"
use_home dirbusy
mkdir -p "$HOME/.claude"
: > "$HOME/.claude/agents"
out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
[ "$rc" -ne 0 ]; check $? "код возврата не ноль"
if printf '%s' "$out" | grep -qF "$SUCCESS_MARK"; then bad "напечатан успех при недоступном каталоге"; else ok "строка успеха не напечатана"; fi

echo "== 3. Неверный вход отвергается"
use_home args
f="$(bridge_file)"
out="$(write_bridge "" 2>&1)"; rc=$?
[ "$rc" -ne 0 ]; check $? "пустой аргумент: код возврата не ноль"
[ ! -e "$f" ]; check $? "пустой аргумент: файл не создан"

out="$(write_bridge "relative/path" 2>&1)"; rc=$?
[ "$rc" -ne 0 ]; check $? "относительный путь: код возврата не ноль"
if printf '%s' "$out" | grep -qF "$SUCCESS_MARK"; then bad "относительный путь: напечатан успех"; else ok "относительный путь: без строки успеха"; fi
[ ! -e "$f" ]; check $? "относительный путь: файл не создан"

out="$(write_bridge "$TMPROOT/no-such-dir" 2>&1)"; rc=$?
[ "$rc" -ne 0 ]; check $? "несуществующий каталог: код возврата не ноль"
# Причина отказа обязана быть настоящей: без проверки существования тот же отказ выдаст
# проверка CLAUDE.md, и оператор пойдёт искать не ту неисправность.
printf '%s' "$out" | grep -qF "каталог не существует"; check $? "несуществующий каталог: причина названа верно"
[ ! -e "$f" ]; check $? "несуществующий каталог: файл не создан"

echo "== 3д. Каталог без CLAUDE.md — не корень мозга"
use_home nobrain
NOBRAIN="$TMPROOT/not-a-brain"; mkdir -p "$NOBRAIN"
out="$(write_bridge "$NOBRAIN" 2>&1)"; rc=$?
[ "$rc" -ne 0 ]; check $? "каталог без CLAUDE.md: код возврата не ноль"
if printf '%s' "$out" | grep -qF "$SUCCESS_MARK"; then bad "каталог без CLAUDE.md: напечатан успех"; else ok "каталог без CLAUDE.md: без строки успеха"; fi
[ ! -e "$(bridge_file)" ]; check $? "каталог без CLAUDE.md: файл не создан"

echo "== 1б. Контракт писатель → читатель (интеграционно, на настоящем резолвере)"
# Главная дыра, найденная сверкой 2026-08-20: набор проверял ТЕКСТ указателя, но никогда —
# что его читает настоящий locate_sysadmin_root. Из-за этого мимо прошли два дефекта:
# читатель требовал, чтобы путь оканчивался на «sysadmin», и ломался от снятых обратных
# кавычек. Тест поднимает мозг в каталоге с ЧУЖИМ именем и требует, чтобы резолвер вернул
# именно его.
use_home roundtrip
ODDNAME="$TMPROOT/ops-brain"; mkdir -p "$ODDNAME/.claude/skills"; : > "$ODDNAME/CLAUDE.md"; : > "$ODDNAME/.sysadmin-root"
write_bridge "$ODDNAME" >/dev/null 2>&1; check $? "указатель записан для каталога с именем не sysadmin"
(
    # shellcheck source=/dev/null
    source "$FIND_CONFIG_LIB"
    locate_sysadmin_root >/dev/null 2>&1
    [ "$(cd "$SYSADMIN_ROOT" 2>/dev/null && pwd -P)" = "$(cd "$ODDNAME" && pwd -P)" ]
); check $? "настоящий locate_sysadmin_root вернул тот же каталог"

# Та же проверка для РОДНОЙ виндовой формы пути: диверсант круга 4 — снять нормализацию
# cygpath в читателе. Кейс «3е» проверяет только писателя, и без этого прохода мутант
# оставался бы незамеченным.
if command -v cygpath >/dev/null 2>&1; then
    # Форма с ОБРАТНЫМИ слэшами (`cygpath -w`), а не с прямыми: прямые bash понимает и без
    # нормализации, поэтому проверка на них зелена даже со снятым cygpath — мутант выживал.
    use_home roundtripwin
    write_bridge "$(cygpath -w "$ODDNAME")" >/dev/null 2>&1
    (
        # shellcheck source=/dev/null
        source "$FIND_CONFIG_LIB"
        locate_sysadmin_root >/dev/null 2>&1
        [ "$(cd "$SYSADMIN_ROOT" 2>/dev/null && pwd -P)" = "$(cd "$ODDNAME" && pwd -P)" ]
    ); check $? "читатель разобрал указатель с виндовым путём"
else
    skip "round-trip с виндовым путём" "нет cygpath — система не Windows"
fi

echo "== 1в. Читатель отвергает указатель на каталог без ядра"
# Указатель может пережить сам мозг: каталог остался, CLAUDE.md удалён. Тогда резолвер
# обязан НЕ принимать этот путь, иначе агент пойдёт грузить персону из пустоты.
use_home staleroot
STALE="$TMPROOT/stale-root"; mkdir -p "$STALE/.claude/skills"; : > "$STALE/CLAUDE.md"; : > "$STALE/.sysadmin-root"
write_bridge "$STALE" >/dev/null 2>&1
rm -f "$STALE/CLAUDE.md"
(
    # shellcheck source=/dev/null
    source "$FIND_CONFIG_LIB"
    locate_sysadmin_root >/dev/null 2>&1
    [ "$(cd "${SYSADMIN_ROOT:-/nowhere}" 2>/dev/null && pwd -P)" != "$(cd "$STALE" && pwd -P)" ]
); check $? "читатель не принял каталог без CLAUDE.md"

echo "== 3ж. Чужой каталог с CLAUDE.md корнем мозга не считается"
# CLAUDE.md есть у множества репозиториев. Признак корня должен совпадать с тем, по которому
# указатель ЧИТАЕТСЯ (find-config.sh): маркер .sysadmin-root либо CLAUDE.md + .claude/skills.
use_home foreign
FOREIGN="$TMPROOT/foreign-repo"; mkdir -p "$FOREIGN"; : > "$FOREIGN/CLAUDE.md"
out="$(write_bridge "$FOREIGN" 2>&1)"; rc=$?
[ "$rc" -ne 0 ]; check $? "чужой репозиторий с CLAUDE.md отвергнут"
[ ! -e "$(bridge_file)" ]; check $? "чужой репозиторий: файл не создан"

echo "== 5б. Провал бэкапа останавливает замену"
# Копия делается ПЕРЕД подменой именно для того, чтобы прежний указатель пережил неудачу.
# Если провал `cp` игнорировать, замена всё равно произойдёт — уже без страховки.
use_home backupfail
write_bridge "$BRAIN" >/dev/null 2>&1
before_hash="$(command cat "$(bridge_file)" | cksum)"
cp() { return 1; }
out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
unset -f cp
[ "$rc" -ne 0 ]; check $? "провал бэкапа: код возврата не ноль"
printf '%s' "$out" | grep -qF "не удалось сохранить копию"; check $? "провал бэкапа: причина названа верно"
[ "$(command cat "$(bridge_file)" | cksum)" = "$before_hash" ]; check $? "провал бэкапа: прежний указатель не заменён"

echo "== 1г. Набор ключей frontmatter — ровно ожидаемый"
# Диверсант круга 5: добавить `tools: Read, Grep`. Формально frontmatter валиден, все
# прежние проверки зелёные, а @sysadmin молча лишается Bash и SSH. Поэтому проверяется не
# «нужные ключи есть», а «лишних нет».
use_home keys
write_bridge "$BRAIN" >/dev/null 2>&1
keys="$(sed -n '2,/^---$/p' "$(bridge_file)" | grep -oE '^[a-zA-Z_-]+:' | tr -d ':' | sort | tr '\n' ' ')"
[ "$keys" = "description model name " ]; check $? "ключи frontmatter ровно name/description/model (получено: $keys)"
if grep -qE '^tools:' "$(bridge_file)"; then bad "во frontmatter появился tools — агент лишится инструментов"; else ok "ключа tools нет (инструменты наследуются)"; fi

echo "== 3м. На месте указателя каталог"
# `mv` положил бы временный файл ВНУТРЬ каталога и вернул ноль: указателя как файла нет,
# а отказа никто не заметил (находка круга 5).
use_home dirtarget
mkdir -p "$HOME/.claude/agents/sysadmin.md"
out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
[ "$rc" -ne 0 ]; check $? "каталог на месте указателя: код возврата не ноль"
printf '%s' "$out" | grep -qF "каталог, а должен быть файлом"; check $? "каталог на месте указателя: причина названа верно"
if ls "$HOME/.claude/agents/sysadmin.md/".sysadmin-bridge.* >/dev/null 2>&1; then bad "временный файл уехал внутрь каталога"; else ok "внутрь каталога ничего не записано"; fi

echo "== 3н. Протухший замок снимается, свежий — уважается"
use_home stalelock
mkdir -p "$HOME/.claude/agents/.sysadmin-bridge.lock"
# Состариваем замок на час: свежий обязан блокировать (кейс 3л), протухший — сниматься.
touch -d '1 hour ago' "$HOME/.claude/agents/.sysadmin-bridge.lock" 2>/dev/null \
    || touch -t "$(date -d '1 hour ago' +%Y%m%d%H%M 2>/dev/null || echo 202001010000)" "$HOME/.claude/agents/.sysadmin-bridge.lock" 2>/dev/null
out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
[ "$rc" -eq 0 ]; check $? "протухший замок снят, запись прошла"
printf '%s' "$out" | grep -qF "снят протухший замок"; check $? "о снятии замка сказано вслух"

echo "== 3о. Живой владелец замка неприкосновенен, сколько бы ни держал"
# Возраст сам по себе смерти владельца не доказывает (находка круга 6). Замок, состаренный
# на час, но принадлежащий ЖИВОМУ процессу, снимать нельзя.
use_home livelock
mkdir -p "$HOME/.claude/agents/.sysadmin-bridge.lock"
printf '%s' "$$" > "$HOME/.claude/agents/.sysadmin-bridge.lock/pid"
touch -d '1 hour ago' "$HOME/.claude/agents/.sysadmin-bridge.lock" 2>/dev/null || true
out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
rm -f "$HOME/.claude/agents/.sysadmin-bridge.lock/pid" 2>/dev/null
rmdir "$HOME/.claude/agents/.sysadmin-bridge.lock" 2>/dev/null
[ "$rc" -ne 0 ]; check $? "живой владелец: замок не отобран, запись отклонена"
if printf '%s' "$out" | grep -qF "снят протухший замок"; then bad "живой владелец: замок отобрали"; else ok "живой владелец: замок не тронут"; fi

echo "== 3р. Подмена не состоялась, а старый указатель битый — успех не печатается"
# Диверсант круга 7: если игнорировать отказ `mv`, финальное постусловие увидит СТАРЫЙ файл.
# Он ведёт на тот же путь, поэтому проверка «непустой и путь внутри» его примет — а
# frontmatter в нём испорчен, и агент по такому указателю не заработает.
use_home mvfail_oldbad
write_bridge "$BRAIN" >/dev/null 2>&1
# Портим frontmatter уже стоящего указателя, сохраняя правильный путь внутри.
sed -i 's|^model: inherit$|model: [inherit|' "$(bridge_file)" 2>/dev/null
# `mv`, отчитавшийся успехом и ничего не сделавший: только так управление доходит до
# ФИНАЛЬНОГО постусловия, и оно видит старый файл. Заглушка с ошибкой сюда не годится —
# при ней helper останавливается раньше, и проверка глубины постусловия не срабатывает.
mv() { return 0; }
out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
unset -f mv
[ "$rc" -ne 0 ]; check $? "мнимый успех mv при битом старом файле: код возврата не ноль"
if printf '%s' "$out" | grep -qF "$SUCCESS_MARK"; then bad "принят старый битый указатель как свежий"; else ok "старый битый указатель не принят за свежий"; fi

echo "== 3с. В старом указателе испорчена КАНОНИЧЕСКАЯ строка пути"
# Резолвер берёт путь из строки `**`путь/`**`. Снятые обратные кавычки оставляют путь
# видимым и в строке прозы, поэтому прежнее постусловие такой файл принимало за свежий —
# а `locate_sysadmin_root` его уже не разбирает (мой замер перед кругом 8).
use_home mvfail_nobackticks
write_bridge "$BRAIN" >/dev/null 2>&1
sed -i 's|^\*\*`\(.*\)`\*\*$|**\1**|' "$(bridge_file)" 2>/dev/null
grep -qE '^\*\*[^`]+\*\*$' "$(bridge_file)"; check $? "стенд: каноническая строка старого указателя лишилась кавычек"
mv() { return 0; }
out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
unset -f mv
[ "$rc" -ne 0 ]; check $? "старый указатель без канонической строки: код возврата не ноль"
if printf '%s' "$out" | grep -qF "$SUCCESS_MARK"; then bad "принят указатель, который резолвер не разберёт"; else ok "указатель без канонической строки не принят"; fi

echo "== 3т. Дрейф шаблона: указатель без обратных кавычек наружу не выпускается"
# Каноническую строку `**`путь/`**` разбирает резолвер, и портится она не в бою, а правкой
# самого шаблона внутри helper. Проверяю тем же способом, каким мутационная оснастка портит
# helper: делаю копию со снятыми кавычками и требую отказ ДО подмены боевого файла.
use_home tmpldrift
DRIFT="$TMPROOT/drifted-write-bridge.sh"
awk '{ if (index($0,"sysadmin_root/") > 0 && index($0,"**") > 0 && index($0,"grep") == 0) print "**$sysadmin_root/**"; else print }' \
    "$WRITE_BRIDGE_LIB" > "$DRIFT"
if cmp -s "$WRITE_BRIDGE_LIB" "$DRIFT"; then
    bad "стенд: испортить шаблон не удалось — кейс ничего не проверяет"
else
    ok "стенд: в копии helper каноническая строка лишилась кавычек"
    out="$(bash -c 'source "$1"; write_bridge "$2"' _ "$DRIFT" "$BRAIN" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ]; check $? "дрейф шаблона: код возврата не ноль"
    if [ -f "$(bridge_file)" ]; then bad "дрейф шаблона: битый указатель всё-таки записан"; else ok "дрейф шаблона: боевой файл не появился"; fi
fi

echo "== 3п. Не смог измерить возраст замка — не трогает его"
# Круг 6: пустой вывод `find` при ОТКАЗЕ выглядел так же, как пустой вывод для старого
# замка, и отказ инструмента трактовался как «протух». Любое сомнение решается в пользу
# «замок живой».
use_home findbroken
mkdir -p "$HOME/.claude/agents/.sysadmin-bridge.lock"
touch -d '1 hour ago' "$HOME/.claude/agents/.sysadmin-bridge.lock" 2>/dev/null || true
find() { return 1; }
out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
unset -f find
rmdir "$HOME/.claude/agents/.sysadmin-bridge.lock" 2>/dev/null
[ "$rc" -ne 0 ]; check $? "отказ find: замок не отобран"
if printf '%s' "$out" | grep -qF "снят протухший замок"; then bad "отказ find: замок сочли протухшим"; else ok "отказ find: замок сочтён живым"; fi

echo "== 3к. Путь с обратной кавычкой отвергается"
# Такой путь ломает разбор указателя, а запись при этом «удаётся» — указатель молча
# становится нечитаемым (сверка 2026-08-20, круг 4).
use_home backtick
TICKDIR="$TMPROOT/bad\`name"; mkdir -p "$TICKDIR/.claude/skills" 2>/dev/null; : > "$TICKDIR/CLAUDE.md" 2>/dev/null
if [ -d "$TICKDIR" ]; then
    out="$(write_bridge "$TICKDIR" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ]; check $? "путь с обратной кавычкой: код возврата не ноль"
    printf '%s' "$out" | grep -qF "обратная кавычка"; check $? "путь с обратной кавычкой: причина названа верно"
    [ ! -e "$(bridge_file)" ]; check $? "путь с обратной кавычкой: файл не создан"
else
    skip "путь с обратной кавычкой" "файловая система не приняла такое имя"
fi

echo "== 3л. Одновременная запись не допускается"
# Замок держит критическую секцию «бэкап → подмена → проверка»: без него второй процесс
# восстанавливает старый указатель уже после того, как первый отчитался об успехе.
use_home lockbusy
mkdir -p "$HOME/.claude/agents/.sysadmin-bridge.lock"
out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
rmdir "$HOME/.claude/agents/.sysadmin-bridge.lock" 2>/dev/null
[ "$rc" -ne 0 ]; check $? "занятый замок: код возврата не ноль"
printf '%s' "$out" | grep -qF "уже пишет другой процесс"; check $? "занятый замок: причина названа верно"
if ls "$HOME/.claude/agents/".sysadmin-bridge.?????? >/dev/null 2>&1; then bad "занятый замок: временный файл остался"; else ok "занятый замок: временный файл убран"; fi

echo "== 3и. Маркер без CLAUDE.md корнем не считается"
# Указатель ведёт на CLAUDE.md. Каталог с маркером, но без ядра — успешная запись в пустоту.
use_home markeronly
MARKONLY="$TMPROOT/marker-only"; mkdir -p "$MARKONLY"; : > "$MARKONLY/.sysadmin-root"
out="$(write_bridge "$MARKONLY" 2>&1)"; rc=$?
[ "$rc" -ne 0 ]; check $? "маркер без CLAUDE.md отвергнут"
printf '%s' "$out" | grep -qF "указатель вёл бы в пустоту"; check $? "маркер без CLAUDE.md: причина названа верно"

echo "== 3з. Корень по маркеру .sysadmin-root принимается"
use_home marker
MARKED="$TMPROOT/marked-root"; mkdir -p "$MARKED"; : > "$MARKED/CLAUDE.md"; : > "$MARKED/.sysadmin-root"
write_bridge "$MARKED" >/dev/null 2>&1; check $? "каталог с маркером принят"

echo "== 3е. Родной виндовый путь принимается"
# На Windows вызывающий передаёт C:/… — отказ ломал бы установку. Проверяем только там,
# где такой путь вообще существует; на прочих системах кейс громко пропускается.
if command -v cygpath >/dev/null 2>&1; then
    use_home winpath
    WINBRAIN="$(cygpath -m "$BRAIN")"
    out="$(write_bridge "$WINBRAIN" 2>&1)"; rc=$?
    [ "$rc" -eq 0 ]; check $? "путь вида C:/… принят"
    grep -qF "$WINBRAIN/CLAUDE.md" "$(bridge_file)"; check $? "в указателе записан виндовый путь"
else
    skip "родной виндовый путь" "нет cygpath — система не Windows"
fi

echo "== 3б. Относительный путь отвергается, даже когда он существует"
# Без этого кейса проверку абсолютности подменяет проверка существования каталога:
# «relative/path» не существует, и тест зелен даже со снятой проверкой абсолютности.
use_home relexists
pushd "$TMPROOT" >/dev/null || exit 1
out="$(write_bridge "brain" 2>&1)"; rc=$?
popd >/dev/null || exit 1
[ "$rc" -ne 0 ]; check $? "существующий относительный путь: код возврата не ноль"
if printf '%s' "$out" | grep -qF "$SUCCESS_MARK"; then bad "существующий относительный путь: напечатан успех"; else ok "существующий относительный путь: без строки успеха"; fi
[ ! -e "$(bridge_file)" ]; check $? "существующий относительный путь: файл не создан"

echo "== 3в. Неудачная запись не разрушает уже стоящий указатель"
# Смысл постусловия на ВРЕМЕННОМ файле: битый результат не должен подменить рабочий.
# Моделируем не отказ записи (его ловит более ранняя проверка), а МОЛЧАЛИВО пустую запись —
# команда отчиталась нулём, а файла с содержимым нет. Именно этот случай отличает
# постусловие на временном файле от финального.
use_home keepold
write_bridge "$BRAIN" >/dev/null 2>&1
before="$(command cat "$(bridge_file)")"
cat() { return 0; }
out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
unset -f cat
[ "$rc" -ne 0 ]; check $? "код возврата не ноль"
[ "$(command cat "$(bridge_file)")" = "$before" ]; check $? "прежний указатель уцелел"
# Уцелел он должен потому, что замены НЕ БЫЛО, а не потому, что откатили после разрушения.
# Иначе постусловие на временном файле можно снять незаметно: восстановление из копии скроет
# разницу, а боевой указатель успеет побывать битым.
if printf '%s' "$out" | grep -qF "восстановлен из"; then bad "указатель был заменён и откачен, а не сохранён нетронутым"; else ok "замены не было вовсе"; fi

echo "== 3г. Подмена файла провалилась молча — helper обязан это заметить"
# Смысл ФИНАЛЬНОГО постусловия: mv может вернуть 0, не сделав работу.
use_home movefail
mv() { return 0; }
out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
unset -f mv
[ "$rc" -ne 0 ]; check $? "код возврата не ноль"
if printf '%s' "$out" | grep -qF "$SUCCESS_MARK"; then bad "напечатан успех при неподменённом файле"; else ok "строка успеха не напечатана"; fi

echo "== 4. Не задан HOME"
out="$(env -u HOME bash -c "source '$WRITE_BRIDGE_LIB'; write_bridge '$BRAIN'" 2>&1)"; rc=$?
[ "$rc" -ne 0 ]; check $? "код возврата не ноль"
if printf '%s' "$out" | grep -qF "$SUCCESS_MARK"; then bad "напечатан успех без HOME"; else ok "строка успеха не напечатана"; fi
# Отказ обязан назвать НАСТОЯЩУЮ причину. Без явной проверки $HOME отказ тоже случится —
# на попытке создать /.claude — но сообщение будет о каталоге, и оператор пойдёт чинить не то.
printf '%s' "$out" | grep -qF "не задан \$HOME"; check $? "причина отказа названа верно"

echo "== 5. Повторный вызов: бэкап прежнего и свежий путь"
use_home again
OLD="$TMPROOT/brain-old"; mkdir -p "$OLD"; : > "$OLD/CLAUDE.md"; : > "$OLD/.sysadmin-root"
write_bridge "$OLD"   >/dev/null 2>&1
write_bridge "$BRAIN" >/dev/null 2>&1; rc=$?
f="$(bridge_file)"
[ "$rc" -eq 0 ]; check $? "повторный вызов успешен"
grep -qF "$BRAIN/CLAUDE.md" "$f"; check $? "путь обновлён на свежий"
ls "$HOME/.claude/agents/"sysadmin.md.bak.* >/dev/null 2>&1; check $? "прежний указатель сохранён в бэкап"
if ls "$HOME/.claude/agents/".sysadmin-bridge.* >/dev/null 2>&1; then bad "временный файл остался"; else ok "временный файл не остался"; fi

echo "== 6. Хвостовой слэш не удваивается"
use_home slash
write_bridge "$BRAIN/" >/dev/null 2>&1
if grep -qF "$BRAIN//" "$(bridge_file)"; then bad "в пути появился двойной слэш"; else ok "путь нормализован"; fi

echo "== 7. Предупреждение про облачную папку — только когда уместно"
use_home cloud
CLOUD="$TMPROOT/Dropbox/sysadmin"; mkdir -p "$CLOUD"; : > "$CLOUD/CLAUDE.md"; : > "$CLOUD/.sysadmin-root"
write_bridge "$CLOUD" >/dev/null 2>&1
grep -qF "облачной синхронизации" "$(bridge_file)"; check $? "для облачной папки предупреждение есть"

use_home nocloud
write_bridge "$BRAIN" >/dev/null 2>&1
if grep -qF "облачной синхронизации" "$(bridge_file)"; then bad "предупреждение появилось без повода"; else ok "для обычной папки предупреждения нет"; fi


echo "== 8. Приманка во frontmatter: настоящее имя чужое, правильное — в теле"
# Диверсант круга 8. `name: impostor` во frontmatter плюс строка `name: sysadmin` ниже:
# все проверки, ищущие `^name: sysadmin$` по ВСЕМУ файлу, зелены, а subagent
# регистрируется под чужим именем — @sysadmin не отзывается.
use_home decoy
write_bridge "$BRAIN" >/dev/null 2>&1
DECOY="$(bridge_file)"
awk 'NR<=5 { sub(/^name: sysadmin$/, "name: impostor"); print; next }
     NR==6 { print "name: sysadmin"; print; next }
     { print }' "$DECOY" > "$DECOY.tmp" && command mv "$DECOY.tmp" "$DECOY"
awk 'NR==1{next} /^---$/{exit} /^name:/{print}' "$DECOY" | grep -qx 'name: impostor'
check $? "стенд: во frontmatter стоит чужое имя"
grep -qx 'name: sysadmin' "$DECOY"; check $? "стенд: приманка в теле на месте"
mv() { return 0; }
out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
unset -f mv
[ "$rc" -ne 0 ]; check $? "приманка во frontmatter: код возврата не ноль"
if printf '%s' "$out" | grep -qF "$SUCCESS_MARK"; then bad "принят указатель с чужим именем агента"; else ok "указатель с чужим именем не принят"; fi

echo "== 8б. Повторённый ключ во frontmatter"
# YAML берёт ПОСЛЕДНЕЕ значение ключа: `name: sysadmin` сверху не спасает от
# `name: impostor` ниже в том же блоке.
use_home dupkey
write_bridge "$BRAIN" >/dev/null 2>&1
DUP="$(bridge_file)"
awk 'NR==2 { print; print "name: impostor"; next } { print }' "$DUP" > "$DUP.tmp" && command mv "$DUP.tmp" "$DUP"
awk 'NR==1{next} /^---$/{exit} /^name:/{c++} END{exit !(c==2)}' "$DUP"
check $? "стенд: ключ name во frontmatter повторён"
mv() { return 0; }
out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
unset -f mv
[ "$rc" -ne 0 ]; check $? "повторённый ключ: код возврата не ноль"
if printf '%s' "$out" | grep -qF "$SUCCESS_MARK"; then bad "принят указатель с повторённым ключом"; else ok "указатель с повторённым ключом не принят"; fi

echo "== 9. Первая установка провалилась — активного битого указателя не остаётся"
# Круг 8: при провале финального постусловия копии прежнего файла нет (ставим впервые),
# и битый `sysadmin.md` оставался активным вопреки rc=1. Отсутствующий агент безопаснее
# невалидного: невалидный Claude молча пропустит, а оператор будет считать установленным.
use_home firstfail
# `mv`, который переносит файл, но портит цель: имитация записи, не прошедшей проверку.
mv() { command mv "$@" 2>/dev/null; local d; for d; do :; done; printf 'сломано\n' > "$d"; return 0; }
out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
unset -f mv
[ "$rc" -ne 0 ]; check $? "первая установка с битой целью: код возврата не ноль"
[ ! -e "$(bridge_file)" ]; check $? "активного sysadmin.md не осталось"
if ls "$(bridge_file)".failed.* >/dev/null 2>&1; then ok "битый файл сохранён под именем .failed.*"; else bad "битый файл исчез без следа"; fi
printf '%s' "$out" | grep -qF "битый указатель убран"; check $? "об уборке сказано вслух"

echo "== 10. Читатель отвергает деградировавший корень (нет ни маркера, ни скиллов)"
# Круг 8: читатель требовал только CLAUDE.md, писатель — CLAUDE.md плюс второй признак.
# Из-за расхождения любой чужой проект с CLAUDE.md по устаревшему пути грузился как мозг.
use_home degraded
DEGRADED="$TMPROOT/degraded-root"; mkdir -p "$DEGRADED/.claude/skills"; : > "$DEGRADED/CLAUDE.md"; : > "$DEGRADED/.sysadmin-root"
write_bridge "$DEGRADED" >/dev/null 2>&1
rm -f "$DEGRADED/.sysadmin-root"; rmdir "$DEGRADED/.claude/skills" "$DEGRADED/.claude" 2>/dev/null
[ -f "$DEGRADED/CLAUDE.md" ] && [ ! -d "$DEGRADED/.claude/skills" ]
check $? "стенд: остался только CLAUDE.md"
(
    # shellcheck source=/dev/null
    source "$FIND_CONFIG_LIB"
    locate_sysadmin_root >/dev/null 2>&1
    [ "$(cd "${SYSADMIN_ROOT:-/nowhere}" 2>/dev/null && pwd -P)" != "$(cd "$DEGRADED" && pwd -P)" ]
); check $? "читатель не принял каталог без второго признака корня"

echo "== 11. Корень файловой системы корнем мозга не считается"
# `${путь%/}` превращает `/` в пустую строку, а `C:/` — в `C:`. Без отдельной проверки отказ
# всё равно случится, но ПО ЛОЖНОЙ ПРИЧИНЕ («нет CLAUDE.md»), а при существующем
# `/CLAUDE.md` указатель запишется с неразбираемым путём. Проверяю именно причину отказа:
# сторож, чьё снятие ничего не меняет в наблюдаемом поведении, доказан не был бы (круг 8).
use_home fsroot
out="$(write_bridge "/" 2>&1)"; rc=$?
[ "$rc" -ne 0 ]; check $? "корень файловой системы отвергнут"
printf '%s' "$out" | grep -qF "корень файловой системы не может быть корнем мозга"
check $? "корень файловой системы: причина названа верно"
[ ! -e "$(bridge_file)" ]; check $? "корень файловой системы: файл не создан"

echo "== 12. Висячая символическая ссылка на месте указателя"
# `-f` висячую ссылку не видит: копировать нечего, и прежде она заменялась молча. Оператор
# при этом уверен, что указатель ведёт в другое место (сверка круга 8).
use_home dangling
mkdir -p "$HOME/.claude/agents"
if ln -s "$TMPROOT/nowhere-at-all" "$(bridge_file)" 2>/dev/null; then
    out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
    [ "$rc" -eq 0 ]; check $? "висячая ссылка: запись всё же прошла"
    printf '%s' "$out" | grep -qF "висячей символической ссылкой"; check $? "о висячей ссылке предупреждено"
else
    skip "висячая ссылка на месте указателя" "символические ссылки в этой среде не создаются"
fi

echo "== 13. Блочный скаляр в description: строка непустая, значение пустое"
# Диверсант круга 9. `description: |` проходит проверку `^description: .+`, но YAML читает
# такое описание как пустую строку: обязательный по контракту субагентов ключ фактически
# отсутствует, а все сторожа зелены.
use_home blockdesc
write_bridge "$BRAIN" >/dev/null 2>&1
BD="$(bridge_file)"
awk '{ if (NR<=5 && index($0,"description: ")==1) print "description: |"; else print }' "$BD" > "$BD.tmp" && command mv "$BD.tmp" "$BD"
grep -qx 'description: |' "$BD"; check $? "стенд: описание заменено блочным скаляром"
mv() { return 0; }
out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
unset -f mv
[ "$rc" -ne 0 ]; check $? "блочный скаляр в description: код возврата не ноль"
if printf '%s' "$out" | grep -qF "$SUCCESS_MARK"; then bad "принято описание, пустое после разбора YAML"; else ok "пустое после разбора описание не принято"; fi

echo "== 13б. Незакрытая последовательность в description рвёт разбор frontmatter"
use_home brokendesc
write_bridge "$BRAIN" >/dev/null 2>&1
BR2="$(bridge_file)"
awk '{ if (NR<=5 && index($0,"description: ")==1) print "description: [unterminated"; else print }' "$BR2" > "$BR2.tmp" && command mv "$BR2.tmp" "$BR2"
grep -qx 'description: \[unterminated' "$BR2"; check $? "стенд: описание стало незакрытой последовательностью"
mv() { return 0; }
out="$(write_bridge "$BRAIN" 2>&1)"; rc=$?
unset -f mv
[ "$rc" -ne 0 ]; check $? "невалидный YAML в description: код возврата не ноль"
if printf '%s' "$out" | grep -qF "$SUCCESS_MARK"; then bad "принят frontmatter, который YAML не разбирает"; else ok "неразбираемый frontmatter не принят"; fi

echo "== 14. Корень перестал быть корнем во время записи"
# Между входной проверкой и постусловием каталог может перестать быть корнем мозга. Тогда
# указатель ведёт туда, откуда читатель его уже не примет, — а запись «удалась» (круг 9).
use_home vanishing
VANISH="$TMPROOT/vanishing-root"; mkdir -p "$VANISH/.claude/skills"; : > "$VANISH/CLAUDE.md"; : > "$VANISH/.sysadmin-root"
# `mv` переносит файл штатно и заодно разбирает корень — имитация гонки без гонки.
mv() { command mv "$@" 2>/dev/null; rm -f "$VANISH/.sysadmin-root"; rmdir "$VANISH/.claude/skills" "$VANISH/.claude" 2>/dev/null; return 0; }
out="$(write_bridge "$VANISH" 2>&1)"; rc=$?
unset -f mv
[ "$rc" -ne 0 ]; check $? "исчезнувший корень: код возврата не ноль"
printf '%s' "$out" | grep -qF "перестал быть корнем мозга"; check $? "исчезнувший корень: причина названа верно"
if printf '%s' "$out" | grep -qF "$SUCCESS_MARK"; then bad "напечатан успех при исчезнувшем корне"; else ok "успех при исчезнувшем корне не напечатан"; fi

echo "== 15. Самопроверка установки не зеленеет на деградировавшем корне"
# Круг 9: `self_test_setup` печатала «bridge-файл на месте» для каталога, который читатель
# указателя уже отвергает. Ложно-зелёный вердикт установки — худший класс отказа: оператор
# уходит работать с агентом, которого нет.
if [ -f "$ROOT/.claude/skills/_lib/self-test-setup.sh" ] && [ -f "$ROOT/agent-config.json" ]; then
    use_home selftest
    DEG="$TMPROOT/degraded-selftest"; mkdir -p "$DEG/.claude/skills"; : > "$DEG/CLAUDE.md"; : > "$DEG/.sysadmin-root"
    write_bridge "$DEG" >/dev/null 2>&1
    cp "$ROOT/agent-config.json" "$DEG/agent-config.json" 2>/dev/null
    rm -f "$DEG/.sysadmin-root"; rmdir "$DEG/.claude/skills" "$DEG/.claude" 2>/dev/null
    st_out="$(HOME="$HOME" bash -c '
        # shellcheck source=/dev/null
        source "$1"; self_test_setup "$2/agent-config.json" "$2" 2>&1' _ "$SELF_TEST_LIB" "$DEG")"; st_rc=$?
    [ "$st_rc" -ne 0 ]; check $? "самопроверка на деградировавшем корне: код возврата не ноль"
    if printf '%s' "$st_out" | grep -qF "Самопроверка пройдена"; then bad "самопроверка объявила установку исправной"; else ok "самопроверка не объявила установку исправной"; fi
    printf '%s' "$st_out" | grep -qF "не корень мозга"; check $? "самопроверка назвала причину верно"
else
    skip "самопроверка установки на деградировавшем корне" "нет self-test-setup.sh или agent-config.json"
fi
echo
echo "────────────────────────────────────────────────────"
if [ "$PASS" -eq 0 ]; then
    echo "FAIL — не выполнено ни одной проверки, набор считается сломанным"
    exit 1
fi
if [ "$FAIL" -eq 0 ]; then
    echo "PASS — прошло проверок: $PASS, пропущено: $SKIP, падений: 0"
    exit 0
fi
echo "FAIL — падений: $FAIL, прошло: $PASS, пропущено: $SKIP"
exit 1
