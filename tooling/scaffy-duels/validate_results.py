#!/usr/bin/env python3
"""validate_results.py — gate the duel results dir for completeness and honesty.

Usage:
    validate_results.py <results-dir> [--matrix matrix.json] [--cells id1,id2,...]
    validate_results.py --self-test

The results dir is VALID only when EVERY expected cell has a result file whose
meter + score fields are complete, whose spend respects its cap, and whose runs
form a non-overlapping (serial) timeline. Exits 0 clean, nonzero on ANY gap.

Expected cells:
  * default    -> the registered matrix (matrix.json `cells[]`), and each file's
                  cap_usd must equal the registered cap (catches mis-registration).
  * --cells    -> exactly the given ids (arm/cap read from each file); used for the
                  smoke cell, which is not a registered matrix rep.

Honesty (distrust-vacuous-green): `--self-test` proves the validator REDS on an
incomplete / meter-less / over-cap / non-serial fixture and GREENS on a complete
one. A validator that only ever greens is worthless.
"""
import argparse
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
LLM_ARMS = {"A", "Ap", "B"}


def _fail(errs, msg):
    errs.append(msg)


def validate_cell_file(path, expected_cap, cross_check_cap, errs):
    """Validate one cell result file. expected_cap used only when cross_check_cap."""
    if not os.path.isfile(path):
        _fail(errs, f"missing result file: {os.path.basename(path)}")
        return
    try:
        r = json.load(open(path))
    except Exception as e:  # noqa: BLE001
        _fail(errs, f"{os.path.basename(path)}: not valid JSON ({e})")
        return

    cell = r.get("cell", os.path.basename(path))
    arm = r.get("arm")

    # meter completeness (D66)
    meter = r.get("meter")
    if not isinstance(meter, dict):
        _fail(errs, f"{cell}: meter object missing")
        return
    if "total_cost_usd" not in meter:
        _fail(errs, f"{cell}: meter.total_cost_usd missing")
    if "usage" not in meter:
        _fail(errs, f"{cell}: meter.usage key missing")
    cost = meter.get("total_cost_usd")
    if arm in LLM_ARMS:
        if cost is None:
            _fail(errs, f"{cell}: LLM arm has null total_cost_usd (meter not captured)")
        if not isinstance(meter.get("usage"), dict):
            _fail(errs, f"{cell}: LLM arm has no usage object (naive JSONL sum? meter law D66)")
    elif arm == "C":
        if cost not in (0, 0.0):
            _fail(errs, f"{cell}: engine arm C must have total_cost_usd 0, got {cost}")

    # cap respected
    cap = r.get("cap_usd")
    if cap is None:
        _fail(errs, f"{cell}: cap_usd missing")
    else:
        if cross_check_cap and expected_cap is not None and float(cap) != float(expected_cap):
            _fail(errs, f"{cell}: cap_usd {cap} != registered {expected_cap}")
        if isinstance(cost, (int, float)) and float(cost) > float(cap):
            _fail(errs, f"{cell}: spend ${cost} exceeds cap ${cap}")

    # score completeness (D67/D68)
    score = r.get("score")
    if not isinstance(score, dict):
        _fail(errs, f"{cell}: score object missing")
        return
    for k, typ in (("gates_green", bool), ("reversible", bool), ("diff_sha256", str)):
        if k not in score:
            _fail(errs, f"{cell}: score.{k} missing")
        elif not isinstance(score[k], typ):
            _fail(errs, f"{cell}: score.{k} wrong type")
    if isinstance(score.get("diff_sha256"), str) and not score["diff_sha256"]:
        _fail(errs, f"{cell}: score.diff_sha256 empty")
    # An LLM-arm cell is never green by trust: a mechanical check (agent_gate or a
    # force-run TIER-ci gate) must have actually run (distrust-vacuous-green).
    if arm in LLM_ARMS and score.get("gates_green") is True:
        checks = (score.get("agent_gate") or []) + (score.get("tier_ci_forced") or [])
        if not checks:
            _fail(errs, f"{cell}: gates_green with ZERO mechanical checks recorded (vacuous green)")


def check_serial(runlog_path, expected_ids, errs):
    """Every expected cell has a run record; records do not overlap (serial, D66)."""
    if not os.path.isfile(runlog_path):
        _fail(errs, "RUNLOG.jsonl missing (no serial-execution proof)")
        return
    records = []
    for line in open(runlog_path):
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except Exception:  # noqa: BLE001
            _fail(errs, "RUNLOG.jsonl has a non-JSON line")
            return
    logged = {rec.get("cell") for rec in records}
    for cid in expected_ids:
        if cid not in logged:
            _fail(errs, f"{cid}: no RUNLOG entry (unproven it ran serially)")
    # non-overlap over the expected set
    relevant = sorted(
        (rec for rec in records if rec.get("cell") in expected_ids),
        key=lambda r: r.get("start", 0),
    )
    for a, b in zip(relevant, relevant[1:]):
        if b.get("start", 0) < a.get("end", 0):
            _fail(errs, f"serial violation: {a['cell']} overlaps {b['cell']}")


def load_expected(matrix_path, cells_arg):
    """Return list of (id, cap) and whether to cross-check caps against the matrix."""
    if cells_arg:
        ids = [c.strip() for c in cells_arg.split(",") if c.strip()]
        return [(cid, None) for cid in ids], False
    matrix = json.load(open(matrix_path))
    return [(c["id"], c["cap_usd"]) for c in matrix["cells"]], True


