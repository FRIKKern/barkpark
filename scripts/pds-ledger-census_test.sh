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
row() {
  local id=$1 parent=$2 lifecycle=$3 disposition=$4 reason=$5
  printf '{"_id":"%s","_type":"task","_updatedAt":"2020-01-01T00:00:00.000000Z","parent_id":%s,"lifecycle_status":"%s","disposition":"%s","disposition_reason":"%s"}' \
    "$id" "$parent" "$lifecycle" "$disposition" "$reason"
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
# vocabulary, every row carries a reopen trigger.
build_healthy() {
  local dir=$1
  local p0 p1
  p0="$(row "$ROOT_SLUG" 'null' open open 'root row. REOPEN: never'),"
  p0+="$(row kid-a "\"$ROOT_SLUG\"" open open 'kid a reason one. REOPEN: alpha'),"
  p0+="$(row kid-b "\"$ROOT_SLUG\"" done closed 'kid b reason two. REACTIVATE: bravo'),"
  p0+="$(row kid-c "\"$ROOT_SLUG\"" blocked parked 'kid c reason three. REOPEN: charlie')"
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
expect_output_contains "every row carries a reopen trigger" "carrying a reopen trigger       5" \
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
# USAGE. Bad input is exit 3, never a quietly smaller board.
# =============================================================================
echo "usage — bad input is a usage error, never a board"
expect_status "--page-limit 0 is a usage error" 3 \
  run --page-limit 0 --fixture-dir "$HEALTHY"
expect_status "--fixture-dir that does not exist is a usage error" 3 \
  run --page-limit 4 --fixture-dir "$TMP/nope"
expect_status "an unknown --lens is rejected by argparse" 2 \
  run --page-limit 4 --fixture-dir "$HEALTHY" --lens sideways
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
root and a childless root -- and its done-condition can say no in all three of
its own directions (duplicate reasons, off-vocabulary dispositions, no reasons
at all).
SUMMARY
