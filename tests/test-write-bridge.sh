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
[ "$rc" -eq 0 ]; check $? "код возврата 0"
[ -s "$f" ]; check $? "файл создан и непустой"
grep -qF "$BRAIN/CLAUDE.md" "$f"; check $? "внутри путь к ядру"
grep -qE '^name: sysadmin$' "$f"; check $? "frontmatter содержит name: sysadmin"
# Без description файл не является определением агента: поле обязательно по контракту
# Claude Code, а его пропажа не ломает ни одного другого теста (диверсант сверки 2026-08-20).
grep -qE '^description: .+' "$f"; check $? "frontmatter содержит непустой description"
grep -qE '^model: ' "$f"; check $? "frontmatter содержит model"
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
if printf '%s' "$out" | grep -qF "временный файл неполон"; then bad "к отказу приписана вторая, ложная причина"; else ok "причина отказа ровно одна"; fi
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
    source "$ROOT/.claude/skills/_lib/find-config.sh"
    locate_sysadmin_root >/dev/null 2>&1
    [ "$(cd "$SYSADMIN_ROOT" 2>/dev/null && pwd -P)" = "$(cd "$ODDNAME" && pwd -P)" ]
); check $? "настоящий locate_sysadmin_root вернул тот же каталог"

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