def validate_dir(results_dir, matrix_path, cells_arg):
    errs = []
    expected, cross = load_expected(matrix_path, cells_arg)
    for cid, cap in expected:
        validate_cell_file(os.path.join(results_dir, f"{cid}.json"), cap, cross, errs)
    check_serial(os.path.join(results_dir, "RUNLOG.jsonl"), [cid for cid, _ in expected], errs)
    return errs


# ---------------------------------------------------------------------------
# self-test: prove RED on broken fixtures, GREEN on a complete one.
# ---------------------------------------------------------------------------
def _complete_cell(cid, arm, cap, cost, usage):
    gate = [] if arm == "C" else [{"cmd": "true", "rc": 0}]
    return {
        "cell": cid, "chore": cid.split("--")[0], "arm": arm, "rep": cid.split("--")[-1],
        "cap_usd": cap, "worktree": "/tmp/x", "duration_ms": 1000,
        "meter": {"total_cost_usd": cost, "usage": usage, "source": "x"},
        "score": {"gates_green": True, "asserts": [], "tier_ci_forced": [],
                  "agent_gate": gate, "diff_sha256": "abc123", "reversible": True},
    }


def _write_full_fixture(d, matrix_path, mutate=None):
    """Write a complete result set for the registered matrix into dir d."""
    matrix = json.load(open(matrix_path))
    t = 1000
    runlog = []
    for c in matrix["cells"]:
        arm = c["arm"]
        cost = 0.0 if arm == "C" else round(c["cap_usd"] * 0.5, 4)
        usage = None if arm == "C" else {"input_tokens": 10, "output_tokens": 20}
        obj = _complete_cell(c["id"], arm, c["cap_usd"], cost, usage)
        if mutate:
            obj = mutate(c["id"], obj)
            if obj is None:  # mutate may drop a cell entirely
                continue
        json.dump(obj, open(os.path.join(d, f"{c['id']}.json"), "w"))
        runlog.append({"cell": c["id"], "start": t, "end": t + 5})
        t += 10
    with open(os.path.join(d, "RUNLOG.jsonl"), "w") as f:
        for rec in runlog:
            f.write(json.dumps(rec) + "\n")
    return matrix


def self_test(matrix_path):
    cases = []  # (name, mutate, expect_red)

    cases.append(("complete", None, False))

    def drop_first(cid, obj):
        return None if cid == json.load(open(matrix_path))["cells"][0]["id"] else obj
    cases.append(("missing-cell", drop_first, True))

    def strip_meter(cid, obj):
        if cid == json.load(open(matrix_path))["cells"][0]["id"]:
            obj["meter"].pop("total_cost_usd", None)
        return obj
    cases.append(("meter-less", strip_meter, True))

    def over_cap(cid, obj):
        if obj["arm"] in LLM_ARMS:
            obj["meter"]["total_cost_usd"] = obj["cap_usd"] + 5.0
        return obj
    cases.append(("over-cap", over_cap, True))

    def null_llm_meter(cid, obj):
        if obj["arm"] in LLM_ARMS:
            obj["meter"]["total_cost_usd"] = None
            obj["meter"]["usage"] = None
        return obj
    cases.append(("null-llm-meter", null_llm_meter, True))

    def vacuous_green(cid, obj):
        if obj["arm"] in LLM_ARMS:
            obj["score"]["agent_gate"] = []
            obj["score"]["tier_ci_forced"] = []
        return obj
    cases.append(("vacuous-green", vacuous_green, True))

    ok = True
    for name, mutate, expect_red in cases:
        with tempfile.TemporaryDirectory() as d:
            _write_full_fixture(d, matrix_path, mutate)
            errs = validate_dir(d, matrix_path, None)
            got_red = bool(errs)
            verdict = "OK" if got_red == expect_red else "WRONG"
            if got_red != expect_red:
                ok = False
            print(f"  self-test {name:16} expect_red={expect_red!s:5} got_red={got_red!s:5} {verdict}")
            if name == "complete" and errs:
                for e in errs:
                    print(f"      unexpected error: {e}")

    # serial-overlap case: hand-build an overlapping RUNLOG.
    with tempfile.TemporaryDirectory() as d:
        matrix = _write_full_fixture(d, matrix_path)
        ids = [c["id"] for c in matrix["cells"][:2]]
        with open(os.path.join(d, "RUNLOG.jsonl"), "w") as f:
            f.write(json.dumps({"cell": ids[0], "start": 100, "end": 200}) + "\n")
            f.write(json.dumps({"cell": ids[1], "start": 150, "end": 250}) + "\n")  # overlaps
        errs = validate_dir(d, matrix_path, None)
        got_red = any("serial violation" in e for e in errs)
        verdict = "OK" if got_red else "WRONG"
        if not got_red:
            ok = False
        print(f"  self-test {'serial-overlap':16} expect_red=True  got_red={got_red!s:5} {verdict}")

    print("SELF-TEST:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("results_dir", nargs="?")
    ap.add_argument("--matrix", default=os.path.join(HERE, "matrix.json"))
    ap.add_argument("--cells", default=None, help="comma-separated cell ids to require")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test(args.matrix)

    if not args.results_dir:
        ap.error("results_dir required (or --self-test)")
    if not os.path.isdir(args.results_dir):
        print(f"validate_results: no such dir: {args.results_dir}", file=sys.stderr)
        return 4

    errs = validate_dir(args.results_dir, args.matrix, args.cells)
    if errs:
        print(f"validate_results: {len(errs)} problem(s):", file=sys.stderr)
        for e in errs:
            print(f"  - {e}", file=sys.stderr)
        return 5
    n = len(args.cells.split(",")) if args.cells else len(json.load(open(args.matrix))["cells"])
    print(f"validate_results: OK — {n} cell(s) complete, capped, serial.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
