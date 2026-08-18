#!/usr/bin/env bash
# write-bridge.sh — единый источник создания выездного bridge-указателя
# ~/.claude/agents/sysadmin.md (ADR-0015).
#
# Зачем: чтобы агента можно было звать @sysadmin из ЛЮБОЙ папки, в ~/.claude/agents/
# кладётся тонкий указатель с абсолютным путём к sysadmin/. Его читают:
#   • find-config.sh  — достаёт из него $SYSADMIN_ROOT (locate_sysadmin_root);
#   • self-test-setup.sh — проверяет, что файл на месте;
#   • сам агент при вызове @sysadmin — идёт по пути за ядром CLAUDE.md.
# Под 2.0 (ADR-0015) ядро персоны — в CLAUDE.md, поэтому bridge ведёт туда.
#
# Это ЕДИНСТВЕННОЕ место, где bridge создаётся: и /sysadmin-init (Шаг 10.4), и ручная
# установка (INSTALL.md, Шаг 7) зовут эту функцию, а не пишут свой heredoc. Два генератора
# одного файла расходятся молча — так и вышло до 2026-08-18, когда INSTALL.md писал
# указатель с другим frontmatter.
#
# Отказы объявляются громко (урок 2026-08-18): раньше строка успеха и rc=0 печатались
# безусловно — при недоступной для записи цели функция рапортовала «записан», оставляя файл
# нулевого размера. Теперь успех объявляется только после постусловия, а запись идёт через
# временный файл с подменой, чтобы обрыв не оставил битый указатель.
#
# Использование (source + вызов функции):
#   source "$LIB/write-bridge.sh"
#   write_bridge "$SYSADMIN_ROOT"
#
# Возврат:
#   0 — bridge записан И проверен постусловием (существует, непустой, содержит путь к ядру).
#   1 — bridge НЕ записан: пустой/относительный/несуществующий путь, не задан $HOME, нет
#       каталога ~/.claude/agents, отказ записи или непрошедшее постусловие. Вызывающий
#       обязан считать это неуспехом и не рапортовать оператору «готово».

write_bridge() {
    local sysadmin_root="${1:-}"

    if [ -z "$sysadmin_root" ]; then
        echo "write_bridge: не передан путь к корню sysadmin/ (\$1)" >&2
        return 1
    fi
    # Путь уезжает в файл и читается с ЛЮБОЙ рабочей папки — относительный там бессмыслен.
    case "$sysadmin_root" in
        /*) ;;
        *)
            echo "write_bridge: путь к корню должен быть абсолютным, получено: $sysadmin_root" >&2
            return 1
            ;;
    esac
    if [ ! -d "$sysadmin_root" ]; then
        echo "write_bridge: каталог не существует: $sysadmin_root" >&2
        return 1
    fi
    sysadmin_root="${sysadmin_root%/}"

    if [ -z "${HOME:-}" ]; then
        echo "write_bridge: не задан \$HOME — некуда класть bridge." >&2
        return 1
    fi

    local bridge_dir="$HOME/.claude/agents"
    local bridge="$bridge_dir/sysadmin.md"
    local tmp="$bridge.tmp.$$"

    if ! mkdir -p "$bridge_dir" 2>/dev/null; then
        echo "WARN: не создать $bridge_dir — bridge пропускаю, @sysadmin из чужих папок будет недоступен." >&2
        return 1
    fi

    # Репозиторий в облачной синхронизации — файлы расходятся между машинами (перенесено
    # из INSTALL.md Шаг 7, чтобы предупреждение не потерялось вместе со вторым генератором).
    local cloud_note=""
    case "$sysadmin_root" in
        *Yandex.Disk*|*Dropbox*|*iCloud*|*OneDrive*|*Google?Drive*|*Mega*)
            cloud_note="

> Внимание: мозг лежит в облачной синхронизации. При одновременной работе с двух машин
> файлы расходятся — источником правды считай git, а не содержимое папки."
            ;;
    esac

    if ! cat > "$tmp" <<EOF
---
name: sysadmin
description: Агент-сисадмин персональной инфраструктуры (выездной указатель). Полная персона — в CLAUDE.md репозитория sysadmin/.
model: inherit
---

# Sysadmin Agent — выездной указатель (bridge, ADR-0015)

Ядро персоны (ценности, конституция, три зоны, протоколы) живёт в \`CLAUDE.md\` репозитория
sysadmin/ по пути:

**\`$sysadmin_root/\`**

При вызове \`@sysadmin\` из любой папки: прочитай \`$sysadmin_root/CLAUDE.md\` — это ядро;
детальные протоколы — в \`$sysadmin_root/.claude/agents/references/\`. Инструменты не
ограничиваю (наследую от родителя, включая Skill для запуска скиллов).

**Скиллы репозитория указатель не переносит.** Он даёт персону и путь к ядру; сами скиллы
(\`/health-check\`, \`/deploy-service\`, …) остаются проектными и вызываются, когда открыта
папка \`$sysadmin_root/\`. Из чужой папки доступны персона и чтение файлов, но не вызов
скилла как команды.$cloud_note
EOF
    then
        rm -f "$tmp"
        echo "write_bridge: не удалось записать временный файл $tmp" >&2
        return 1
    fi

    # Постусловие на временном файле — ДО того, как он станет боевым.
    if [ ! -s "$tmp" ] || ! grep -qF "$sysadmin_root/CLAUDE.md" "$tmp"; then
        rm -f "$tmp"
        echo "write_bridge: временный файл пуст или не содержит путь к ядру — bridge не заменён." >&2
        return 1
    fi

    # Бэкап прежнего указателя (перенесено из INSTALL.md Шаг 7).
    if [ -f "$bridge" ]; then
        cp -p "$bridge" "$bridge.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    fi

    if ! mv -f "$tmp" "$bridge" 2>/dev/null; then
        rm -f "$tmp"
        echo "write_bridge: не удалось заменить $bridge" >&2
        return 1
    fi

    # Финальное постусловие — уже на цели.
    if [ ! -s "$bridge" ] || ! grep -qF "$sysadmin_root/CLAUDE.md" "$bridge"; then
        echo "write_bridge: после записи $bridge не проходит проверку — считаю неудачей." >&2
        return 1
    fi

    echo "✅ bridge-указатель записан: $bridge (путь к мозгу: $sysadmin_root)"
    return 0
}
