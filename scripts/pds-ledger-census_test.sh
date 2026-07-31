#!/usr/bin/env bash
#
# MUTATION FIXTURES FOR THE PDS LEDGER CENSUS.
#
# THE SELFTEST IS THE DELIVERABLE, NOT A COURTESY. A census is a verb whose
# entire output is a success claim, and every failure mode this instrument
# exists to stop -- a rate-limited page, a silently capped page, a truncated
# page, a one-level lens, a cleanly-parsing failure envelope -- ALREADY exits 0
# and reports a SMALLER board when you get it wrong. So a selftest whose
# fixtures all pass proves nothing at all: it proves the checker runs, which was
# never in doubt. Every fixture below is a MUTATION that must make the census
# EXIT NON-ZERO, and each one asserts the exact exit code, so a guard that
# degrades into "always red" is caught by the green fixtures and a guard that
# degrades into "always green" is caught by the red ones.
#
# Shape borrowed from api/scripts/sobelow-baseline-staleness-check.sh --selftest,
# which is this repo's existing example of the pattern (8 fixtures, each pinned
# to a specific exit code).
#
# NO NETWORK. Every fixture runs through --fixture-dir, the census's canned-HTTP
# transport, which feeds the SAME status-scoring / shape-asserting / paging code
# the live run uses. A fixture that bypassed that code would prove nothing about
# the live run.
#
# EXIT CODES UNDER TEST (from the census)
#   0 coherent census    1 round-done predicate false    2 fail closed
#   3 usage              4 snapshot incoherent
#
# usage: bash scripts/pds-ledger-census_test.sh

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CENSUS="$HERE/pds-ledger-census.sh"
ROOT_SLUG="fixture-root"
FAILURES=0
CHECKS=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pds-ledger-census-selftest.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

# --- fixture construction -----------------------------------------------------
#
# `page <dir> <index> <status> <json>` writes one canned HTTP response.

page() {
  local dir=$1 index=$2 status=$3 body=$4
  mkdir -p "$dir"
  { printf 'HTTP %s\n' "$status"; printf '%s' "$body"; } > "$dir/page-$index.http"
}

# A row, as the query endpoint serves it. Deliberately three levels deep so a
# one-level lens has a grandchild to lose.
#
# The SIXTH field is the STRUCTURED `reopen_trigger`, and it is omitted from the
# JSON entirely when empty -- exactly how a row that never carried one is served.
# Clause 4(c) reads this field and nothing else, so a fixture that could only
# express a trigger as prose could not tell the two apart.
# The SEVENTH field is `_createdAt`, and it is likewise omitted when empty --
# the live `row()` shape has never carried one, and clause 4(a)'s anchor reads it
# ONLY for rows that are already live-and-bare, so every pre-existing fixture is
# untouched by its absence. An anchored fixture must supply it or fail closed.
row() {
  local id=$1 parent=$2 lifecycle=$3 disposition=$4 reason=$5 trigger=${6:-} created=${7:-}
  local extra=''
  if [[ -n $trigger ]]; then
    extra=$(printf ',"reopen_trigger":"%s"' "$trigger")
  fi
  if [[ -n $created ]]; then
    extra+=$(printf ',"_createdAt":"%s"' "$created")
  fi
  printf '{"_id":"%s","_type":"task","_updatedAt":"2020-01-01T00:00:00.000000Z","parent_id":%s,"lifecycle_status":"%s","disposition":"%s","disposition_reason":"%s"%s}' \
    "$id" "$parent" "$lifecycle" "$disposition" "$reason" "$extra"
}

# `paper <dir> <slug> <status> <json>` cans the ANCHOR read --
# GET /v1/data/doc/<dataset>/paper/<slug>. It runs through the same
# status-first / shape-asserted resolver the live run uses, so a fixture here
# proves something about the live anchor and not merely about the fixture.
paper() {
  local dir=$1 slug=$2 status=$3 body=$4
  mkdir -p "$dir"
  { printf 'HTTP %s\n' "$status"; printf '%s' "$body"; } > "$dir/paper-$slug.http"
}

# A well-formed page envelope.
envelope() {
  local count=$1 offset=$2 limit=$3 docs=$4
  printf '{"result":{"count":%s,"offset":%s,"limit":%s,"perspective":"published","documents":[%s]}}' \
    "$count" "$offset" "$limit" "$docs"
}

# THE HEALTHY CORPUS. 7 rows over 2 pages of limit 4, so the walk MUST reach
# page 1 to be complete: `deep-a` and `deep-b` are grandchildren that live only
# on the second page. Every reason is distinct, every disposition is in
# vocabulary, every reason MENTIONS a reopen trigger in prose -- and exactly one
# row, `kid-c`, the only LIVE park, carries the STRUCTURED `reopen_trigger`
# field. That asymmetry is the point: a healthy board is 1 structured against 4
# prose-only, and the two numbers are reported side by side, never summed.
build_healthy() {
  local dir=$1
  local p0 p1
  p0="$(row "$ROOT_SLUG" 'null' open open 'root row. REOPEN: never'),"
  p0+="$(row kid-a "\"$ROOT_SLUG\"" open open 'kid a reason one. REOPEN: alpha'),"
  p0+="$(row kid-b "\"$ROOT_SLUG\"" done closed 'kid b reason two. REACTIVATE: bravo'),"
  p0+="$(row kid-c "\"$ROOT_SLUG\"" blocked parked 'kid c reason three. REOPEN: charlie' 'TRIGGER: charlie ships')"
  p1="$(row deep-a '"kid-a"' open open 'deep a reason four. REOPEN: delta'),"
  p1+="$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),"
  p1+="$(row unrelated 'null' open open 'not under the root at all. REOPEN: foxtrot')"
  page "$dir" 0 200 "$(envelope 4 0 4 "$p0")"
  page "$dir" 1 200 "$(envelope 3 4 4 "$p1")"
}

