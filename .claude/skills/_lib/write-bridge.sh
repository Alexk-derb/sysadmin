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
# Это ЕДИНСТВЕННОЕ место, где bridge создаётся (раньше heredoc жил в
# sysadmin-init/SKILL.md Шаг 10.4 — вынесено в общий _lib, чтобы не плодить копии).
#
# Использование (source + вызов функции):
#   source "$LIB/write-bridge.sh"
#   write_bridge "$SYSADMIN_ROOT"
#
# Возврат:
#   0 — bridge записан (или обновлён свежим путём).
#   1 — не удалось создать каталог ~/.claude/agents (bridge пропущен; @sysadmin
#       из чужих папок будет недоступен, но это не фатально для текущей сессии).

write_bridge() {
    local sysadmin_root="$1"
    if [ -z "$sysadmin_root" ]; then
        echo "write_bridge: не передан путь к корню sysadmin/ (\$1)" >&2
        return 1
    fi

    local bridge_dir="$HOME/.claude/agents"
    local bridge="$bridge_dir/sysadmin.md"

    if ! mkdir -p "$bridge_dir" 2>/dev/null; then
        echo "WARN: не создать $bridge_dir — bridge пропускаю, @sysadmin из чужих папок будет недоступен."
        return 1
    fi

    cat > "$bridge" <<EOF
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
EOF

    echo "✅ bridge-указатель записан: $bridge (путь к мозгу: $sysadmin_root)"
    return 0
}
