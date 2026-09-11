#!/usr/bin/env bash
# main-workflow-rollup.test.sh — both-ways proofs for the every-workflow roll-up.
#
# Nothing here asserts "the script ran". Every verdict is proven on synthetic
# fixture trees plus recorded-shape `actions/runs` payloads, and each of the
# three properties the roll-up claims is proven by MUTATION as well as by
# assertion — a mutation that does NOT flip the verdict means the assertion was
# never measuring the thing it names.
#
#   THE DENOMINATOR IS THE TREE
#     * adding a workflow file with no run on main raises the printed
#       denominator by one AND puts the new name in the listing
#     * MUTATION: replace the enumeration with a fixed three-name list and the
#       same arm must fail — which is what proves the arm can lose at all
#
#   THE LABEL IS DERIVED FROM THE SPEC
#     * a workflow rendering a required context reads REQUIRED
#     * MUTATION: move that context from .protection...checks into .exclusions
#       in a COPY of the spec and the same workflow must read ADVISORY
#
#   THE GRACE WINDOW DECIDES, IN BOTH DIRECTIONS, IN ONE RUN
#     * the red fixture (a failure streak older than the window) exits 1
#     * the otherwise-identical clean fixture (the same streak inside the
#       window) exits 0, and so does a fixture whose newest run is green
#     * MUTATION: make the staleness comparison always false and the RED
#       fixture must go green
#
# FULLY OFFLINE. `gh` is replaced by a stub that fails loudly, so any accidental
# network path in the script under test shows up as a failing case rather than
# as a hidden dependency on GitHub being up.
#
#   bash scripts/main-workflow-rollup.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROLLUP="$REPO_ROOT/scripts/main-workflow-rollup.sh"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*" >&2; }
section() { echo; echo "── $* ──"; }

[ -f "$ROLLUP" ] || { echo "missing subject: $ROLLUP" >&2; exit 1; }

# ═══ no network, ever ════════════════════════════════════════════════════════
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh: this test is offline and must never call the network (args: $*)" >&2
exit 97
STUB
chmod +x "$BIN/gh"
PATH="$BIN:$PATH"; export PATH

# ═══ the fixture tree ════════════════════════════════════════════════════════
# Three workflow files. alpha renders a required context as a job name; beta and
# gamma do not; gamma has no run on main at all.
WFD="$TMP/wf"; mkdir -p "$WFD"
cat > "$WFD/alpha.yml" <<'YML'
name: Alpha
on: [push]
jobs:
  gate:
    name: Elixir gate
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
YML
cat > "$WFD/beta.yml" <<'YML'
name: Beta
on: [push]
jobs:
  beta:
    name: Beta job
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
YML
cat > "$WFD/gamma.yml" <<'YML'
name: Gamma
on: [workflow_dispatch]
jobs:
  gamma:
    name: Gamma job
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
YML

# ═══ the spec ════════════════════════════════════════════════════════════════
SPEC="$TMP/required-checks.json"
cat > "$SPEC" <<'JSON'
{
  "repo": "FRIKKern/barkpark",
  "branch": "main",
  "protection": {
    "required_status_checks": {
      "strict": false,
      "checks": [
        {"context": "Elixir gate", "app_id": 15368},
        {"context": "Cloud gate", "app_id": 15368}
      ]
    }
  },
  "exclusions": [
    {"context": "Beta job", "reason": "advisory by construction"}
  ]
}
JSON

# THE LABEL MUTATION: the same spec with `Elixir gate` moved out of the required
# checks and into the exclusions. Nothing else differs.
SPEC_MOVED="$TMP/required-checks-moved.json"
jq '
  .protection.required_status_checks.checks
    |= map(select(.context != "Elixir gate"))
  | .exclusions += [{"context": "Elixir gate", "reason": "MUTATION: moved out of required"}]
' "$SPEC" > "$SPEC_MOVED"

NOW="2026-09-11T12:00:00Z"

