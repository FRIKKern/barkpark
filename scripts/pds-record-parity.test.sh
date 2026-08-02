#!/usr/bin/env bash
#
# MUTATION FIXTURES FOR THE PDS RECORD-PARITY ARM.
#
# THE SELFTEST IS THE DELIVERABLE, NOT A COURTESY. This arm's entire output is
# a success claim about the epic's own record, which makes it exactly the verb
# most able to lie — and every failure mode it exists to stop ALREADY exits 0
# when you get it wrong: a grace window as wide as its own sample greens over
# every divergent row in it; a `gh` with no credentials greens over a window it
# never read; a `$?` test on the trailer extractor greens over every PR that
# names no task at all. So a harness whose fixtures all PASS proves nothing: it
# proves the checker runs, which was never in doubt.
#
# EVERY FIXTURE BELOW PINS AN EXACT EXIT CODE, and the set is deliberately
# two-sided: the green fixtures catch a guard that degrades into ALWAYS-RED, the
# red ones catch a guard that degrades into ALWAYS-GREEN. Deleting either half
# leaves a harness that cannot tell a working arm from a broken one.
#
# NO NETWORK. Axis B runs through `--fixture-dir`, the arm's canned transport,
# which feeds the SAME extraction / status-scoring / disposition code the live
# run uses. Axis A runs through `--charter` + `--commits-file`. A fixture that
# bypassed that code would prove nothing about the live run.
#
# NO `timeout(1)` ANYWHERE — it does not exist on this darwin host, and inside
# an `&&` chain behind a pipe it printed EXIT=0 for a command that never ran.
#
# EXIT CODES UNDER TEST (from the arm)
#   0 PARITY    1 DIVERGENT    2 UNCHECKED / REFUSED    3 USAGE
#
# usage: bash scripts/pds-record-parity.test.sh   (exit 0 = all green)

set -uo pipefail

cd "$(dirname "$0")/.." || { echo "TEST HARNESS FAIL: cannot cd to the repo root" >&2; exit 99; }
ARM="scripts/pds-record-parity.sh"
[ -f "$ARM" ] || { echo "TEST HARNESS FAIL: $ARM not found from $PWD" >&2; exit 99; }
[ -f "scripts/pr-task-gate.sh" ] || { echo "TEST HARNESS FAIL: the canonical extractor is missing" >&2; exit 99; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pds-record-parity-selftest.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

CHECKS=0
FAILURES=0
LAST_OUT=""

# `run <expected-rc> <label> -- <args…>` — runs the arm hermetically and pins
# the exit code. The output is kept in LAST_OUT so a fixture can additionally
# assert on WHAT was said, not merely on the number: an arm that reds for the
# wrong reason is a different defect from an arm that reds.
run() {
  local want="$1" label="$2"; shift 3
  CHECKS=$((CHECKS + 1))
  LAST_OUT="$(bash "$ARM" "$@" 2>&1)"
  local got=$?
  if [ "$got" -ne "$want" ]; then
    FAILURES=$((FAILURES + 1))
    echo "FAIL  ${label}"
    echo "      expected exit ${want}, got ${got}"
    printf '      | %s\n' "$LAST_OUT" | head -40
    return 1
  fi
  echo "ok    ${label}  (exit ${got})"
  return 0
}

# `says <needle> <label>` — assert on the last run's output.
says() {
  local needle="$1" label="$2"
  CHECKS=$((CHECKS + 1))
  case "$LAST_OUT" in
    *"$needle"*) echo "ok    ${label}" ;;
    *) FAILURES=$((FAILURES + 1)); echo "FAIL  ${label}"; echo "      output did not contain: ${needle}" ;;
  esac
}

says_not() {
  local needle="$1" label="$2"
  CHECKS=$((CHECKS + 1))
  case "$LAST_OUT" in
    *"$needle"*) FAILURES=$((FAILURES + 1)); echo "FAIL  ${label}"; echo "      output WRONGLY contained: ${needle}" ;;
    *) echo "ok    ${label}" ;;
  esac
}

