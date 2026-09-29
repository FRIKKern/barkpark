#!/usr/bin/env python3
"""shell-harness-matrix.py — turn the dispatcher's per-slug true/false verdicts
into the matrix the `harness` job fans out over.

WHY THIS EXISTS. shell-harnesses.yml used to carry 53 sibling jobs, each gated
by one uniform `if: needs.changes.outputs.<slug> == 'true'`. GitHub renders a
check run for a job it SKIPS, so every head that started this workflow rendered
54 names whether or not any harness had anything to measure — and on a head
whose diff hit a broad path all 53 BOOTED (measured 2026-09-17 on PR #18915:
0 skipped / 54 success, 15 minutes wall, more real compute than all four
required workflows combined). A matrix leg that is not in the matrix renders
NOTHING, so N selected harnesses now cost N+1 names instead of 54.

THE NAMES ARE THE CONTRACT. `harness` sets `name: ${{ matrix.leg.name }}`, and
an explicit `name:` on a matrix job is rendered VERBATIM — GitHub appends the
`(leg)` suffix only when the job has no name of its own. So every one of the 53
check-run names is byte-identical to the name its sibling job published before
the collapse. scripts/shell-harness-name-census.sh proves that against any git
ref and is wired in this workflow's own `dispatch-selftest` leg.

THE EMPTY MATRIX IS THE TRAP. A `strategy.matrix` that evaluates to an empty
list does not skip the job — it makes the whole job VANISH, and a vanished job
is indistinguishable from a workflow that never started. The `harness` job is
therefore additionally gated on `needs.changes.outputs.any == 'true'`, which
this script emits alongside the matrix, so the zero-selection case is an
explicit skip rather than a hole.

USAGE
  python3 scripts/shell-harness-matrix.py '<json map slug -> "true"/"false">'
writes `matrix=<json>` and `any=true|false` on stdout in $GITHUB_OUTPUT form.

EXIT CODES
  0  a matrix was emitted (possibly empty, with any=false)
  2  CANNOT MEASURE — the legs file is missing/unparseable/empty, the selection
     argument is not a JSON object, or the selection names a slug the legs file
     does not carry (or omits one it does). Never a vacuous empty matrix: a
     disagreement between the roster and the legs file is a REFUSAL, because an
     empty matrix silently runs nothing and reports nothing.
"""
import json
import os
import sys

LEGS = os.environ.get("SHELL_HARNESS_LEGS", ".github/shell-harness-legs.json")


def die(msg):
    sys.stderr.write("::error::shell-harness-matrix: %s\n" % msg)
    raise SystemExit(2)


def main(argv):
    if len(argv) != 2:
        die("expected exactly one argument (the selection JSON), got %d" % (len(argv) - 1))
    try:
        with open(LEGS) as fh:
            legs = json.load(fh)
    except Exception as exc:  # noqa: BLE001 - any failure here is CANNOT MEASURE
        die("cannot read %s: %s" % (LEGS, exc))
    if not isinstance(legs, list) or not legs:
        die("%s must be a non-empty JSON list of legs" % LEGS)
    try:
        selection = json.loads(argv[1])
    except Exception as exc:  # noqa: BLE001
        die("selection argument is not JSON: %s" % exc)
    if not isinstance(selection, dict):
        die("selection argument must be a JSON object of slug -> 'true'/'false'")

    leg_slugs = [leg["slug"] for leg in legs]
    if len(set(leg_slugs)) != len(leg_slugs):
        die("duplicate slug in %s" % LEGS)

    # The dispatcher step also writes non-slug bookkeeping keys; only slugs the
    # legs file knows are considered, but a leg with NO verdict is a refusal —
    # that is the shape where a harness silently stops being dispatched.
    missing = [s for s in leg_slugs if s not in selection]
    if missing:
        die("the dispatcher emitted no verdict for %d leg(s): %s" % (len(missing), " ".join(missing)))

    chosen = [leg for leg in legs if str(selection[leg["slug"]]).strip() == "true"]
    out = json.dumps([{"slug": l["slug"], "name": l["name"], "timeout": l["timeout"],
                       "fetch_depth": l["fetch_depth"], "node": l["node"]} for l in chosen],
                     separators=(",", ":"))
    sys.stdout.write("matrix=%s\n" % out)
    sys.stdout.write("any=%s\n" % ("true" if chosen else "false"))
    sys.stderr.write("shell-harness-matrix: %d of %d legs selected\n" % (len(chosen), len(legs)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
