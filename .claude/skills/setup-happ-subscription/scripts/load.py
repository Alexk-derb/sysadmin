#!/usr/bin/env python3
"""
Загрузчик VPN-подписок в sqlite-реестр серверов (паттерн OpenGate).

Мультипровайдерный: каждый сервер помечен `source`. Многоформатный парсер с каскадом
fallback — смена формата у провайдера не ломает пайплайн (детальнее — knowledge
networking/_reference/happ-subscription-format.md §9):
  1) сырой JSON-массив конфигов (формат NurVPN с ~июня 2026)
  2) base64 → JSON-массив
  3) base64 → список vless://
  4) plain-текст vless://
  5) не распознано → код возврата 2, реестр НЕ трогаем

Команды:
  ingest --source NAME --db registry.db FILE
  list   --db registry.db [--role R]
  override       --db registry.db --match SUBSTR --role R   # ручная роль (бьёт авто)
  unset-override --db registry.db --match SUBSTR

Роли: us | world | ru | bypass. Эффективная роль = manual_override ?? role_auto.
Серверы без определённой страны → world + needs_review=1 (видны в отчёте).
"""
import sys, json, base64, re, argparse, sqlite3, urllib.parse as up
from datetime import datetime, timezone

SCHEMA = """
CREATE TABLE IF NOT EXISTS servers (
  fp              TEXT PRIMARY KEY,                 -- отпечаток (без волатильного sid)
  source          TEXT NOT NULL,
  remarks         TEXT, server_desc TEXT, country TEXT,
  role_auto       TEXT NOT NULL DEFAULT 'world',
  manual_override TEXT,
  traffic_mult    TEXT,                             -- '×9' / '×10' / 'Безлимит' / NULL
  protocol        TEXT, host TEXT, port INTEGER,
  network         TEXT, security TEXT, sni TEXT, service_name TEXT,
  config_json     TEXT NOT NULL,                    -- proxy-outbound целиком (для генератора)
  needs_review    INTEGER NOT NULL DEFAULT 0,
  first_seen      TEXT, last_seen TEXT,
  alive           INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_role ON servers(source, role_auto, manual_override, alive);
"""


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def b64try(text):
    t = re.sub(r"\s+", "", text)
    t += "=" * (-len(t) % 4)
    return base64.b64decode(t).decode("utf-8", "replace")


def country_from_flag(s):
    """Два regional-indicator символа подряд → ISO-2 ('🇺🇸' → 'US')."""
    ri = [c for c in (s or "") if 0x1F1E6 <= ord(c) <= 0x1F1FF]
    if len(ri) >= 2:
        return (chr(ord(ri[0]) - 0x1F1E6 + ord("A"))
                + chr(ord(ri[1]) - 0x1F1E6 + ord("A")))
    return None


def classify(remarks, country):
    """→ (role_auto, needs_review). Адаптируй правила под свой парк/провайдера."""
    low = (remarks or "").lower()
    if "обход" in low or "lte" in low:
        return "bypass", False
    if country == "US" or "united states" in low or re.search(r"\busa\b", low):
        return "us", False
    if country == "RU" or "russia" in low or "россия" in low:
        return "ru", False
    if country:                       # обычный зарубежный выход (включая мосты)
        return "world", False
    return "world", True              # страна не определена → world + сигнал review


def traffic_mult(desc):
    d = desc or ""
    m = re.search(r"[×xXхХ]\s*(\d+)", d)
    if m:
        return "×" + m.group(1)
    if "безлимит" in d.lower():
        return "Безлимит"
    return None


