---
knowledge_domain: vpn
layer: reference
last_researched: 2026-06-15
ttl_days: 60
sources_checked:
  - https://www.happ.su/main/ru/dev-docs/app-management.md
  - https://www.happ.su/main/ru/dev-docs/examples-of-links-and-parameters.md
  - https://www.happ.su/main/ru/dev-docs/routing.md
  - https://xtls.github.io/ru/config/observatory.html
  - https://xtls.github.io/ru/config/routing.html
  - "эмпирика на устройстве (iOS Happ) + боевая выгрузка NurVPN, 2026-06-14/15"
---

# Формат мульти-кнопочной подписки Happ и управление приложением

> Слой `_reference` (устройство механизма, меняется кварталами). TTL 60 дней.
> Документ родился из боевой задачи «гибкая маршрутизация через Happ» (2026-06-14/15):
> построение своей подписки OpenGate с кнопками-политиками поверх NurVPN.
> Дополняет `client-apps.md` (карта клиентов) и `subscription-mirroring.md` (зеркалирование).

## 1. Главный вывод

> 🎯 **Подписка Happ может отдавать не плоский список серверов, а JSON-массив готовых
> xray-конфигов — и тогда каждый элемент массива становится отдельной кнопкой** в
> приложении. Это позволяет раздать пользователю **кнопки-политики** (балансир США,
> балансир «весь мир», обход, реверс-РФ), а не только список серверов. Логика
> (balancer, observatory, routing) полностью внутри каждого конфига — Happ передаёт
> его в Xray-ядро 1:1 и свои правила не накладывает.
>
> Это подтверждено практикой дважды: так делает **сам NurVPN** (перешёл на этот формат
> ~июнь 2026, отдаёт 71 конфиг-кнопку), и так собрана наша **OpenGate** (реестр→генератор, §9).

## 2. Wire-формат: JSON-массив конфигов = кнопки

- Тело подписки — **сырой JSON-массив** `[ {конфиг1}, {конфиг2}, ... ]`. Дока дословно:
  «сама JSON-структура, а **не** base64-обёртка». `Content-Type: application/json`
  (на практике Happ принимает и `text/plain`; ставить `application/json`).
- **Один элемент массива = одна кнопка.** Имя кнопки — поле `remarks`; подпись под
  именем — `meta.serverDescription` (или в URI-форме `#Name?serverDescription=<base64>`).
- Структура элемента (как у эталона NurVPN): `dns / routing / inbounds / outbounds / remarks / meta`.
- **`inbounds` обязателен в конфиге** — Happ его НЕ подставляет, передаёт JSON «как есть».
  Рабочий минимум (из эталона NurVPN): socks `127.0.0.1:10808` + http `127.0.0.1:10809`,
  у обоих `sniffing.enabled=true`, `destOverride: [http,tls,quic]`.
- При JSON-подписке Happ **не накладывает свой routing-профиль** на трафик — дословно:
  «правила берутся исключительно из JSON-конфигурации». Профиль остаётся только для
  гео-файлов/нарезки/DNS (§4).

Пример скелета одной кнопки-балансира (теги-префиксы — главный рычаг, см. §5):
```json
{
  "remarks": "🤖 USA",
  "meta": { "serverDescription": "нейросети · авто-быстрейший US" },
  "dns": { "servers": ["https://dns.google/dns-query"] },
  "inbounds": [ {"tag":"socks","listen":"127.0.0.1","port":10808,"protocol":"socks",
                 "sniffing":{"enabled":true,"destOverride":["http","tls","quic"]},"settings":{"udp":true}},
                {"tag":"http","listen":"127.0.0.1","port":10809,"protocol":"http",
                 "sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}} ],
  "outbounds": [ {"tag":"us-1","protocol":"vless", "...": "..."},
                 {"tag":"us-2","protocol":"vless", "...": "..."},
                 {"tag":"direct","protocol":"freedom"}, {"tag":"block","protocol":"blackhole"} ],
  "observatory": { "subjectSelector":["us-"], "probeUrl":"https://www.gstatic.com/generate_204",
                   "probeInterval":"10m", "enableConcurrency": true },
  "routing": { "domainStrategy":"IPIfNonMatch",
    "balancers":[ {"tag":"auto","selector":["us-"],"strategy":{"type":"leastPing"}} ],
    "rules":[ {"type":"field","ip":["geoip:private"],"outboundTag":"direct"},
              {"type":"field","domain":["geosite:category-ru"],"outboundTag":"direct"},
              {"type":"field","ip":["geoip:ru"],"outboundTag":"direct"},
              {"type":"field","network":"tcp,udp","balancerTag":"auto"} ] }
}
```

