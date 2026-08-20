#!/usr/bin/env python3
"""meter.py — executable half of METER.md: verify cost envelopes against published rates.

Usage:
    meter.py verify <results-dir-or-envelope.json> [...]
    meter.py --self-test            (alias: meter.py self-test)

`verify` walks every *.agent.json under the given paths (recursively), recomputes
cost from `usage` x the rates table below (TTL-aware cache-write pricing), and
fails unless the result matches the envelope's `total_cost_usd` to <1e-6 relative
error. It also asserts the structural identity sum(modelUsage[*].costUSD) ==
total_cost_usd. A mismatch means rates, service tier, or cache TTL changed —
fix the table (with a source) before publishing any dollar figure.

Three things are carried by the EXIT CODE, not by prose a human has to read:

1. EVERY envelope must be `exact`. An envelope this tool cannot recompute from a
   measurement — multi-model (the TTL split is only top-level), `modelUsage`
   absent, an unregistered model — is a REFUSAL, not a pass. METER.md §4 always
   said "must print all-exact"; before 2026-08-05 the rule lived in prose while
   rc was 0.
2. The walked population must equal the figure METER.md publishes (the
   `<!-- meter:population N -->` marker and the §2 prose literal, which must
   themselves agree). This is asserted only for the canonical `results/` corpus
   next to this file; an ad-hoc directory has no published figure.
3. The rate table in tally_wf.py — a deliberate mirror, so that file stays a
   single copyable dependency-free script — must be byte-identical to this one.
   Asserted by --self-test, so the gate carries it.

Honesty (distrust-vacuous-green): --self-test proves the verifier REDS on a
perturbed envelope and GREENS on a faithful one.
"""
import glob
import json
import os
import re
import sys

# $/MTok, standard tier. Source: Anthropic pricing (cached 2026-08; re-verify
# via platform.claude.com/docs/en/pricing when a mismatch appears).
RATES = {
    "claude-fable-5": (10.00, 50.00),
    "claude-opus-5": (5.00, 25.00),
    "claude-opus-4": (5.00, 25.00),
    "claude-sonnet-5": (3.00, 15.00),
    "claude-sonnet-4-6": (3.00, 15.00),
    "claude-haiku-4-5": (1.00, 5.00),
}
CACHE_WRITE_5M = 1.25
CACHE_WRITE_1H = 2.00
CACHE_READ = 0.10
REL_TOL = 1e-6

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS_DIR = os.path.join(HERE, "results")
METER_DOC = os.path.join(HERE, "METER.md")

# The doc's published population, in both the places it appears. Both must agree
# with each other AND with what verify actually walked.
POP_MARKER_RE = re.compile(r"<!--\s*meter:population\s+(\d+)\s*-->")
POP_PROSE_RE = re.compile(r"on\s+(\d+)/(\d+)\*\*\s+recorded duel envelopes")


def rate_for(model):
    for prefix, r in RATES.items():
        if model and model.startswith(prefix):
            return r
    return None


def compute_cost(usage, rate):
    """The METER.md §2 formula. usage is the envelope's top-level `usage` object."""
    rate_in, rate_out = rate
    cc = usage.get("cache_creation") or {}
    w1h = cc.get("ephemeral_1h_input_tokens", 0)
    w5m = cc.get("ephemeral_5m_input_tokens", 0)
    if not cc and usage.get("cache_creation_input_tokens"):
        # No TTL split available: cannot verify exactly. Caller treats None as a refusal.
        return None
    return (
        usage.get("input_tokens", 0) * rate_in
        + usage.get("output_tokens", 0) * rate_out
        + w5m * rate_in * CACHE_WRITE_5M
        + w1h * rate_in * CACHE_WRITE_1H
        + usage.get("cache_read_input_tokens", 0) * rate_in * CACHE_READ
    ) / 1e6