# --- assertion helpers --------------------------------------------------------

expect_status() {
  local label=$1 want=$2
  shift 2
  CHECKS=$((CHECKS + 1))
  local got=0 out
  out=$("$@" 2>&1) || got=$?
  if [[ $got -ne $want ]]; then
    printf 'SELFTEST FAIL: %s — expected exit %d, got %d\n%s\n' "$label" "$want" "$got" "$out" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  printf '  ok    %-52s exit %d\n' "$label" "$got"
}

# A red exit is not enough: it has to be red for the RIGHT reason, or a guard
# can rot into a different failure and the fixture will never notice.
expect_status_matching() {
  local label=$1 want=$2 needle=$3
  shift 3
  CHECKS=$((CHECKS + 1))
  local got=0 out
  out=$("$@" 2>&1) || got=$?
  if [[ $got -ne $want ]]; then
    printf 'SELFTEST FAIL: %s — expected exit %d, got %d\n%s\n' "$label" "$want" "$got" "$out" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  if [[ $out != *"$needle"* ]]; then
    printf 'SELFTEST FAIL: %s — exit %d was right but the reason was not: expected to find %q\n%s\n' \
      "$label" "$got" "$needle" "$out" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  printf '  ok    %-52s exit %d  (%s)\n' "$label" "$got" "$needle"
}

expect_output_contains() {
  local label=$1 needle=$2
  shift 2
  CHECKS=$((CHECKS + 1))
  local out
  out=$("$@" 2>&1)
  if [[ $out != *"$needle"* ]]; then
    printf 'SELFTEST FAIL: %s — output did not contain %q\n%s\n' "$label" "$needle" "$out" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  printf '  ok    %-52s contains %q\n' "$label" "$needle"
}

run() {
  bash "$CENSUS" --root "$ROOT_SLUG" --pace 0 --retries 0 "$@"
}

echo "pds-ledger-census selftest: mutation fixtures"
echo

# =============================================================================
# CONTROL. The instrument must be able to be GREEN, or every red below is
# meaningless.
# =============================================================================
echo "control — a healthy 2-page corpus"
HEALTHY="$TMP/healthy"
build_healthy "$HEALTHY"
expect_status "healthy corpus censuses cleanly" 0 \
  run --page-limit 4 --fixture-dir "$HEALTHY"
# It must reach page 1: deep-a/deep-b are grandchildren that exist ONLY there,
# and `unrelated` (page 1, no parent) must NOT be counted.
expect_output_contains "closure is 5, not 3 (page 1 was read)" "closure     5 descendants" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
expect_output_contains "live is 3 (done + cancelled are terminal)" "live        3" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
expect_output_contains "reasons are all distinct" "distinct reason hashes          5" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
# STRUCTURED and PROSE are counted separately and never summed: 1 row carries the
# field, 4 only talk about it. A summed counter would print 5 and call it coverage.
expect_output_contains "structured triggers are counted alone" "carrying a reopen trigger       1   (structured" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
expect_output_contains "prose mentions are counted as DECORATION, beside" "prose-only REOPEN mention       4   (DECORATION" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
expect_output_contains "no off-vocabulary dispositions" "(none)" \
  run --page-limit 4 --fixture-dir "$HEALTHY"
# The done-condition must be able to be GREEN too. A predicate that is red on
# everything is not a predicate.
expect_status "--assert-round-done PASSES on a clean board" 0 \
  run --page-limit 4 --fixture-dir "$HEALTHY" --assert-round-done
echo

# =============================================================================
# CLAUSE 3 — RATE LIMITING. The 429 body is VALID JSON. A census that scores on
# "json.load succeeded", or on an `error.code` key, reads this AS DATA and
# counts the rows it never got as leaves.
# =============================================================================
echo "clause 3 — a rate-limited fetch must FAIL, never be counted as a leaf"
RATE="$TMP/rate-limited"
build_healthy "$RATE"
page "$RATE" 1 429 '{"ok":false,"error":{"code":"rate_limited","message":"slow down"}}'
expect_status_matching "429 on page 1 fails closed" 2 "rate limited" \
  run --page-limit 4 --fixture-dir "$RATE"
# and it must NOT quietly report the 3 rows it did get
expect_status_matching "429 reports no board at all" 2 "refusing to treat a rate-limited response as an empty page" \
  run --page-limit 4 --fixture-dir "$RATE"
# with retries budgeted, it backs off and then still fails closed
expect_status_matching "429 still fails after its retries" 2 "after 2 retries" \
  bash "$CENSUS" --root "$ROOT_SLUG" --pace 0 --retries 2 --page-limit 4 --fixture-dir "$RATE"
# backoff must RECOVER, not merely fail: 429 on the first attempt, the real page
# on the retry. A guard that only ever reds under 429 would be a different bug.
RECOVER="$TMP/rate-limited-recovers"
build_healthy "$RECOVER"
cp "$RECOVER/page-1.http" "$RECOVER/page-1-keep.http"
page "$RECOVER" 1 429 '{"ok":false,"error":{"code":"rate_limited"}}'
mv "$RECOVER/page-1.http" "$RECOVER/page-1-attempt-0.http"
mv "$RECOVER/page-1-keep.http" "$RECOVER/page-1.http"
expect_status "429 then success on retry censuses cleanly" 0 \
  bash "$CENSUS" --root "$ROOT_SLUG" --pace 0 --retries 2 --page-limit 4 --fixture-dir "$RECOVER"
