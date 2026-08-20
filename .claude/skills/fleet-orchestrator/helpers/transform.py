#!/usr/bin/env python3
"""
transform.py — the messy-edge adapter between the LIVE roster and the pure router.

`bp fleet roster -o json` speaks the server dialect (documents envelope, structured
capacity in three historical encodings, ISO8601 timestamps, server-computed status).
`route.py` is a pure function that speaks floats and flat keys — and stays byte-untouched
(purity law: its 9/9 selftest is the proof it never drifted). THIS file owns every
translation between them:

  - capacity decoded THREE ways: native map / JSON-string (json.loads) / legacy plain
    string (e.g. "16gb") → treated as ABSENT structured fields (route.py's own defaults)
  - `size_class` renamed → `max_class` (the router's vocabulary)
  - `slots_total` / `slots_free` / `budget` passed through ONLY when present
  - `last_seen` ISO8601 → epoch float (Z-suffix normalized for python < 3.11)
  - `now` minted from the SAME UTC epoch clock the timestamps are converted with
  - server `status` passed through UNCHANGED (PDF-D20: the server's one staleness
    formula wins; the client never re-derives liveness) — `ttl_s` likewise

Output is exactly the `route.py --route` stdin payload:
    {"roster": [...], "orders": [...], "now": <float>, "spend_cap_reached": <bool>}

Usage:
    bp fleet roster -o json | transform.py --orders orders.json [--cap-reached] [--now E]
    transform.py --roster roster.json --orders orders.json
    transform.py --selftest        # the three proven scenarios, end-to-end through route.py
"""
from __future__ import annotations
import argparse, json, os, sys
from datetime import datetime, timezone


def iso_to_epoch(value):
    """ISO8601 → epoch float. Accepts an already-numeric epoch unchanged (idempotent).

    python < 3.11 `fromisoformat` rejects the Z suffix — normalize to +00:00 first.
    A naive timestamp is taken as UTC (the server stamps UTC, PDF-D17)."""
    if value is None:
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    s = str(value).strip()
    if not s:
        return None
    if s.endswith(("Z", "z")):
        s = s[:-1] + "+00:00"
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


def decode_capacity(raw):
    """The three capacity shapes seen in the wild, decoded to ONE dict.

    1. native map            → as-is
    2. JSON-string           → json.loads (a beat that serialized its map)
    3. legacy plain string   → {} — absent structured fields; route.py applies its
                                own defaults rather than us inventing numbers (a
                                guess here would masquerade as a measurement)
    """
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        try:
            parsed = json.loads(raw)
        except ValueError:
            return {}
        return parsed if isinstance(parsed, dict) else {}
    return {}


def transform_row(row):
    """One roster document → one route.py roster entry. Emit a key ONLY when the
    source really carries it — route.py's defaults are the single fallback truth."""
    src = row
    content = row.get("content")
    if isinstance(content, dict) and "worker" in content:
        src = content  # some readers nest the fields under content; the shape is the same
    out = {"worker": src.get("worker")}
    cap = decode_capacity(src.get("capacity"))
    max_class = cap.get("max_class", cap.get("size_class"))  # rename size_class → max_class
    if max_class is not None:
        out["max_class"] = max_class
    for key in ("slots_total", "slots_free", "budget"):
        if cap.get(key) is not None:
            out[key] = cap[key]
    last_seen = iso_to_epoch(src.get("last_seen"))
    if last_seen is not None:
        out["last_seen"] = last_seen
    if src.get("ttl_s") is not None:
        out["ttl_s"] = src["ttl_s"]
    if src.get("status") is not None:
        out["status"] = src["status"]  # UNCHANGED — server status wins (PDF-D20)
    return out


def build_payload(roster_doc, orders_doc, now=None, spend_cap_reached=False):
    rows = roster_doc.get("documents", roster_doc) if isinstance(roster_doc, dict) else roster_doc
    orders = orders_doc.get("orders", orders_doc) if isinstance(orders_doc, dict) else orders_doc
    if now is None:
        now = datetime.now(timezone.utc).timestamp()  # same clock family as iso_to_epoch
    return {
        "roster": [transform_row(r) for r in rows],
        "orders": orders,  # passed through — route.py reads id/klass/fence, dispatch keeps the rest
        "now": float(now),
        "spend_cap_reached": bool(spend_cap_reached),
    }