def vless_to_proxy(uri):
    """Минимальный парс vless:// → элемент с proxy-outbound (fallback-форматы 3/4)."""
    m = re.match(r"vless://([^@]+)@([^:/?#]+):(\d+)\?([^#]*)(?:#(.*))?", uri)
    if not m:
        return None
    uuid, host, port, query, frag = m.groups()
    params = dict(p.split("=", 1) for p in query.split("&") if "=" in p)
    remarks = up.unquote((frag or "").split("?")[0])
    desc = ""
    if frag and "serverDescription=" in frag:
        try:
            desc = b64try(frag.split("serverDescription=", 1)[1])
        except Exception:
            desc = ""
    ob = {
        "tag": "proxy", "protocol": "vless",
        "settings": {"vnext": [{
            "address": host, "port": int(port),
            "users": [{"id": uuid, "encryption": params.get("encryption", "none"),
                       "flow": params.get("flow", "")}]}]},
        "streamSettings": {
            "network": params.get("type", "tcp"),
            "security": params.get("security", "none"),
            "realitySettings": {"serverName": up.unquote(params.get("sni", "")),
                                "publicKey": params.get("pbk", ""),
                                "shortId": params.get("sid", "")},
            "grpcSettings": {"serviceName": up.unquote(params.get("serviceName", ""))},
        },
    }
    return {"remarks": remarks, "meta": {"serverDescription": desc}, "outbounds": [ob]}


def parse_subscription(raw):
    """→ (формат, [элементы]) либо (None, None). Детекция по содержимому."""
    text = raw.decode("utf-8", "replace").strip()
    try:                                            # 1) сырой JSON-массив
        j = json.loads(text)
        if isinstance(j, list):
            return "json-array", j
    except Exception:
        pass
    try:                                            # 2) base64 → JSON
        j = json.loads(b64try(text))
        if isinstance(j, list):
            return "base64-json", j
    except Exception:
        pass
    try:                                            # 3) base64 → vless
        dec = b64try(text)
        if "vless://" in dec:
            return "base64-vless", [vless_to_proxy(l) for l in dec.splitlines()
                                    if l.startswith("vless://")]
    except Exception:
        pass
    if "vless://" in text:                           # 4) plain vless
        return "plain-vless", [vless_to_proxy(l) for l in text.splitlines()
                               if l.startswith("vless://")]
    return None, None


def extract(elem):
    """Элемент (кнопка/конфиг) → запись сервера (или None)."""
    remarks = elem.get("remarks") or (elem.get("meta") or {}).get("remarks") or ""
    desc = (elem.get("meta") or {}).get("serverDescription") or ""
    if re.fullmatch(r"[A-Za-z0-9+/=]{8,}", desc or ""):   # desc бывает base64
        try:
            desc = b64try(desc)
        except Exception:
            pass
    proxy = next((o for o in elem.get("outbounds", []) if o.get("tag") == "proxy"), None)
    if proxy is None and elem.get("outbounds"):
        proxy = elem["outbounds"][0]
    if proxy is None:
        return None
    v = (proxy.get("settings", {}).get("vnext") or [{}])[0]
    ss = proxy.get("streamSettings", {})
    sni = (ss.get("realitySettings") or ss.get("tlsSettings") or {}).get("serverName", "")
    svc = (ss.get("grpcSettings") or {}).get("serviceName", "")
    country = country_from_flag(remarks)
    role_auto, review = classify(remarks, country)
    return {
        "remarks": remarks, "server_desc": desc, "country": country,
        "role_auto": role_auto, "needs_review": int(review),
        "traffic_mult": traffic_mult(desc),
        "protocol": proxy.get("protocol", ""),
        "host": v.get("address", ""), "port": v.get("port", 0),
        "network": ss.get("network", ""), "security": ss.get("security", ""),
        "sni": sni, "service_name": svc,
        "config_json": json.dumps(proxy, ensure_ascii=False),
    }


def fp_of(source, r):
    """Стабильный отпечаток без волатильных полей (sid дрожит каждый запрос)."""
    return "|".join([source, r["host"], str(r["port"]), r["sni"], r["service_name"], r["network"]])


def connect(db_path):
    db = sqlite3.connect(db_path)
    db.executescript(SCHEMA)
    return db