# a 429 on the FIRST page must not read as an empty population either
RATE0="$TMP/rate-limited-first"
page "$RATE0" 0 429 '{"ok":false,"error":{"code":"rate_limited"}}'
expect_status_matching "429 on page 0 is not an empty board" 2 "rate limited" \
  run --page-limit 4 --fixture-dir "$RATE0"
echo

# =============================================================================
# CLAUSE 1 — PAGING. `limit=5000` is answered HTTP 200 with `limit: 1000`. The
# server never says it capped. A reader that trusts its own request reports a
# smaller board and exits 0.
# =============================================================================
echo "clause 1 — an unpaginated / truncated read must FAIL, not shrink the board"
CAPPED="$TMP/silently-capped"
build_healthy "$CAPPED"
# asked for everything in one page; the source silently answers with a 4-row cap
expect_status_matching "silently capped page fails closed" 2 "server silently capped the page" \
  run --page-limit 5000 --fixture-dir "$CAPPED"
# count says 4, only 2 documents arrived: a truncated page
TRUNC="$TMP/truncated"
build_healthy "$TRUNC"
page "$TRUNC" 0 200 "$(envelope 4 0 4 "$(row "$ROOT_SLUG" 'null' open open 'root. REOPEN: never'),$(row kid-a "\"$ROOT_SLUG\"" open open 'kid a. REOPEN: alpha')")"
expect_status_matching "count != delivered documents fails closed" 2 "truncated page at offset 0" \
  run --page-limit 4 --fixture-dir "$TRUNC"
# the source stops answering mid-read: a truncated read, not a smaller board
SHORT="$TMP/short-read"
build_healthy "$SHORT"
rm -f "$SHORT/page-1.http"
expect_status_matching "source stops answering mid-read fails closed" 2 "that is a truncated read, not a smaller board" \
  run --page-limit 4 --fixture-dir "$SHORT"
# answering a different offset than the one asked for
SKEW="$TMP/offset-skew"
build_healthy "$SKEW"
page "$SKEW" 1 200 "$(envelope 1 0 4 "$(row deep-a '"kid-a"' open open 'deep a. REOPEN: delta')")"
expect_status_matching "wrong offset echoed fails closed" 2 "server answered a different page" \
  run --page-limit 4 --fixture-dir "$SKEW"
echo

# =============================================================================
# CLAUSE 2 — THE LENS. `.children` is one level. On the live board it scores 181
# of 287. The guard is a fixpoint assertion, not a claim about which lens was
# used, so it catches any walk that stops early.
# =============================================================================
echo "clause 2 — a one-level .children lens must FAIL"
expect_status_matching "--lens children fails closed on a grandchild" 2 "closure is NOT closed under parent_id" \
  run --page-limit 4 --fixture-dir "$HEALTHY" --lens children
expect_status_matching "and it names the rows it dropped" 2 "escaped: deep-a (parent kid-a)" \
  run --page-limit 4 --fixture-dir "$HEALTHY" --lens children
echo

# =============================================================================
# CLAUSE 3 — ENVELOPES. /v1/data fails with error.code, /v1/tasks with `reason`.
# Both parse. Neither is data.
# =============================================================================
echo "clause 3 — a malformed / foreign envelope must FAIL"
TASKSHAPE="$TMP/tasks-envelope"
build_healthy "$TASKSHAPE"
page "$TASKSHAPE" 1 200 '{"ok":false,"reason":"task_not_found"}'
expect_status_matching "a 200 /v1/tasks-shaped failure fails closed" 2 "no \`result\` object" \
  run --page-limit 4 --fixture-dir "$TASKSHAPE"
ARRAY="$TMP/array-body"
build_healthy "$ARRAY"
page "$ARRAY" 1 200 '[]'
expect_status_matching "a 200 whose body is a list fails closed" 2 "not an object" \
  run --page-limit 4 --fixture-dir "$ARRAY"
NOTJSON="$TMP/not-json"
build_healthy "$NOTJSON"
page "$NOTJSON" 1 200 '<html>502 upstream</html>'
expect_status_matching "a 200 that is not JSON fails closed" 2 "unparseable body" \
  run --page-limit 4 --fixture-dir "$NOTJSON"
MISSINGKEY="$TMP/missing-key"
build_healthy "$MISSINGKEY"
page "$MISSINGKEY" 1 200 '{"result":{"count":0,"offset":4,"limit":4}}'
expect_status_matching "result without documents fails closed" 2 "result.documents is missing" \
  run --page-limit 4 --fixture-dir "$MISSINGKEY"
FIVEHUNDRED="$TMP/five-hundred"
build_healthy "$FIVEHUNDRED"
page "$FIVEHUNDRED" 1 500 '{"ok":false,"error":{"code":"internal"}}'
expect_status_matching "a 500 is never a leaf" 2 "a non-2xx is never a leaf" \
  run --page-limit 4 --fixture-dir "$FIVEHUNDRED"
echo

