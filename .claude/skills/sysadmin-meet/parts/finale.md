**Финальное напутствие при выборе «запустить /sysadmin-init».**

Перед выводом этого текста — обнови onboarding-флаг в `agent-config.json` оператора
(мозг агента), если конфиг уже существует (повторное прохождение знакомства, или
пользователь сначала запустил /sysadmin-init без знакомства, теперь возвращается).
Ставишь `meta.onboarding_completed: true`. Это останавливает напоминания агента.

Конфиг мозга живёт в **известном месте** — корне репо `sysadmin/` (ADR-0013), его
не нужно искать перебором. Резолвишь корень `sysadmin/` так же, как Cold Start
(см. `references/cold-start.md`): `agent-config.json` рядом с `CLAUDE.md` и
`.claude/`. На совместимость со старыми установками — fallback на единый
`sysadmin-config.json` в `infra/`, если `agent-config.json` ещё нет.

```bash
# Конфиг мозга — в корне sysadmin/ (известное место, без перебора)
CONFIG_PATH=""
for candidate in \
    "./agent-config.json" \
    "../sysadmin/agent-config.json" \
    "$HOME/sysadmin/agent-config.json"; do
    if [ -f "$candidate" ]; then
        CONFIG_PATH="$candidate"
        break
    fi
done

# Fallback: старая установка с единым sysadmin-config.json (до ADR-0013)
if [ -z "$CONFIG_PATH" ]; then
    for candidate in \
        "./sysadmin-config.json" \
        "../infra/sysadmin-config.json" \
        "$HOME/infra/sysadmin-config.json"; do
        if [ -f "$candidate" ]; then
            CONFIG_PATH="$candidate"
            break
        fi
    done
fi

if [ -n "$CONFIG_PATH" ]; then
    if jq -e '.meta' "$CONFIG_PATH" >/dev/null 2>&1; then
        # Поле meta уже есть — обновляю
        tmp=$(mktemp) && jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '.meta.onboarding_completed = true | .meta.onboarding_completed_at = $ts' \
            "$CONFIG_PATH" > "$tmp" && mv "$tmp" "$CONFIG_PATH"
    else
        # Конфиг без meta — создаю блок целиком
        tmp=$(mktemp) && jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '. + {meta: {onboarding_completed: true, onboarding_completed_at: $ts}}' \
            "$CONFIG_PATH" > "$tmp" && mv "$tmp" "$CONFIG_PATH"
    fi
    echo "Знакомство засчитано — агент больше не будет напоминать про /sysadmin-meet."
fi
```

Если конфига **нет** (типичный сценарий: новый пользователь, прошёл знакомство первым,
сейчас идёт на /sysadmin-init) — флаг поставит сам скилл /sysadmin-init после
создания конфигов. Здесь ничего делать не нужно — просто выводи напутствие.

---

**Текст напутствия (показать оператору как есть):**

> Отлично. Сейчас знакомство завершается, и ты переходишь к технической настройке.
>
> **Перед запуском проверь, где открыт Claude Code.** Рекомендуемая рабочая папка —
> **родительская**, та, где соседями лежат `sysadmin/` (мой мозг) и `infra/`
> (твои данные — её создаст `/sysadmin-init`, если её ещё нет). Так у тебя в
> проекте видны оба репо сразу, и я найду конфиг автоматически. Открывать
> Claude Code **внутри** `sysadmin/` или `infra/` тоже можно — я подхвачу
> конфиг по алгоритму поиска, — но удобнее всего из родительской.
>
> **Короткий чек перед настройкой** (подробно — во вводной Части 0): стоит ли `jq`
> (`/sysadmin-init` проверит и подскажет); заходишь ли `ssh <твой-сервер>` из терминала
> (агент работает через твой SSH-доступ); для алертов — бот от **@BotFather**. **Сервера
> ещё нет?** Не блокер: заведи профиль сейчас, сервер впишешь позже через
> `/sysadmin-init --reconfigure`.
>
> Просто напиши в следующем сообщении:
>
> ```
> /sysadmin-init
> ```
>
> Скилл задаст тебе 6 вопросов про твой проект, всё объяснит по пути, и в конце
> создаст два конфига: `agent-config.json` (мозг агента, в `sysadmin/`) и
> `infra-config.json` (карта инфры, в папке `infra/`). Это займёт около 5 минут.
>
> После этого ты сможешь работать с агентом полноценно. Напиши `@sysadmin привет,
> познакомься с моим сервером` — и он сам разберётся с чего начать.
>
> Удачи. И помни — этот скилл `/sysadmin-meet` всегда здесь, можешь перезапустить
> в любой момент, если что-то забудешь.
