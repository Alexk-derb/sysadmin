#!/usr/bin/env python3
"""
Генератор мульти-кнопочной Happ-подписки из sqlite-реестра (паттерн OpenGate).

Тело подписки — сырой JSON-массив кнопок (НЕ base64). Профиль-манифест уезжает HTTP-заголовком
`routing: happ://routing/onadd/{base64}` (скрипт печатает его + набор add_header для nginx).
Детали формата — knowledge networking/_reference/happ-subscription-format.md.

Кнопки (адаптируй под свой парк): 🤖 USA / 🌍 Мир / 🛡 WL / 🔁 RU + по кнопке на сервер.
  generate.py --db registry.db --out sub.json
  generate.py --db registry.db --only USA --out proto.json
"""
import json, base64, argparse, sqlite3

PING_DEST = "https://www.gstatic.com/generate_204"
# Обычный observatory (НЕ burst): замер раз в OBS_INTERVAL, между замерами leastPing держит
# один узел → выход не скачет. burstObservatory дёргает выбор каждые секунды (плохо для аккаунтов).
OBS_INTERVAL = "10m"

# Манифест гео-тегов для iOS-нарезки: ВСЁ, что встречается в routing кнопок (иначе тег вырежется).
GEO_DIRECT_IP   = ["geoip:private", "geoip:ru"]
GEO_DIRECT_SITE = ["geosite:category-ru"]
GEO_BLOCK_SITE  = ["geosite:category-ads-all"]


def dns_block():
    return {"servers": ["https://dns.google/dns-query", "https://cloudflare-dns.com/dns-query"]}


def inbounds():
    sniff = {"enabled": True, "destOverride": ["http", "tls", "quic"]}
    return [
        {"tag": "socks", "listen": "127.0.0.1", "port": 10808, "protocol": "socks",
         "sniffing": sniff, "settings": {"udp": True}},
        {"tag": "http", "listen": "127.0.0.1", "port": 10809, "protocol": "http", "sniffing": sniff},
    ]


def proxy_outbound(config_json, tag):
    o = json.loads(config_json)
    o["tag"] = tag
    return o


def fetch(db, roles):
    ph = ",".join("?" * len(roles))
    return db.execute(
        f"SELECT remarks,traffic_mult,config_json FROM servers "
        f"WHERE alive=1 AND COALESCE(manual_override,role_auto) IN ({ph}) "
        f"ORDER BY remarks", roles).fetchall()


def balancer_button(remarks, desc, rows, prefix):
    outs = [proxy_outbound(cfg, f"{prefix}-{i}") for i, (_, _, cfg) in enumerate(rows, 1)]
    outs += [{"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"}]
    return {
        "remarks": remarks, "meta": {"serverDescription": desc},
        "dns": dns_block(), "inbounds": inbounds(), "outbounds": outs,
        "observatory": {"subjectSelector": [prefix + "-"], "probeUrl": PING_DEST,
                        "probeInterval": OBS_INTERVAL, "enableConcurrency": True},
        "routing": {"domainStrategy": "IPIfNonMatch",
                    "balancers": [{"tag": "auto", "selector": [prefix + "-"],
                                   "strategy": {"type": "leastPing"}}],
                    "rules": [
                        {"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"},
                        {"type": "field", "domain": GEO_BLOCK_SITE, "outboundTag": "block"},
                        # РФ → напрямую (согласовано с DomesticDNS профиля, иначе РФ-сайт ломается)
                        {"type": "field", "domain": GEO_DIRECT_SITE, "outboundTag": "direct"},
                        {"type": "field", "ip": ["geoip:ru"], "outboundTag": "direct"},
                        {"type": "field", "network": "tcp,udp", "balancerTag": "auto"}]},
    }


def reverse_ru_button(rows):
    rem, mult, cfg = rows[0]
    outs = [proxy_outbound(cfg, "ru-1"),
            {"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"}]
    return {
        "remarks": "🔁 RU", "meta": {"serverDescription": "рус. трафик через РФ, остальное напрямую"},
        "dns": dns_block(), "inbounds": inbounds(), "outbounds": outs,
        "routing": {"domainStrategy": "IPIfNonMatch", "rules": [
            {"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"},
            {"type": "field", "domain": GEO_DIRECT_SITE, "outboundTag": "ru-1"},
            {"type": "field", "ip": ["geoip:ru"], "outboundTag": "ru-1"},
            {"type": "field", "network": "tcp,udp", "outboundTag": "direct"}]},
    }


