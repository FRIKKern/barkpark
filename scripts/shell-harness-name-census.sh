#!/usr/bin/env bash
# shell-harness-name-census.sh — enumerate every CHECK-RUN NAME
# .github/workflows/shell-harnesses.yml can publish, and prove the set did not
# move across a refactor.
#
# WHY. The 53 sibling harness jobs were collapsed into one `harness` matrix job.
# A matrix job normally renders `<job name> (<leg>)`, so a careless collapse
# RENAMES all 53 check runs at once and breaks every pin, watcher and required-
# set reference that names one. It does not here — an explicit `name:` on a
# matrix job is rendered VERBATIM — but "it does not" is a claim, and this is
# the instrument that settles it against a real git ref instead of a memory.
#
# SHAPE-AGNOSTIC BY DESIGN. The enumerator handles BOTH shapes off the same
# workflow text, so the same command answers for the pre- and post-collapse
# tree and the comparison is never between two different readers:
#   LEGACY  every job under `jobs:` publishes its `name:`, or its job id when
#           it has none.
#   MATRIX  a job whose `strategy.matrix` fans out over a leg list publishes
#           `name:` once per leg; `${{ matrix.leg.name }}` is resolved from
#           .github/shell-harness-legs.json at that same ref.
# A job that publishes neither shape is a REFUSAL, not a silent omission.
#
# EXIT CODES
#   0  the census printed (no --compare), or the two sets are EQUAL
#   1  --compare and the sets DIFFER — every added and removed name is printed
#   2  CANNOT MEASURE: no python3/PyYAML, a missing or unparseable workflow at
#      the requested ref, a legs file a matrix shape needs and cannot read, or a
#      census that came out EMPTY. An empty census compares equal to another
#      empty census, so it is refused before it can manufacture a green.
#
# USAGE
#   bash scripts/shell-harness-name-census.sh                  # working tree
#   bash scripts/shell-harness-name-census.sh --ref origin/main
#   bash scripts/shell-harness-name-census.sh --compare origin/main
#       compare the WORKING TREE against that ref (or --ref A --compare B)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF_REL=".github/workflows/shell-harnesses.yml"
LEGS_REL=".github/shell-harness-legs.json"

REF=""
COMPARE=""
COMPARE_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="${2:-}"; shift 2 ;;
    --compare) COMPARE="${2:-}"; shift 2 ;;
    --compare-file) COMPARE_FILE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

unavailable() { echo "CANNOT MEASURE: $*" >&2; exit 2; }

command -v python3 >/dev/null 2>&1 || unavailable "python3 is required"
python3 -c 'import yaml' 2>/dev/null || unavailable "PyYAML is required (pip3 install pyyaml)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/shnc.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# materialise <ref-or-worktree> into $TMP/<tag>.{yml,json}
materialise() {
  tag="$1"; ref="$2"
  if [ -z "$ref" ]; then
    [ -f "$REPO_ROOT/$WF_REL" ] || unavailable "working tree has no $WF_REL"
    cp "$REPO_ROOT/$WF_REL" "$TMP/$tag.yml"
    if [ -f "$REPO_ROOT/$LEGS_REL" ]; then cp "$REPO_ROOT/$LEGS_REL" "$TMP/$tag.json"; fi
  else
    git -C "$REPO_ROOT" show "$ref:$WF_REL" >"$TMP/$tag.yml" 2>/dev/null \
      || unavailable "cannot read $WF_REL at ref '$ref' (bad ref, or the file is absent there)"
    git -C "$REPO_ROOT" show "$ref:$LEGS_REL" >"$TMP/$tag.json" 2>/dev/null || rm -f "$TMP/$tag.json"
  fi
}

# print one name per line, sorted
enumerate() {
  tag="$1"
  python3 - "$TMP/$tag.yml" "$TMP/$tag.json" <<'PY'
import json, os, sys, yaml
wf, legs_path = sys.argv[1], sys.argv[2]
try:
    doc = yaml.safe_load(open(wf))
except Exception as exc:
    sys.stderr.write("unparseable workflow: %s\n" % exc); sys.exit(2)
jobs = (doc or {}).get("jobs") or {}
if not jobs:
    sys.stderr.write("no jobs in the workflow\n"); sys.exit(2)

legs = None
def load_legs():
    global legs
    if legs is None:
        if not os.path.exists(legs_path):
            sys.stderr.write("a matrix job needs %s and it is absent at this ref\n" % legs_path)
            sys.exit(2)
        legs = json.load(open(legs_path))
    return legs

names = []
for jid, job in jobs.items():
    job = job or {}
    strat = (job.get("strategy") or {}).get("matrix")
    if not strat:
        names.append(job.get("name") or jid)
        continue
    # A matrix job. Its `name:` MUST be an explicit template, or GitHub
    # auto-suffixes and the census cannot answer for it.
    tmpl = job.get("name")
    if not tmpl or "${{" not in str(tmpl):
        sys.stderr.write(
            "job %r fans out over a matrix with no explicit name template; GitHub "
            "would auto-suffix its check-run names and this census cannot predict them\n" % jid)
        sys.exit(2)
    tmpl = str(tmpl).strip()
    if tmpl != "${{ matrix.leg.name }}":
        sys.stderr.write("job %r has an unrecognised name template %r — teach this census "
                         "how to resolve it before trusting a result\n" % (jid, tmpl))
        sys.exit(2)
    for leg in load_legs():
        names.append(leg["name"])

if not names:
    sys.stderr.write("the census came out EMPTY\n"); sys.exit(2)
dupes = sorted({n for n in names if names.count(n) > 1})
if dupes:
    sys.stderr.write("duplicate check-run name(s): %s\n" % ", ".join(dupes)); sys.exit(2)
for n in sorted(names):
    print(n)
PY
}

