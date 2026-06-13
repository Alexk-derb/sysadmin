#!/usr/bin/env bash
# collect-diagnostics.sh — обезличенный диагностический блок для баг-репорта.
#
# Зачем: вайбкодеру трудно вручную собрать «версию ОС, shell, jq, коммит». Этот скрипт
# собирает всё сам и печатает готовый блок — вставляешь в issue на
# https://github.com/vefmvai/sysadmin/issues. Можно и попросить агента: «собери
# диагностику для баг-репорта» — он запустит этот скрипт.
#
# БЕЗОПАСНОСТЬ: собирает ТОЛЬКО версии и статусы — НЕ секреты, НЕ токены, НЕ IP, НЕ
# содержимое конфигов. Вывод безопасно вставлять в публичный issue.
#
# Запуск из корня репо (или откуда угодно — сам найдёт корень):
#   bash scripts/collect-diagnostics.sh

set -u
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

echo "### Диагностика sysadmin-агента (обезличено)"
echo '```'
echo "VERSION:        $(cat "$ROOT/VERSION" 2>/dev/null || echo '?')"
echo "OS:             $(uname -srm 2>/dev/null || echo '?')"
echo "shell:          ${BASH_VERSION:-$(bash --version 2>/dev/null | head -1)}"
echo "jq:             $(jq --version 2>/dev/null || echo 'НЕ установлен')"
echo "python3:        $(python3 --version 2>/dev/null || echo 'нет (валидатор знаний пропускается)')"
echo "git:            $(git --version 2>/dev/null || echo '?')"
echo "commit:         $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
echo "tag/описание:   $(git -C "$ROOT" describe --tags --always 2>/dev/null || echo '?')"
echo "core.hooksPath: $(git -C "$ROOT" config core.hooksPath 2>/dev/null || echo 'не задан')"
if [ -f "$ROOT/.claude/skills/_lib/check-persona-sync.sh" ]; then
    echo "persona-linter: $(bash "$ROOT/.claude/skills/_lib/check-persona-sync.sh" >/dev/null 2>&1 && echo PASS || echo FAIL)"
fi
echo '```'
echo "_(собраны только версии/статусы — секретов, токенов и IP здесь нет)_"