# ═══ the run payloads ════════════════════════════════════════════════════════
# Shape is a recorded `gh api repos/O/R/actions/runs` object. alpha is green.
# beta carries a FAILURE STREAK; only the streak's start time differs between
# the red and the clean fixture, so the two are otherwise identical.
runs_payload() { # $1 = beta's oldest-failure start, $2 = beta's newest conclusion
  cat <<JSON
{
  "total_count": 6,
  "workflow_runs": [
    {"id": 1, "path": ".github/workflows/alpha.yml", "status": "completed",
     "conclusion": "success", "run_started_at": "2026-09-11T11:00:00Z"},
    {"id": 2, "path": ".github/workflows/alpha.yml", "status": "completed",
     "conclusion": "success", "run_started_at": "2026-09-10T11:00:00Z"},
    {"id": 3, "path": ".github/workflows/beta.yml", "status": "completed",
     "conclusion": "$2", "run_started_at": "2026-09-11T11:30:00Z"},
    {"id": 4, "path": ".github/workflows/beta.yml", "status": "completed",
     "conclusion": "failure", "run_started_at": "$1"},
    {"id": 5, "path": ".github/workflows/beta.yml", "status": "completed",
     "conclusion": "success", "run_started_at": "2026-09-01T00:00:00Z"},
    {"id": 6, "path": ".github/workflows/beta.yml", "status": "in_progress",
     "conclusion": null, "run_started_at": "2026-09-11T11:59:00Z"}
  ]
}
JSON
}

# RED: beta's failure streak opened 2026-09-07 (≈101h before NOW) — well past a
# 24h window.
runs_payload "2026-09-07T07:00:00Z" "failure" > "$TMP/runs-red.json"
# CLEAN (streak inside the window): identical but for the streak start, which is
# 2h before NOW.
runs_payload "2026-09-11T10:00:00Z" "failure" > "$TMP/runs-clean-young.json"
# CLEAN (newest run green): the old streak is still there but a green landed on
# top, so the clock reset.
runs_payload "2026-09-07T07:00:00Z" "success" > "$TMP/runs-clean-green.json"

run_rollup() { # extra args...; prints combined output, returns rc
  "$ROLLUP" --workflows-dir "$WFD" --spec "$SPEC" --now "$NOW" --grace-hours 24 "$@" 2>&1
}

# ═══════════════════════════════════════════════════════════════════════════
section "BOTH DIRECTIONS — the grace window decides"

OUT_RED="$(run_rollup --runs-file "$TMP/runs-red.json")"; RC_RED=$?
if [ "$RC_RED" -eq 1 ]; then
  ok "red fixture exits 1 (streak opened 2026-09-07T07:00:00Z, ≈101h before $NOW)"
else
  bad "red fixture: expected rc 1, got $RC_RED"
  echo "$OUT_RED" >&2
fi
case "$OUT_RED" in
  *"RED PAST GRACE"*"beta.yml"*) ok "red fixture names beta.yml as RED PAST GRACE" ;;
  *) bad "red fixture did not name beta.yml as RED PAST GRACE"; echo "$OUT_RED" >&2 ;;
esac

OUT_YOUNG="$(run_rollup --runs-file "$TMP/runs-clean-young.json")"; RC_YOUNG=$?
if [ "$RC_YOUNG" -eq 0 ]; then
  ok "otherwise-identical clean fixture (same streak, 2h old) exits 0"
else
  bad "young-streak fixture: expected rc 0, got $RC_YOUNG"
  echo "$OUT_YOUNG" >&2
fi
case "$OUT_YOUNG" in
  *"RED (within 24h grace"*) ok "young streak is still PRINTED as red, not silently dropped" ;;
  *) bad "young streak was not printed as a red inside the window"; echo "$OUT_YOUNG" >&2 ;;
esac

OUT_GREEN="$(run_rollup --runs-file "$TMP/runs-clean-green.json")"; RC_GREEN=$?
if [ "$RC_GREEN" -eq 0 ]; then
  ok "a green on top of the old streak exits 0 (the clock resets on a green)"
else
  bad "green-on-top fixture: expected rc 0, got $RC_GREEN"
  echo "$OUT_GREEN" >&2
fi

section "MUTATION — an always-false staleness comparison must un-red the red fixture"
MUT_STALE="$TMP/mut-staleness.sh"
sed 's|if \[ "\$age" -gt "\$GRACE_SECONDS" \]; then     # MUT: staleness comparison|if false; then     # MUT: staleness comparison|' \
  "$ROLLUP" > "$MUT_STALE"