# =============================================================================
# CLAUSE 5 — THE INSTANT. A snapshot or an average, never both.
# =============================================================================
echo "clause 5 — the named instant must be coherent"
DRIFT="$TMP/drifted"
build_healthy "$DRIFT"
# a descendant stamped in the year 3000 lands inside any window this run has
page "$DRIFT" 1 200 "$(envelope 3 4 4 "$(printf '{"_id":"deep-a","_type":"task","_updatedAt":"3000-01-01T00:00:00.000000Z","parent_id":"kid-a","lifecycle_status":"open","disposition":"open","disposition_reason":"deep a. REOPEN: delta"}'),$(row deep-b '"kid-b"' cancelled closed 'deep b. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
# (a future stamp is outside the window, so it must NOT red — only rows that
# moved INSIDE the window do)
expect_status "a future _updatedAt is not drift" 0 \
  run --page-limit 4 --fixture-dir "$DRIFT"
NOSTAMP="$TMP/no-stamp"
build_healthy "$NOSTAMP"
page "$NOSTAMP" 1 200 "$(envelope 3 4 4 "$(printf '{"_id":"deep-a","_type":"task","parent_id":"kid-a","lifecycle_status":"open","disposition":"open","disposition_reason":"deep a. REOPEN: delta"}'),$(row deep-b '"kid-b"' cancelled closed 'deep b. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "a row with no _updatedAt fails closed" 2 "carries no _updatedAt" \
  run --page-limit 4 --fixture-dir "$NOSTAMP"
BADSTAMP="$TMP/bad-stamp"
build_healthy "$BADSTAMP"
page "$BADSTAMP" 1 200 "$(envelope 3 4 4 "$(printf '{"_id":"deep-a","_type":"task","_updatedAt":"last tuesday","parent_id":"kid-a","lifecycle_status":"open","disposition":"open","disposition_reason":"deep a. REOPEN: delta"}'),$(row deep-b '"kid-b"' cancelled closed 'deep b. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "an unreadable _updatedAt fails closed" 2 "unreadable _updatedAt" \
  run --page-limit 4 --fixture-dir "$BADSTAMP"
DUPES="$TMP/dupes"
build_healthy "$DUPES"
page "$DUPES" 1 200 "$(envelope 3 4 4 "$(row kid-a "\"$ROOT_SLUG\"" open open 'kid a again — the corpus shifted. REOPEN: alpha'),$(row deep-a '"kid-a"' open open 'deep a. REOPEN: delta'),$(row deep-b '"kid-b"' cancelled closed 'deep b. REOPEN: echo')")"
expect_status_matching "a row served twice is an incoherent snapshot" 4 "shifted under pagination" \
  run --page-limit 4 --fixture-dir "$DUPES"
echo

# =============================================================================
# FAIL-CLOSED POPULATIONS. A census with nothing in it has not passed.
# =============================================================================
echo "fail-closed — an empty or rootless population is never a pass"
EMPTY="$TMP/empty"
page "$EMPTY" 0 200 "$(envelope 0 0 4 '')"
expect_status_matching "zero rows fails closed" 2 "empty population" \
  run --page-limit 4 --fixture-dir "$EMPTY"
ROOTLESS="$TMP/rootless"
page "$ROOTLESS" 0 200 "$(envelope 1 0 4 "$(row somebody-else 'null' open open 'nothing to do with the root. REOPEN: never')")"
expect_status_matching "a missing root fails closed" 2 "is not in the" \
  run --page-limit 4 --fixture-dir "$ROOTLESS"
CHILDLESS="$TMP/childless"
page "$CHILDLESS" 0 200 "$(envelope 1 0 4 "$(row "$ROOT_SLUG" 'null' open open 'root with no children. REOPEN: never')")"
expect_status_matching "a childless root fails closed" 2 "zero descendants" \
  run --page-limit 4 --fixture-dir "$CHILDLESS"
echo

# =============================================================================
# THE DONE-CONDITION. It must be able to fail in each of its own directions --
# otherwise the round can be declared done by a predicate that cannot say no.
# =============================================================================
echo "done-condition — each half must be able to say no"
BOILER="$TMP/boilerplate"
build_healthy "$BOILER"
# two rows share a reason verbatim (modulo whitespace): 5 non-empty, 4 distinct
page "$BOILER" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open open 'kid a reason one.   REOPEN:   alpha'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "duplicate reasons red the predicate" 1 "collapse to 4 hashes" \
  run --page-limit 4 --fixture-dir "$BOILER" --assert-round-done
# ...and the census itself still exits 0: duplicate reasons are a finding, not a
# transport failure.
expect_status "duplicate reasons alone do not red the census" 0 \
  run --page-limit 4 --fixture-dir "$BOILER"
VOCAB="$TMP/off-vocabulary"
build_healthy "$VOCAB"
# uppercase `OPEN` — the exact 67-row split measured on the live board
page "$VOCAB" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open OPEN 'deep a reason four. REOPEN: delta'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "off-vocabulary disposition reds the predicate" 1 "carry a disposition outside" \
  run --page-limit 4 --fixture-dir "$VOCAB" --assert-round-done
expect_output_contains "and the case split is visible, not averaged" "OPEN                 1" \
  run --page-limit 4 --fixture-dir "$VOCAB"
NOREASONS="$TMP/no-reasons"
build_healthy "$NOREASONS"
page "$NOREASONS" 0 200 "$(envelope 4 0 4 "$(row "$ROOT_SLUG" 'null' open open ''),$(row kid-a "\"$ROOT_SLUG\"" open open ''),$(row kid-b "\"$ROOT_SLUG\"" done closed ''),$(row kid-c "\"$ROOT_SLUG\"" blocked parked '')")"
page "$NOREASONS" 1 200 "$(envelope 2 4 4 "$(row deep-a '"kid-a"' open open ''),$(row deep-b '"kid-b"' cancelled closed '')")"
expect_status_matching "an all-empty board is unstarted, not done" 1 "zero non-empty reasons" \
  run --page-limit 4 --fixture-dir "$NOREASONS" --assert-round-done
echo

# =============================================================================
# CLAUSE 4 — LIVE COVERAGE. Every fixture below EXITS 0 against the census as it
# stood on origin/main before this clause existed, because clauses 1-3 are
# closure-scoped and structurally cannot see a live row that says nothing. Three
# reds and four greens: the reds prove the clause can say no, and the greens
# prove it says no to the RIGHT rows — a clause 4 that reds on terminal rows, or
# on a shared family trigger, would be a different and worse instrument.
# =============================================================================
echo "clause 4 — a LIVE row that says nothing must red the round-done predicate"

# (a) BARE: a live row with no disposition at all. It lands in the `<unset>`
# bucket that clauses 1-3 never read.
BARE="$TMP/live-bare"
build_healthy "$BARE"
page "$BARE" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open '' 'deep a reason four. REOPEN: delta'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "a live row with no disposition reds the predicate" 1 "LIVE row(s) carry NO disposition" \
  run --page-limit 4 --fixture-dir "$BARE" --assert-round-done
expect_status_matching "and it NAMES the silent row" 1 "deep-a" \
  run --page-limit 4 --fixture-dir "$BARE" --assert-round-done
expect_output_contains "live_bare is a ROW-ID LIST in --json" "$(printf '"live_bare": [\n    "deep-a"\n  ]')" \
  run --page-limit 4 --fixture-dir "$BARE" --json

# (b) an adjudicated live row with no reason: a verdict it cannot prove.
NOREASONLIVE="$TMP/live-adjudicated-no-reason"
build_healthy "$NOREASONLIVE"
page "$NOREASONLIVE" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open closed ''),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "a live verdict with no reason reds the predicate" 1 "carry NO disposition_reason" \
  run --page-limit 4 --fixture-dir "$NOREASONLIVE" --assert-round-done
expect_output_contains "live_adjudicated_no_reason is a ROW-ID LIST in --json" "$(printf '"live_adjudicated_no_reason": [\n    "deep-a"\n  ]')" \
  run --page-limit 4 --fixture-dir "$NOREASONLIVE" --json

# (c) LIVEPARK: a live park with no way back out.
LIVEPARK="$TMP/live-park-no-trigger"
build_healthy "$LIVEPARK"
page "$LIVEPARK" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open parked 'deep a reason four, parked with no way back'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "a live park with no reopen_trigger reds the predicate" 1 "carry NO structured reopen_trigger" \
  run --page-limit 4 --fixture-dir "$LIVEPARK" --assert-round-done
expect_output_contains "live_park_no_trigger is a ROW-ID LIST in --json" "$(printf '"live_park_no_trigger": [\n    "deep-a"\n  ]')" \
  run --page-limit 4 --fixture-dir "$LIVEPARK" --json

# DECORATED — THE FIXTURE THAT EARNS THE CLAUSE. `kid-c` is a live park whose
# reason SAYS "REOPEN: charlie" in prose while the structured field is DROPPED.
# A trigger test that inherited the prose regex would call this covered. It is
# decoration, and PDS-D336(b) condemns scoring it.
DECORATED="$TMP/decorated-trigger"
build_healthy "$DECORATED"
page "$DECORATED" 0 200 "$(envelope 4 0 4 "$(row "$ROOT_SLUG" 'null' open open 'root row. REOPEN: never'),$(row kid-a "\"$ROOT_SLUG\"" open open 'kid a reason one. REOPEN: alpha'),$(row kid-b "\"$ROOT_SLUG\"" done closed 'kid b reason two. REACTIVATE: bravo'),$(row kid-c "\"$ROOT_SLUG\"" blocked parked 'kid c reason three. REOPEN: charlie')")"
expect_status_matching "prose 'REOPEN: charlie' is NOT a trigger" 1 "carry NO structured reopen_trigger" \
  run --page-limit 4 --fixture-dir "$DECORATED" --assert-round-done
expect_status_matching "and the decorated row is named" 1 "kid-c" \
  run --page-limit 4 --fixture-dir "$DECORATED" --assert-round-done
expect_output_contains "the prose mention is still visible, as DECORATION" "prose-only REOPEN mention       5" \
  run --page-limit 4 --fixture-dir "$DECORATED"

# TERMBARE / TERMPARK — the SAME two mutations on TERMINAL rows. Clause 4 is
# live-scoped: a finished row is allowed to be silent, and a clause that reds
# here would demand the round re-adjudicate history.
echo
echo "clause 4 — but a TERMINAL row is allowed to be silent (live-scoped, not closure-scoped)"
TERMBARE="$TMP/terminal-bare"
build_healthy "$TERMBARE"
page "$TERMBARE" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open open 'deep a reason four. REOPEN: delta'),$(row deep-b '"kid-b"' cancelled '' 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status "a TERMINAL row with no disposition does not red" 0 \
  run --page-limit 4 --fixture-dir "$TERMBARE" --assert-round-done
TERMPARK="$TMP/terminal-park"
build_healthy "$TERMPARK"
page "$TERMPARK" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open open 'deep a reason four. REOPEN: delta'),$(row deep-b '"kid-b"' cancelled parked 'deep b reason five, parked and finished'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status "a TERMINAL park with no reopen_trigger does not red" 0 \
  run --page-limit 4 --fixture-dir "$TERMPARK" --assert-round-done

# SHAREDTRIG — PDS-D336(a), pinned in the other direction. Three live parks, two
# of them sharing ONE trigger verbatim over DISTINCT reasons. Only REASONS must
# be distinct; a family trigger is legitimate and is what the board's best eight
# rows already do. This fixture exists so a later wave cannot quietly tighten
# clause 4(c) into a trigger-distinctness check and break them.
SHAREDTRIG="$TMP/shared-trigger"
build_healthy "$SHAREDTRIG"
page "$SHAREDTRIG" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open parked 'deep a reason four, its own distinct reason' 'REOPEN when the Hetzner rate cap lifts'),$(row deep-b '"kid-b"' open parked 'deep b reason five, a different distinct reason' 'REOPEN when the Hetzner rate cap lifts'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status "a family trigger shared over distinct reasons does NOT red" 0 \
  run --page-limit 4 --fixture-dir "$SHAREDTRIG" --assert-round-done
expect_output_contains "all three live parks count as covered" "live parked with NO reopen_trigger     0   (of 3 parked)" \
  run --page-limit 4 --fixture-dir "$SHAREDTRIG"

# TERMDUP — clauses 1-3 were NOT silently rescoped to live. A duplicate reason on
# a TERMINAL row still reds, because distinctness is a property of everything
# ever written.
TERMDUP="$TMP/terminal-duplicate-reason"
build_healthy "$TERMDUP"
page "$TERMDUP" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open open 'deep a reason four. REOPEN: delta'),$(row deep-b '"kid-b"' cancelled closed 'kid b reason two. REACTIVATE: bravo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "a duplicate reason on a TERMINAL row still reds (1-3 stay closure-scoped)" 1 "collapse to 4 hashes" \
  run --page-limit 4 --fixture-dir "$TERMDUP" --assert-round-done
echo

# =============================================================================
# CLAUSE 4(a) — THE ROUND ANCHOR (PDS-D364/D365). 4(a) unanchored is
# structurally unreachable by any round that discovers work: a row is BORN bare,
# so a round that files one row can never certify. The anchor says WHICH ROUND
# the clause is asking about — and the danger it introduces is the opposite one,
# that a round seals itself by moving the anchor. So the reds below are as
# important as the greens: an argv anchor is REFUSED, an unresolvable Paper
# FAILS CLOSED, and a row the predicate cannot place FAILS CLOSED.
# =============================================================================
echo "clause 4(a) — the round anchor is DERIVED, and it defers rather than excuses"
WAVE_SLUG="pds-wave-26-fixture"
ANCHOR_TS="2025-01-01T00:00:00.000000Z"

# ANCHORED — `deep-a` is a LIVE BARE row BORN IN THE YEAR 2030: residue of any
# round anchored before then, in scope for any round anchored after.
ANCHORED="$TMP/anchored"
build_healthy "$ANCHORED"
page "$ANCHORED" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open '' 'deep a reason four. REOPEN: delta' '' '2030-01-01T00:00:00.000000Z'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
paper "$ANCHORED" "$WAVE_SLUG" 200 "$(printf '{"result":{"_id":"%s","_type":"paper","_createdAt":"%s"}}' "$WAVE_SLUG" "$ANCHOR_TS")"

# UNANCHORED, the wave-25 behaviour, unchanged: the newborn row reds the round.
expect_status_matching "unanchored, a newborn bare row still reds 4(a)" 1 "LIVE row(s) carry NO disposition" \
  run --page-limit 4 --fixture-dir "$ANCHORED" --assert-round-done
# ANCHORED ON THE WAVE PAPER: the same row is DEFERRED, and NAMED while it is.
expect_status "--anchor-from-paper defers the newborn row and the round certifies" 0 \
  run --page-limit 4 --fixture-dir "$ANCHORED" --assert-round-done --anchor-from-paper "$WAVE_SLUG"
expect_output_contains "the residue is an ENUMERATED NAMED list, not a count" "residue: deep-a" \
  run --page-limit 4 --fixture-dir "$ANCHORED" --assert-round-done --anchor-from-paper "$WAVE_SLUG"
expect_output_contains "the derived anchor is printed with its provenance" "paper/$WAVE_SLUG _createdAt $ANCHOR_TS" \
  run --page-limit 4 --fixture-dir "$ANCHORED" --anchor-from-paper "$WAVE_SLUG"
expect_output_contains "live_bare_residue is a ROW-ID LIST in --json" "$(printf '"live_bare_residue": [\n    "deep-a"\n  ]')" \
  run --page-limit 4 --fixture-dir "$ANCHORED" --anchor-from-paper "$WAVE_SLUG" --json
# ...and 4(a)'s DENOMINATOR is still the whole live board: deferring a row must
# not quietly shrink what the clause claims to have covered. The NUMERATOR is
# literal in the other direction (review, wave 26): a deferred row does NOT
# carry a disposition, so it is not counted as one. 3 live rows, 1 deferred,
# 2 actually dispositioned -> "2/3 PASS" plus the named residue line. Printing
# "3/3" here would be a success claim about a row nobody looked at, which is the
# defect class this whole epic exists to kill.
expect_output_contains "4(a)'s denominator is the WHOLE live board and its numerator is literal" \
  "live rows carrying a disposition               2/3" \
  run --page-limit 4 --fixture-dir "$ANCHORED" --assert-round-done --anchor-from-paper "$WAVE_SLUG"
expect_output_contains "the deferred row is NOT counted as dispositioned" \
  "deferred to the next round (RESIDUE)        1" \
  run --page-limit 4 --fixture-dir "$ANCHORED" --assert-round-done --anchor-from-paper "$WAVE_SLUG"

# TERMINATION. The same row is IN SCOPE for the next round: anchor after its
# birth and it reds again. Residue is deferred by exactly one round, never
# forever — this is the fixture that would catch an anchor that hides rows.
expect_status_matching "the residue is IN SCOPE for the NEXT round" 1 "LIVE row(s) carry NO disposition" \
  run --page-limit 4 --fixture-dir "$ANCHORED" --assert-round-done --anchor 2031-01-01T00:00:00Z

# TERMINATION, the other half: adjudicating the residue GREENS the round with or
# without an anchor, and files no new rows (the closure is the same 5).
ADJUDICATED="$TMP/anchored-adjudicated"
build_healthy "$ADJUDICATED"
page "$ADJUDICATED" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open open 'deep a reason four, now adjudicated. REOPEN: delta' '' '2030-01-01T00:00:00.000000Z'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
paper "$ADJUDICATED" "$WAVE_SLUG" 200 "$(printf '{"result":{"_createdAt":"%s"}}' "$ANCHOR_TS")"
expect_status "adjudicated residue certifies UNANCHORED too" 0 \
  run --page-limit 4 --fixture-dir "$ADJUDICATED" --assert-round-done
expect_status "adjudicated residue certifies anchored, with zero residue" 0 \
  run --page-limit 4 --fixture-dir "$ADJUDICATED" --assert-round-done --anchor 2031-01-01T00:00:00Z
expect_output_contains "adjudicating filed no new rows (closure unchanged)" "closure     5 descendants" \
  run --page-limit 4 --fixture-dir "$ADJUDICATED" --anchor-from-paper "$WAVE_SLUG"
expect_output_contains "and the residue line reads 0" "deferred to the next round (RESIDUE)        0" \
  run --page-limit 4 --fixture-dir "$ADJUDICATED" --assert-round-done --anchor-from-paper "$WAVE_SLUG"

# FAIL CLOSED ON A ROW THE PREDICATE CANNOT PLACE — exactly as clause 5 does for
# _updatedAt. A live bare row with no readable birth instant sits on neither side
# of the anchor, and an unplaceable row is never excused into the residue.
NOBIRTH="$TMP/anchored-no-createdat"
build_healthy "$NOBIRTH"
page "$NOBIRTH" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open '' 'deep a reason four. REOPEN: delta'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
paper "$NOBIRTH" "$WAVE_SLUG" 200 "$(printf '{"result":{"_createdAt":"%s"}}' "$ANCHOR_TS")"
expect_status_matching "a bare live row with NO _createdAt fails closed under an anchor" 2 "cannot place it" \
  run --page-limit 4 --fixture-dir "$NOBIRTH" --assert-round-done --anchor-from-paper "$WAVE_SLUG"
# ...and the SAME fixture unanchored is exit 1, not 2: the birth read fires only
# under an anchor, so no pre-existing fixture can be broken by it.
expect_status_matching "the same fixture unanchored is a plain 4(a) red" 1 "LIVE row(s) carry NO disposition" \
  run --page-limit 4 --fixture-dir "$NOBIRTH" --assert-round-done
BADBIRTH="$TMP/anchored-bad-createdat"
build_healthy "$BADBIRTH"
page "$BADBIRTH" 1 200 "$(envelope 3 4 4 "$(row deep-a '"kid-a"' open '' 'deep a reason four. REOPEN: delta' '' 'last tuesday'),$(row deep-b '"kid-b"' cancelled closed 'deep b reason five. REOPEN: echo'),$(row unrelated 'null' open open 'unrelated. REOPEN: foxtrot')")"
expect_status_matching "an unreadable _createdAt fails closed under an anchor" 2 "cannot place it" \
  run --page-limit 4 --fixture-dir "$BADBIRTH" --assert-round-done --anchor 2031-01-01T00:00:00Z

# THE ANCHOR RESOLVER FAILS CLOSED IN EVERY DIRECTION. It NEVER falls back to
# now(): an anchor at now() excuses every row the round just filed.
echo
echo "clause 4(a) — an anchor that cannot be resolved is never a default"
ANCHOR404="$TMP/anchor-404"
build_healthy "$ANCHOR404"
paper "$ANCHOR404" "$WAVE_SLUG" 404 '{"ok":false,"error":{"code":"not_found"}}'
expect_status_matching "a 404 wave Paper fails closed" 2 "refusing to fall back to now()" \
  run --page-limit 4 --fixture-dir "$ANCHOR404" --assert-round-done --anchor-from-paper "$WAVE_SLUG"
ANCHORBAD="$TMP/anchor-unreadable"
build_healthy "$ANCHORBAD"
paper "$ANCHORBAD" "$WAVE_SLUG" 200 '{"result":{"_createdAt":"last tuesday"}}'
expect_status_matching "an unreadable Paper _createdAt fails closed" 2 "is not an anchor" \
  run --page-limit 4 --fixture-dir "$ANCHORBAD" --assert-round-done --anchor-from-paper "$WAVE_SLUG"
ANCHORNONE="$TMP/anchor-no-createdat"
build_healthy "$ANCHORNONE"
paper "$ANCHORNONE" "$WAVE_SLUG" 200 '{"result":{"_id":"pds-wave-26-fixture"}}'
expect_status_matching "a Paper with no _createdAt at all fails closed" 2 "missing or unreadable _createdAt" \
  run --page-limit 4 --fixture-dir "$ANCHORNONE" --assert-round-done --anchor-from-paper "$WAVE_SLUG"
ANCHORENV="$TMP/anchor-foreign-envelope"
build_healthy "$ANCHORENV"
paper "$ANCHORENV" "$WAVE_SLUG" 200 '{"ok":false,"reason":"paper_not_found"}'
expect_status_matching "a cleanly-parsing failure envelope is not an anchor" 2 "no \`result\` object resolving anchor Paper" \
  run --page-limit 4 --fixture-dir "$ANCHORENV" --assert-round-done --anchor-from-paper "$WAVE_SLUG"
expect_status_matching "a Paper the source does not serve at all fails closed" 2 "unresolvable anchor is never a default" \
  run --page-limit 4 --fixture-dir "$HEALTHY" --assert-round-done --anchor-from-paper "$WAVE_SLUG"

# CLAUSE 5 IS ORTHOGONAL. The anchor is the ROUND window; clause 5 asserts the
# census's own READ window. Widening clause 5 to the round window would trip on
# every residue write and make a certifying run impossible — so the racing
# fixture must exit 4 IDENTICALLY with and without an anchor.
echo
echo "clause 4(a) — the round window and clause 5's read window stay orthogonal"
expect_status_matching "a racing corpus is exit 4 WITHOUT an anchor" 4 "shifted under pagination" \
  run --page-limit 4 --fixture-dir "$DUPES"
paper "$DUPES" "$WAVE_SLUG" 200 "$(printf '{"result":{"_createdAt":"%s"}}' "$ANCHOR_TS")"
expect_status_matching "the SAME racing corpus is exit 4 WITH one" 4 "shifted under pagination" \
  run --page-limit 4 --fixture-dir "$DUPES" --assert-round-done --anchor-from-paper "$WAVE_SLUG"
expect_status_matching "an unreadable _updatedAt still fails closed under an anchor" 2 "unreadable _updatedAt" \
  run --page-limit 4 --fixture-dir "$BADSTAMP" --anchor 2031-01-01T00:00:00Z
echo

# =============================================================================
# USAGE. Bad input is exit 3, never a quietly smaller board.
# =============================================================================
echo "usage — bad input is a usage error, never a board"
expect_status "--page-limit 0 is a usage error" 3 \
  run --page-limit 0 --fixture-dir "$HEALTHY"
expect_status "--fixture-dir that does not exist is a usage error" 3 \
  run --page-limit 4 --fixture-dir "$TMP/nope"
expect_status "an unknown --lens is rejected by argparse" 2 \
  run --page-limit 4 --fixture-dir "$HEALTHY" --lens sideways
# THE ARGV ANCHOR IS REFUSED IN A CERTIFYING RUN. On the live board
# `--anchor 2020-01-01T00:00:00Z` flips 4(a) from 157/172 FAIL to 172/172 PASS,
# so a raw anchor outside --fixture-dir would let a round seal itself by argv.
# This check needs no server: the guard fires before any transport is built.
expect_status_matching "--anchor outside --fixture-dir is REFUSED" 3 "seal itself by argv" \
  run --page-limit 4 --anchor 2020-01-01T00:00:00Z --assert-round-done
expect_status_matching "--anchor and --anchor-from-paper are mutually exclusive" 3 "mutually exclusive" \
  run --page-limit 4 --fixture-dir "$HEALTHY" --anchor 2020-01-01T00:00:00Z --anchor-from-paper "$WAVE_SLUG"
expect_status_matching "an --anchor that is not an instant is a usage error" 3 "not an ISO-8601 instant" \
  run --page-limit 4 --fixture-dir "$HEALTHY" --anchor "last tuesday"
echo

if [[ $FAILURES -ne 0 ]]; then
  printf 'SELFTEST FAILED: %d of %d checks failed\n' "$FAILURES" "$CHECKS" >&2
  exit 1
fi

printf 'SELFTEST PASS: %d checks. The census greens on a healthy 2-page corpus and\n' "$CHECKS"
cat <<'SUMMARY'
REDS on: a 429 (whose body is valid JSON), a silently capped page, a page whose
count exceeds its documents, a source that stops answering mid-read, a wrong
echoed offset, a one-level .children lens, a /v1/tasks-shaped 200 failure, a
non-object body, a non-JSON body, a result with no documents, a 500, a missing
or unreadable _updatedAt, a row served twice, an empty population, a missing
root and a childless root -- and its done-condition can say no in all six of
its own directions: closure-scoped (duplicate reasons, off-vocabulary
dispositions, no reasons at all) and LIVE-scoped clause 4 (a live row with no
disposition, a live verdict with no reason, a live park with no STRUCTURED
reopen_trigger -- prose that merely says "REOPEN: charlie" is decoration and
reds). Clause 4 stays live-scoped: the same two mutations on TERMINAL rows do
NOT red, a family trigger shared over distinct reasons does NOT red, and a
duplicate reason on a terminal row STILL reds -- clauses 1-3 were not rescoped.

Clause 4(a) is ROUND-ANCHORED and the anchor cannot be argued: a raw --anchor
outside --fixture-dir is REFUSED (exit 3), and --anchor-from-paper fails closed
on a 404, a foreign envelope, an unreadable _createdAt, an absent _createdAt and
a Paper the source does not serve -- never falling back to now(). A live bare row
the anchor cannot PLACE fails closed too, while the same fixture unanchored is a
plain 4(a) red, so no pre-existing fixture is touched. Residue is an ENUMERATED
NAMED list, 4(a) still scores against the WHOLE live board, and it TERMINATES:
the same row is deferred by round N and IN SCOPE for round N+1, and adjudicating
it greens the round anchored or not, filing no new rows. Clause 5 stays
orthogonal -- the racing corpus exits 4 identically with and without an anchor.
SUMMARY
