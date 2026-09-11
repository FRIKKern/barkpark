#!/usr/bin/env python3
"""meter.py — executable half of METER.md: verify cost envelopes against published rates.

Usage:
    meter.py verify <results-dir-or-envelope.json> [...]
    meter.py shares [<results-dir>]  (re-takes the §3 dollar figures)
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

4. The §3 dollar figures must be RE-TAKEN, not remembered. `shares` recomputes the
   corpus total, the by-dollar component shares, the median envelope cost and the
   median component shares straight from the envelopes; `verify` asserts METER.md
   §3's published literals against that recompute whenever the run covers the
   canonical corpus. Before 2026-09-11 those figures were hand-computed literals
   with no re-taker: adding an envelope and bumping the population markers left
   §3 untouched at rc=0.

Honesty (distrust-vacuous-green): --self-test proves the verifier REDS on a
perturbed envelope and GREENS on a faithful one — and it never prints an arm it
did not run. A missing `results/` corpus or a missing `tally_wf.py` twin is a
REFUSAL here, not a skipped arm with a banner that claims it fired.
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


def in_repo_checkout(start=None):
    """Is meter.py running from inside a git checkout (as opposed to a copied-out tree)?

    Used to tell a DELETION from a legitimate copy-away. Inside a checkout every file
    this instrument asserts against — the corpus, the doc, the mirrored twin — is
    committed next to it, so an absence is a broken tree, not a supported mode.
    """
    d = start or HERE
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return True
        parent = os.path.dirname(d)
        if parent == d:
            return False
        d = parent


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


COMPONENTS = ("cache writes", "cache reads", "output tokens", "fresh input")

# §3's own row labels, with the bolding stripped.
DOC_ROW_LABELS = {
    "cache writes": "cache writes",
    "cache reads": "cache reads",
    "output tokens": "output tokens",
    "fresh input": "fresh input",
}


def split_cost(usage, rate):
    """The §2 formula, kept apart by component. None when the TTL split is absent."""
    rate_in, rate_out = rate
    cc = usage.get("cache_creation") or {}
    if not cc and usage.get("cache_creation_input_tokens"):
        return None
    return {
        "cache writes": (
            cc.get("ephemeral_5m_input_tokens", 0) * rate_in * CACHE_WRITE_5M
            + cc.get("ephemeral_1h_input_tokens", 0) * rate_in * CACHE_WRITE_1H
        ) / 1e6,
        "cache reads": usage.get("cache_read_input_tokens", 0) * rate_in * CACHE_READ / 1e6,
        "output tokens": usage.get("output_tokens", 0) * rate_out / 1e6,
        "fresh input": usage.get("input_tokens", 0) * rate_in / 1e6,
    }


def corpus_shares(files):
    """(stats, error). The §3 statistics, re-taken from `files`.

    Every figure §3 publishes for a population comes from here: the corpus total,
    the by-dollar component shares, the median envelope cost and the median
    per-envelope component shares. A file this cannot decompose is an error, not a
    skipped row — a share computed over a subset is a number nothing measured.
    """
    import statistics

    totals = {c: 0.0 for c in COMPONENTS}
    per_envelope, costs = [], []
    for f in files:
        name = os.path.basename(f)
        try:
            env = json.load(open(f))
        except Exception as e:  # noqa: BLE001
            return None, f"{name}: unreadable ({e})"
        usage, mu = env.get("usage"), env.get("modelUsage") or {}
        if usage is None or len(mu) != 1:
            return None, f"{name}: not a single-model CLI envelope — shares are not derivable"
        rate = rate_for(next(iter(mu)))
        if rate is None:
            return None, f"{name}: no rate registered for model {next(iter(mu))} — update RATES"
        parts = split_cost(usage, rate)
        if parts is None:
            return None, f"{name}: cache_creation_input_tokens with no TTL split — refusing"
        cost = sum(parts.values())
        if cost <= 0:
            return None, f"{name}: recomputed cost is {cost} — cannot take a share of it"
        for c in COMPONENTS:
            totals[c] += parts[c]
        costs.append(cost)
        per_envelope.append({c: parts[c] / cost * 100.0 for c in COMPONENTS})
    if not costs:
        return None, "no envelopes — nothing to take a share of"
    grand = sum(totals.values())
    return {
        "n": len(costs),
        "total_usd": grand,
        "dollar_share": {c: totals[c] / grand * 100.0 for c in COMPONENTS},
        "median_cost_usd": statistics.median(costs),
        "median_share": {
            c: statistics.median([e[c] for e in per_envelope]) for c in COMPONENTS
        },
    }, None


def _doc_tables(doc):
    """Every markdown table in `doc`, as a list of rows of stripped cells."""
    tables, cur = [], []
    for line in doc.splitlines():
        if line.lstrip().startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if not all(set(c) <= set("-: ") and c for c in cells):
                cur.append(cells)
        elif cur:
            tables.append(cur)
            cur = []
    if cur:
        tables.append(cur)
    return tables


def _cell_matches(cell, value):
    """Does §3's published cell agree with the re-taken `value` (a percentage)?"""
    cell = cell.replace("**", "").strip()
    if cell.startswith("~0"):
        return value < 0.05
    return cell == f"{value:.1f}%"