# ── fixture construction ─────────────────────────────────────────────────────

# `ledger <dir> <id> <http> <json>` — one canned ledger response. An id with NO
# file 404s, exactly as the live ledger answers for a task that does not exist.
ledger() {
  local dir="$1" id="$2" code="$3" body="$4"
  mkdir -p "$dir/task"
  { printf 'HTTP %s\n' "$code"; printf '%s' "$body"; } > "$dir/task/$id.http"
}

task_doc() { # task_doc <id> <lifecycle> <parent|->
  local id="$1" lc="$2" p="$3" pj="null"
  [ "$p" != "-" ] && pj="\"$p\""
  printf '{"result":{"_id":"%s","_type":"task","kind":"task","lifecycle_status":"%s","parent_id":%s}}' "$id" "$lc" "$pj"
}

# `prs <file> <spec…>` — a canned `gh pr list --json number,mergedAt,body,title`
# array. Each spec is `number|mergedAt|task-id-or-NONE`.
prs() {
  local out="$1"; shift
  local first=1
  printf '[' > "$out"
  local spec num when tid body
  for spec in "$@"; do
    IFS='|' read -r num when tid <<< "$spec"
    if [ "$tid" = "NONE" ]; then
      body="Some description with no trailer at all."
    elif [ "$tid" = "BACKTICK" ]; then
      # The exact shape an ad-hoc jq lens gets WRONG: a backtick-wrapped id.
      # The canonical extractor strips the backticks; a home-grown regex keeps
      # them and the ledger 404s on \`fixture-leaf-done\`, manufacturing a
      # NOT-FOUND that is an artifact of the reader.
      body=$'Summary line.\n\nTask: `fixture-leaf-done`\n'
    else
      body=$'Summary line.\n\nTask: '"$tid"$'\n\nMore prose after the trailer.\n'
    fi
    [ "$first" -eq 0 ] && printf ',' >> "$out"
    first=0
    jq -cn --argjson n "$num" --arg m "$when" --arg b "$body" --arg t "pr $num" \
      '{number:$n, mergedAt:$m, body:$b, title:$t}' >> "$out"
  done
  printf ']' >> "$out"
}

command -v jq >/dev/null 2>&1 || { echo "TEST HARNESS FAIL: jq is required to build fixtures" >&2; exit 99; }

echo "── pds-record-parity selftest ───────────────────────────────────────────"
echo

# ══ AXIS A ═══════════════════════════════════════════════════════════════════
echo "AXIS A — a commit may not cite an authority that does not exist"

CH="$TMP/charter.md"
cat > "$CH" <<'EOF'
# A charter

Some prose that mentions PDS-D999 in passing, which is a REFERENCE, not a
definition — a lens that counted it would call an undefined D defined.

- **PDS-D1** the first decision.
* **PDS-D2** the second, with an asterisk bullet.
**PDS-D3** the third, with no bullet at all.

## PDS-D404 a decision defined as a HEADING

Nothing else defines a D.
EOF

CM_OK="$TMP/commits-ok.txt"
printf 'fix(x): do a thing per PDS-D1 and PDS-D2\n\nfeat(y): PDS-D3\n' > "$CM_OK"
CM_BAD="$TMP/commits-bad.txt"
printf 'fix(x): PDS-D1\n\nfeat(y): cites PDS-D777 which nothing defines\n' > "$CM_BAD"

run 0 "axis A greens when every cited D resolves" -- --axis a --charter "$CH" --commits-file "$CM_OK"
says "defined:    3 distinct PDS-D" "axis A counts only the three DEFINED forms (bullet, asterisk, bare bold)"
says "unresolved: 0" "axis A reports zero unresolved"
says_not "PDS-D999" "a D merely MENTIONED in charter prose is not counted as defined"

# THE RED SIDE. Without this the arm could hardcode `unresolved: 0`.
run 1 "axis A REDS on a commit citing an undefined D" -- --axis a --charter "$CH" --commits-file "$CM_BAD"
says "UNRESOLVED-CITATION PDS-D777" "the red names the offending citation"

