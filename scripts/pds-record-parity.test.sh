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
run() { run_at "$ARM" "$@"; }

# `run_at <arm-path> <expected-rc> <label> -- <args…>` — the same, against a COPY
# of the arm planted in another repository. The shallow / off-HEAD-graft fixtures
# need this: the arm `cd`s to `dirname $0/..`, so the only way to point its
# default `git log` corpus at a fixture repo is to run the copy that lives there.
run_at() {
  local arm="$1" want="$2" label="$3"; shift 4
  CHECKS=$((CHECKS + 1))
  LAST_OUT="$(bash "$arm" "$@" 2>&1)"
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

# `harness_fail <msg>` — a FIXTURE that did not come out in the shape it needs to
# be in proves nothing about the arm, and must never be scored as a pass.
harness_fail() {
  FAILURES=$((FAILURES + 1))
  CHECKS=$((CHECKS + 1))
  echo "FAIL  FIXTURE PRECONDITION: $1"
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

# ══ AXIS A, THE DEFAULT PATH — the `git log` corpus itself ═══════════════════
#
# EVERY fixture above hands the arm a `--commits-file`, which means the DEFAULT
# corpus — `git log` — had ZERO coverage, and that is exactly where the vacuous
# green lived: under `git clone --depth 1` the arm printed `cited: 0 /
# unresolved: 0` and PARITY at exit 0, the same verdict sentence a full checkout
# prints over 188 citations. actions/checkout@v4 is shallow BY DEFAULT.
#
# These fixtures are hermetic and NETWORK-FREE: a synthetic origin cloned over
# `file://` (a local transport — and the only one under which `--depth` is not
# silently ignored). Global/system git config is neutered so a host with, say,
# `commit.gpgsign = true` cannot break fixture construction.
echo "AXIS A — the default git-log corpus (truncated-walk guard)"

GITFX="$(cd "$TMP" && pwd -P)/gitfx"          # physical: GIT_CEILING_DIRECTORIES does not resolve symlinks
mkdir -p "$GITFX"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=pds GIT_AUTHOR_EMAIL=pds@example.invalid
export GIT_COMMITTER_NAME=pds GIT_COMMITTER_EMAIL=pds@example.invalid

# `plant <dir>` — put a copy of the arm where its own `cd $(dirname $0)/..`
# lands in the fixture repo.
plant() { mkdir -p "$1/scripts" && cp "$ARM" "$1/scripts/pds-record-parity.sh"; }

# ORIGIN: `main` cites PDS-D1..3 (all defined by $CH). An ORPHAN `sidecar`
# branch cites PDS-D9 and shares no ancestor with main — that disjointness is
# what makes the off-HEAD graft below genuinely off-HEAD.
ORIGIN="$GITFX/origin"
(
  set -e
  git init -q -b main "$ORIGIN"
  cd "$ORIGIN"
  for n in 1 2 3; do echo "$n" > "f$n"; git add -A; git commit -q -m "chore: per PDS-D$n"; done
  git checkout -q --orphan sidecar
  git rm -q -rf . >/dev/null 2>&1 || true
  echo s > s.txt; git add -A; git commit -q -m "chore: sidecar per PDS-D9"
  git checkout -q main
) >/dev/null 2>&1 || harness_fail "could not build the synthetic origin repo"

# ── (1) THE REAL CASE: a --depth 1 checkout ──────────────────────────────────
SHALLOW="$GITFX/shallow"
git clone -q --depth 1 "file://$ORIGIN" "$SHALLOW" >/dev/null 2>&1 || harness_fail "could not build the --depth 1 clone"
plant "$SHALLOW"
SH_GRAFT="$(head -1 "$SHALLOW/.git/shallow" 2>/dev/null || true)"
SH_HEAD="$(git -C "$SHALLOW" rev-parse HEAD 2>/dev/null || true)"
if [ -z "$SH_GRAFT" ] || [ "$SH_GRAFT" != "$SH_HEAD" ]; then
  harness_fail "the --depth 1 clone did not graft at HEAD (graft='${SH_GRAFT}' head='${SH_HEAD}') — the fixture would prove nothing"
fi

run_at "$SHALLOW/scripts/pds-record-parity.sh" 2 \
  "a --depth 1 checkout is UNCHECKED, never PARITY" -- --axis a --charter "$CH"
says "UNCHECKED: TRUNCATED WALK" "the refusal names the TRUNCATION"
says "$SH_GRAFT" "the refusal names the GRAFT it stopped at"
says "visible: 1 commit(s) reachable from HEAD" "the refusal states how much of the corpus it could see"
says "fetch-depth: 0" "the refusal names the CI fix"
says "git fetch --unshallow" "the refusal names the local fix"
says "--commits-file" "the refusal names the honest escape"
# The VERDICT SENTENCE, not the bare word: the refusal itself says the words
# "instead of printing PARITY at exit 0", and a needle that loose would red on
# the arm's own explanation of what it refused to do.
says_not "pds-record-parity: PARITY" "the truncated run does NOT print the parity verdict sentence"
says_not "unresolved: 0" "the truncated run does not report a citation tally it never computed"

# ── (2) THE ESCAPE STILL WORKS on that same shallow checkout ─────────────────
# Proves the guard is FENCED to the git-log path: --commits-file brings its own
# corpus, so the arm still runs — and can still RED.
run_at "$SHALLOW/scripts/pds-record-parity.sh" 0 \
  "the shallow checkout still RUNS when handed --commits-file" -- --axis a --charter "$CH" --commits-file "$CM_OK"
says "cited:      3 distinct PDS-D" "the escape reads the corpus it was handed, not the truncated walk"
run_at "$SHALLOW/scripts/pds-record-parity.sh" 1 \
  "the escape can still RED on a shallow checkout" -- --axis a --charter "$CH" --commits-file "$CM_BAD"
says "UNRESOLVED-CITATION PDS-D777" "the escape's red still names the offending citation"

# ── (3) THE OFF-HEAD GRAFT: store-shallow, HEAD complete ────────────────────
# THIS IS THE FIXTURE THAT PINS THE PREDICATE. One `--depth` fetch of an
# unrelated branch flips `--is-shallow-repository` to true for the whole
# repository while `git log HEAD` still reaches the root — the shape the shared
# checkout /Volumes/SATECHI/github/barkpark is in today (graft 360b675903, 5132
# commits, one root). A future builder who "simplifies" the predicate back to
# `--is-shallow-repository` reds HERE, by name.
OFFHEAD="$GITFX/offhead"
git clone -q "file://$ORIGIN" "$OFFHEAD" >/dev/null 2>&1 || harness_fail "could not build the full clone"
git -C "$OFFHEAD" fetch -q --depth 1 origin sidecar >/dev/null 2>&1 || harness_fail "could not plant the off-HEAD graft"
plant "$OFFHEAD"
OH_STORE="$(git -C "$OFFHEAD" rev-parse --is-shallow-repository 2>/dev/null || true)"
OH_GRAFT="$(head -1 "$OFFHEAD/.git/shallow" 2>/dev/null || true)"
git -C "$OFFHEAD" merge-base --is-ancestor "${OH_GRAFT:-HEAD}" HEAD >/dev/null 2>&1
OH_ANC=$?
if [ "$OH_STORE" != "true" ] || [ "$OH_ANC" -ne 1 ]; then
  harness_fail "the off-HEAD fixture is not in shape (is-shallow='${OH_STORE}' want true; is-ancestor rc=${OH_ANC} want 1) — it could pass for the wrong reason"
fi

run_at "$OFFHEAD/scripts/pds-record-parity.sh" 0 \
  "a store-shallow repo whose HEAD history is COMPLETE still RUNS" -- --axis a --charter "$CH"
says "cited:      3 distinct PDS-D" "the off-HEAD-graft repo's full corpus is read (3 commits, 3 citations)"
says "unresolved: 0" "the off-HEAD-graft repo greens on its real corpus"
says_not "TRUNCATED WALK" "a graft that is NOT an ancestor of HEAD does not truncate the walk"
says_not "WALK COMPLETENESS UNKNOWN" "an off-HEAD graft is a decided answer, not an unknown"

# ── (4) NOT A WORK TREE AT ALL — the pre-existing arm with zero coverage ────
# GIT_CEILING_DIRECTORIES stops git's upward search at the fixture root, so a
# host whose TMPDIR happens to sit inside a repository cannot make this pass
# (or fail) for the wrong reason. $GITFX is a PHYSICAL path for the same reason.
NOWT="$GITFX/nowt"
mkdir -p "$NOWT"
plant "$NOWT"
export GIT_CEILING_DIRECTORIES="$GITFX"
run_at "$NOWT/scripts/pds-record-parity.sh" 2 \
  "a directory that is not a work tree is UNCHECKED" -- --axis a --charter "$CH"
says "UNCHECKED: not inside a git work tree" "the UNCHECKED names the missing work tree"
says_not "TRUNCATED WALK" "the work-tree refusal is not mislabelled as a truncated walk"
unset GIT_CEILING_DIRECTORIES

unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

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

# …but a DECLARED ABSENCE is not a ghost. #6371 on the live record says
# literally `Task: n/a`; the canonical grammar extracts `n/a` as an id and the
# ledger 404s on it. Reporting that as "merged over a task id the ledger does
# not carry" is a true statement wearing the wrong sentence, and it REDS where
# the structurally identical no-trailer case is advisory. Two-sided: the
# sentinel must be advisory AND the real ghost above must still red, or the
# disposition rule has degraded into a suppression switch.
FXNA="$TMP/fxna"
mkdir -p "$FXNA"
prs "$FXNA/prs.json" \
  "701|2026-01-01T00:00:00Z|n/a" \
  "702|2026-01-03T00:00:00Z|N/A" \
  "703|2026-01-05T04:00:00Z|fixture-leaf-done"
ledger "$FXNA" fixture-leaf-done 200 "$(task_doc fixture-leaf-done done fixture-root-open)"
run 0 "a PR declaring \`Task: n/a\` is advisory, not a NOT-FOUND red" -- --axis b --fixture-dir "$FXNA"
says "declared none: 2 PRs declare a SENTINEL id" "both spellings of the sentinel are counted, case-insensitively"
says_not "NOT-FOUND  " "no ghost task is manufactured out of a declared absence"
says "task ids:   1 distinct across 3 PRs" "the sentinel never reaches the ledger sweep"

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

# THE PACE SLEEP MUST PRECEDE THE REQUEST IT PACES. It first shipped at the
# BOTTOM of the sweep loop, after every `continue` — so it fired only on rows
# that had already been fetched AND scored DIVERGENT, and paced nothing at all
# on a healthy ledger. Position is the whole behaviour here, and position is
# what this asserts: a wall-clock fixture over a canned transport that answers
# instantly could not tell the two placements apart.
CHECKS=$((CHECKS + 1))
PACE_LINE="$(grep -n 'sleep "\$PACE"' "$ARM" | head -1 | cut -d: -f1)"
FETCH_LINE="$(grep -n 'if ! ledger_fetch "\$tid"' "$ARM" | head -1 | cut -d: -f1)"
if [ -n "$PACE_LINE" ] && [ -n "$FETCH_LINE" ] && [ "$PACE_LINE" -lt "$FETCH_LINE" ]; then
  echo "ok    the PACE sleep sits BEFORE the ledger request it paces (${PACE_LINE} < ${FETCH_LINE})"
else
  FAILURES=$((FAILURES + 1))
  echo "FAIL  the PACE sleep must precede ledger_fetch (pace=${PACE_LINE:-none} fetch=${FETCH_LINE:-none})"
  echo "      below the fetch it paces only rows already scored — i.e. nothing on a healthy ledger"
fi

# THE TRUNCATION GUARD MUST STAY FENCED INSIDE THE `git log` BRANCH. Every axis-B
# fixture in this harness runs through --fixture-dir inside THIS full checkout, and
# every axis-A fixture but the four above hands over a --commits-file — so a future
# edit that hoists `walk_truncation` to top level would UNCHECK `--axis b` on every
# shallow CI checkout and this harness would stay GREEN. Position is the behaviour,
# so position is what is asserted (the PACE-sleep idiom above, same reason).
CHECKS=$((CHECKS + 1))
WT_CALLS="$(grep -cE '^[[:space:]]*walk_truncation$' "$ARM")"
WT_CALL="$(grep -nE '^[[:space:]]*walk_truncation$' "$ARM" | head -1 | cut -d: -f1)"
WT_WORKTREE="$(grep -n 'UNCHECKED: not inside a git work tree' "$ARM" | head -1 | cut -d: -f1)"
WT_LOG="$(grep -n "git log --format=%B | grep -oE 'PDS-D" "$ARM" | head -1 | cut -d: -f1)"
WT_AXISB="$(grep -n '^axis_b()' "$ARM" | head -1 | cut -d: -f1)"
if [ "$WT_CALLS" = "1" ] && [ -n "$WT_CALL" ] && [ -n "$WT_WORKTREE" ] && [ -n "$WT_LOG" ] &&
   [ -n "$WT_AXISB" ] && [ "$WT_WORKTREE" -lt "$WT_CALL" ] && [ "$WT_CALL" -lt "$WT_LOG" ] &&
   [ "$WT_LOG" -lt "$WT_AXISB" ]; then
  echo "ok    walk_truncation is called ONCE, inside axis A's git-log branch (${WT_WORKTREE} < ${WT_CALL} < ${WT_LOG} < ${WT_AXISB})"
else
  FAILURES=$((FAILURES + 1))
  echo "FAIL  walk_truncation must be called exactly once, between the work-tree check and the git log walk"
  echo "      (calls=${WT_CALLS} call=${WT_CALL:-none} worktree=${WT_WORKTREE:-none} log=${WT_LOG:-none} axis_b=${WT_AXISB:-none})"
  echo "      hoisted out of that branch it UNCHECKS --axis b and --commits-file on every shallow checkout"
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
