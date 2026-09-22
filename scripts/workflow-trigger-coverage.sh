#!/usr/bin/env bash
#
# workflow-trigger-coverage.sh — a workflow must be able to FIRE on the things
# it measures, and every path it declares must name something that exists.
#
# WHY THIS EXISTS
# ---------------
# A gate that cannot be triggered by its own subject is counted as present and
# is blind. Measured 2026-09-01 across all 58 workflows: 19 run over more than
# they can be triggered by. The dominant shape is NOT a missing top-level tree
# (that explains 2) but the gate own instrument, or the second half of a pair,
# sitting outside its own filter -- main-gate-watch cannot be triggered by
# .github/required-checks.json, the file its harness asserts over.
#
# THE DESIGN IS NOT INVENTED. The repo already contains a controlled comparison:
# the dispatchers that delegate to a *-path-escape-check.sh ratchet (cloud.yml,
# console-harness.yml, elixir.yml) are ALL correct, and the two with
# hand-written inline filters (compose-smoke.yml, deploy.yml) BOTH drifted.
# Same problem, two designs, one perfect record and one perfect failure record.
# This generalises the winning one from a single tree to the workflow corpus.
#
# ARM B -- A DECLARED PATH MUST MATCH SOMETHING
# ---------------------------------------------
# Every alternative in every on.*.paths / paths-ignore list must match at least
# one file in the working tree. An alternative that matches nothing is a filter
# branch that can never fire, and it is invisible: the workflow looks gated.
#
# The known instance is twoslash.yml, which triggers on apps/docs/** while the
# docs app is js/docs/ (33 files). apps/ holds only hundesteder and mobile.
# So no docs edit could ever run the docs gate -- and the repo ALREADY KNEW:
# tooling/twoslash-mocks/README.md records that no apps/docs path exists and
# that earlier drafts assumed it. The knowledge and the defect coexisted, in
# writing, in one repo. A filter is not self-evidencing; only a check is.
#
# ARM C -- A PATHS LIST MIRRORED ACROSS TRIGGER ARMS MUST ACTUALLY MATCH
# ----------------------------------------------------------------------
# When a workflow filters BOTH `push:` and `pull_request:` by `paths:`, the two
# lists are a mirrored pair: the PR arm decides whose red it is, the push arm
# decides that a direct push to main is not unchecked. Drift between them is
# invisible by reading -- the workflow still looks gated on both sides, and the
# arm that lost an entry simply stops firing for it.
#
# THE REPO ALREADY KNOWS THIS AND ALREADY WROTE IT DOWN, in the header of
# .github/workflows/grip-suite.yml: "the mirrored-list discipline every tenant
# in shell-harnesses.yml already follows ... kept by hand and by inspection
# since drift here has only one place to hide". A discipline kept by hand and
# by inspection is a written finding that does not fire by itself. This is the
# mechanical form of it.
#
# COMPARED AS SETS, NOT AS LISTS. A duplicate entry is a no-op to GitHub, and
# measured 2026-09-17 shell-harnesses.yml carries three of them (deploy-rebuild
# .sh, main-red-breaker.sh, pdf-efficiency-proof.sh) -- 253 pull_request
# entries against 252 push entries with IDENTICAL sets. Comparing lists would
# report that as drift, which is a nuisance finding, not a defect.
#
# ONLY WHEN BOTH ARMS DECLARE paths. An arm that declares none is unfiltered on
# purpose -- 11 workflows in this corpus are deliberately asymmetric that way
# (push:main unfiltered, PR filtered, or the reverse) and none of them is a
# finding. The pair has to exist before it can drift.
#
# ARM C REPORTS ITS OWN SUBJECT COUNT, and says NO SUBJECT rather than OK when
# that count is zero -- a gate over nothing must not read as a certification.
# Measured 2026-09-17 on this corpus: 29 mirrored pairs across 77 workflows, 0
# drifted. (A first pass at this comment said "exactly ONE pair", having counted
# only the pairs that PRINTED -- i.e. the divergent ones -- and read the silence
# as the population. The count is emitted on every run precisely so the next
# reader does not have to re-derive it from what the gate chose to print.)
#
# WORKING TREE, NOT git ls-files (the cloud ratchet learned this the hard way):
# a prototype that enumerated via git reported OK while an untracked fixture sat
# on disk -- a vacuous pass of exactly the class this removes. We walk the tree.
#
# COVERAGE IS ASSERTED. A gate over zero inputs reports success, so this one
# FAILS if it parsed no workflows or checked no globs, and it prints both counts.
#
# EXIT CODES
#   0  every declared alternative matches something
#   1  FINDING -- at least one alternative is dead (arm B), or a mirrored
#      push/pull_request paths pair has drifted (arm C)
#   2  HARNESS-UNAVAILABLE -- no python3 or no PyYAML. NOT a pass: a gate that
#      cannot read its input must not certify it.
#
# NO APOSTROPHES OR BACKTICKS IN THE PYTHON BLOCK BELOW. bash 3.2 (what macOS
# ships) scans for the closing paren THROUGH a quoted heredoc inside a command
# substitution, so a lone apostrophe in a Python comment fails to parse the
# whole file -- green in CI, red on every developer machine.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF_DIR="${WORKFLOW_TRIGGER_DIR:-$ROOT/.github/workflows}"
TREE_ROOT="${WORKFLOW_TRIGGER_ROOT:-$ROOT}"