chmod +x "$MUT_STALE"
if cmp -s "$ROLLUP" "$MUT_STALE"; then
  bad "the staleness mutation changed nothing — the # MUT anchor has drifted; this arm measures NOTHING"
else
  ok "staleness mutation applied (the '# MUT: staleness comparison' line is now 'if false')"
  OUT_MUT="$("$MUT_STALE" --workflows-dir "$WFD" --spec "$SPEC" --now "$NOW" --grace-hours 24 --runs-file "$TMP/runs-red.json" 2>&1)"
  RC_MUT=$?
  if [ "$RC_MUT" -eq 0 ]; then
    ok "mutant goes GREEN on the red fixture (rc 0) — the comparison is load-bearing"
  else
    bad "mutant still rc $RC_MUT on the red fixture; the staleness comparison is not what decided"
    echo "$OUT_MUT" >&2
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
section "THE DENOMINATOR IS THE TREE, and a zero-run workflow is printed"

case "$OUT_RED" in
  *"enumerated 3 workflow files"*) ok "denominator printed: enumerated 3 workflow files" ;;
  *) bad "denominator line absent or wrong"; echo "$OUT_RED" >&2 ;;
esac
case "$OUT_RED" in
  *"gamma.yml"*"NO COMPLETED RUN ON main"*)
    ok "gamma.yml (zero runs on main) is printed with that fact, never omitted" ;;
  *) bad "the zero-run workflow was omitted or unlabelled"; echo "$OUT_RED" >&2 ;;
esac
case "$OUT_RED" in
  *"read 5 completed runs on main"*)
    ok "the READ WINDOW is printed: 5 completed runs (the 6th fixture entry is in_progress and is not one)" ;;
  *) bad "the read-window line is absent or wrong — 'no completed run' would be an unbounded claim"; echo "$OUT_RED" >&2 ;;
esac
case "$OUT_RED" in
  *"NO COMPLETED RUN ON main among the 5 read"*)
    ok "the zero-run line is relative to that window, not to all of history" ;;
  *) bad "the zero-run line does not name the window it is relative to"; echo "$OUT_RED" >&2 ;;
esac
case "$OUT_RED" in
  *"zero-run 1"*) ok "the summary line counts the zero-run workflow" ;;
  *) bad "summary line does not count zero-run workflows"; echo "$OUT_RED" >&2 ;;
esac

# The named mutation from the row: ADD a workflow file with no run on main.
cat > "$WFD/delta.yml" <<'YML'
name: Delta
on: [push]
jobs:
  delta:
    name: Delta job
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
YML
OUT_ADDED="$(run_rollup --runs-file "$TMP/runs-red.json")"
case "$OUT_ADDED" in
  *"enumerated 4 workflow files"*) ok "adding a workflow file raises the denominator 3 → 4" ;;
  *) bad "the denominator did NOT rise when the tree gained a workflow"; echo "$OUT_ADDED" >&2 ;;
esac
case "$OUT_ADDED" in
  *"delta.yml"*"NO COMPLETED RUN ON main"*)
    ok "the newly added, never-run workflow appears in the listing by name" ;;
  *) bad "the added workflow is absent from the listing"; echo "$OUT_ADDED" >&2 ;;
esac

section "MUTATION — a roster read from a fixed list must fail the arm above"
# This is what proves the denominator arm can LOSE. The enumeration is replaced
# by a hardcoded three-name list, exactly the defect the row describes ("reading
# a watched set rather than the tree").
MUT_ROSTER="$TMP/mut-roster.sh"
sed "s|^WF_FILES=\"\$(find .*|WF_FILES=\"\$WORKFLOWS_DIR/alpha.yml\\n\$WORKFLOWS_DIR/beta.yml\\n\$WORKFLOWS_DIR/gamma.yml\"|" \
  "$ROLLUP" > "$MUT_ROSTER"
chmod +x "$MUT_ROSTER"
if cmp -s "$ROLLUP" "$MUT_ROSTER"; then
  bad "the roster mutation changed nothing — the find line has drifted; this arm measures NOTHING"
