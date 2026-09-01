#!/usr/bin/env bash
# workflow-trigger-coverage.test.sh — prove the coverage gate can lose.
#
#   bash scripts/workflow-trigger-coverage.test.sh    (exit 0 = all green)
#
# The subject reds when a workflow declares a path alternative that matches
# nothing in the tree. Three things have to be true for that to be worth having:
#   1. it FIRES on a dead alternative
#   2. it does NOT fire when every alternative is live (or it is just noise)
#   3. it REFUSES rather than passes when it cannot see the corpus
#
# (3) is the one that matters most here. This gate answers a question of the
# form "does anything match?", and an empty or truncated tree makes EVERY glob
# look dead -- while an unparsed workflow list makes every glob look fine. Both
# are ways to be confidently wrong, in opposite directions.
#
# The glob translation is hand-written (GitHub ** spans separators, * does not,
# and fnmatch cannot tell them apart), so it gets its own cases: a wrong
# translation would silently UNDER-report, which is the failure nobody notices.
#
# HERMETIC. Synthetic trees under mktemp. No network, no real repo.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUBJECT="${WTC_SH:-$HERE/workflow-trigger-coverage.sh}"
pass=0; fail=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'ok   %-58s (%s)\n' "$1" "$3"
  else fail=$((fail+1)); printf 'FAIL %-58s want %s got %s\n' "$1" "$2" "$3"; fi
}
[ -r "$SUBJECT" ] || { echo "FAIL: cannot read $SUBJECT" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wtc.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# A synthetic tree big enough to clear the subject own coverage floors, so the
# floors are not what is being measured in cases 1-4.
mk_tree() { # mk_tree <dir>
  local d="$1"
  rm -rf "$d"; mkdir -p "$d/.github/workflows" "$d/js/docs" "$d/scripts" "$d/filler"
  printf 'x\n' > "$d/js/docs/index.md"
  printf 'x\n' > "$d/scripts/thing.sh"
  local i=0
  while [ "$i" -lt 1200 ]; do printf 'x\n' > "$d/filler/f$i.txt"; i=$((i+1)); done
}

wf() { # wf <dir> <name> <paths...>
  local d="$1" name="$2"; shift 2
  { echo "name: $name"; echo "on:"; echo "  pull_request:"; echo "    paths:"
    for p in "$@"; do echo "      - \"$p\""; done
    echo "jobs:"; echo "  a:"; echo "    runs-on: ubuntu-latest"
    echo "    steps:"; echo "      - run: echo hi"
  } > "$d/.github/workflows/$name.yml"
}

# Fixtures are necessarily small, so the coverage floors are lowered FOR THE
# FIXTURE ONLY. Case 3 deliberately does NOT lower them, so the shipped
# defaults are what gets asserted there.
run() { # run <dir> -> rc  (fixture-scaled floors)
  WORKFLOW_TRIGGER_DIR="$1/.github/workflows" WORKFLOW_TRIGGER_ROOT="$1" \
  WORKFLOW_TRIGGER_MIN_WF=2 WORKFLOW_TRIGGER_MIN_GLOBS=2 WORKFLOW_TRIGGER_MIN_TREE=10 \
    bash "$SUBJECT" >"$TMP/out.txt" 2>&1
  echo $?
}

run_default_floors() { # run <dir> -> rc  (SHIPPED floors, nothing lowered)
  WORKFLOW_TRIGGER_DIR="$1/.github/workflows" WORKFLOW_TRIGGER_ROOT="$1" \
    bash "$SUBJECT" >"$TMP/out.txt" 2>&1
  echo $?
}

echo "== 1. a dead alternative REDS =="
D="$TMP/t1"; mk_tree "$D"
i=0; while [ "$i" -lt 25 ]; do wf "$D" "live$i" "js/docs/**"; i=$((i+1)); done
wf "$D" "dead" "apps/docs/**" "js/docs/**"
check "dead alternative -> exit 1"            1 "$(run "$D")"
check "  ...names the workflow"               1 "$(grep -c 'dead.yml' "$TMP/out.txt" | awk '{print ($1>0)?1:0}')"
check "  ...names the dead glob"              1 "$(grep -c 'apps/docs/\*\*' "$TMP/out.txt" | awk '{print ($1>0)?1:0}')"
check "  ...does NOT flag the live sibling"   0 "$(grep -c '\"js/docs/\*\*\", which matches NO' "$TMP/out.txt" | tr -d ' ')"

echo ""
echo "== 2. NON-VACUITY — all-live corpus stays green =="
# Without this, a gate hard-wired to exit 1 would pass case 1.
D="$TMP/t2"; mk_tree "$D"
i=0; while [ "$i" -lt 26 ]; do wf "$D" "live$i" "js/docs/**" "scripts/thing.sh"; i=$((i+1)); done
check "every alternative live -> exit 0"      0 "$(run "$D")"
check "  ...and it reports what it checked"   1 "$(grep -cE 'arm B\): OK -- [0-9]+ path glob' "$TMP/out.txt" | awk '{print ($1>0)?1:0}')"

echo ""
echo "== 3. it REFUSES rather than passing when it cannot see the corpus =="
# An empty tree makes every glob look dead; an empty workflow dir makes every
# glob look fine. Both must be exit 2 (cannot measure), never 0 and never 1.
# These use the SHIPPED floors — no override — so the defaults are what is tested.
D="$TMP/t3"; mk_tree "$D"; rm -f "$D"/.github/workflows/*.yml
check "no workflows -> REFUSES (2, not 0)"    2 "$(run_default_floors "$D")"
check "  ...and says it found nothing"        1 "$(grep -c 'found essentially nothing' "$TMP/out.txt" | awk '{print ($1>0)?1:0}')"

# Enough workflows and globs to clear those two floors, but a truncated tree —
# so the TREE floor is the one that must fire, and it must blame the tree.
D="$TMP/t4"; mk_tree "$D"
i=0; while [ "$i" -lt 26 ]; do wf "$D" "live$i" "js/docs/**" "scripts/thing.sh"; i=$((i+1)); done
rm -rf "$D/filler"
check "truncated tree -> REFUSES (2, not 1)"  2 "$(run_default_floors "$D")"
check "  ...and blames the tree, not the globs" 1 "$(grep -c 'truncated tree makes every glob look dead' "$TMP/out.txt" | awk '{print ($1>0)?1:0}')"

# NON-VACUITY on the override itself: the same truncated tree, with the floor
# lowered, must reach a real verdict — proving case 3 measured the floor and
# not some unrelated breakage.
check "  ...and the SAME tree verdicts once the floor is lowered" 0 "$(run "$D")"

echo "== 4. the glob translation — ** spans separators, * does not =="
# Hand-written, because fnmatch cannot tell them apart. A wrong translation
# UNDER-reports, which is the failure nobody notices.
D="$TMP/t5"; mk_tree "$D"
i=0; while [ "$i" -lt 25 ]; do wf "$D" "live$i" "js/docs/**"; i=$((i+1)); done
# `js/*` must NOT match js/docs/index.md (one segment deep only) -> dead -> red.
wf "$D" "single" "js/*"
check "single * does NOT span a separator"    1 "$(run "$D")"
check "  ...and names js/* as dead"           1 "$(grep -c '"js/\*"' "$TMP/out.txt" | awk '{print ($1>0)?1:0}')"

D="$TMP/t6"; mk_tree "$D"
i=0; while [ "$i" -lt 26 ]; do wf "$D" "live$i" "js/**"; i=$((i+1)); done
check "double ** DOES span separators"        0 "$(run "$D")"

D="$TMP/t7"; mk_tree "$D"
i=0; while [ "$i" -lt 26 ]; do wf "$D" "live$i" "**/thing.sh"; i=$((i+1)); done
check "leading **/ matches a nested file"     0 "$(run "$D")"

echo ""
echo "---"
echo "workflow-trigger-coverage: $pass passed, $fail failed"
[ "$fail" = 0 ]