command -v python3 >/dev/null 2>&1 || {
  echo "HARNESS-UNAVAILABLE: python3 not on PATH -- cannot read workflow YAML." >&2
  echo "This is NOT a pass. Install python3 + PyYAML and re-run." >&2
  exit 2
}

PROBE="$(cat <<'PY'
import glob, os, sys

try:
    import yaml
except ImportError:
    print("PyYAML not importable", file=sys.stderr)
    sys.exit(2)

wf_dir, tree_root = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(wf_dir, "*.yml")) +
               glob.glob(os.path.join(wf_dir, "*.yaml")))

# Enumerate the WORKING TREE once. Skipping the noise directories keeps the
# match cheap and cannot hide a finding: nothing under them is a legitimate
# trigger path.
SKIP = {".git", "node_modules", "_build", "deps", ".elixir_ls", "target"}
tree = []
for dirpath, dirs, names in os.walk(tree_root):
    dirs[:] = [d for d in dirs if d not in SKIP]
    rel_dir = os.path.relpath(dirpath, tree_root)
    if rel_dir == ".":
        rel_dir = ""
    for n in names:
        tree.append(os.path.join(rel_dir, n) if rel_dir else n)

def matches(pattern):
    # GitHub path filters are glob-ish. ** spans separators; * does not.
    # Translate to a regex rather than using fnmatch, which cannot tell them
    # apart -- and that difference is the whole point of the check.
    import re
    p = pattern.strip()
    neg = p.startswith("!")
    if neg:
        p = p[1:]
    rx, i = "", 0
    while i < len(p):
        c = p[i]
        if c == "*":
            if p[i:i+3] == "**/":
                rx += "(?:.*/)?"
                i += 3
                continue
            if p[i:i+2] == "**":
                rx += ".*"
                i += 2
                continue
            rx += "[^/]*"
            i += 1
            continue
        if c == "?":
            rx += "[^/]"
        elif c in ".+()[]{}^$|\\":
            rx += "\\" + c
        else:
            rx += c
        i += 1
    creg = re.compile("^" + rx + "$")
    for f in tree:
        if creg.match(f):
            return True
    return False

def path_lists(doc):
    out = []
    on = doc.get(True, doc.get("on"))  # PyYAML parses bare `on:` as boolean True
    if not isinstance(on, dict):
        return out
    for event, cfg in on.items():
        if not isinstance(cfg, dict):
            continue
        for key in ("paths", "paths-ignore"):
            vals = cfg.get(key)
            if isinstance(vals, list):
                out.append((str(event), key, vals))
    return out

# ARM C. Events whose paths lists form a mirrored pair when both declare one.
MIRROR_EVENTS = ("push", "pull_request", "pull_request_target")

def mirror_sets(doc):
    # Returns {event: frozenset(paths)} for MIRROR_EVENTS that declare paths.
    on = doc.get(True, doc.get("on"))
    out = {}
    if not isinstance(on, dict):
        return out
    for event, cfg in on.items():
        if str(event) not in MIRROR_EVENTS:
            continue
        if not isinstance(cfg, dict):
            continue
        vals = cfg.get("paths")
        if isinstance(vals, list):
            out[str(event)] = frozenset(str(v) for v in vals)
    return out

wf_count = 0
glob_count = 0
pair_count = 0
dead = []
drift = []
for path in files:
    try:
        doc = yaml.safe_load(open(path))
    except Exception as exc:
        print("YAMLFAIL\t%s\t%s" % (os.path.basename(path), exc))
        continue
    if not isinstance(doc, dict):
        continue
    wf_count += 1
    msets = mirror_sets(doc)
    if len(msets) >= 2:
        pair_count += 1
        events = sorted(msets)
        base = msets[events[0]]
        if any(msets[e] != base for e in events[1:]):
            union = set()
            for e in events:
                union |= msets[e]
            for e in events:
                missing = sorted(union - msets[e])
                if missing:
                    drift.append((os.path.basename(path), e,
                                  ",".join(sorted(events)), " ".join(missing)))
    for event, key, vals in path_lists(doc):
        for g in vals:
            glob_count += 1
            if not matches(str(g)):
                dead.append((os.path.basename(path), event, key, str(g)))

for d in dead:
    print("DEAD\t%s\t%s\t%s\t%s" % d)
for d in drift:
    print("DRIFT\t%s\t%s\t%s\t%s" % d)
print("COUNTS\t%d\t%d\t%d\t%d" % (wf_count, glob_count, len(tree), pair_count))
PY
)"