def declared_population(path=METER_DOC):
    """(n, error). The population METER.md publishes, or (None, why) if it does not."""
    try:
        doc = open(path).read()
    except OSError as e:  # noqa: BLE001
        return None, f"cannot read {os.path.basename(path)} ({e})"
    marker = POP_MARKER_RE.search(doc)
    prose = POP_PROSE_RE.search(doc)
    if not marker:
        return None, "METER.md publishes no `<!-- meter:population N -->` marker"
    if not prose:
        return None, "METER.md §2 publishes no `on N/N** recorded duel envelopes` literal"
    n_marker = int(marker.group(1))
    n_prose, n_exact = int(prose.group(1)), int(prose.group(2))
    if n_prose != n_exact:
        return None, f"METER.md §2 claims {n_prose}/{n_exact} — the doc does not claim all-exact"
    if n_marker != n_prose:
        return None, (
            f"METER.md disagrees with itself: marker says {n_marker}, "
            f"§2 prose says {n_prose} — the doc's own population is not one number"
        )
    return n_marker, None


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

    if not mu:
        # The identity above is unassertable and there is no model to price with.
        # Nothing here descends from a measurement — refuse rather than pass.
        errs.append(
            f"{name}: no modelUsage — total_cost_usd=${reported:.6f} is unverifiable "
            f"(no model to price with, identity sum unassertable)"
        )
        return "no-model-usage"

    if len(mu) != 1:
        # The TTL split is only recorded top-level, so a per-model recompute is not
        # possible from this envelope. The identity check alone cannot detect a
        # uniformly-scaled total, so passing here would assert what was never measured.
        errs.append(
            f"{name}: multi-model envelope ({', '.join(sorted(mu))}) — the cache-write "
            f"TTL split is only top-level, so per-model cost is not derivable; refusing"
        )
        return "multi-model"

    model = next(iter(mu))
    rate = rate_for(model)
    if rate is None:
        errs.append(f"{name}: no rate registered for model {model} — update RATES")
        return "mismatch"
    computed = compute_cost(usage, rate)
    if computed is None:
        errs.append(
            f"{name}: cache_creation_input_tokens with no TTL split — the 1.25x/2.00x "
            f"choice would be an assumption, not a measurement; refusing"
        )
        return "no-ttl-split"
    rel = abs(computed - reported) / reported if reported else abs(computed)
    if rel > REL_TOL:
        errs.append(
            f"{name}: computed ${computed:.6f} != reported ${reported:.6f} "
            f"(rel {rel * 100:.2f}%) — rates/tier/TTL drift?"
        )
        return "mismatch"
    return "exact"


def _collect(paths):
    """Every *.agent.json under `paths`, recursively, plus the dirs that were walked."""
    files, walked_dirs = [], []
    for p in paths:
        if os.path.isdir(p):
            walked_dirs.append(os.path.realpath(p))
            files.extend(sorted(glob.glob(os.path.join(p, "**", "*.agent.json"), recursive=True)))
        else:
            files.append(p)
    return files, walked_dirs


def cmd_verify(paths):
    files, walked_dirs = _collect(paths)
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

    # The population assertion: only the canonical corpus has a published figure.
    #
    # IT IS KEYED TO THE CORPUS, NOT TO THE ARGUMENT. Matching `walked_dirs`
    # against CORPUS_DIR exactly was a fail-open the assertion itself
    # introduced: `verify tooling/scaffy-duels/` walks the same 34 envelopes
    # recursively, and the drift check silently did not apply — a CI job wired
    # to the parent path would have carried the gate's name and none of its
    # force. So the trigger is "did this run cover the corpus", and the COUNT
    # asserted is the corpus's own, taken independently of what was asked for.
    if os.path.isdir(CORPUS_DIR) and any(
        d == os.path.realpath(CORPUS_DIR) or os.path.realpath(CORPUS_DIR).startswith(d + os.sep)
        for d in walked_dirs
    ):
        corpus_files, _ = _collect([CORPUS_DIR])
        n_corpus = len(corpus_files)
        declared, why = declared_population()
        if declared is None:
            errs.append(f"population unassertable: {why}")
        elif declared != n_corpus:
            errs.append(
                f"population drift: the corpus holds {n_corpus} envelopes, METER.md publishes "
                f"{declared} (delta {n_corpus - declared:+d}) — the doc's figures were computed "
                f"over a different corpus than the one on disk"
            )
        else:
            print(f"meter.py: population {n_corpus} — matches METER.md")

    if counts.get("exact", 0) != total:
        errs.append(
            f"not all-exact: {total - counts.get('exact', 0)} of {total} envelopes were not "
            f"recomputed from a measurement (METER.md §4: a single non-exact blocks publication)"
        )

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