## 2.1 Полная структура VLESS-outbound внутри кнопки (значения замаскированы)

Самая нагруженная часть — proxy-outbound (Reality). Структура (эталон NurVPN):
```json
{ "tag": "us-1", "protocol": "vless",
  "settings": { "vnext": [ {
    "address": "<host>", "port": 443,
    "users": [ { "id": "<uuid>", "encryption": "none", "flow": "" } ] } ] },
  "streamSettings": {
    "network": "tcp",                         // или "grpc" → serviceName в grpcSettings
    "security": "reality",
    "realitySettings": { "serverName": "<sni>", "publicKey": "<pbk>",
                         "shortId": "<sid>", "fingerprint": "random" } } }
```
- Служебные: `{"tag":"direct","protocol":"freedom"}`, `{"tag":"block","protocol":"blackhole"}`.
- Отпечаток сервера для дедупа/UPSERT в реестре — `source|host|port|sni|serviceName|network`,
  **без `shortId`** (Reality short ID дрожит каждый запрос провайдера).

## 2.2 Четыре типа кнопок-политик (различие — в routing)

Все кнопки используют общий блок `inbounds` (§2) и `outbounds` = серверы своей роли +
`direct` + `block`. Различаются только `balancers.selector` и `rules`:

| Кнопка | selector | routing-логика |
|---|---|---|
| **USA** (нейросети) | `["us-"]` | приватка→direct, ads→block, **РФ→direct**, остальное→balancer. `observatory` 10м (стабильный US-выход). |
| **Мир** (общий) | `["wd-","us-"]` (всё кроме bypass/ru) | то же; остальное→balancer по всему миру. Межстрановой — для веба, не для аккаунтов. |
| **WL** (обход БС) | `["bp-"]` (только Обход/LTE, дорогие ×N) | то же; пул только маскировочных узлов. Множитель ×N — в `meta.serverDescription`. |
| **RU** (reverse) | — (без балансира, один outbound `ru-1`) | **инверсия:** `geosite:category-ru`+`geoip:ru`→`ru-1` (через РФ-сервер); приватка→direct; **всё остальное→direct** (мимо VPN). Для «я за границей, нужны РФ-сайты». |

> Префикс тега = роль (`us-N`, `wd-N`, `bp-N`, `ru-1`). `selector` в Xray ловит по префиксу,
> поэтому именование тегов — главный рычаг состава пула (см. §5).

## 3. Управляющие HTTP-заголовки подписки (app-management)

Провайдер настраивает **внешний вид и поведение** приложения заголовками ответа подписки.
Это объясняет, почему после чужой подписки у пользователя «чернеет интерфейс» или «пинг
показывается галочкой». На своей подписке — задаём как нужно (или НЕ задаём ненужное).

| Заголовок | Значения | Что делает |
|---|---|---|
| `profile-title` | строка ≤25 | название профиля подписки |
| `routing` | `happ://routing/onadd/{base64}` | доставка routing-профиля заголовком (§4) |
| `routing-enable` | `0`/`false` | **глобально отключает** пользовательскую маршрутизацию (⚠ провайдерский стоп-сигнал) |
| `ping-type` | `proxy`, `proxy-head`, `tcp`, `icmp` | способ замера пинга (§6) |
| `check-url-via-proxy` | URL | цель для proxy-пинга |
| `ping-result` | `time`, `icon` | формат пинга: миллисекунды или иконка |
| `subscriptions-sort-type` | `without`, `ping`, `alphabet` | сортировка серверов в списке |
| `subscription-pin` | `true`/`1` | закрепить подписку сверху |
| `color-profile` | JSON/base64 | тема/цвета интерфейса (iOS) |
| `subscription-autoconnect` (+`-type` `lastused`/`lowestdelay`/`random`) | `true` | автоподключение при старте (требует Provider ID) |
| `subscription-ping-onopen-enabled` | `true` | автозамер пинга при открытии |
| `profile-update-interval` | целое (часы) | интервал автообновления подписки |
| `subscription-userinfo` | `upload=…;download=…;total=…;expire=…` | показ квоты/срока |
| `dns-from-json-enable` | `true` | использовать DNS из JSON-конфига (а не из профиля) |
| `per-app-proxy-mode`/`-list` | `off/on/bypass`, `com.app,…` | per-app routing (Android) |
| `hide-settings`, `manual-block-user-agent`, `mux-*`, `fragmentation-*`, `noises-*`, `tun-*` | — | прочие тонкие настройки (см. app-management.md) |

