#!/usr/bin/env python3
"""
route.py — the Personal Dev Fleet capacity router.

The orchestrator's clever core: given a live roster of listeners (each a different
SIZE of resource) and a batch of orders (each a weight CLASS), assign every order to
the CHEAPEST SUFFICIENT listener — so a big export-class box is never wasted on a lint
task, and a lean box never gets handed an export it cannot hold.

Strategy = Best-Fit-Decreasing bin-packing, capacity-, fence- and budget-aware:
  1. Drop OFFLINE listeners (heartbeat older than its ttl).
  2. Sort orders heaviest-first (a heavy order must grab a big box before a light one fills it).
  3. For each order, pick the SMALLEST listener that can (a) handle the class, (b) has a
     free slot, (c) has budget for the class, (d) is fence-disjoint from what it already holds.
  4. Anything unplaceable is reported (→ wait, escalate size, or refuse) — never silently dropped.

Pure function. No I/O. `python3 route.py` runs the self-test (the winning-strategy proof).
"""
from __future__ import annotations
import json, sys

# Task weight classes, ordered. A listener advertises the MAX class it can safely run.
CLASS = {"light": 1, "standard": 2, "heavy": 3, "xl": 4}
# Rough token cost per class (relative) — used only for the budget gate.
CLASS_COST = {"light": 1, "standard": 4, "heavy": 12, "xl": 30}


def _online(listener: dict, now: float) -> bool:
    """A listener is live iff it is not offline.

    Prefer the SERVER-COMPUTED `status` field (the roster's one staleness formula, PDF-D20): when
    present, `status == "offline"` is authoritative and the client never re-derives liveness from
    raw timestamps. Only for rows lacking a computed status (e.g. a hand-built roster) fall back to
    the local heartbeat-freshness math (stale = offline)."""
    status = listener.get("status")
    if status is not None:
        return status != "offline"
    return (now - listener.get("last_seen", now)) <= listener.get("ttl_s", 120)


def route(roster: list[dict], orders: list[dict], now: float = 0.0, spend_cap_reached: bool = False):
    """
    roster:  [{worker, max_class, slots_total, slots_free, budget, last_seen, ttl_s, ram_mb?}]
    orders:  [{id, klass, fence}]
    returns: {"assignments": [{order, worker}], "unplaceable": [{order, reason}]}
    """
    # spend cap = ambition forced to zero (the hard brake).
    if spend_cap_reached:
        return {"assignments": [], "unplaceable": [{"order": o["id"], "reason": "spend_cap"} for o in orders]}

    live = [dict(l) for l in roster if _online(l, now)]
    for l in live:
        l["_free"] = l.get("slots_free", l.get("slots_total", 1))
        l["_budget"] = l.get("budget", 10 ** 9)
        l["_held_fences"] = set()

    # heaviest orders first — they have the fewest boxes that can hold them.
    ordered = sorted(orders, key=lambda o: CLASS.get(o.get("klass", "standard"), 2), reverse=True)

    assignments, unplaceable = [], []
    for o in ordered:
        w = CLASS.get(o.get("klass", "standard"), 2)
        cost = CLASS_COST.get(o.get("klass", "standard"), 4)
        fence = o.get("fence")
        # candidates: capable, free, budgeted, fence-disjoint — then take the SMALLEST (best fit).
        cands = [
            l for l in live
            if CLASS.get(l.get("max_class", "standard"), 2) >= w
            and l["_free"] > 0
            and l["_budget"] >= cost
            and (fence is None or fence not in l["_held_fences"])
        ]
        if not cands:
            # why? distinguish "no box is big enough" from "the big boxes are busy/broke".
            capable_exists = any(CLASS.get(l.get("max_class", "standard"), 2) >= w for l in live)
            reason = "no_capacity_for_class" if not capable_exists else "all_capable_busy_or_over_budget"
            unplaceable.append({"order": o["id"], "reason": reason})
            continue
        # best fit = smallest max_class, then fewest free slots (pack tight), then name for determinism.
        pick = min(cands, key=lambda l: (CLASS.get(l.get("max_class", "standard"), 2), l["_free"], l["worker"]))
        pick["_free"] -= 1
        pick["_budget"] -= cost
        if fence:
            pick["_held_fences"].add(fence)
        assignments.append({"order": o["id"], "worker": pick["worker"], "klass": o.get("klass", "standard")})

    assignments.sort(key=lambda a: a["order"])
    return {"assignments": assignments, "unplaceable": unplaceable}