def manual_button(rem, mult, cfg):
    desc = (mult + " · " if mult else "") + "ручной выбор"
    outs = [proxy_outbound(cfg, "proxy"),
            {"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"}]
    return {"remarks": rem, "meta": {"serverDescription": desc},
            "dns": dns_block(), "inbounds": inbounds(), "outbounds": outs,
            "routing": {"domainStrategy": "IPIfNonMatch", "rules": [
                {"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"},
                {"type": "field", "network": "tcp,udp", "outboundTag": "proxy"}]}}


def profile_manifest():
    return {
        "Name": "OpenGate", "GlobalProxy": "true", "UseChunkFiles": "true",
        "RouteOrder": "block-direct-proxy",
        "RemoteDNSType": "DoH", "RemoteDNSDomain": "https://dns.google/dns-query", "RemoteDNSIP": "8.8.8.8",
        "DomesticDNSType": "DoH",
        "DomesticDNSDomain": "https://common.dot.dns.yandex.net/dns-query", "DomesticDNSIP": "77.88.8.8",
        "Geoipurl": "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat",
        "Geositeurl": "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat",
        "DnsHosts": {},
        "DirectSites": GEO_DIRECT_SITE, "DirectIp": GEO_DIRECT_IP,
        "ProxySites": GEO_DIRECT_SITE, "ProxyIp": ["geoip:ru"],
        "BlockSites": GEO_BLOCK_SITE, "BlockIp": [],
        "DomainStrategy": "IPIfNonMatch", "FakeDNS": "false",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--only", help="одна кнопка: USA|Мир|WL|RU")
    ap.add_argument("--out", default="sub.json")
    ap.add_argument("--no-manual", action="store_true")
    args = ap.parse_args()
    db = sqlite3.connect(args.db)

    us = fetch(db, ["us"])
    world = fetch(db, ["world", "us"])
    byp = fetch(db, ["bypass"])
    ru = fetch(db, ["ru"])

    def want(name):
        return (not args.only) or args.only.upper() == name.upper()

    buttons = []
    if want("USA") and us:
        buttons.append(balancer_button("🤖 USA", "нейросети · авто-быстрейший US", us, "us"))
    if want("Мир") and world:
        buttons.append(balancer_button("🌍 Мир", "общий · авто-быстрейший (без обхода)", world, "wd"))
    if want("WL") and byp:
        mults = sorted({m for _, m, _ in byp if m})
        buttons.append(balancer_button("🛡 WL", "обход белых списков · " + "/".join(mults), byp, "bp"))
    if want("RU") and ru:
        buttons.append(reverse_ru_button(ru))
    if not args.only and not args.no_manual:
        for rem, mult, cfg in world + byp:
            buttons.append(manual_button(rem, mult, cfg))

    json.dump(buttons, open(args.out, "w"), ensure_ascii=False)
    b64 = base64.b64encode(json.dumps(profile_manifest(), ensure_ascii=False).encode()).decode()

    print(f"кнопок: {len(buttons)} → {args.out} ({len(json.dumps(buttons, ensure_ascii=False))} байт)")
    print("первые:", ", ".join(b["remarks"] for b in buttons[:6]) + (" ..." if len(buttons) > 6 else ""))
    print(f"\n--- routing-профиль (заголовок) ---\nrouting: happ://routing/onadd/{b64}")
    print("\n--- nginx add_header (вставить в location подписки) ---")
    for k, v in [("profile-title", "OpenGate"), ("ping-type", "proxy"),
                 ("check-url-via-proxy", PING_DEST), ("ping-result", "time"),
                 ("subscriptions-sort-type", "without"), ("subscription-pin", "true")]:
        print(f'  add_header {k} "{v}" always;')
    print('  add_header routing "happ://routing/onadd/<base64-выше>" always;')


if __name__ == "__main__":
    main()