# RULING 1 — the heading lens is a LENS ARTIFACT, and the arm says so instead
# of gating on it. The fixture charter defines PDS-D1/2/3 as bullets and only
# PDS-D404 as a heading, so the heading lens loses all three real definitions.
run 0 "--heading-lens does NOT fold its red into the exit code" -- --axis a --charter "$CH" --commits-file "$CM_OK" --heading-lens
says "defined:    1 distinct PDS-D" "the heading lens sees only the one heading-defined D"
says "unresolved: 3" "the heading lens reports every bullet-defined D as unresolved"
says "LENS ARTIFACT" "the heading lens labels its own red as an artifact"

# A missing charter is UNCHECKED, never a pass — an arm that cannot read the
# charter has resolved exactly zero citations.
run 2 "a missing charter lands in UNCHECKED, never a silent PASS" -- --axis a --charter "$TMP/no-such-charter.md" --commits-file "$CM_OK"
says "UNCHECKED: charter not found" "the UNCHECKED names the missing charter"

echo

# ══ AXIS B ═══════════════════════════════════════════════════════════════════
echo "AXIS B — a merged PR may not leave its task row open"

# One window, six PRs, spanning 100 hours so a 6h grace is legal against it.
FX="$TMP/fx"
mkdir -p "$FX"
prs "$FX/prs.json" \
  "101|2026-01-01T00:00:00Z|fixture-leaf-done" \
  "102|2026-01-02T00:00:00Z|fixture-leaf-open" \
  "103|2026-01-03T00:00:00Z|fixture-root-open" \
  "104|2026-01-04T00:00:00Z|fixture-cancelled" \
  "105|2026-01-05T04:00:00Z|NONE" \
  "106|2026-01-05T04:00:00Z|BACKTICK"
ledger "$FX" fixture-leaf-done  200 "$(task_doc fixture-leaf-done  done   fixture-root-open)"
ledger "$FX" fixture-leaf-open  200 "$(task_doc fixture-leaf-open  open   fixture-root-open)"
ledger "$FX" fixture-root-open  200 "$(task_doc fixture-root-open  open   -)"
ledger "$FX" fixture-cancelled  200 "$(task_doc fixture-cancelled  cancelled fixture-root-open)"

# NOW is pinned far past the window so nothing is graced by accident. A fixture
# whose verdict depends on the wall clock is a fixture that rots.
export PDS_RECORD_PARITY_NOW=1800000000

run 1 "axis B REDS on the one leaf slice merged over an open row" -- --axis b --fixture-dir "$FX"
says "DIVERGENT  fixture-leaf-open" "the red names the leaf row"
says "EPIC-ROOT-IN-FLIGHT  fixture-root-open" "an open epic ROOT is advisory, never redding"
says "LEAF slices (REDDING):          1" "exactly one leaf reds"
says_not "DIVERGENT  fixture-leaf-done" "a done row is parity"
says_not "DIVERGENT  fixture-cancelled" "a cancelled row is terminal, not divergent"

# THE WINDOW HEADER — printed every run, or the denominator drifts in silence.
says "PR range:   #101 … #106" "the run prints the PR-number range it actually fetched"
says "span:       100.0 h" "the run prints the derived window span in hours"

# RULING 2, the OTHER direction: the root must not red merely because it is
# open, and the leaf must not be excused merely because its parent is.
says "terminal (done|cancelled):   2" "both terminal lifecycles are counted terminal"

# SHARP EDGE (a) — the extractor exits 0 with NO trailer and signals absence
# only by empty stdout. #105 has no trailer. If the arm tested `$?` it would
# read an empty task id as a successful extraction and then 404 on "".
says "no trailer: 1 PRs carry no Task: trailer" "a trailer-less PR is counted as such, not as an empty id"
says_not "NOT-FOUND  " "no NOT-FOUND is manufactured out of a trailer-less PR"