DOC_TOTAL_RE = re.compile(r"by dollars,\s*n=(\d+)\s*\(\$([\d.]+)\)")
DOC_MEDIAN_COST_RE = re.compile(r"\$([\d.]+)\s*\(n=(\d+)\)")


def assert_published_shares(stats, path=METER_DOC):
    """Errors where METER.md §3's literals disagree with the re-taken statistics.

    §3 used to be four hand-computed dollar literals and eight percentages with no
    re-taker in the repo: MUT_E (add a 35th envelope, bump both population markers,
    leave §3 alone) returned rc=0. This is the re-taker.
    """
    n = stats["n"]
    try:
        doc = open(path).read()
    except OSError as e:  # noqa: BLE001
        return [f"cannot read {os.path.basename(path)} ({e})"]
    errs = []

    totals = {int(m.group(1)): m.group(2) for m in DOC_TOTAL_RE.finditer(doc)}
    if n not in totals:
        errs.append(
            f"METER.md §3 publishes no `by dollars, n={n} ($X)` column — the corpus holds "
            f"{n} envelopes and the doc's dollar columns are for n={sorted(totals) or 'none'}"
        )
    elif totals[n] != f"{stats['total_usd']:.2f}":
        errs.append(
            f"§3 dollar total drift: the corpus totals ${stats['total_usd']:.4f} "
            f"(prints as ${stats['total_usd']:.2f}), METER.md §3 publishes ${totals[n]} for n={n}"
        )

    medians = {int(m.group(2)): m.group(1) for m in DOC_MEDIAN_COST_RE.finditer(doc)}
    if n not in medians:
        errs.append(f"METER.md §3 publishes no `$X (n={n})` median envelope cost")
    elif medians[n] != f"{stats['median_cost_usd']:.4f}":
        errs.append(
            f"§3 median-cost drift: the corpus median is ${stats['median_cost_usd']:.4f}, "
            f"METER.md §3 publishes ${medians[n]} for n={n}"
        )

    want_cols = {
        f"by dollars, n={n}": ("dollar_share", f"by dollars, n={n}"),
        f"median share, n={n}": ("median_share", f"median share, n={n}"),
    }
    for header_key, (stat_key, label) in want_cols.items():
        col = None
        for table in _doc_tables(doc):
            head = table[0]
            for i, cell in enumerate(head):
                if cell.startswith(header_key):
                    col, rows = i, table[1:]
                    break
            if col is not None:
                break
        if col is None:
            errs.append(f"METER.md §3 publishes no `{label}` column to assert against")
            continue
        by_label = {r[0].replace("**", "").strip(): r for r in rows if len(r) > col}
        for comp in COMPONENTS:
            row = by_label.get(DOC_ROW_LABELS[comp])
            if row is None:
                errs.append(f"METER.md §3 `{label}` has no `{comp}` row")
                continue
            if not _cell_matches(row[col], stats[stat_key][comp]):
                errs.append(
                    f"§3 share drift [{label} / {comp}]: re-taken "
                    f"{stats[stat_key][comp]:.1f}%, METER.md publishes "
                    f"{row[col].replace('**', '').strip()}"
                )
    return errs


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

        # THE §3 FIGURES ARE RE-TAKEN, NOT REMEMBERED. The population marker forces
        # a doc TOUCH when the corpus grows; it does not force the DOLLARS to move.
        # MUT_E (add a 35th envelope, bump both markers, leave §3) returned rc=0.
        stats, why_stats = corpus_shares(corpus_files)
        if stats is None:
            errs.append(f"§3 figures unassertable: {why_stats}")
        else:
            share_errs = assert_published_shares(stats)
            errs.extend(share_errs)
            if not share_errs:
                print(
                    f"meter.py: §3 re-taken — corpus totals ${stats['total_usd']:.4f}, "
                    f"median ${stats['median_cost_usd']:.4f}, shares by dollars "
                    + " / ".join(
                        f"{c.split()[-1]} {stats['dollar_share'][c]:.1f}%" for c in COMPONENTS
                    )
                    + " — all match METER.md §3"
                )

    if counts.get("exact", 0) != total:
        errs.append(
            f"not all-exact: {total - counts.get('exact', 0)} of {total} envelopes were not "
            f"recomputed from a measurement (METER.md §4: a single non-exact blocks publication)"
        )

    for e in errs:
        print(f"  FAIL {e}", file=sys.stderr)
    return 1 if errs else 0