else
  OUT_MR="$("$MUT_ROSTER" --workflows-dir "$WFD" --spec "$SPEC" --now "$NOW" --grace-hours 24 --runs-file "$TMP/runs-red.json" 2>&1)"
  case "$OUT_MR" in
    *"enumerated 4 workflow files"*|*delta.yml*)
      bad "the fixed-list mutant still saw delta.yml — the denominator arm cannot discriminate" ;;
    *"enumerated 3 workflow files"*)
      ok "fixed-list mutant still says 3 and never names delta.yml — the arm above is a real discriminator" ;;
    *) bad "fixed-list mutant printed neither denominator; arm inconclusive"; echo "$OUT_MR" >&2 ;;
  esac
fi
rm -f "$WFD/delta.yml"

# ═══════════════════════════════════════════════════════════════════════════
section "REQUIRED vs ADVISORY is derived from the spec"

case "$OUT_RED" in
  *"REQUIRED  alpha.yml"*) ok "alpha.yml (renders 'Elixir gate') reads REQUIRED" ;;
  *) bad "alpha.yml was not labelled REQUIRED"; echo "$OUT_RED" >&2 ;;
esac
case "$OUT_RED" in
  *"ADVISORY  beta.yml"*) ok "beta.yml (renders no required context) reads ADVISORY" ;;
  *) bad "beta.yml was not labelled ADVISORY"; echo "$OUT_RED" >&2 ;;
esac
case "$OUT_RED" in
  *'required-context="Elixir gate"'*) ok "the row names WHICH required context it matched" ;;
  *) bad "the REQUIRED row does not say which context it matched"; echo "$OUT_RED" >&2 ;;
esac

# THE NAMED MUTATION: move the context between required and excluded.
OUT_MOVED="$("$ROLLUP" --workflows-dir "$WFD" --spec "$SPEC_MOVED" --now "$NOW" \
             --grace-hours 24 --runs-file "$TMP/runs-red.json" 2>&1)"
case "$OUT_MOVED" in
  *"ADVISORY  alpha.yml"*) ok "moving 'Elixir gate' into .exclusions flips alpha.yml to ADVISORY" ;;
  *) bad "alpha.yml did NOT flip when the spec moved its context out of required"; echo "$OUT_MOVED" >&2 ;;
esac
case "$OUT_MOVED" in
  *"REQUIRED  alpha.yml"*) bad "alpha.yml is still REQUIRED under the moved spec — the label is hardcoded" ;;
  *) ok "no REQUIRED alpha.yml row survives the moved spec" ;;
esac

section "NO LIST OF CONTEXT NAMES LIVES IN THE SCRIPT BODY"
# The label must come from the spec at run time. A required context name spelled
# out in the EXECUTABLE part of the script is the failure mode this arm exists
# to catch. Full-line comments are stripped first and deliberately so: the
# header documents which four workflows render the required four today, and
# documenting the derivation is not performing it. Everything that survives the
# strip is code.
BODY="$TMP/rollup-body.sh"
grep -v '^[[:space:]]*#' "$ROLLUP" > "$BODY"
if [ ! -s "$BODY" ]; then
  bad "the comment strip emptied the script — this arm is measuring nothing"
else
  ok "control: the comment-stripped body is $(wc -l < "$BODY" | tr -d ' ') lines, not empty"
  HARDCODED=0
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    if grep -qF -- "$ctx" "$BODY"; then
      bad "the script BODY spells out the required context '$ctx' — the label is not derived"
      HARDCODED=1
    fi
  done < <(jq -r '.protection.required_status_checks.checks[].context' "$REPO_ROOT/.github/required-checks.json")
  [ "$HARDCODED" -eq 0 ] && ok "no live required context name appears in the script body"
  # POSITIVE CONTROL: the same grep over a body that DOES carry one must fire,
  # or the arm above is an absence claim nobody proved can be made.
  CTRL_CTX="$(jq -r '.protection.required_status_checks.checks[0].context' "$REPO_ROOT/.github/required-checks.json")"
  { cat "$BODY"; echo "HARDCODED_LIST=\"$CTRL_CTX\""; } > "$TMP/rollup-body-control.sh"
  if grep -qF -- "$CTRL_CTX" "$TMP/rollup-body-control.sh"; then
    ok "positive control: the same grep DOES fire on a body carrying '$CTRL_CTX'"
  else
    bad "positive control did not fire — the absence arm above proves nothing"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