# --------------------------------------------------------------------------------------
def _selftest():
    """The three proven scenarios, run END-TO-END: fixture → transform → route.route()."""
    import importlib.util
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("route", os.path.join(here, "route.py"))
    route_mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(route_mod)

    ok = 0
    def check(name, cond):
        nonlocal ok
        assert cond, f"FAIL: {name}"
        ok += 1
        print(f"  ok  {name}")

    base = iso_to_epoch("2026-07-22T10:00:00Z")
    now = base + 10.0
    xl_map = {"size_class": "xl", "slots_total": 2, "slots_free": 2, "budget": 100}
    light_str = json.dumps({"size_class": "light", "slots_total": 1, "slots_free": 1})

    def roster_env(box_cap, laptop_cap):
        return {"documents": [
            {"worker": "box-32gb", "status": "idle", "ttl_s": 120,
             "last_seen": "2026-07-22T10:00:00Z", "capacity": box_cap},
            {"worker": "laptop-lean", "status": "idle", "ttl_s": 120,
             "last_seen": "2026-07-22T10:00:05.250Z", "capacity": laptop_cap},
            {"worker": "old-box", "status": "idle", "ttl_s": 120,
             "last_seen": "2026-07-22T10:00:05Z", "capacity": "16gb"},  # legacy plain string
        ]}

    orders = [{"id": "o-export", "klass": "heavy"}, {"id": "o-lint", "klass": "light"}]

    # ------ scenario 1: heavy → big, light → lean; all three capacity shapes decoded ------
    p = build_payload(roster_env(xl_map, light_str), orders, now=now)
    by = {r["worker"]: r for r in p["roster"]}
    check("native-map capacity: size_class renamed → max_class xl",
          by["box-32gb"]["max_class"] == "xl" and "size_class" not in by["box-32gb"])
    check("JSON-string capacity decoded → max_class light + slots",
          by["laptop-lean"]["max_class"] == "light" and by["laptop-lean"]["slots_free"] == 1)
    check("legacy plain-string capacity → structured fields ABSENT (router defaults)",
          "max_class" not in by["old-box"] and "slots_free" not in by["old-box"])
    check("ISO8601 last_seen → epoch float (Z + fractional handled on py<3.11)",
          by["box-32gb"]["last_seen"] == base and by["laptop-lean"]["last_seen"] == base + 5.25)
    check("server status + ttl_s pass through UNCHANGED (PDF-D20)",
          all(r["status"] == "idle" and r["ttl_s"] == 120 for r in p["roster"]))
    check("payload carries now as float + cap flag false",
          isinstance(p["now"], float) and p["now"] == now and p["spend_cap_reached"] is False)
    r = route_mod.route(p["roster"], p["orders"], p["now"], p["spend_cap_reached"])
    amap = {a["order"]: a["worker"] for a in r["assignments"]}
    check("live shapes routed: heavy → box-32gb, light → laptop-lean, zero unplaceable",
          amap == {"o-export": "box-32gb", "o-lint": "laptop-lean"} and r["unplaceable"] == [])

    # ------ scenario 2: capacities SWAPPED, names constant → the assignment FLIPS ------
    p2 = build_payload(roster_env(light_str, xl_map), orders, now=now)
    r2 = route_mod.route(p2["roster"], p2["orders"], p2["now"], p2["spend_cap_reached"])
    amap2 = {a["order"]: a["worker"] for a in r2["assignments"]}
    check("swap-flip: heavy → laptop-lean, light → box-32gb (beats drive routing, not names)",
          amap2 == {"o-export": "laptop-lean", "o-lint": "box-32gb"})

    # ------ scenario 3: spend cap reached → ambition zero, every reason spend_cap ------
    p3 = build_payload(roster_env(xl_map, light_str), orders, now=now, spend_cap_reached=True)
    r3 = route_mod.route(p3["roster"], p3["orders"], p3["now"], p3["spend_cap_reached"])
    check("cap tripped: assignments empty, EVERY order refused spend_cap",
          r3["assignments"] == [] and len(r3["unplaceable"]) == len(orders)
          and all(u["reason"] == "spend_cap" for u in r3["unplaceable"]))

    print(f"\nTRANSFORM PROOF: {ok}/{ok} checks passed — three capacity shapes, ISO→epoch, "
          "server status untouched; heavy→big/light→lean, swap flips, cap freezes.")


def main():
    ap = argparse.ArgumentParser(description="roster/orders → route.py --route payload")
    ap.add_argument("--selftest", action="store_true", help="run the three proven scenarios")
    ap.add_argument("--roster", help="roster JSON file (documents envelope); default: stdin")
    ap.add_argument("--orders", help="orders JSON file (list or {orders: [...]})")
    ap.add_argument("--cap-reached", action="store_true", help="spend cap reached → ambition zero")
    ap.add_argument("--now", type=float, help="override the UTC epoch clock (tests)")
    args = ap.parse_args()

    if args.selftest:
        _selftest()
        return

    if not args.orders:
        ap.error("--orders is required (or use --selftest)")
    if args.roster:
        with open(args.roster) as f:
            roster_doc = json.load(f)
    else:
        roster_doc = json.load(sys.stdin)
    with open(args.orders) as f:
        orders_doc = json.load(f)

    payload = build_payload(roster_doc, orders_doc, now=args.now,
                            spend_cap_reached=args.cap_reached)
    print(json.dumps(payload, indent=2))


if __name__ == "__main__":
    main()
