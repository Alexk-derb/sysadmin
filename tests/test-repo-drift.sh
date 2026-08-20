#!/usr/bin/env bash
# tests/test-repo-drift.sh — тесты проверки расхождений scripts/check-repo-drift.sh.
#
# Зачем: скрипт нужен ровно там, где ошибиться дороже всего — он говорит оператору, можно ли
# доверять локальной копии inventory. Две его лжи опасны по-разному:
#   • сказать «в ногу», когда копия отстала, — агент пойдёт работать по устаревшей карте;
#   • молча слить расхождение — исчезнет чужая работа.
# Поэтому набор проверяет не только распознавание состояний, но и обещание «ничего не меняю».
#
# Фикстуры настоящие: локальный bare-репозиторий как remote и два клона.
#
# Запуск:  bash tests/test-repo-drift.sh
# Код возврата: 0 — все прошли, 1 — есть падения.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIFT_SH="${DRIFT_SH:-$ROOT/scripts/check-repo-drift.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

G() { git -c user.name=test -c user.email=test@example.com -C "$1" "${@:2}"; }
run_drift() { bash "$DRIFT_SH" "$1" 2>&1; }

# --- фикстуры -------------------------------------------------------------
git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/a"
echo "первая строка" > "$TMP/a/inventory.md"
G "$TMP/a" add inventory.md
G "$TMP/a" commit -q -m "первый коммит"
G "$TMP/a" push -q origin HEAD:refs/heads/master
G "$TMP/a" branch -q --set-upstream-to=origin/master 2>/dev/null
git clone -q "$TMP/origin.git" "$TMP/b"

echo "== 1. Копия в ногу и чистая"
out="$(run_drift "$TMP/a")"; rc=$?
printf '%s' "$out" | grep -qF "в ногу"; check $? "состояние «в ногу»"
printf '%s' "$out" | grep -qF "чисто"; check $? "правок нет"
[ "$rc" -eq 0 ]; check $? "код возврата 0"

echo "== 2. Есть неотданный коммит"
echo "вторая строка" >> "$TMP/a/inventory.md"
G "$TMP/a" commit -q -am "второй коммит"
out="$(run_drift "$TMP/a")"; rc=$?
printf '%s' "$out" | grep -qF "впереди 1"; check $? "распознано «впереди 1»"
[ "$rc" -ne 0 ]; check $? "код возврата ненулевой"

echo "== 3. Копия отстала"
G "$TMP/a" push -q origin master
out="$(run_drift "$TMP/b")"; rc=$?
printf '%s' "$out" | grep -qF "отстал 1"; check $? "распознано «отстал 1»"
[ "$rc" -ne 0 ]; check $? "код возврата ненулевой"

echo "== 4. Проверка НИЧЕГО не сливает и не меняет копию"
head_before="$(G "$TMP/b" rev-parse HEAD)"
run_drift "$TMP/b" >/dev/null 2>&1
head_after="$(G "$TMP/b" rev-parse HEAD)"
[ "$head_before" = "$head_after" ]; check $? "HEAD отставшей копии не тронут"
[ -z "$(G "$TMP/b" status --porcelain)" ]; check $? "рабочее дерево не тронуто"

echo "== 5. Несохранённые правки видны"
echo "черновик" > "$TMP/b/черновик.md"
out="$(run_drift "$TMP/b")"
printf '%s' "$out" | grep -qF "несохранённых: 1"; check $? "посчитан один несохранённый файл"
rm -f "$TMP/b/черновик.md"

echo "== 6. Недостижимый remote — отказ громкий, а не «в ногу»"
# Самый опасный случай: сеть недоступна, состояние выяснить нельзя. Скрипт обязан сказать
# «неизвестно», иначе оператор примет вчерашние данные за сегодняшние.
G "$TMP/b" remote set-url origin "$TMP/no-such-repo.git"
out="$(run_drift "$TMP/b")"; rc=$?
printf '%s' "$out" | grep -qF "состояние неизвестно"; check $? "состояние помечено неизвестным"
if printf '%s' "$out" | grep -qF "в ногу"; then bad "напечатано «в ногу» при недостижимом remote"; else ok "«в ногу» не печатается"; fi
[ "$rc" -ne 0 ]; check $? "код возврата ненулевой"

echo "== 7. Ветка без upstream"
git init -q "$TMP/solo"
echo x > "$TMP/solo/f.md"
G "$TMP/solo" add f.md
G "$TMP/solo" commit -q -m "один"
out="$(run_drift "$TMP/solo")"; rc=$?
printf '%s' "$out" | grep -qF "нет upstream"; check $? "распознано отсутствие upstream"
[ "$rc" -ne 0 ]; check $? "код возврата ненулевой"

echo "== 8. Не репозиторий и отсутствующий каталог"
mkdir -p "$TMP/plain"
out="$(run_drift "$TMP/plain")"; rc=$?
printf '%s' "$out" | grep -qF "не git-репозиторий"; check $? "обычный каталог распознан"
[ "$rc" -ne 0 ]; check $? "код возврата ненулевой"

out="$(run_drift "$TMP/no-such-dir")"; rc=$?
printf '%s' "$out" | grep -qF "каталога нет"; check $? "отсутствующий каталог распознан"
[ "$rc" -ne 0 ]; check $? "код возврата ненулевой"

echo
echo "────────────────────────────────────────────────────"
if [ "$PASS" -eq 0 ]; then
    echo "FAIL — не выполнено ни одной проверки, набор сломан"; exit 1
fi
if [ "$FAIL" -eq 0 ]; then
    echo "PASS — прошло проверок: $PASS, падений: 0"; exit 0
fi
echo "FAIL — падений: $FAIL, прошло: $PASS"
exit 1