def cmd_shares(paths):
    """Emit the §3 statistics from the envelopes themselves. The re-taker."""
    files, _ = _collect(paths or [CORPUS_DIR])
    if not files:
        print("meter.py: no envelopes found", file=sys.stderr)
        return 1
    stats, why = corpus_shares(files)
    if stats is None:
        print(f"meter.py: cannot take shares — {why}", file=sys.stderr)
        return 1
    n = stats["n"]
    print(f"meter.py: shares over {n} envelopes")
    print(f"  corpus total          ${stats['total_usd']:.4f}")
    print(f"  median envelope cost  ${stats['median_cost_usd']:.4f}")
    print(f"  {'component':<16}{'by dollars':>12}{'median share':>15}")
    for c in COMPONENTS:
        print(
            f"  {c:<16}{stats['dollar_share'][c]:>11.1f}%{stats['median_share'][c]:>14.1f}%"
        )
    if os.path.realpath(files[0]).startswith(os.path.realpath(CORPUS_DIR) + os.sep):
        errs = assert_published_shares(stats)
        for e in errs:
            print(f"  FAIL {e}", file=sys.stderr)
        if errs:
            return 1
        print(f"  METER.md §3 agrees with this re-take (n={n})")
    return 0


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
        # THE TWIN-ABSENT FAIL-OPEN. "not adjacent — parity unasserted" at rc=0 made
        # an in-repo deletion and a legitimate copy-away indistinguishable to the exit
        # code. The copy-away constraint is about tally_wf.py travelling, not about
        # meter.py running outside its checkout — so inside a checkout, absence is a
        # deletion and a refusal. Outside one, the arm is named as NOT RUN.
        if in_repo_checkout():
            raise AssertionError(
                "tally_wf.py is not adjacent to meter.py, but meter.py is running from a "
                "git checkout — the twin is committed here, so this is a deletion, not a "
                "copy-away. The mirrored rate table is unasserted; refusing."
            )
        return None
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
    # THE CORPUS-ABSENT FAIL-OPEN. This whole arm used to sit behind a bare
    # `if os.path.isdir(CORPUS_DIR)` while the banner below printed "the population
    # assertion fires from the corpus path AND an ancestor" regardless — a receipt
    # naming a measurement it did not take. The corpus is committed data of record
    # next to this file, so inside a checkout its absence is a broken tree.
    arms = []
    if not os.path.isdir(CORPUS_DIR):
        if in_repo_checkout():
            print(
                f"meter.py: self-test REFUSED — the canonical corpus {CORPUS_DIR} is absent "
                f"but meter.py is running from a git checkout, where results/ is committed "
                f"data of record. The population and §3 arms cannot run; a pass here would "
                f"assert two measurements that were never taken.",
                file=sys.stderr,
            )
            return 1
    else:
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
                assert "§3 re-taken" in out, (
                    f"the §3 share assertion did NOT fire when verify was given the {label} "
                    f"path ({arg}) — the dollars would be unmoored literals again:\n{out}"
                )
        arms.append("the population AND §3 assertions fire from the corpus path AND an ancestor")

        # MUT_E, taken not remembered: the §3 assertion must RED on a corpus that
        # grew, even when both population markers were dutifully bumped.
        with tempfile.TemporaryDirectory() as d:
            grown = os.path.join(d, "results")
            import shutil

            shutil.copytree(CORPUS_DIR, grown)
            seed = sorted(glob.glob(os.path.join(grown, "*.agent.json")))[0]
            extra = json.load(open(seed))
            json.dump(extra, open(os.path.join(grown, "zz-mut-e.agent.json"), "w"))
            grown_files, _ = _collect([grown])
            grown_stats, why_g = corpus_shares(grown_files)
            assert grown_stats is not None, f"MUT_E control could not be measured: {why_g}"
            assert assert_published_shares(grown_stats), (
                "MUT_E: a 35th envelope left METER.md §3 assertable — the dollars are "
                "still frozen literals with no re-taker"
            )
        arms.append("MUT_E: a grown corpus reds §3 even with the population markers bumped")

    parity = _assert_tally_table_parity()
    arms.append(parity if parity else "tally_wf.py NOT adjacent — the mirror arm did NOT run")
    arms.append(f"METER.md declares {n}")
    print(
        "meter.py: self-test OK (greens on faithful, reds on 1.25x-trap fixture; "
        "two-model / modelUsage-less / nested-envelope paths all refuse; "
        + "; ".join(arms)
        + ")"
    )
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] in (["--self-test"], ["self-test"]):
        sys.exit(cmd_self_test())
    if args[:1] == ["shares"]:
        sys.exit(cmd_shares(args[1:]))
    if args[:1] == ["verify"]:
        if len(args) > 1:
            sys.exit(cmd_verify(args[1:]))
        # Naming it "unknown command 'verify'" would send the reader hunting for
        # a verb that exists; the fault is the missing path.
        print("meter.py: `verify` needs at least one path", file=sys.stderr)
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    if args:
        print(f"meter.py: unknown command {args[0]!r} — expected `verify <path>`, `shares [path]` or `--self-test`", file=sys.stderr)
    print(__doc__, file=sys.stderr)
    sys.exit(2)
