#!/usr/bin/env bash
#
# task-lease-renew.test.sh — the hermetic harness for scripts/task-lease-renew.sh.
#
# WHAT IT PROVES. The subject's whole job is a CLASSIFICATION: every answer
# /v1/tasks/:doc_id/renew can give has to land on the right verdict, and all but
# one of them must exit 0, because this mechanism is advisory and a red on it
# would refuse a pull request for a ledger state. A classification nobody drives
# is a table, not a behaviour, so every arm below is executed.
#
# HOW IT IS HERMETIC. A stub `curl` goes on PATH ahead of the real one, so the
# subject builds its REAL argument list — URL, method, headers, --data-binary —
# and the stub answers with a canned code and body. Nothing reaches guerrilla,
# no token exists, and the harness cannot rot into a skip. The stub also LOGS
# its argv, which is how the request body and the URL are asserted rather than
# assumed.
#
# RED BEFORE: there is none to quote. Before this commit neither the subject nor
# this harness existed, and the renew endpoint had no caller at all — the API
# half shipped INERT. The absence IS the red-before: every case below fails with
# "no such file" against the previous tree.
#
# THE TRAILER GRAMMAR IS NOT RE-TESTED HERE, it is re-USED: the subject shells
# out to scripts/pr-task-gate.sh --extract-task-id, and the cases below prove
# the delegation works end to end (bare id, backticked id, ambiguity, absence)
# rather than re-asserting a regex that pr-task-gate.test.sh already owns. A
# fourth copy of that grammar in this repo is the thing this file exists to
# prevent, so one case asserts the subject contains no `Task:` regex of its own.
#
# EXIT CODES
#   0  every case passed
#   1  at least one case failed
#   2  the harness could not run (missing subject, no python3)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/scripts/task-lease-renew.sh"
WORKFLOW="$ROOT/.github/workflows/task-lease-renew.yml"

[ -f "$SUBJECT" ] || { echo "task-lease-renew.test: CANNOT RUN — $SUBJECT is missing" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "task-lease-renew.test: CANNOT RUN — no python3" >&2; exit 2; }

TMP="$(mktemp -d -t task-lease-renew-harness.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

check() { # $1 label, $2 got, $3 want
  if [ "$2" = "$3" ]; then ok "$1 (= $3)"; else bad "$1 — got '$2', want '$3'"; fi
}
has() { # $1 haystack, $2 needle, $3 label
  case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 — '$2' not in output: $(printf '%s' "$1" | tr '\n' ' ' | cut -c1-220)" ;; esac
}
hasnt() { # $1 haystack, $2 needle, $3 label
  case "$1" in *"$2"*) bad "$3 — '$2' IS in the output" ;; *) ok "$3" ;; esac
}

# ── The stub curl ────────────────────────────────────────────────────────────
# CODES is a comma-separated sequence consumed one per call, so a retry path can
# be driven honestly (500,500,200) instead of asserted. The last code repeats
# once the list is spent.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Hermetic stand-in for curl. Logs argv, writes the canned body to -o, prints a
# code from the CODES sequence.
{ printf '%s\n' "ARGV: $*"; } >> "$FAKE_CURL_LOG"
n=0
[ -f "$FAKE_CURL_N" ] && n="$(cat "$FAKE_CURL_N")"
n=$((n + 1)); printf '%s' "$n" > "$FAKE_CURL_N"
code="$(printf '%s' "$FAKE_CURL_CODES" | cut -d, -f"$n")"
[ -n "$code" ] || code="$(printf '%s' "$FAKE_CURL_CODES" | tr ',' '\n' | tail -1)"
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  # `--data-binary @file` is how the subject sends the request body; capture the
  # FILE CONTENTS so a case can assert the JSON that actually went out.
  case "$a" in
    @*) [ -f "${a#@}" ] && cat "${a#@}" >> "$FAKE_CURL_BODY_LOG" && printf '\n' >> "$FAKE_CURL_BODY_LOG" ;;
  esac
  prev="$a"
done
[ -n "$out" ] && printf '%s' "${FAKE_CURL_RESPONSE:-}" > "$out"
printf '%s' "$code"
exit 0
STUB
chmod +x "$TMP/bin/curl"

