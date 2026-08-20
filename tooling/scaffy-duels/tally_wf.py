#!/usr/bin/env python3
"""tally_wf.py — meter a whole workflow's agent transcripts into one $/token tally.

Cost standard: tooling/scaffy-duels/METER.md (the §2 verified formula, TTL-aware
cache-write pricing). Filed under bp task grb-append-e4-e6-scoreboard-rows
(append measured E4/E6 rows to /papers/epic-cycle-research-program-abcde).

Why this exists: a workflow run leaves one agent-*.jsonl transcript per subagent.
Each transcript is a stream of message lines and a streaming partial repeats the
SAME message id on every chunk with a GROWING usage.output_tokens — so naively
summing usage across lines overcounts 2-5x, exactly METER.md's banned move. The
only valid transcript-derived number is deduped by message id (LAST occurrence
wins — the final line for an id carries the complete usage), then priced per
model via the METER.md formula. The envelope's total_cost_usd still wins on any
disagreement; this is a transcript-side estimate, labelled "computed" (tier-3).

Token axis reported is ALL-AXIS (input + output + cache_read + cache_creation
5m/1h) — the same axes the $-cost formula bills, not just fresh prompt tokens.

Formula constants are mirrored from meter.py (not imported, to keep this a
single dependency-free file that can be copied next to a transcript dump). The
mirror is ASSERTED, not trusted: `check_table_parity()` below compares the two
tables whenever meter.py is adjacent, and `meter.py --self-test` runs the same
comparison — so the gate carries it. Before 2026-08-05 the mirror had silently
drifted (no `claude-opus-5` prefix in either table) and an unrated model's
DOLLARS were dropped from the total while its tokens stayed counted, at rc=0.

An unrated model is now a REFUSAL: the JSON still prints (it is the useful
artifact), `total_usd_complete` says false, and the exit code is 1. A tally that
silently omits one model's spend is worse than no tally.

Usage:
    python3 tally_wf.py <workflow-dir>
"""
import json, sys, glob, os

RATES = {
    "claude-fable-5": (10.00, 50.00),
    "claude-opus-5": (5.00, 25.00),
    "claude-opus-4": (5.00, 25.00),
    "claude-sonnet-5": (3.00, 15.00),
    "claude-sonnet-4-6": (3.00, 15.00),
    "claude-haiku-4-5": (1.00, 5.00),
}
W1H, W5M, CREAD = 2.00, 1.25, 0.10


def check_table_parity():
    """Prove the mirror above is identical to meter.py's, when meter.py is adjacent.

    Returns None when they agree or meter.py is absent (this file copied away);
    a message describing the drift otherwise.
    """
    twin = os.path.join(os.path.dirname(os.path.abspath(__file__)), "meter.py")
    if not os.path.exists(twin):
        return None
    import importlib.util

    spec = importlib.util.spec_from_file_location("_tally_twin", twin)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    if mod.RATES != RATES:
        return f"RATES drifted from meter.py: {RATES} != {mod.RATES}"
    if (W1H, W5M, CREAD) != (mod.CACHE_WRITE_1H, mod.CACHE_WRITE_5M, mod.CACHE_READ):
        return (
            f"multipliers drifted from meter.py: {(W1H, W5M, CREAD)} != "
            f"{(mod.CACHE_WRITE_1H, mod.CACHE_WRITE_5M, mod.CACHE_READ)}"
        )
    return None

def rate_for(model):
    for prefix, r in RATES.items():
        if model and model.startswith(prefix):
            return r
    return None

def compute_cost(u, rate):
    rin, rout = rate
    cc = u.get("cache_creation") or {}
    return (
        u.get("input_tokens", 0) * rin
        + u.get("output_tokens", 0) * rout
        + cc.get("ephemeral_5m_input_tokens", 0) * rin * W5M
        + cc.get("ephemeral_1h_input_tokens", 0) * rin * W1H
        + u.get("cache_read_input_tokens", 0) * rin * CREAD
    ) / 1e6

def tally_dir(d):
    seen = {}  # msg_id -> (model, usage) LAST wins (streaming: later line = fuller usage)
    files = sorted(glob.glob(os.path.join(d, "agent-*.jsonl")))
    n_lines = 0
    for f in files:
        with open(f) as fh:
            for line in fh:
                n_lines += 1
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                msg = obj.get("message")
                if not isinstance(msg, dict):
                    continue
                u = msg.get("usage")
                mid = msg.get("id")
                if not u or not mid:
                    continue
                seen[mid] = (msg.get("model"), u)
    total = 0.0
    no_rate = set()
    per_model = {}
    total_tokens = 0
    for mid, (model, u) in seen.items():
        cc = u.get("cache_creation") or {}
        total_tokens += (
            u.get("input_tokens", 0)
            + u.get("output_tokens", 0)
            + u.get("cache_read_input_tokens", 0)
            + cc.get("ephemeral_5m_input_tokens", 0)
            + cc.get("ephemeral_1h_input_tokens", 0)
        )
        rate = rate_for(model)
        if rate is None:
            # Tokens are still counted above, so omitting the dollars here would make
            # total_usd_computed silently disagree with total_tokens_all_axes. Record
            # it; the caller turns it into a non-zero exit.
            no_rate.add(model)
            continue
        c = compute_cost(u, rate)
        total += c
        per_model[model] = per_model.get(model, 0.0) + c
    return {
        "dir": d,
        "n_files": len(files),
        "n_lines_scanned": n_lines,
        "n_unique_msg_ids": len(seen),
        "total_usd_computed": round(total, 4),
        "total_usd_complete": not no_rate,
        "total_tokens_all_axes": total_tokens,
        "per_model_usd": {k: round(v, 4) for k, v in per_model.items()},
        "unrated_models": sorted(m for m in no_rate if m) + ([None] if None in no_rate else []),
    }

if __name__ == "__main__":
    drift = check_table_parity()
    out = tally_dir(sys.argv[1])
    print(json.dumps(out, indent=2))
    rc = 0
    if drift:
        print(f"tally_wf.py: FAIL {drift}", file=sys.stderr)
        rc = 1
    if not out["total_usd_complete"]:
        print(
            f"tally_wf.py: FAIL unrated model(s) {out['unrated_models']} — their tokens are "
            f"counted but their DOLLARS are missing from total_usd_computed="
            f"{out['total_usd_computed']}. Add the rate to RATES (and to meter.py's mirror) "
            f"before quoting this number.",
            file=sys.stderr,
        )
        rc = 1
    sys.exit(rc)