section "A BLIND ROLL-UP NEVER REPORTS GREEN (configuration faults are rc 3)"

"$ROLLUP" --workflows-dir "$TMP/does-not-exist" --spec "$SPEC" --now "$NOW" \
          --runs-file "$TMP/runs-red.json" >/dev/null 2>&1
[ $? -eq 3 ] && ok "a missing workflows dir is rc 3, not rc 0" || bad "missing workflows dir did not exit 3"

EMPTY_DIR="$TMP/empty"; mkdir -p "$EMPTY_DIR"
"$ROLLUP" --workflows-dir "$EMPTY_DIR" --spec "$SPEC" --now "$NOW" \
          --runs-file "$TMP/runs-red.json" >/dev/null 2>&1
[ $? -eq 3 ] && ok "an EMPTY workflows dir is rc 3 — zero enumerated is not a clean bill of health" \
             || bad "empty workflows dir did not exit 3"

echo '{"repo":"x/y","branch":"main","protection":{"required_status_checks":{"checks":[]}}}' > "$TMP/spec-empty.json"
"$ROLLUP" --workflows-dir "$WFD" --spec "$TMP/spec-empty.json" --now "$NOW" \
          --runs-file "$TMP/runs-red.json" >/dev/null 2>&1
[ $? -eq 3 ] && ok "a spec with an EMPTY required set is rc 3, never 'everything is advisory'" \
             || bad "empty required set did not exit 3"

"$ROLLUP" --workflows-dir "$WFD" --spec "$SPEC" --now "$NOW" \
          --runs-file "$TMP/nope.json" >/dev/null 2>&1
[ $? -eq 3 ] && ok "an unreadable runs file is rc 3, never an empty green" || bad "unreadable runs file did not exit 3"

echo 'not json at all' > "$TMP/runs-garbage.json"
"$ROLLUP" --workflows-dir "$WFD" --spec "$SPEC" --now "$NOW" \
          --runs-file "$TMP/runs-garbage.json" >/dev/null 2>&1
[ $? -eq 3 ] && ok "a non-JSON runs payload is rc 3" || bad "non-JSON runs payload did not exit 3"

"$ROLLUP" --workflows-dir "$WFD" --spec "$SPEC" --now "not-a-timestamp" \
          --runs-file "$TMP/runs-red.json" >/dev/null 2>&1
[ $? -eq 3 ] && ok "an unparseable --now is rc 3" || bad "unparseable --now did not exit 3"

section "IN-FLIGHT RUNS ARE NOT VERDICTS"
# The payloads carry an in_progress beta run NEWER than every completed one. If
# it were counted, beta's newest conclusion would read as the empty string and
# the red would vanish.
case "$OUT_RED" in
  *"beta.yml"*"newest=failure at 2026-09-11T11:30:00Z"*)
    ok "the in_progress run (11:59Z) is excluded; beta's newest COMPLETED verdict decides" ;;
  *) bad "an in-flight run leaked into the newest-conclusion read"; echo "$OUT_RED" >&2 ;;
esac

section "THE LIVE TREE (smoke, still offline)"
LIVE_OUT="$("$ROLLUP" --spec "$REPO_ROOT/.github/required-checks.json" \
            --runs-file "$TMP/runs-red.json" --now "$NOW" 2>&1)"
LIVE_N="$(printf '%s\n' "$LIVE_OUT" | awk '/^enumerated [0-9]+ workflow files/ {print $2; exit}')"
TREE_N="$(find "$REPO_ROOT/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | wc -l | tr -d ' ')"
if [ -n "$LIVE_N" ] && [ "$LIVE_N" = "$TREE_N" ]; then
  ok "against the real tree the denominator equals the file count ($TREE_N)"
else
  bad "denominator '$LIVE_N' != real workflow file count '$TREE_N'"
fi
for wf in cloud.yml console-harness.yml elixir.yml pr-task-gate.yml; do
  case "$LIVE_OUT" in
    *"REQUIRED  $wf"*) ok "live tree: $wf reads REQUIRED off the committed spec" ;;
    *) bad "live tree: $wf did not read REQUIRED"; echo "$LIVE_OUT" | grep -F "$wf" >&2 ;;
  esac
done

echo
echo "main-workflow-rollup.test.sh — $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