RENEW_200='{"ok":true,"doc":{"claim":{"worker":"lead-gates","epoch":9,"lease_extension":{"until":"2026-09-02T13:45:00Z","pr":15234,"reason":"open_pr","renewals":3}},"content":{}}}'
# The shape a pre-lift server (or an old fixture) answers with — the reader must still see it.
RENEW_200_LEGACY='{"ok":true,"doc":{"content":{"claim":{"worker":"lead-gates","epoch":9,"lease_extension":{"until":"2026-09-02T13:45:00Z","pr":15234,"reason":"open_pr","renewals":3}}}}}'
CLEAR_200='{"ok":true,"doc":{"claim":{"worker":"lead-gates","epoch":9},"content":{}}}'

run() { # env comes from the caller; $@ are subject flags
  ( export PATH="$TMP/bin:$PATH"
    export FAKE_CURL_LOG="$TMP/curl.log" FAKE_CURL_N="$TMP/curl.n" \
           FAKE_CURL_BODY_LOG="$TMP/curl.body"
    bash "$SUBJECT" "$@" 2>&1 )
}
reset_stub() { : > "$TMP/curl.log"; : > "$TMP/curl.body"; rm -f "$TMP/curl.n"; }
# `grep -c` PRINTS A COUNT AND EXITS NONZERO on no match, so the idiom
# `grep -c ... || printf 0` emits BOTH sides and the capture becomes "0\n0" —
# a value that equals neither 0 nor anything else, and every zero-call assertion
# reads FAIL for a reason that is not the subject. Count the lines instead.
calls() { grep '^ARGV: ' "$TMP/curl.log" 2>/dev/null | wc -l | tr -d '[:space:]'; }

BODY_OK="Renews the claim.

Task: task-16e56d05b809dd39
"
BODY_TICKS="Renews the claim.