# REUSE, NOT A SECOND LENS — #106 wraps its id in backticks. The canonical
# extractor strips them; a home-grown jq regex keeps them and 404s.
says "task ids:   4 distinct across 6 PRs" "the backticked id resolves to the SAME task, via the canonical grammar"

# ── the vacuity assertion ────────────────────────────────────────────────────
# THE CENTRAL FIXTURE. A grace at least as wide as the window suppresses every
# divergent row in it and prints a green that proves nothing. The arm must
# REFUSE, not green.
run 2 "grace >= window span is REFUSED, not run vacuously" -- --axis b --fixture-dir "$FX" --grace-hours 168
says "REFUSED: grace (168 h) >= window span (100 h floor)" "the refusal names both numbers"
says_not "PARITY" "the refusal is not dressed up as a pass"

# The boundary, both sides. 100h span: 100 is refused, 99 runs.
run 2 "grace exactly equal to the span is refused (>=, not >)" -- --axis b --fixture-dir "$FX" --grace-hours 100
run 1 "grace one hour under the span still runs, and still reds" -- --axis b --fixture-dir "$FX" --grace-hours 99

# Grace DOES suppress an honestly-fresh row. Without this the arm could satisfy
# every fixture above by ignoring grace entirely.
FXG="$TMP/fxg"
mkdir -p "$FXG"
prs "$FXG/prs.json" \
  "201|2026-01-01T00:00:00Z|fixture-leaf-done" \
  "202|2026-01-05T04:00:00Z|fixture-leaf-open"
ledger "$FXG" fixture-leaf-done 200 "$(task_doc fixture-leaf-done done fixture-root-open)"
ledger "$FXG" fixture-leaf-open 200 "$(task_doc fixture-leaf-open open fixture-root-open)"
# now = 2026-01-05T05:00:00Z → the open row's PR merged 1h ago.
# Set it as a PLAIN assignment, not as a command prefix: a variable assignment
# prefixed to a SHELL FUNCTION call persists in the shell after the call in
# bash, so the prefix form would silently leak this clock into every later
# fixture — the harness would then be testing a different arm than it thinks.
PDS_RECORD_PARITY_NOW=1767589200
run 0 "a leaf whose latest PR merged inside grace is suppressed" -- --axis b --fixture-dir "$FXG" --grace-hours 6
says "GRACE      fixture-leaf-open" "the suppression is PRINTED, never silent"
# …and the same row reds once grace is narrow enough not to cover it.
run 1 "the same row REDS with a 0h grace — grace is doing real work" -- --axis b --fixture-dir "$FXG" --grace-hours 0
PDS_RECORD_PARITY_NOW=1800000000

# ── UNCHECKED, in every direction ───────────────────────────────────────────
# A 404 from the ledger is an ANSWER: the PR merged over a task id that does
# not exist. That is a definitive red, not an outage.
FX404="$TMP/fx404"
mkdir -p "$FX404/task"
prs "$FX404/prs.json" \
  "301|2026-01-01T00:00:00Z|fixture-ghost" \
  "302|2026-01-05T04:00:00Z|fixture-leaf-done"
ledger "$FX404" fixture-leaf-done 200 "$(task_doc fixture-leaf-done done fixture-root-open)"
run 1 "a merged PR naming a task the ledger does not carry is a definitive RED" -- --axis b --fixture-dir "$FX404"
says "NOT-FOUND  fixture-ghost" "the 404 row is named"

# A 2xx with no document in the envelope is an answer that answers NOTHING. It
# is not evidence the task is absent (absence answers 404) — UNCHECKED.
FXNULL="$TMP/fxnull"
mkdir -p "$FXNULL"
prs "$FXNULL/prs.json" \
  "401|2026-01-01T00:00:00Z|fixture-nulldoc" \
  "402|2026-01-05T04:00:00Z|fixture-leaf-done"
