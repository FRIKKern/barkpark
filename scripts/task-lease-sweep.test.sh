#!/usr/bin/env bash
# task-lease-sweep.test.sh — hermetic harness for scripts/task-lease-sweep.sh.
#
# Same idiom as task-lease-renew.test.sh: a stub `curl` ahead of the real one
# answers the renew POSTs (so the WHOLE chain — sweep → task-lease-renew.sh →
# extractor → request body → answer table — runs for real), and the PR list is
# supplied as JSON lines through TASK_LEASE_SWEEP_LIST so no GitHub call is
# made. A stub `gh` that always fails proves the unreadable-list arm.
#
# Exit 0 = every case passed; 1 = at least one failed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/scripts/task-lease-sweep.sh"
TMP="$(mktemp -d -t task-lease-sweep-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 — '$2' not in output: $(printf '%s' "$1" | tr '\n' ' ' | cut -c1-240)" ;; esac; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
{ printf '%s\n' "ARGV: $*"; } >> "$FAKE_CURL_LOG"
n=0; [ -f "$FAKE_CURL_N" ] && n="$(cat "$FAKE_CURL_N")"; n=$((n + 1)); printf '%s' "$n" > "$FAKE_CURL_N"
code="$(printf '%s' "$FAKE_CURL_CODES" | cut -d, -f"$n")"
[ -n "$code" ] || code="$(printf '%s' "$FAKE_CURL_CODES" | tr ',' '\n' | tail -1)"
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && printf '%s' "${FAKE_CURL_RESPONSE:-}" > "$out"
printf '%s' "$code"; exit 0
STUB
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh: stub — HTTP 502 from api.github.com" >&2; exit 1
STUB
chmod +x "$TMP/bin/curl" "$TMP/bin/gh"
RENEW_200='{"ok":true,"doc":{"claim":{"worker":"lead-x","epoch":3,"lease_extension":{"until":"2026-09-03T06:00:00Z","renewals":2}},"content":{}}}'
ACCEPTED_NO_ECHO_200='{"ok":true,"doc":{"content":{}}}'
NOTCLAIMED_409='{"ok":false,"error":{"code":"conflict","reason":"not_claimed"}}'

run() { # $1 = list file or "", $2 = codes, $3 = response ; rest = extra env assignments
  ( export PATH="$TMP/bin:$PATH" LEDGER_TOKEN="${LEDGER_TOKEN-tok}" LEDGER_BASE="https://ledger.test"
    export FAKE_CURL_LOG="$TMP/curl.log" FAKE_CURL_N="$TMP/curl.n" FAKE_CURL_CODES="$2" FAKE_CURL_RESPONSE="$3"
    : > "$FAKE_CURL_LOG"; rm -f "$FAKE_CURL_N"
    [ -n "$1" ] && export TASK_LEASE_SWEEP_LIST="$1"
    bash "$SUBJECT" 2>&1; echo "RC=$?" )
}

# ── 1. two PRs naming rows: both renewed, one POST each, to the right ids ──
L1="$TMP/l1.jsonl"; printf '%s\n' '{"number":101,"body":"fix things\n\nTask: task-aaaaaaaaaaaaaaaa"}' '{"number":102,"body":"more\n\nTask: task-bbbbbbbbbbbbbbbb"}' > "$L1"
out="$(run "$L1" 200 "$RENEW_200")"
has "$out" "2 renewed" "1) two named rows are both renewed"
has "$out" "RC=0" "1) rc 0"
posts="$(grep -c 'v1/tasks/task-' "$TMP/curl.log")"; [ "$posts" = "2" ] && ok "1) exactly two renew POSTs went out" || bad "1) expected 2 POSTs, saw $posts"
grep -q 'task-aaaaaaaaaaaaaaaa/renew' "$TMP/curl.log" && grep -q 'task-bbbbbbbbbbbbbbbb/renew' "$TMP/curl.log" && ok "1) each POST names its own row" || bad "1) POST targets wrong"

# ── 2. a PR with no Task: trailer is skipped and the sweep continues ──
L2="$TMP/l2.jsonl"; printf '%s\n' '{"number":201,"body":"no trailer here"}' '{"number":202,"body":"x\n\nTask: task-cccccccccccccccc"}' > "$L2"
out="$(run "$L2" 200 "$RENEW_200")"
has "$out" "1 renewed, 1 skipped" "2) trailer-less PR skipped, the next still renewed"
has "$out" "RC=0" "2) rc 0"

# ── 3. the ledger declines (409 not_claimed): counted, never retried, rc 0 ──
out="$(run "$L1" 409 "$NOTCLAIMED_409")"
has "$out" "2 declined" "3) 409 not_claimed is a decline, not a failure"
posts="$(grep -c 'renew' "$TMP/curl.log")"; [ "$posts" = "2" ] && ok "3) a decline is not retried (2 POSTs for 2 PRs)" || bad "3) expected 2 POSTs, saw $posts"
has "$out" "RC=0" "3) rc 0"

# ── 4. token refused: rc 1 (the sweep is inert and must be red) ──
out="$(run "$L1" 401 '{"ok":false}')"
has "$out" "token-refused" "4) 401 is reported as token-refused"
has "$out" "RC=1" "4) rc 1"

# ── 5. zero open PRs: rc 0 and it says so ──
: > "$TMP/l5.jsonl"; out="$(run "$TMP/l5.jsonl" 200 "$RENEW_200")"
has "$out" "0 open PR(s)" "5) an empty list is reported, not hidden"
has "$out" "RC=0" "5) rc 0"

# ── 6. the PR list cannot be read (stub gh fails): rc 2, no POST ──
out="$(run "" 200 "$RENEW_200")"
has "$out" "CANNOT MEASURE" "6) unreadable list is CANNOT MEASURE"
has "$out" "RC=2" "6) rc 2"
posts="$(grep -c 'renew' "$TMP/curl.log" 2>/dev/null || true)"; [ "${posts:-0}" = "0" ] && ok "6) no POST when the population is unknown" || bad "6) POSTed over an unknown population"

# ── 7. a malformed line is unmeasured: rc 2, the good line still renewed ──
L7="$TMP/l7.jsonl"; printf '%s\n' 'not json at all' '{"number":702,"body":"Task: task-dddddddddddddddd"}' > "$L7"
out="$(run "$L7" 200 "$RENEW_200")"
has "$out" "1 renewed" "7) the well-formed line is still renewed"
has "$out" "1 unmeasured" "7) the malformed line is counted"
has "$out" "RC=2" "7) rc 2"

# ── 7b. a 200 whose answer carries no until is still a renew (the write happened; only the echo is missing) ──
out="$(run "$L1" 200 "$ACCEPTED_NO_ECHO_200")"
has "$out" "2 renewed" "7b) accepted-without-echo counts as renewed, not unclassified"
has "$out" "0 unclassified" "7b) nothing left unclassified"

# ── 8. the subject owns no Task: grammar of its own ──
grep -qE 'Task:[^"]*\[' "$SUBJECT" && bad "8) subject carries its own Task: regex" || ok "8) subject delegates the trailer grammar (no Task: regex of its own)"

echo; echo "task-lease-sweep.test.sh: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