Task: \`task-16e56d05b809dd39\`
"
BODY_NONE="A PR that names no row at all.
"
BODY_MID="This mentions see Task: task-16e56d05b809dd39 mid-sentence only.
"
BODY_AMBIG="Task: task-16e56d05b809dd39
Task: task-99999999deadbeef
"

echo "task-lease-renew.test.sh — response classification and trailer delegation"
echo
echo "── TRAILER DELEGATION (no ledger call is reached) ──────────────────────"

reset_stub
OUT="$(PR_BODY="$BODY_NONE" PR_NUMBER=15234 PR_ACTION=opened LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=200 run)"; RC=$?
check "1. a PR with no Task: trailer exits 0" "$RC" "0"
has "$OUT" "names no task row" "1b. …and says so as a ::notice, not a failure"
check "1c. …and reaches the ledger zero times" "$(calls)" "0"

reset_stub
OUT="$(PR_BODY="$BODY_MID" PR_NUMBER=15234 PR_ACTION=opened LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=200 run)"; RC=$?
check "2. a mid-sentence 'see Task: x' is NOT a trailer (exit 0)" "$RC" "0"
check "2b. …and reaches the ledger zero times" "$(calls)" "0"

reset_stub
OUT="$(PR_BODY="$BODY_AMBIG" PR_NUMBER=15234 PR_ACTION=opened LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=200 run)"; RC=$?
check "3. two DISTINCT column-0 ids exits 0 (the required context reds it, not this)" "$RC" "0"
has "$OUT" "DISTINCT" "3b. …and names the ambiguity"
check "3c. …and renews nothing" "$(calls)" "0"

reset_stub
OUT="$(PR_BODY="$BODY_TICKS" PR_NUMBER=15234 PR_ACTION=opened LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=200 FAKE_CURL_RESPONSE="$RENEW_200" run)"; RC=$?
check "4. a BACKTICKED trailer is accepted (the #5290 regression)" "$RC" "0"
has "$(cat "$TMP/curl.log")" "/v1/tasks/task-16e56d05b809dd39/renew" "4b. …with the backticks stripped from the URL"

echo
echo "── THE REQUEST THIS SCRIPT ACTUALLY SENDS ──────────────────────────────"

reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=15234 PR_ACTION=synchronize LEDGER_TOKEN=s3cr3t-token \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=200 FAKE_CURL_RESPONSE="$RENEW_200" run)"; RC=$?
LOG="$(cat "$TMP/curl.log")"
check "5. a synchronize renews (exit 0)" "$RC" "0"
has "$LOG" "-X POST" "5b. …by POST"
has "$LOG" "/v1/tasks/task-16e56d05b809dd39/renew" "5c. …to /v1/tasks/:doc_id/renew"
has "$LOG" "--max-time 20" "5d. …with a bounded --max-time"
has "$(cat "$TMP/curl.body")" '"pr":15234' "5e. …and the body names the PR (the API 400s without it)"
has "$(cat "$TMP/curl.body")" '"state":"open"' "5f. …with state open"
hasnt "$(cat "$TMP/curl.body")" "until" "5g. …and computes NO time: the API owns the window"
hasnt "$OUT" "s3cr3t-token" "5h. the token never reaches the output"

# IDEMPOTENCE, driven rather than asserted: a second synchronize must send a
# byte-identical body. The window is the server's, so nothing here can drift.
FIRST="$(cat "$TMP/curl.body")"
reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=15234 PR_ACTION=synchronize LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=200 FAKE_CURL_RESPONSE="$RENEW_200" run)"; RC=$?
check "6. a REPEATED synchronize sends a byte-identical body" "$(cat "$TMP/curl.body")" "$FIRST"

reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=15234 PR_ACTION=closed PR_MERGED=true LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=200 FAKE_CURL_RESPONSE="$CLEAR_200" run)"; RC=$?
check "7. a MERGED close exits 0" "$RC" "0"
has "$(cat "$TMP/curl.body")" '"state":"merged"' "7b. …and clears with state=merged (the same verb, not a DELETE)"
has "$OUT" "cleared" "7c. …and reports the clear"

reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=15234 PR_ACTION=closed PR_MERGED=false LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=200 FAKE_CURL_RESPONSE="$CLEAR_200" run)"; RC=$?
check "8. an ABANDONED close exits 0 too" "$RC" "0"
has "$(cat "$TMP/curl.body")" '"state":"closed"' "8b. …and clears with state=closed — an abandon must not hold the row"

echo
echo "── RESPONSE CLASSIFICATION: every arm but one is exit 0 ────────────────"

reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=15234 PR_ACTION=opened LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=200 FAKE_CURL_RESPONSE="$RENEW_200" run)"; RC=$?
check "9. 200 exits 0" "$RC" "0"
has "$OUT" "2026-09-02T13:45:00Z" "9b. …and reports the returned lease_extension.until"
has "$OUT" "::notice" "9c. …as a ::notice, so it reaches the check-run UI"

reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=15234 PR_ACTION=opened LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=404 FAKE_CURL_RESPONSE='{"ok":false}' run)"; RC=$?
check "10. 404 (row gone) exits 0" "$RC" "0"
has "$OUT" "::notice" "10b. …as a ::notice, never an error"
check "10c. …and is not retried" "$(calls)" "1"

reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=15234 PR_ACTION=opened LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=409 \
       FAKE_CURL_RESPONSE='{"ok":false,"reason":"not_claimed"}' run)"; RC=$?
check "11. 409 not_claimed exits 0 — a ledger state is never this PR's fault" "$RC" "0"
has "$OUT" "not_claimed" "11b. …and names the reason the ledger gave"
has "$OUT" "may never resurrect" "11c. …and says what a renew cannot do"

reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=15234 PR_ACTION=opened LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=409 \
       FAKE_CURL_RESPONSE='{"ok":false,"reason":"extension_cap_reached"}' run)"; RC=$?
check "12. 409 extension_cap_reached exits 0" "$RC" "0"
has "$OUT" "extension_cap_reached" "12b. …and names the cap"

reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=15234 PR_ACTION=opened LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=401 FAKE_CURL_RESPONSE='{"ok":false}' run)"; RC=$?
check "13. 401 is the ONE non-zero arm" "$RC" "1"
has "$OUT" "BARKPARK_TASK_TOKEN" "13b. …and names the secret by name"
has "$OUT" "::error" "13c. …as an ::error, so it lifts into the check-run UI"
check "13d. …and a refused credential is never retried" "$(calls)" "1"

reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=15234 PR_ACTION=opened LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=403 FAKE_CURL_RESPONSE='{"ok":false}' run)"; RC=$?
check "14. 403 exits 1 as well" "$RC" "1"

reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=15234 PR_ACTION=opened LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 TASK_LEASE_RENEW_RETRIES=3 \
       FAKE_CURL_CODES=500,500,500 FAKE_CURL_RESPONSE='' run)"; RC=$?
check "15. a 5xx outage exits 0 after the bounded retries" "$RC" "0"
has "$OUT" "::warning" "15b. …as a ::warning UNCHECKED"
has "$OUT" "not a finding about this PR" "15c. …and disclaims the PR explicitly"
check "15d. …having tried exactly 3 times" "$(calls)" "3"

reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=15234 PR_ACTION=opened LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 TASK_LEASE_RENEW_RETRIES=3 \
       FAKE_CURL_CODES=500,500,200 FAKE_CURL_RESPONSE="$RENEW_200" run)"; RC=$?
check "16. a transient 5xx that recovers still renews" "$RC" "0"
has "$OUT" "2026-09-02T13:45:00Z" "16b. …and reports the window the third attempt bought"

reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=15234 PR_ACTION=opened LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 TASK_LEASE_RENEW_RETRIES=3 \
       FAKE_CURL_CODES=000 FAKE_CURL_RESPONSE='' run)"; RC=$?
check "17. a timeout (000) exits 0 after the bounded retries" "$RC" "0"
check "17b. …having tried exactly 3 times" "$(calls)" "3"

reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=15234 PR_ACTION=opened LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=400 \
       FAKE_CURL_RESPONSE='{"ok":false,"reason":"pr is required"}' run)"; RC=$?
check "18. a 400 contract mismatch exits 0 and blames the script, not the PR" "$RC" "0"
has "$OUT" "contract mismatch" "18b. …saying which side is wrong"

reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=15234 PR_ACTION=opened LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=200 FAKE_CURL_RESPONSE='not json at all' run)"; RC=$?
check "19. a 200 whose body cannot be read exits 0" "$RC" "0"
has "$OUT" "no claim.lease_extension.until" "19b. …and says which fact is missing rather than inventing a time"

echo
echo "── REFUSALS AND THE FORK CASE ──────────────────────────────────────────"

reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=15234 PR_ACTION=opened \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=200 run)"; RC=$?
check "20. no BARKPARK_TASK_TOKEN (a fork PR) exits 0" "$RC" "0"
has "$OUT" "::warning" "20b. …as a ::warning, never an accusation against a fork"
check "20c. …and calls the ledger zero times" "$(calls)" "0"

reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=notanumber PR_ACTION=opened LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=200 run)"; RC=$?
check "21. a non-numeric PR_NUMBER is CANNOT MEASURE (rc 2), never a silent skip" "$RC" "2"

reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=15234 PR_ACTION=opened LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=200 run --slftest)"; RC=$?
check "22. an unknown flag exits 2 — a typo must never pass as a no-op" "$RC" "2"

reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=15234 PR_ACTION=opened LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=200 \
       TASK_LEASE_RENEW_EXTRACTOR="$TMP/nope.sh" run)"; RC=$?
check "23. a missing trailer extractor is CANNOT MEASURE (rc 2)" "$RC" "2"
has "$OUT" "no second copy" "23b. …and says why this script owns no fallback regex"

reset_stub
OUT="$(PR_BODY="$BODY_OK" PR_NUMBER=15234 PR_ACTION=opened LEDGER_TOKEN=t \
       TASK_LEASE_RENEW_RETRY_DELAY=0 FAKE_CURL_CODES=200 run --dry-run)"; RC=$?
check "24. --dry-run exits 0" "$RC" "0"
check "24b. …and writes nothing to the ledger" "$(calls)" "0"

echo
echo "── ONE GRAMMAR, AND THE WORKFLOW THAT CALLS THIS FILE ──────────────────"

# The point of the delegation is that no fourth copy of the `Task:` grammar
# exists. Anchor on the regex pr-task-gate.sh owns, not on the word "task".
GRAM="$(grep "\^task:" "$SUBJECT" 2>/dev/null | wc -l | tr -d '[:space:]')"
check "25. the subject carries NO Task: trailer regex of its own" "$GRAM" "0"
has "$(cat "$SUBJECT")" "pr-task-gate.sh" "25b. …it shells out to pr-task-gate.sh instead"

if [ -f "$WORKFLOW" ]; then
  WF="$(cat "$WORKFLOW")"
  has "$WF" "bash scripts/task-lease-renew.sh" "26. the workflow runs THIS script (so the harness and CI share code)"
  for t in opened synchronize reopened ready_for_review closed; do
    case "$WF" in *"$t"*) ok "26.$t the workflow fires on $t" ;; *) bad "26.$t the workflow does not fire on $t" ;; esac
  done
  has "$WF" "secrets.BARKPARK_TASK_TOKEN" "27. …and reads the write-tier secret by the documented name"
  # A KEY, not the word: the file's own prose explains why the key is absent,
  # and a substring match on prose would red on the explanation. Anchor on a
  # YAML key at the start of a line.
  CIE="$(grep -E '^[[:space:]]*continue-on-error:' "$WORKFLOW" | wc -l | tr -d '[:space:]')"
  check "28. …with no continue-on-error KEY laundering the one loud arm" "$CIE" "0"
  # Absent from the required set is a PROPERTY of this mechanism, not an
  # oversight, so it is asserted rather than remembered.
  #
  # THIS CLAUSE USED TO GREP THE WHOLE FILE, and that was wrong in the one
  # direction that matters: a whole-file substring search cannot tell a REQUIRED
  # context from an EXCLUSION row, and an exclusion row is the exact OPPOSITE of
  # what it forbids. #16597 gave this job's rendered name `Keep the claim alive
  # while this PR is open` an S7 exclusion row — the ledger AGREEING that it must
  # never gate — and this clause reddened main on it (runs 34062750066,
  # 34064052560). Ask jq for the contexts. Identical fix to the one #16597 made
  # in crown-reconcile.test.sh; this was its underived sibling.
  SPEC_LR="$ROOT/.github/required-checks.json"
  if [ ! -f "$SPEC_LR" ]; then
    ok "29. this job is not in the required set (no spec file to read)"
  elif ! command -v jq >/dev/null 2>&1; then
    # Never silently pass: an unreadable input is a failed read, not a green.
    bad "29. jq is unavailable, so the required set could not be read — this clause refuses rather than guessing"
  elif jq -e '[.protection.required_status_checks.checks[]?.context]
              | any(. == "Keep the claim alive while this PR is open")' "$SPEC_LR" >/dev/null 2>&1; then
    bad "29. \`Keep the claim alive while this PR is open\` is a REQUIRED context in $SPEC_LR — a ledger state must never refuse a PR: $(jq -r '[.protection.required_status_checks.checks[]?.context] | join(", ")' "$SPEC_LR")"
  else
    ok "29. this job is NOT in the required set — a ledger state must never refuse a PR ($(jq -r '.protection.required_status_checks.checks | length' "$SPEC_LR") required context(s) read with jq, not grepped)"
  fi
  # …and the mirror, so the clause above cannot be satisfied by a spec that
  # simply FORGOT the name: an unaccounted rendered name is the defect the
  # census clause in required-checks-verify.sh exists for. Absent-from-required
  # and absent-from-the-file are different states and only one of them is right.
  if [ ! -f "$SPEC_LR" ] || ! command -v jq >/dev/null 2>&1; then
    :
  elif jq -e '[.exclusions[]?.context] | index("Keep the claim alive while this PR is open")' "$SPEC_LR" >/dev/null 2>&1; then
    ok "29b. …and it carries an EXCLUSION row, so the name is accounted rather than merely absent"
  else
    bad "29b. \`Keep the claim alive while this PR is open\` has no exclusion row in $SPEC_LR — an unaccounted rendered name reds the census clause"
  fi
else
  bad "26. the workflow .github/workflows/task-lease-renew.yml is missing"
fi

echo
# ── claim shape: the reader accepts doc.claim (live server) AND doc.content.claim (legacy) ──
reset_stub
out="$(PR_BODY=$'Fix\n\nTask: task-aaaaaaaaaaaaaaaa' PR_NUMBER=15234 PR_ACTION=synchronize LEDGER_TOKEN=tok FAKE_CURL_CODES=200 FAKE_CURL_RESPONSE="$RENEW_200_LEGACY" run)"
case "$out" in *"keeps task-aaaaaaaaaaaaaaaa claimed until 2026-09-02T13:45:00Z"*) ok "legacy doc.content.claim shape still reads the until" ;; *) bad "legacy shape not read: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)" ;; esac

echo "task-lease-renew.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
[ "$PASS" -gt 0 ] || { echo "task-lease-renew.test: a green over ZERO cases is not a green" >&2; exit 2; }
exit 0
