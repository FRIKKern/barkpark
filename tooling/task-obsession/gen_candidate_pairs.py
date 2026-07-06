#!/usr/bin/env python3
"""Generate candidate task-pairs for dedup judging — the mechanical tier-1 filter.

Pulls every task from the ledger, computes a deterministic similarity for each
ACTIVE task against every other task (active + done), keeps each task's top-K
neighbours, then buckets the resulting pairs:

  auto_distinct   sim <  LO           — obviously unrelated, no judge needed
  gray_zone       LO <= sim < HI      — the judge earns its keep here
  auto_similar    sim >= HI           — near-identical, flag for human review

Only the gray-zone pairs go to the LLM judge (tob-w1-judge-calibration step 2).
This is the "FTS top-k, not O(n^2)" filter from the task-obsession paper, done
with local token+label similarity so it needs no API and is fully reproducible —
the same shape tier-1 (tob-w2-match-in-create) will run inside task.create.

Similarity = 0.7 * Jaccard(title+description tokens) + 0.3 * label overlap.
Directionality: a candidate that is `done` can only be an "already_landed" match
for an active task, never the reverse — recorded so the judge sees it.

Usage:
  python3 gen_candidate_pairs.py --tasks tasks.json --out pairs.json [--k 3] [--lo 0.30] [--hi 0.55]
  (fetch tasks first: see fetch_tasks.sh)
"""
import argparse
import json
import re
import sys

STOP = set("""a an the of to for and or in on at by with from is are be this that
these those it its as into per via not no yes we our you your they their can will
should must task tasks add fix update use make build run new when then than also
each any all one two both only same into onto over under out off up down""".split())

TOKEN_RE = re.compile(r"[a-z0-9]+")


def tokens(text: str) -> set:
    return {t for t in TOKEN_RE.findall((text or "").lower()) if t not in STOP and len(t) > 2}


def jaccard(a: set, b: set) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def norm_id(x: str) -> str:
    # parent_id references the PUBLISHED id (`pdd-m1`) but a draft doc's own id
    # carries a `drafts.` prefix — normalise so chain detection matches.
    return (x or "").removeprefix("drafts.")


def task_fields(t: dict) -> dict:
    # Tolerate both the flattened doc shape and the content-nested shape.
    c = t.get("content") or {}
    get = lambda k: t.get(k) if t.get(k) is not None else c.get(k)
    return {
        "id": t.get("doc_id") or t.get("_id"),
        "nid": norm_id(t.get("doc_id") or t.get("_id")),
        "title": get("title") or "",
        "description": get("description") or "",
        "labels": [str(x) for x in (get("labels") or [])],
        "lifecycle": get("lifecycle_status") or "",
        "parent": norm_id(get("parent_id") or ""),
    }


def similarity(a: dict, b: dict) -> float:
    ta = tokens(a["title"] + " " + a["description"])
    tb = tokens(b["title"] + " " + b["description"])
    la, lb = set(a["labels"]), set(b["labels"])
    return 0.7 * jaccard(ta, tb) + 0.3 * jaccard(la, lb)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tasks", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--k", type=int, default=3, help="top-K neighbours per active task")
    ap.add_argument("--lo", type=float, default=0.30, help="below this = auto-distinct")
    ap.add_argument("--hi", type=float, default=0.55, help="at/above this = auto-similar")
    args = ap.parse_args()

    raw = json.load(open(args.tasks))
    docs = raw.get("docs", raw) if isinstance(raw, dict) else raw
    tasks = [task_fields(t) for t in docs]
    tasks = [t for t in tasks if t["id"]]
    by_id = {t["id"]: t for t in tasks}

    # Parent index (normalised ids) for chain detection.
    parent_of = {t["nid"]: t["parent"] for t in tasks}

    def ancestors(nid: str) -> set:
        out, cur = set(), nid
        for _ in range(6):
            p = parent_of.get(cur, "")
            if not p or p in out:
                break
            out.add(p)
            cur = p
        return out

    def structural_relation(a: dict, b: dict) -> str:
        # Calibrated exclusions (tob-w1-judge-calibration): these lexical matches
        # are benign structure, not duplication.
        if a["parent"] and a["parent"] == b["parent"]:
            return "sibling"          # same-epic decomposition (D1 --sibling-of)
        an, bn = a["nid"], b["nid"]
        if bn in ancestors(an) or an in ancestors(bn):
            return "chain"            # milestone ⊇ step
        if ancestors(an) & ancestors(bn):
            return "chain"            # shared ancestor
        return "cross"

    active = [t for t in tasks if t["lifecycle"] in ("open", "in_progress")]
    # Skip the task-obsession epic's OWN tasks as query anchors: they are
    # intentional siblings (D1 --sibling-of), not accidental dups — including
    # them would just re-flag the epic we just seeded. They remain valid
    # CANDIDATES for other tasks, so keep them in `tasks`.
    epic_siblings = {t["id"] for t in tasks if t["parent"] == "task-obsession-epic"
                     or t["id"] == "task-obsession-epic"}
    anchors = [t for t in active if t["id"] not in epic_siblings]

    # Top-K neighbours per anchor. Dedup pairs by unordered id set.
    seen = set()
    pairs = []
    for a in anchors:
        scored = []
        for b in tasks:
            if b["id"] == a["id"]:
                continue
            s = similarity(a, b)
            if s > 0:
                scored.append((s, b))
        scored.sort(key=lambda x: x[0], reverse=True)
        for s, b in scored[: args.k]:
            key = frozenset((a["id"], b["id"]))
            if key in seen:
                continue
            seen.add(key)
            rel = structural_relation(a, b)
            # Sibling / chain pairs are benign structure — recorded as excluded,
            # never sent to the judge. Only structurally-CROSS pairs bucket by
            # similarity; the judge sees the cross gray-zone residue.
            if rel != "cross":
                bucket = f"structural_{rel}"
            else:
                bucket = "auto_similar" if s >= args.hi else "gray_zone" if s >= args.lo else "auto_distinct"
            pairs.append({
                "a": a["id"], "b": b["id"], "sim": round(s, 4),
                "bucket": bucket, "structural": rel,
                "a_lifecycle": a["lifecycle"], "b_lifecycle": b["lifecycle"],
                "a_title": a["title"], "b_title": b["title"],
            })

    pairs.sort(key=lambda p: p["sim"], reverse=True)
    buckets = {}
    for p in pairs:
        buckets[p["bucket"]] = buckets.get(p["bucket"], 0) + 1

    out = {
        "params": {"k": args.k, "lo": args.lo, "hi": args.hi},
        "corpus": {"total": len(tasks), "active": len(active),
                   "anchors": len(anchors), "epic_siblings_excluded": len(epic_siblings)},
        "bucket_counts": buckets,
        "pairs": pairs,
    }
    json.dump(out, open(args.out, "w"), indent=1)
    print(f"corpus: {len(tasks)} tasks, {len(anchors)} anchors "
          f"(excluded {len(epic_siblings)} epic siblings)", file=sys.stderr)
    print(f"pairs: {len(pairs)}  buckets: {buckets}", file=sys.stderr)
    print(f"gray-zone pairs to judge: {buckets.get('gray_zone', 0)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