## 4. Профиль-манифест и iOS-нарезка гео (UseChunkFiles)

- Профиль доставляется заголовком `routing: happ://routing/onadd/{base64}` (`onadd` =
  добавить и сразу активировать, даже если активны другие; `add` — без активации).
  Тело подписки — чистый JSON-массив, текстовую `happ://` строку туда не вставить → только заголовком.
- На **iOS** у ядра лимит памяти ~50 МБ, поэтому Happ **режет** гео-базы (`UseChunkFiles:"true"`),
  оставляя только нужные секции. **Нарезка идёт по тегам из профиля, НЕ из JSON-конфига.**
- ⚠ **Критично:** если правило в JSON использует тег (`geosite:youtube`, `geoip:ru`),
  которого НЕТ в профиле — после нарезки тег вырезается и **правило молча перестаёт
  срабатывать**. Поэтому профиль обязан быть **манифестом**: объединение всех гео-тегов,
  встречающихся в кнопках (в `DirectSites/DirectIp/ProxySites/BlockSites`).
- Поля профиля (живой эталон NurVPN): `Name`, `GlobalProxy` (`"true"`/`"false"` строкой),
  `UseChunkFiles`, `RemoteDNS*`/`DomesticDNS*` (DoH для proxy- и direct-доменов),
  `Geoipurl`/`Geositeurl` (источник баз), `DnsHosts` (домен→IP), `RouteOrder`
  (напр. `block-proxy-direct`), `DirectSites/DirectIp/ProxySites/ProxyIp/BlockSites/BlockIp`,
  `DomainStrategy`, `FakeDNS`, `LastUpdated` (Unix-время; ⚠ именно `LastUpdated`, не
  `LastUpdatedDate` — частая ошибка в сторонних ТЗ). Конструктор профиля — routing.happ.su.

## 5. Балансир: observatory vs burstObservatory (стабильность выхода)

Для авто-выбора быстрейшего сервера в Xray — `routing.balancers` со `strategy.type=leastPing`,
питается данными observatory. `selector` группирует outbound'ы **по префиксу тега**
(`["us-"]` ловит `us-1`,`us-2`,…). Правило ссылается на балансир через `balancerTag`.

⚠ **Главный практический урок (боевой, iOS, 2026-06-14):**
- **`burstObservatory`** (с `pingConfig`) — рандомизированный **непрерывный** прозвон.
  Даёт «живую» картинку → `leastPing` **дёргает выбор каждые несколько секунд** →
  выходной IP скачет в пределах пула. Для нейросетей/аккаунтов это плохо (антифрод).
- **Обычный `observatory`** (`probeUrl` + `probeInterval`) — замер раз в интервал, между
  замерами данные заморожены → `leastPing` держит один узел до следующего замера.
  **Смена сервера максимум раз в `probeInterval`.** Для стабильного выхода —
  `probeInterval: "10m"` + `enableConcurrency: true` (быстрый прогрев). ⚠ Это **клиентская
  кнопка** (выход не должен скакать). Не путать с серверным observatory в `routing-server-3xui.md`,
  где интервал короче (~30s) — там другой контекст (сервер сам балансирует, IP-стабильность сессии не та цель).
- Вывод: **для кнопки под нейросети/аккаунты — обычный `observatory` с большим интервалом**,
  не burst. Узел-«мост через РФ» в пуле США сам станет fallback (его пинг выше, leastPing
  выберет прямой US; мост подхватится только если прямые лягут).