ledger "$FXNULL" fixture-nulldoc  200 '{"result":null}'
ledger "$FXNULL" fixture-leaf-done 200 "$(task_doc fixture-leaf-done done fixture-root-open)"
run 2 "a 2xx with no task document is UNCHECKED, never a pass" -- --axis b --fixture-dir "$FXNULL"
says "with no task document in the envelope" "the UNCHECKED says what it saw"

# UNCHECKED OUTRANKS DIVERGENT. The worst-case fold, proven: a window carrying
# BOTH an unreadable row and a red row must exit 2, because "the rule could not
# be checked" is a bigger claim than "the rule was checked and broken".
FXBOTH="$TMP/fxboth"
mkdir -p "$FXBOTH"
prs "$FXBOTH/prs.json" \
  "501|2026-01-01T00:00:00Z|fixture-nulldoc" \
  "502|2026-01-05T04:00:00Z|fixture-leaf-open"
ledger "$FXBOTH" fixture-nulldoc  200 '{"result":null}'
ledger "$FXBOTH" fixture-leaf-open 200 "$(task_doc fixture-leaf-open open fixture-root-open)"
run 2 "UNCHECKED outranks DIVERGENT in the worst-case fold" -- --axis b --fixture-dir "$FXBOTH"
says "DIVERGENT  fixture-leaf-open" "the divergent row is still REPORTED, only outranked"

# An EMPTY window cannot falsify anything. Exiting 0 over it would be the exact
# vacuous green this arm exists to refuse.
FXEMPTY="$TMP/fxempty"
mkdir -p "$FXEMPTY"
printf '[]' > "$FXEMPTY/prs.json"
run 2 "an empty PR window is UNCHECKED, never a green" -- --axis b --fixture-dir "$FXEMPTY"
says "window is EMPTY" "the empty-window refusal says why"

# A transport that answers with something that is not an array answered without
# answering.
FXJUNK="$TMP/fxjunk"
mkdir -p "$FXJUNK"
printf '{"message":"Not Found"}' > "$FXJUNK/prs.json"
run 2 "a non-array PR list is UNCHECKED" -- --axis b --fixture-dir "$FXJUNK"

# A green window — no divergent leaves anywhere. Without this fixture an arm
# that had degraded into ALWAYS-RED would still pass every red fixture above.
FXOK="$TMP/fxok"
mkdir -p "$FXOK"
prs "$FXOK/prs.json" \
  "601|2026-01-01T00:00:00Z|fixture-leaf-done" \
  "602|2026-01-05T04:00:00Z|fixture-cancelled"
ledger "$FXOK" fixture-leaf-done 200 "$(task_doc fixture-leaf-done done fixture-root-open)"
ledger "$FXOK" fixture-cancelled 200 "$(task_doc fixture-cancelled cancelled fixture-root-open)"
run 0 "a window whose every row is terminal is PARITY (exit 0)" -- --axis b --fixture-dir "$FXOK"
says "PARITY" "the green says PARITY"

# ── offline / credential-less ───────────────────────────────────────────────
# `gh` absent and `gh` present-but-credential-less both land in UNCHECKED. A
# PATH with no gh on it reproduces the first exactly; the second is reproduced
# by pointing gh's config at a directory that does not exist, which makes real
# gh exit 4.
echo
echo "OFFLINE — the arm must never green because it could not look"

# A PATH carrying EVERY tool the arm needs EXCEPT gh. A blanket
# PATH=/nonexistent would also remove jq and would therefore prove only that
# the jq guard fires — a fixture that passes for the wrong reason is not
# evidence about the branch it claims to cover.
SHIMBIN="$TMP/bin-no-gh"
mkdir -p "$SHIMBIN"
for t in bash dirname env jq curl base64 date sed grep awk head tail cut sort uniq wc tr mktemp sleep cat rm cp printf; do
  p="$(command -v "$t" 2>/dev/null)" || continue
  ln -sf "$p" "$SHIMBIN/$t"