def _assert_tally_table_parity():
    """tally_wf.py mirrors this rate table by design — prove the mirror has not drifted.

    The mirror exists so tally_wf.py stays a single dependency-free file that can be
    copied next to a transcript dump. That is a real constraint, so the fix for a
    duplicated table is not to delete it — it is to make the duplication assertable.
    """
    twin = os.path.join(HERE, "tally_wf.py")
    if not os.path.exists(twin):
        return "tally_wf.py not adjacent — parity unasserted"
    import importlib.util

    spec = importlib.util.spec_from_file_location("_meter_twin", twin)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    assert mod.RATES == RATES, f"tally_wf.py RATES drifted from meter.py: {mod.RATES} != {RATES}"
    assert (mod.W1H, mod.W5M, mod.CREAD) == (CACHE_WRITE_1H, CACHE_WRITE_5M, CACHE_READ), (
        f"tally_wf.py multipliers drifted: {(mod.W1H, mod.W5M, mod.CREAD)} != "
        f"{(CACHE_WRITE_1H, CACHE_WRITE_5M, CACHE_READ)}"
    )
    return f"tally_wf.py mirror identical ({len(RATES)} rates)"


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

        # The three fail-open paths closed 2026-08-05 (PDS wave 48). Each was
        # mutation-proven to return rc=0 before; each must be non-exact now.
        two_model = _fixture(good_cost * 3)
        two_model["modelUsage"] = {
            "claude-sonnet-5": {"costUSD": good_cost},
            "some-unreleased-model": {"costUSD": good_cost * 2},
        }
        no_mu = _fixture(good_cost * 10)
        no_mu.pop("modelUsage")
        for name, env, want in (
            ("two-model", two_model, "multi-model"),
            ("no-modelUsage", no_mu, "no-model-usage"),
        ):
            p = os.path.join(d, f"{name}.agent.json")
            json.dump(env, open(p, "w"))
            e2 = []
            got = verify_envelope(p, e2)
            assert got == want and e2, f"{name} fixture returned {got!r} with errs={e2} — still fails open"

        # The one-level glob: an envelope a directory deeper must be walked.
        nested = os.path.join(d, "nest", "deeper")
        os.makedirs(nested)
        json.dump(_fixture(good_cost), open(os.path.join(nested, "n.agent.json"), "w"))
        found, _ = _collect([d])
        assert any("deeper" in f for f in found), "nested envelope not walked — glob is still one level"

        # An unregistered model must refuse, not fall through to some other rate.
        assert rate_for("some-unreleased-model") is None, "unknown model resolved to a rate"
        assert rate_for("claude-opus-5") == (5.00, 25.00), "claude-opus-5 is unrated"

        # The doc must publish one self-consistent population.
        n, why = declared_population()
        assert n is not None, f"METER.md publishes no assertable population: {why}"

    # THE POPULATION ASSERTION MUST FIRE FROM AN ANCESTOR PATH TOO. Keying it to
    # an exact CORPUS_DIR argument was a fail-open: `verify tooling/scaffy-duels/`
    # walks the same envelopes and the drift check quietly did not apply, so a CI
    # job wired to the parent would have carried the gate's name and none of its
    # force. Proven by RUNNING both paths, not by reading the condition.
    if os.path.isdir(CORPUS_DIR):
        import io
        import contextlib

        for label, arg in (("corpus", CORPUS_DIR), ("ancestor", HERE)):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = cmd_verify([arg])
            out = buf.getvalue()
            assert rc == 0, f"{label} path did not verify clean: {out}"
            assert "matches METER.md" in out, (
                f"the population assertion did NOT fire when verify was given the {label} "
                f"path ({arg}) — that is the fail-open, back:\n{out}"
            )

    parity = _assert_tally_table_parity()
    print(
        "meter.py: self-test OK (greens on faithful, reds on 1.25x-trap fixture; "
        "two-model / modelUsage-less / nested-envelope paths all refuse; "
        "the population assertion fires from the corpus path AND an ancestor; "
        f"METER.md declares {n}; {parity})"
    )
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] in (["--self-test"], ["self-test"]):
        sys.exit(cmd_self_test())
    if args[:1] == ["verify"]:
        if len(args) > 1:
            sys.exit(cmd_verify(args[1:]))
        # Naming it "unknown command 'verify'" would send the reader hunting for
        # a verb that exists; the fault is the missing path.
        print("meter.py: `verify` needs at least one path", file=sys.stderr)
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    if args:
        print(f"meter.py: unknown command {args[0]!r} — expected `verify <path>` or `--self-test`", file=sys.stderr)
    print(__doc__, file=sys.stderr)
    sys.exit(2)