## 6. Пинг: почему два замера расходятся

Расхождение «пинг рядом с подпиской 154 мс vs проверка после подключения 548 мс» — это не
глюк, а **разные методы** (`ping-type`):
- `icmp` — ICMP-пакеты, **временно отключает туннель** → меряет до входа.
- `tcp` — время TCP-хендшейка, до ближайшей CDN-точки → тоже не весь путь.
- `proxy` (GET) / `proxy-head` (HEAD) — **сквозь весь туннель**, учитывает выходной хоп.
- Лечение: задать `ping-type: proxy` + `check-url-via-proxy: https://www.gstatic.com/generate_204`
  + `ping-result: time`. Тогда и пинг-кнопка, и балансир (если `pingConfig.destination`/`probeUrl`
  та же цель) меряют сквозняком и сходятся. Сравнивать пинги — только в одинаковом `ping-type`.

## 7. Иконки кнопок: только флаг, и он схлопывает дубли

- Иконкой кнопки становится **первый эмодзи названия, только если это флаг** (🇺🇸→флаг США).
  Прочие эмодзи (🤖🌍🛡🔁) остаются **в тексте**, иконка — стандартный серый глобус.
  Кастомных картинок/URL-иконок в Happ **нет**; цвета — только через тему (`color-profile`).
- ⚠ **Дедупликация по флаг-иконке (боевое, 2026-06-14):** кнопка с флаг-иконкой
  схлопывается с другой кнопкой, у которой **тот же флаг + тот же первый сервер**. Пример:
  балансир «🇺🇸 USA» (первый узел = `us.nurcloud.org`) и ручная кнопка «🇺🇸 United States»
  (тот же сервер) → Happ показал одну, вторая «пропала». Лечение: кнопкам-политикам давать
  **не-флаговые** эмодзи (🤖/🌍/🛡/🔁) — уникальны, не конфликтуют с ручными серверами.
  Флаги уместны на ручных серверах (показывают страну, дублей нет).

## 8. РФ→direct: рассинхрон DNS-профиля и маршрута

⚠ **Боевой урок (2026-06-14):** если кнопка гонит **весь** трафик через зарубежный выход
(США), российские сайты ломаются (капча/challenge/таймаут), хотя сам сайт по `curl` отдаёт 200.
Корень — рассинхрон: профиль резолвит РФ-домен через `DomesticDNS` (Yandex) → получает
**РФ-адрес**, а JSON-маршрут тащит его через **US-балансир** → российский IP, запрошенный из
США. Лечение — во все балансиры добавить **РФ→direct**:
`{"domain":["geosite:category-ru"],"outboundTag":"direct"}` +
`{"ip":["geoip:ru"],"outboundTag":"direct"}` (перед правилом балансира). Тогда РФ идёт
напрямую (родной DNS + родной маршрут согласованы), а через VPN — только заграница/нейросети.
Это согласуется с дефолтной моделью сервера (`routing-server-3xui.md`): РФ всегда мимо VPN.

> 💡 Диагностический момент: детектор IP может **сам сидеть за Cloudflare** и показывать не
> реальный выход, а CF-эдж (`104.28.x`). Проверять выход надёжнее `ip-api.com` (не за CF)
> или сверкой `whois`/PTR хоста выхода с конфигом, а не «что показал 2ip.ru».

## 9. OpenGate-паттерн: реестр → генератор (наш стандарт)

Когда нужна **своя** мульти-кнопочная подписка поверх провайдера (NurVPN и др.):
```
крон → curl провайдера → load.py (многоформатный парсер → sqlite-реестр)
     → generate.py (кнопки-политики + профиль-манифест) → /var/www/happ/<rnd>.json (nginx)
```
- **Многоформатный парсер** (каскад: сырой JSON-массив → base64(JSON) → base64(vless) →
  plain vless) — устойчивость к смене формата провайдером (NurVPN уже менял).
- **sqlite-реестр** (поле `source`) — мультипровайдерный: следующий провайдер = ещё один
  `ingest`. Классификация по ролям (us/world/bypass/ru) по флагу-эмодзи + названию;
  `manual_override` для ручной коррекции; `alive=0` для исчезнувших; отпечаток **без
  волатильного `sid`** (Reality short ID дрожит каждый запрос).
