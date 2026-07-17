#!/usr/bin/env python3
"""meter.py — executable half of METER.md: verify cost envelopes against published rates.

Usage:
    meter.py verify <results-dir-or-envelope.json> [...]
    meter.py --self-test

`verify` walks every *.agent.json (or the given envelope files), recomputes cost
from `usage` x the rates table below (TTL-aware cache-write pricing), and fails
unless the result matches the envelope's `total_cost_usd` to <1e-6 relative
error. It also asserts the structural identity sum(modelUsage[*].costUSD) ==
total_cost_usd. A mismatch means rates, service tier, or cache TTL changed —
fix the table (with a source) before publishing any dollar figure.

Honesty (distrust-vacuous-green): --self-test proves the verifier REDS on a
perturbed envelope and GREENS on a faithful one.
"""
import glob
import json
import os
import sys

# $/MTok, standard tier. Source: Anthropic pricing (cached 2026-06; re-verify
# via platform.claude.com/docs/en/pricing when a mismatch appears).
RATES = {
    "claude-fable-5": (10.00, 50.00),
    "claude-opus-4": (5.00, 25.00),
    "claude-sonnet-5": (3.00, 15.00),
    "claude-sonnet-4-6": (3.00, 15.00),
    "claude-haiku-4-5": (1.00, 5.00),
}
CACHE_WRITE_5M = 1.25
CACHE_WRITE_1H = 2.00
CACHE_READ = 0.10
REL_TOL = 1e-6


def rate_for(model):
    for prefix, r in RATES.items():
        if model.startswith(prefix):
            return r
    return None


def compute_cost(usage, rate):
    """The METER.md §2 formula. usage is the envelope's top-level `usage` object."""
    rate_in, rate_out = rate
    cc = usage.get("cache_creation") or {}
    w1h = cc.get("ephemeral_1h_input_tokens", 0)
    w5m = cc.get("ephemeral_5m_input_tokens", 0)
    if not cc and usage.get("cache_creation_input_tokens"):
        # No TTL split available: cannot verify exactly. Caller treats None as skip.
        return None
    return (
        usage.get("input_tokens", 0) * rate_in
        + usage.get("output_tokens", 0) * rate_out
        + w5m * rate_in * CACHE_WRITE_5M
        + w1h * rate_in * CACHE_WRITE_1H
        + usage.get("cache_read_input_tokens", 0) * rate_in * CACHE_READ
    ) / 1e6


def verify_envelope(path, errs):
    name = os.path.basename(path)
    try:
        env = json.load(open(path))
    except Exception as e:  # noqa: BLE001
        errs.append(f"{name}: unreadable ({e})")
        return "error"
    reported = env.get("total_cost_usd")
    usage = env.get("usage")
    mu = env.get("modelUsage") or {}
    if reported is None or usage is None:
        errs.append(f"{name}: missing total_cost_usd or usage — not a CLI envelope")
        return "error"

    # Structural identity: per-model costUSD must sum to the total.
    if mu:
        s = sum(m.get("costUSD", 0.0) for m in mu.values())
        if abs(s - reported) > max(1e-9, abs(reported) * REL_TOL):
            errs.append(f"{name}: sum(modelUsage.costUSD)={s:.6f} != total_cost_usd={reported:.6f}")
            return "mismatch"

    if len(mu) != 1:
        # Multi-model or modelUsage-less envelope: the TTL split is only top-level,
        # so a per-model recompute is not possible. Identity check above stands.
        return "identity-only"

    model = next(iter(mu))
    rate = rate_for(model)
    if rate is None:
        errs.append(f"{name}: no rate registered for model {model} — update RATES")
        return "mismatch"
    computed = compute_cost(usage, rate)
    if computed is None:
        return "no-ttl-split"
    rel = abs(computed - reported) / reported if reported else abs(computed)
    if rel > REL_TOL:
        errs.append(
            f"{name}: computed ${computed:.6f} != reported ${reported:.6f} "
            f"(rel {rel * 100:.2f}%) — rates/tier/TTL drift?"
        )
        return "mismatch"
    return "exact"


def cmd_verify(paths):
    files = []
    for p in paths:
        if os.path.isdir(p):
            files.extend(sorted(glob.glob(os.path.join(p, "*.agent.json"))))
        else:
            files.append(p)
    if not files:
        print("meter.py: no envelopes found", file=sys.stderr)
        return 1
    errs = []
    counts = {}
    for f in files:
        outcome = verify_envelope(f, errs)
        counts[outcome] = counts.get(outcome, 0) + 1
    total = len(files)
    summary = ", ".join(f"{v} {k}" for k, v in sorted(counts.items()))
    print(f"meter.py: {total} envelopes — {summary}")
    for e in errs:
        print(f"  FAIL {e}", file=sys.stderr)
    return 1 if errs else 0


def _fixture(cost_usd):
    return {
        "total_cost_usd": cost_usd,
        "usage": {
            "input_tokens": 16,
            "output_tokens": 1478,
            "cache_read_input_tokens": 567141,
            "cache_creation_input_tokens": 61828,
            "cache_creation": {
                "ephemeral_1h_input_tokens": 61828,
                "ephemeral_5m_input_tokens": 0,
            },
        },
        "modelUsage": {"claude-sonnet-5": {"costUSD": cost_usd}},
    }


def cmd_self_test():
    import tempfile

    # The fixture's exact cost under the formula (Sonnet 5, all-1h writes).
    good_cost = (16 * 3 + 1478 * 15 + 61828 * 3 * 2.0 + 567141 * 3 * 0.1) / 1e6
    with tempfile.TemporaryDirectory() as d:
        good = os.path.join(d, "good.agent.json")
        bad = os.path.join(d, "bad.agent.json")
        json.dump(_fixture(good_cost), open(good, "w"))
        # Perturbed: the 1.25x-assumption trap — must RED.
        bad_cost = (16 * 3 + 1478 * 15 + 61828 * 3 * 1.25 + 567141 * 3 * 0.1) / 1e6
        json.dump(_fixture(bad_cost), open(bad, "w"))
        errs = []
        assert verify_envelope(good, errs) == "exact" and not errs, f"good fixture failed: {errs}"
        assert verify_envelope(bad, errs) == "mismatch" and errs, "bad fixture passed — verifier is vacuous"
    print("meter.py: self-test OK (greens on faithful, reds on 1.25x-trap fixture)")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["--self-test"]:
        sys.exit(cmd_self_test())
    if args[:1] == ["verify"] and len(args) > 1:
        sys.exit(cmd_verify(args[1:]))
    print(__doc__, file=sys.stderr)
    sys.exit(2)