done
[ -x "$SHIMBIN/jq" ] || { echo "TEST HARNESS FAIL: could not shim jq into the no-gh PATH" >&2; exit 99; }
CHECKS=$((CHECKS + 1))
OUT="$(PATH="$SHIMBIN" bash "$ARM" --axis b 2>&1)"; RC=$?
case "$OUT" in
  *"\`gh\` is not installed"*)
    if [ "$RC" -eq 2 ]; then
      echo "ok    a PATH with jq but NO gh lands in UNCHECKED  (exit 2)"
    else
      FAILURES=$((FAILURES + 1)); echo "FAIL  a missing gh must exit 2, got ${RC}"
    fi ;;
  *)
    FAILURES=$((FAILURES + 1))
    echo "FAIL  a missing gh must be named as the reason for UNCHECKED"
    printf '      | %s\n' "$OUT" | head -10 ;;
esac

if command -v gh >/dev/null 2>&1; then
  # A REAL gh, failing for real, without ever reaching a real window. The repo
  # is deliberately unresolvable so this fixture cannot degrade into a live
  # 400-PR sweep on a host (or a CI runner) whose gh IS authenticated — a
  # "credential-less" fixture that quietly performs the full live run is not a
  # fixture, it is a second production invocation wearing a test's name.
  # Unauthenticated hosts take this branch with gh's exit 4 (NO CREDENTIALS);
  # authenticated ones take it with gh's repo-resolution failure. Both are the
  # contract under test: gh non-zero => UNCHECKED, never a silent PASS.
  CHECKS=$((CHECKS + 1))
  OUT="$(GH_CONFIG_DIR="$TMP/no-such-gh-config" GH_TOKEN="" GITHUB_TOKEN="" \
         PDS_RECORD_PARITY_REPO="FRIKKern/pds-record-parity-selftest-no-such-repo" \
         bash "$ARM" --axis b 2>&1)"; RC=$?
  case "$OUT" in
    *"UNCHECKED: \`gh pr list\` exited"*)
      if [ "$RC" -eq 2 ]; then
        echo "ok    a failing gh lands in UNCHECKED  (exit 2)"
      else
        FAILURES=$((FAILURES + 1)); echo "FAIL  a failing gh must exit 2, got ${RC}"
      fi ;;
    *)
      FAILURES=$((FAILURES + 1))
      echo "FAIL  a failing gh must be named as the reason for UNCHECKED"
      printf '      | %s\n' "$OUT" | head -10 ;;
  esac
fi

# ── the arm's own hygiene ───────────────────────────────────────────────────
echo
echo "HYGIENE"
CHECKS=$((CHECKS + 1))
# The needle is assembled at runtime so that this harness does not itself
# contain the string it is asserting the absence of — the criterion is a raw
# grep over both files, and a self-matching assertion would red forever.
NEEDLE='timeout'
N_TIMEOUT=$(grep -c "${NEEDLE} " "$ARM" "${BASH_SOURCE[0]}" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
if [ "$N_TIMEOUT" -eq 0 ]; then
  echo "ok    neither file invokes ${NEEDLE}(1)"
else
  FAILURES=$((FAILURES + 1)); echo "FAIL  ${NEEDLE}(1) appears ${N_TIMEOUT}x — it does not exist on this host and reported EXIT=0 for a command that never ran"
fi

CHECKS=$((CHECKS + 1))
if grep -q 'bash "$EXTRACTOR" --extract-task-id' "$ARM"; then
  echo "ok    the task-id extractor is the canonical scripts/pr-task-gate.sh verb"
else
  FAILURES=$((FAILURES + 1)); echo "FAIL  the arm has grown a second copy of the trailer grammar"
fi

run 3 "an unknown argument is a USAGE error (exit 3)" -- --nonsense
run 3 "a --grace-hours that is not a number is a USAGE error" -- --grace-hours six

echo
echo "─────────────────────────────────────────────────────────────────────────"
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS  ${CHECKS} checks, 0 failures"
  exit 0
fi
echo "FAIL  ${CHECKS} checks, ${FAILURES} failures"
exit 1