OUT="$(python3 -c "$PROBE" "$WF_DIR" "$TREE_ROOT" 2>&1)"
rc=$?
if [ "$rc" = "2" ]; then
  echo "HARNESS-UNAVAILABLE: $OUT" >&2
  echo "This is NOT a pass." >&2
  exit 2
fi

WF_N=$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="COUNTS"{print $2}')
GLOB_N=$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="COUNTS"{print $3}')
TREE_N=$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="COUNTS"{print $4}')
PAIR_N=$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="COUNTS"{print $5}')
DEAD_N=$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="DEAD"' | wc -l | tr -d ' ')
DRIFT_N=$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="DRIFT"' | wc -l | tr -d ' ')

# COVERAGE FLOORS. A scan over nothing reports success; these make that a
# failure instead. They are floors, not pins -- growth never reds them.
#
# Overridable ONLY so the harness can drive small synthetic corpora; the
# defaults are what CI runs, and the harness has a case asserting the DEFAULTS
# still refuse. An override that CI could set would be a floor that can be
# switched off, which is not a floor.
MIN_WF="${WORKFLOW_TRIGGER_MIN_WF:-20}"
MIN_GLOBS="${WORKFLOW_TRIGGER_MIN_GLOBS:-50}"
MIN_TREE="${WORKFLOW_TRIGGER_MIN_TREE:-1000}"

if [ -z "${WF_N:-}" ] || [ "$WF_N" -lt "$MIN_WF" ]; then
  echo "::error::workflow-trigger-coverage: parsed only ${WF_N:-0} workflows in $WF_DIR -- the scan found essentially nothing. Refusing to report a verdict." >&2
  exit 2
fi
if [ -z "${GLOB_N:-}" ] || [ "$GLOB_N" -lt "$MIN_GLOBS" ]; then
  echo "::error::workflow-trigger-coverage: checked only ${GLOB_N:-0} path globs -- the corpus cannot be that small. Refusing to report a verdict." >&2
  exit 2
fi
if [ -z "${TREE_N:-}" ] || [ "$TREE_N" -lt "$MIN_TREE" ]; then
  echo "::error::workflow-trigger-coverage: walked only ${TREE_N:-0} files -- a truncated tree makes every glob look dead. Refusing to report a verdict." >&2
  exit 2
fi

printf '%s\n' "$OUT" | awk -F'\t' '$1=="YAMLFAIL"{printf "::warning::unparseable workflow %s: %s\n", $2, $3}'

# ── ARM C ─────────────────────────────────────────────────────────────────────
# Reported BEFORE arm B so a drift finding is never scrolled off by a long dead
# list, and evaluated independently: both arms report, then the exit code is the
# union. A gate that stops at its first finding hides the second one.
if [ "$DRIFT_N" != "0" ]; then
  echo ""
  printf '%s\n' "$OUT" | awk -F'\t' '$1=="DRIFT"{
    printf "::error::%s -- on.%s.paths is MISSING %s, which its mirrored arm(s) (%s) declare. The two lists are a mirrored pair: the arm that lost the entry silently stops firing for it while the workflow still looks gated on both sides.\n", $2, $3, $5, $4
  }'
  echo ""
  echo "workflow-trigger-coverage(arm C): FAILED -- $DRIFT_N drifted arm(s) across $PAIR_N mirrored pair(s)."
  echo "  FIX: add the missing entries to the arm that lacks them, or, if the"
  echo "  asymmetry is deliberate, drop paths: from that arm entirely so it is"
  echo "  unfiltered on purpose rather than filtered by accident."
else
  if [ "${PAIR_N:-0}" = "0" ]; then
    echo "workflow-trigger-coverage(arm C): NO SUBJECT -- no workflow declares paths: on two trigger arms, so this arm measured nothing. Not a certification."
  else
    echo "workflow-trigger-coverage(arm C): OK -- $PAIR_N mirrored push/pull_request paths pair(s) agree as sets."
  fi
fi

if [ "$DEAD_N" != "0" ]; then
  echo ""
  printf '%s\n' "$OUT" | awk -F'\t' '$1=="DEAD"{
    printf "::error::%s -- on.%s.%s declares \"%s\", which matches NO file in the tree. A filter alternative that matches nothing can never fire, and the workflow still looks gated.\n", $2, $3, $4, $5
  }'
  echo ""
  echo "workflow-trigger-coverage(arm B): FAILED -- $DEAD_N dead path alternative(s)."
  echo "  Checked $GLOB_N glob(s) across $WF_N workflow(s) against $TREE_N tree file(s)."
  echo "  FIX: point the alternative at the path that exists, or delete it. Do not"
  echo "  leave it: a dead alternative is indistinguishable from a live one by reading."
  exit 1
fi

echo "workflow-trigger-coverage(arm B): OK -- $GLOB_N path glob(s) across $WF_N workflow(s) all match at least one of $TREE_N tree file(s)."
[ "$DRIFT_N" = "0" ] || exit 1
exit 0