def cmd_ingest(args):
    raw = open(args.file, "rb").read()
    fmt, elems = parse_subscription(raw)
    if not fmt:
        print("ERROR: формат не распознан — реестр не трогаю", file=sys.stderr)
        sys.exit(2)
    db = connect(args.db)
    ts = now()
    seen, new, upd = set(), 0, 0
    for elem in (e for e in elems if e):
        r = extract(elem)
        if not r:
            continue
        fp = fp_of(args.source, r)
        seen.add(fp)
        exists = db.execute("SELECT 1 FROM servers WHERE fp=?", (fp,)).fetchone()
        cols = ("remarks", "server_desc", "country", "role_auto", "needs_review",
                "traffic_mult", "protocol", "host", "port", "network", "security",
                "sni", "service_name", "config_json")
        vals = tuple(r[c] for c in cols)
        if exists:
            db.execute(f"UPDATE servers SET {','.join(c+'=?' for c in cols)}, "
                       f"last_seen=?, alive=1 WHERE fp=?", vals + (ts, fp))
            upd += 1
        else:
            db.execute(f"INSERT INTO servers(fp,source,{','.join(cols)},first_seen,last_seen,alive) "
                       f"VALUES({','.join(['?']*(len(cols)+5))})",
                       (fp, args.source) + vals + (ts, ts, 1))
            new += 1
    gone = []
    for fp, rem in db.execute("SELECT fp,remarks FROM servers WHERE source=? AND alive=1",
                              (args.source,)).fetchall():
        if fp not in seen:
            db.execute("UPDATE servers SET alive=0 WHERE fp=?", (fp,))
            gone.append(rem)
    db.commit()

    print(f"формат входа: {fmt}")
    print(f"источник: {args.source} | в выгрузке {len(seen)} | новых {new} | "
          f"обновлено {upd} | исчезло {len(gone)}")
    print("\nпо эффективной роли (override ?? auto), живые:")
    for role, cnt in db.execute(
            "SELECT COALESCE(manual_override,role_auto) r, COUNT(*) FROM servers "
            "WHERE source=? AND alive=1 GROUP BY r ORDER BY 2 DESC", (args.source,)):
        print(f"  {role:8} {cnt}")
    rev = db.execute("SELECT remarks FROM servers WHERE source=? AND alive=1 AND needs_review=1",
                     (args.source,)).fetchall()
    if rev:
        print("\n⚠ не классифицированы уверенно (нет страны) → 'world' по умолчанию:")
        for (rem,) in rev:
            print(f"    {rem}")
    if gone:
        print(f"\nисчезли из подписки (alive=0): {', '.join(g or '?' for g in gone)}")


def cmd_list(args):
    db = connect(args.db)
    q = ("SELECT COALESCE(manual_override,role_auto),country,traffic_mult,remarks,host "
         "FROM servers WHERE alive=1")
    p = []
    if args.role:
        q += " AND COALESCE(manual_override,role_auto)=?"
        p.append(args.role)
    q += " ORDER BY 1,4"
    for role, c, mult, rem, host in db.execute(q, p):
        print(f"  [{role:6}] {c or '--'} {(mult or ''):8} {rem:32} {host}")


def cmd_override(args):
    db = connect(args.db)
    n = db.execute("UPDATE servers SET manual_override=? WHERE remarks LIKE ?",
                   (args.role, f"%{args.match}%")).rowcount
    db.commit()
    print(f"роль '{args.role}' проставлена для {n} серверов (match '{args.match}')")


def cmd_unset(args):
    db = connect(args.db)
    n = db.execute("UPDATE servers SET manual_override=NULL WHERE remarks LIKE ?",
                   (f"%{args.match}%",)).rowcount
    db.commit()
    print(f"override снят для {n} серверов (match '{args.match}')")


def main():
    ap = argparse.ArgumentParser(description="OpenGate registry loader")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("ingest"); a.add_argument("--source", required=True)
    a.add_argument("--db", required=True); a.add_argument("file"); a.set_defaults(fn=cmd_ingest)
    a = sub.add_parser("list"); a.add_argument("--db", required=True)
    a.add_argument("--role"); a.set_defaults(fn=cmd_list)
    a = sub.add_parser("override"); a.add_argument("--db", required=True)
    a.add_argument("--match", required=True); a.add_argument("--role", required=True)
    a.set_defaults(fn=cmd_override)
    a = sub.add_parser("unset-override"); a.add_argument("--db", required=True)
    a.add_argument("--match", required=True); a.set_defaults(fn=cmd_unset)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
