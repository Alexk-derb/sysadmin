# Backlog находок /retro

Обезличенные находки про агента из пострефлексии сессий. Закрываются правкой в `/dev`.
Формат строки: `дата | severity | фронт | находка | предложение | статус`.

Severity: **MUST** (критично) / **NEVER** (повторяющийся класс, закрепить рефлексом) /
**MAY** (улучшение, копить пачкой). Статус: `open` / `done` / `wontfix`.

| Дата | Severity | Фронт | Находка | Предложение | Статус |
|------|----------|-------|---------|-------------|--------|
| 2026-06-14 | MUST | скиллы | `inventory-scan`: drift-grep `container_name:` не совпадает с табличным форматом `services.md`, который скилл сам же генерит → ложный drift на все контейнеры | сверять `containers-inspect.json` снимок-к-снимку или парсить таблицу; eval «табличный services.md не даёт drift» | open |
| 2026-06-14 | MUST | скиллы | `inventory-scan`: `description` обещает TLS-expiry через openssl, но `dump-snapshot.sh` на acme.sh-хостах openssl не вызывает (только `ls -la`) | прогонять `openssl x509 -enddate` по `~/.acme.sh/*/fullchain.cer`; либо честно сузить scope в description | open |
| 2026-06-14 | NEVER | скиллы/архитектура | `dump-snapshot.sh` выводит `HOST_DIR` из SSH-аргумента, не из `infra-config.json` `servers[].alias` → риск раздвоить inventory при несовпадении алиаса и имени хоста | резолвить `HOST_DIR` из config (`find-config.sh`), SSH-target только для подключения; guard при несовпадении. **ADR-кандидат** | open |
| 2026-06-14 | NEVER | скиллы | `inventory-scan` verify: порог «размер снимка ≥1 МБ» завалил бы валидный малый снимок (реально 324 КБ) | проверять непустоту ключевых файлов + парсинг `containers-inspect.json`, не суммарный размер; согласовать канон числа файлов (15/16/17) | open |
| 2026-06-14 | MAY | скиллы | `inventory-scan`: drift по томам шумит (волатильный `docker system df`, относительные даты) + `automations.md` не создаётся при наличии автоматизаций | volumes сравнивать по именам `docker volume ls`; enforcement «автоматизации есть → файл обязан быть» в Шаг 7 | open |
| 2026-06-14 | MAY | скиллы/UX | снимок не отдаёт готовых health-flags (swap%/disk%/exited/OOM-137/security-апдейты) — агент грепает вручную | добавить `health-flags.txt` в `dump-snapshot.sh`, Шаг 7 презентует готовое | open |