# --------------------------------------------------------------------------------------
def _selftest():
    ok = 0
    def check(name, cond):
        nonlocal ok
        assert cond, f"FAIL: {name}"
        ok += 1
        print(f"  ok  {name}")

    # A mixed fleet: one tiny, two lean, one big export-class box.
    roster = [
        {"worker": "lean-1",  "max_class": "standard", "slots_total": 2, "slots_free": 2, "last_seen": 0, "ttl_s": 120},
        {"worker": "lean-2",  "max_class": "standard", "slots_total": 2, "slots_free": 2, "last_seen": 0, "ttl_s": 120},
        {"worker": "tiny-1",  "max_class": "light",    "slots_total": 1, "slots_free": 1, "last_seen": 0, "ttl_s": 120},
        {"worker": "big-1",   "max_class": "xl",       "slots_total": 1, "slots_free": 1, "last_seen": 0, "ttl_s": 120},
    ]

    # 1) A heavy export lands on the big box (only one capable).
    r = route(roster, [{"id": "exp", "klass": "heavy"}])
    check("heavy → big box", r["assignments"] == [{"order": "exp", "worker": "big-1", "klass": "heavy"}])

    # 2) A light task does NOT waste the big box while smaller boxes are free.
    r = route(roster, [{"id": "lint", "klass": "light"}])
    got = r["assignments"][0]["worker"]
    check("light avoids the big box", got in ("tiny-1",) and got != "big-1")

    # 3) The clever case: a light + a heavy dispatched together — heavy grabs big FIRST,
    #    light packs onto the tiny box; the big box is spent only where it must be.
    r = route(roster, [{"id": "lint", "klass": "light"}, {"id": "exp", "klass": "heavy"}])
    amap = {a["order"]: a["worker"] for a in r["assignments"]}
    check("mixed batch: heavy→big, light→tiny", amap["exp"] == "big-1" and amap["lint"] == "tiny-1")

    # 4) Two heavies but one big box → one placed, one honestly unplaceable (not dropped).
    r = route(roster, [{"id": "e1", "klass": "heavy"}, {"id": "e2", "klass": "heavy"}])
    check("over-capacity heavies: one placed, one flagged",
          len(r["assignments"]) == 1 and r["unplaceable"] == [{"order": "e2", "reason": "all_capable_busy_or_over_budget"}])

    # 5) No box big enough for an xl-when-big-is-offline → distinct reason.
    stale = [dict(l) for l in roster]
    for l in stale:
        if l["worker"] == "big-1":
            l["last_seen"] = -10 ** 6  # heartbeat ancient → offline
    r = route(stale, [{"id": "huge", "klass": "xl"}], now=0)
    check("offline big box excluded → no_capacity_for_class",
          r["assignments"] == [] and r["unplaceable"] == [{"order": "huge", "reason": "no_capacity_for_class"}])

    # 6) Fence-disjointness: two same-fence orders can't both land on one listener's two slots.
    r = route([{"worker": "lean-1", "max_class": "standard", "slots_total": 2, "slots_free": 2, "last_seen": 0, "ttl_s": 120}],
              [{"id": "a", "klass": "standard", "fence": "zoneX"}, {"id": "b", "klass": "standard", "fence": "zoneX"}])
    check("same-fence orders don't co-locate", len(r["assignments"]) == 1 and r["unplaceable"][0]["order"] == "b")

    # 7) Spend cap reached → ambition forced to zero, everything refused (the hard brake).
    r = route(roster, [{"id": "x", "klass": "light"}], spend_cap_reached=True)
    check("spend cap → zero ambition", r["assignments"] == [] and r["unplaceable"][0]["reason"] == "spend_cap")

    # 8) Budget gate: a heavy order is refused on a box that cannot afford it.
    poor = [{"worker": "big-poor", "max_class": "xl", "slots_total": 1, "slots_free": 1, "budget": 5, "last_seen": 0, "ttl_s": 120}]
    r = route(poor, [{"id": "exp", "klass": "heavy"}])  # heavy costs 12 > budget 5
    check("over-budget heavy refused", r["assignments"] == [] and r["unplaceable"][0]["reason"] == "all_capable_busy_or_over_budget")

    # 9) Server field wins: a row the server marked OFFLINE stays excluded even with a FRESH
    #    last_seen (the arithmetic fallback alone would call it online — the computed status must
    #    override). Proves the PDF-D20 preference: one server-side staleness formula, not the client.
    ghost = [{"worker": "ghost", "max_class": "xl", "slots_total": 1, "slots_free": 1,
              "status": "offline", "last_seen": 0, "ttl_s": 900}]
    r = route(ghost, [{"id": "huge", "klass": "xl"}], now=0)  # elapsed 0 << ttl 900, yet server says offline
    check("server status=offline excludes a fresh-last_seen row",
          r["assignments"] == [] and r["unplaceable"] == [{"order": "huge", "reason": "no_capacity_for_class"}])

    print(f"\nROUTER PROOF: {ok}/9 checks passed — best-fit, capacity-, fence-, budget- and cap-aware; server status wins.")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--route":
        payload = json.load(sys.stdin)
        print(json.dumps(route(payload["roster"], payload["orders"],
                               payload.get("now", 0.0), payload.get("spend_cap_reached", False)), indent=2))
    else:
        _selftest()