materialise a "$REF"
enumerate a >"$TMP/a.txt" || exit 2
NA=$(wc -l <"$TMP/a.txt" | tr -d ' ')
[ "$NA" -gt 0 ] || unavailable "the census for '${REF:-<working tree>}' is empty"

# --compare-file is the OFFLINE arm: it needs no second ref and no network, so
# it runs on a shallow CI checkout where `git show origin/main:` does not
# resolve. The baseline is committed, so a leg rename is a DIFF in the same PR
# that makes it, named line by line, instead of a silent rename of 53 checks.
if [ -n "$COMPARE_FILE" ]; then
  [ -f "$COMPARE_FILE" ] || unavailable "baseline file not found: $COMPARE_FILE"
  grep -v -e '^[[:space:]]*$' -e '^#' "$COMPARE_FILE" | LC_ALL=C sort >"$TMP/b.txt"
  NB=$(wc -l <"$TMP/b.txt" | tr -d ' ')
  [ "$NB" -gt 0 ] || unavailable "baseline file '$COMPARE_FILE' is empty — an empty baseline compares equal to anything"
  ADDED="$(comm -23 "$TMP/a.txt" "$TMP/b.txt")"
  REMOVED="$(comm -13 "$TMP/a.txt" "$TMP/b.txt")"
  echo "-- census: '${REF:-<working tree>}' ($NA names) vs baseline $COMPARE_FILE ($NB names) --"
  if [ -z "$ADDED" ] && [ -z "$REMOVED" ]; then
    echo "EQUAL: the workflow publishes exactly the $NA baselined check-run names."
    exit 0
  fi
  # One name per LINE, never `printf ... $VAR`: every one of these names
  # contains spaces, and word-splitting them turns a two-name diff into a
  # twelve-fragment one that nobody can read or grep.
  [ -n "$ADDED" ]   && { echo "ADDED (workflow publishes, baseline does not):"; printf '%s\n' "$ADDED" | sed 's/^/  + /'; }
  [ -n "$REMOVED" ] && { echo "REMOVED (baseline carries, workflow no longer publishes):"; printf '%s\n' "$REMOVED" | sed 's/^/  - /'; }
  echo "DIFFERENT: the published check-run name set MOVED. If the move is intended, update $COMPARE_FILE in this same commit and say in the PR body which pins named the removed check runs."
  exit 1
fi

if [ -z "$COMPARE" ]; then
  echo "── shell-harnesses check-run names at '${REF:-<working tree>}': $NA ──"
  cat "$TMP/a.txt"
  exit 0
fi

materialise b "$COMPARE"
enumerate b >"$TMP/b.txt" || exit 2
NB=$(wc -l <"$TMP/b.txt" | tr -d ' ')
[ "$NB" -gt 0 ] || unavailable "the census for '$COMPARE' is empty"

ADDED="$(comm -23 "$TMP/a.txt" "$TMP/b.txt")"
REMOVED="$(comm -13 "$TMP/a.txt" "$TMP/b.txt")"
echo "── census: '${REF:-<working tree>}' ($NA names) vs '$COMPARE' ($NB names) ──"
if [ -z "$ADDED" ] && [ -z "$REMOVED" ]; then
  echo "EQUAL: both refs publish the same $NA check-run names."
  exit 0
fi
[ -n "$ADDED" ]   && { echo "ADDED (present in '${REF:-<working tree>}', absent in '$COMPARE'):";  printf '%s\n' "$ADDED" | sed 's/^/  + /'; }
[ -n "$REMOVED" ] && { echo "REMOVED (present in '$COMPARE', absent in '${REF:-<working tree>}'):"; printf '%s\n' "$REMOVED" | sed 's/^/  - /'; }
echo "DIFFERENT: the published check-run name set MOVED."
exit 1