- **Защита крона:** при HTTP≠200 / нераспознанном формате / <N кнопок — рабочий файл НЕ
  трогать (+ `.bak`). ⚠ Грабля: переменную, которую скрипт задаёт сам (`TARGET`), объявлять
  **после** `source env` — иначе одноимённая из env перекроет (инцидент 2026-06-14).
**Схема реестра (sqlite, эскиз DDL):**
```sql
CREATE TABLE servers (
  fp TEXT PRIMARY KEY,            -- отпечаток: source|host|port|sni|service_name|network (без sid)
  source TEXT, remarks TEXT, server_desc TEXT, country TEXT,
  role_auto TEXT, manual_override TEXT,    -- эффективная роль = manual_override ?? role_auto
  traffic_mult TEXT,             -- '×9' / '×10' / 'Безлимит' / NULL
  protocol TEXT, host TEXT, port INTEGER, network TEXT, security TEXT, sni TEXT, service_name TEXT,
  config_json TEXT,              -- proxy-outbound целиком (для генератора)
  needs_review INTEGER,          -- 1 = страна/роль не определены уверенно
  first_seen TEXT, last_seen TEXT, alive INTEGER   -- alive=0 = пропал из последней выгрузки
);
```

**Классификация роли** (по `remarks`: флаг-эмодзи + ключевые слова; первое совпадение):
| Условие | role |
|---|---|
| «обход» / «LTE» в названии | `bypass` |
| флаг 🇺🇸 / «United States» / «USA» | `us` |
| флаг 🇷🇺 / «Russia» / «Россия» | `ru` |
| иначе страна определена (любой флаг) | `world` |
| страна не определена | `world` + `needs_review=1` (видно в отчёте, правится `manual_override`) |

Страна из флага: два regional-indicator символа (U+1F1E6..U+1F1FF) → ISO-2.
Множитель `traffic_mult` — regex `[×xXхХ]\s*(\d+)` / «безлимит» по `server_desc`.

**Грабли публикации (критичные для крона):**
- **Имя файла подписки — СТАБИЛЬНОЕ** между прогонами: случайное генерится ОДИН раз при
  создании, дальше крон пишет в **тот же** файл. Рандом каждый прогон → ссылка протухнет у клиента.
- **Заголовки подписки** (`routing`/`ping-type`/`profile-title`/…) ставит **nginx `add_header`
  в `location`**, а НЕ генератор (генератор пишет только тело JSON-массива). Полный vhost —
  в приватном inventory (`domains.md`); `routing`-заголовок с base64-профилем обновлять при
  изменении набора гео-тегов.
- **Порог валидации** — например ≥5 кнопок; меньше / нераспознанный формат / HTTP≠200 →
  рабочий файл НЕ трогать + `.bak` (защита «лучше старый рабочий»).

- Эталон реализации (полный рабочий код) — `infra/scripts/vpn/opengate/`
  (`load.py`/`generate.py`/`opengate-sync.sh`) в **приватном git `vefmvai/infra`**. Для
  воспроизведения на другом компьютере оператора: клонировать `vefmvai/infra` (код) +
  `vefmvai/sysadmin` (этот knowledge). Для нового оператора без доступа к infra — код
  пишется заново по этому §9 (схема + классификация + структура кнопки §2.1–2.2 даны).

## Связь с другими документами

- `client-apps.md` — карта клиентов; Happ — основной клиент (§3.6), его routing-профиль.
- `subscription-mirroring.md` — зеркалирование подписки (base64-список); этот документ —
  следующий уровень (мульти-кнопочная генерируемая подписка).
- `routing-on-device-xray.md` — on-device routing через Xray (balancer/observatory детальнее).
- `routing-server-3xui.md` — серверная модель (РФ→direct как дефолт).
- `transports.md` — параметры vless (reality/sid/sni).

*Триггеры внеплановой ревизии: изменение формата подписки/заголовков Happ; смена поведения
balancer/observatory в Xray-ядре Happ; новая волна изменений у провайдеров (формат выгрузки).*
