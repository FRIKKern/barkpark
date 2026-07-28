#!/usr/bin/env bash
# breakglass.test.sh — the mutation proofs for the break-glass and its scream.
#
# Nothing here asserts "the script ran". Every refusal is DISARMED and the
# specimen watched turning ACCEPTED; every ordering claim is proven by
# snapshotting the log file AT THE MOMENT of the DELETE, not by reading source.
#
# Fully hermetic: no network, no writes outside a temp dir. `gh` is a stub on
# PATH that records every invocation, so "made no API call" is an assertion
# about behaviour rather than a claim about control flow.
#
#   scripts/breakglass.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GLASS="$REPO_ROOT/scripts/breakglass.sh"
WATCH="$REPO_ROOT/scripts/breakglass-watch.sh"
WF="$REPO_ROOT/.github/workflows/breakglass-watch.yml"
GEN="$REPO_ROOT/scripts/required-checks-generate.sh"
DOC="$REPO_ROOT/docs/ops/break-glass-log.md"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
cleanup() { chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*" >&2; }
section() { echo; echo "── $* ──"; }

export BG_RETRY_SLEEP="0 0 0"

# ═══ the gh stub ═════════════════════════════════════════════════════════════
# Behaviour is driven entirely by files in $STUB, so each case sets up its own
# world. Every invocation is appended to $STUB/calls.log — that file is how the
# "no API call" and "protection endpoint only" claims are proven.

BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/calls.log"

# gh api user
if [ "${1:-}" = "api" ] && [ "${2:-}" = "user" ]; then
  if [ -f "$STUB/user.json" ]; then cat "$STUB/user.json"; exit 0; fi
  echo "gh: HTTP 401" >&2; exit 1
fi

method="GET"; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    api) shift ;;
    *) url="$1"; shift ;;
  esac
done

case "$method/$url" in
  DELETE/*enforce_admins)
    # THE ORDERING PROBE: snapshot the log exactly as it stands when the DELETE
    # is issued. If the record is not in this snapshot, it was not written first.
    cp "$BG_LOG" "$STUB/log-at-delete.txt" 2>/dev/null || echo "(no log)" > "$STUB/log-at-delete.txt"
    rc="$(cat "$STUB/delete.rc" 2>/dev/null || echo 0)"
    [ "$rc" = "0" ] && jq '.enforce_admins.enabled = false' "$STUB/protection.json" > "$STUB/p.tmp" \
      && mv "$STUB/p.tmp" "$STUB/protection.json"
    exit "$rc" ;;
  POST/*enforce_admins)
    cp "$BG_LOG" "$STUB/log-at-post.txt" 2>/dev/null || echo "(no log)" > "$STUB/log-at-post.txt"
    rc="$(cat "$STUB/post.rc" 2>/dev/null || echo 0)"
    [ "$rc" = "0" ] && jq '.enforce_admins.enabled = true' "$STUB/protection.json" > "$STUB/p.tmp" \
      && mv "$STUB/p.tmp" "$STUB/protection.json"
    exit "$rc" ;;
  GET/*branches/*/protection)
    if [ -f "$STUB/protection.err" ]; then cat "$STUB/protection.err" >&2; exit 1; fi
    if [ -f "$STUB/protection.errs" ]; then
      n="$(cat "$STUB/errcount" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$STUB/errcount"
      if [ "$n" -lt "$(cat "$STUB/protection.errs")" ]; then echo "gh: HTTP 502 bad gateway" >&2; exit 1; fi
    fi
    cat "$STUB/protection.json"; exit 0 ;;
esac
echo "stub: unexpected call: $method $url" >&2
exit 9
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

SPEC="$TMP/spec.json"
cat > "$SPEC" <<'JSON'
{ "enforced": true, "repo": "FRIKKern/barkpark", "branch": "main",
  "protection": { "required_status_checks": { "strict": false, "checks": [
    { "context": "Elixir gate", "app_id": 15368 } ] }, "enforce_admins": true } }
JSON

# A fresh world per case: an empty committed log, a protected branch, a known actor.
world() { # name
  export STUB="$TMP/$1"; mkdir -p "$STUB"
  export BG_LOG="$STUB/break-glass-log.md"
  : > "$STUB/calls.log"
  printf '<!-- doc-tier: agent | canonical-for: break-glass | budget: 1600tok -->\n# log\n\n<!-- BEGIN RECORDS -->\n' > "$BG_LOG"
  echo '{"login":"pelle","id":4242}' > "$STUB/user.json"
  echo '{"enforce_admins":{"enabled":true}}' > "$STUB/protection.json"
}

glass() { bash "$GLASS" --spec "$SPEC" --log "$BG_LOG" "$@"; }
calls() { cat "$STUB/calls.log" 2>/dev/null; }
ncalls() { grep -c . "$STUB/calls.log" 2>/dev/null || true; }

# ═══ 1. the refusals ═════════════════════════════════════════════════════════
section "1. it refuses before it can touch anything"

world r1
out="$(glass --open --task hgw4-s3 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q -- "--reason is required" <<<"$out"; then
  ok "1.1 --open without --reason refuses (exit $rc): $(head -1 <<<"$out")"
else bad "1.1 --open without --reason should refuse; exit $rc, out: $out"; fi
if [ "$(ncalls)" -eq 0 ]; then
  ok "1.2 …and made ZERO API calls (calls.log empty), not merely 'returned early'"
else bad "1.2 expected no API calls, saw: $(calls)"; fi

world r2
out="$(glass --open --reason "because" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q -- "--task is required" <<<"$out"; then
  ok "1.3 --open without --task refuses (exit $rc): $(head -1 <<<"$out")"
else bad "1.3 --open without --task should refuse; exit $rc, out: $out"; fi
[ "$(ncalls)" -eq 0 ] && ok "1.4 …and made ZERO API calls" || bad "1.4 saw calls: $(calls)"

world r3
out="$(glass --close --task hgw4-s3 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q -- "--reason is required" <<<"$out" \
  && ok "1.5 --close is symmetric in its refusals (no --reason ⇒ exit $rc)" \
  || bad "1.5 --close without --reason should refuse; exit $rc: $out"

world r4
out="$(glass --close --reason "x" --task hgw4-s3 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "no matching OPEN break-glass record" <<<"$out"; then
  ok "1.6 --close against an empty log refuses (exit $rc): $(head -1 <<<"$out")"
else bad "1.6 --close on an empty log should refuse; exit $rc: $out"; fi
if ! grep -q "POST" <<<"$(calls)"; then
  ok "1.7 …and never POSTed — closing what was never recorded would write a lie"
else bad "1.7 --close on an empty log issued a POST: $(calls)"; fi

# ═══ 2. the ordering ═════════════════════════════════════════════════════════
section "2. the record is written and acknowledged BEFORE the delete"

world o1
out="$(glass --open --reason "guerrilla 500s, #6414 is green" --task hgw4-s3 2>&1)"; rc=$?
id="$(grep -o 'BG-[0-9TZ]*-[0-9a-f]*' "$BG_LOG" | head -1)"
if [ "$rc" -eq 0 ] && [ -n "$id" ]; then
  ok "2.1 --open succeeded and wrote record $id"
else bad "2.1 --open failed (exit $rc): $out"; fi
if [ -f "$STUB/log-at-delete.txt" ] && grep -q "$id" "$STUB/log-at-delete.txt"; then
  ok "2.2 the log ALREADY contained $id at the instant the DELETE was issued (snapshot taken inside the stub, not read from source)"
else bad "2.2 the record was not on disk when the DELETE fired"; fi
if grep -q "DELETE .*branches/main/protection/enforce_admins" <<<"$(calls)"; then
  ok "2.3 the narrow endpoint is the one deleted (enforce_admins, not all protection)"
else bad "2.3 wrong delete endpoint: $(calls)"; fi

for f in "event: open" "utc:" "actor: pelle (id 4242)" "task: hgw4-s3" "repo: FRIKKern/barkpark" \
         "branch: main" "command: scripts/breakglass.sh" "pre-state: enforce_admins.enabled=true" \
         "reason: guerrilla 500s, #6414 is green" "outcome: opened"; do
  grep -q -- "- $f" "$BG_LOG" && ok "2.4 record carries '$f'" || bad "2.4 record is missing '$f'"
done

world o2
mkdir -p "$STUB/logdir"; BG_LOG_REAL="$BG_LOG"; export BG_LOG="$STUB/logdir"
out="$(bash "$GLASS" --spec "$SPEC" --log "$BG_LOG" --open --reason "x" --task t 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && ! grep -q "DELETE" <<<"$(calls)"; then
  ok "2.5 an unwritable record ABORTS before the DELETE (exit $rc, no DELETE in calls.log)"
else bad "2.5 an unwritable record still let the DELETE fire: rc=$rc calls=$(calls)"; fi
export BG_LOG="$BG_LOG_REAL"

# ═══ 3. the pre-state ════════════════════════════════════════════════════════
section "3. it reads the pre-state, so an already-open glass is detected"

world p1
echo '{"enforce_admins":{"enabled":false}}' > "$STUB/protection.json"
out="$(glass --open --reason "x" --task t 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "ALREADY false" <<<"$out"; then
  ok "3.1 a live glass already open refuses (exit $rc): $(grep -o 'ALREADY false.*' <<<"$out" | head -1)"
else bad "3.1 should refuse on an already-open glass; exit $rc: $out"; fi
! grep -q "DELETE" <<<"$(calls)" && ok "3.2 …and issued no DELETE" || bad "3.2 it deleted anyway: $(calls)"

world p2
rm -f "$STUB/protection.json"; echo "gh: HTTP 502" > "$STUB/protection.err"
out="$(glass --open --reason "x" --task t 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "pre-state is unreadable" <<<"$out" \
  && ok "3.3 an unreadable pre-state refuses — fail closed, never assume" \
  || bad "3.3 unreadable pre-state should refuse; exit $rc: $out"

world p3
echo '{"enforce_admins":{"enabled":true}}' > "$STUB/protection.json"
glass --open --reason "first" --task t >/dev/null 2>&1
echo '{"enforce_admins":{"enabled":true}}' > "$STUB/protection.json"   # pretend it healed
out="$(glass --open --reason "second" --task t 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "already carries an OPEN break-glass" <<<"$out" \
  && ok "3.4 a standing open RECORD refuses a second open, even when live protection looks fine" \
  || bad "3.4 a second open should refuse; exit $rc: $out"

# ═══ 4. close ════════════════════════════════════════════════════════════════
section "4. close, and the deliberate ordering inversion"

world c1
glass --open --reason "open it" --task t >/dev/null 2>&1
id="$(grep -o 'BG-[0-9TZ]*-[0-9a-f]*' "$BG_LOG" | head -1)"
out="$(glass --close --reason "merged" --task t 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q -- "- closes: $id" "$BG_LOG"; then
  ok "4.1 --close writes a record referencing the open record ($id)"
else bad "4.1 close failed (exit $rc): $out"; fi
if [ -f "$STUB/log-at-post.txt" ] && ! grep -q -- "- closes: $id" "$STUB/log-at-post.txt"; then
  ok "4.2 the close record was written AFTER the POST — a crash mid-close leaves the log over-reporting (says open, is shut), never under-reporting"
else bad "4.2 the close record predated the POST, which is the unsafe direction"; fi
out="$(glass --close --reason "again" --task t 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "4.3 closing an already-closed glass refuses (exit $rc)" \
  || bad "4.3 double-close should refuse"

world c2
glass --open --reason "open it" --task t >/dev/null 2>&1
echo 1 > "$STUB/post.rc"
out="$(glass --close --reason "merged" --task t 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && ! grep -q -- "- closes:" "$BG_LOG"; then
  ok "4.4 a failed POST writes NO close record — the log keeps saying open, and the watch keeps screaming"
else bad "4.4 a failed POST still wrote a close record: $out"; fi

# ═══ 5. the watch ════════════════════════════════════════════════════════════
section "5. the scream: level-triggered, protection only"

world w1
echo '{"enforce_admins":{"enabled":true}}' > "$TMP/prot-true.json"
echo '{"enforce_admins":{"enabled":false}}' > "$TMP/prot-false.json"
echo '{"message":"Branch not protected"}' > "$TMP/prot-none.json"

bash "$WATCH" --spec "$SPEC" --log "$BG_LOG" --protection-file "$TMP/prot-true.json" >/dev/null 2>&1
[ $? -eq 0 ] && ok "5.1 shut + clean log ⇒ exit 0" || bad "5.1 expected 0"

out="$(bash "$WATCH" --spec "$SPEC" --log "$BG_LOG" --protection-file "$TMP/prot-false.json" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q "BREAK-GLASS OPEN" <<<"$out" \
  && ok "5.2 a simulated open glass (enforce_admins=false) exits 1 and names it" \
  || bad "5.2 expected exit 1, got $rc: $out"

out="$(bash "$WATCH" --spec "$SPEC" --log "$BG_LOG" --protection-file "$TMP/prot-none.json" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "5.3 no protection at all, while the spec says enforced ⇒ exit 1 (total glass)" \
  || bad "5.3 expected exit 1, got $rc: $out"

out="$(bash "$WATCH" --spec "$SPEC" --log "$BG_LOG" --protection-file "$TMP/nope.json" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && grep -q "UNKNOWN" <<<"$out" \
  && ok "5.4 an unreadable protection API is UNKNOWN (exit 2), never a green — the documented residual" \
  || bad "5.4 expected exit 2, got $rc: $out"

world w2
glass --open --reason "open it" --task t >/dev/null 2>&1
out="$(bash "$WATCH" --spec "$SPEC" --log "$BG_LOG" --protection-file "$TMP/nope.json" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q "carries an unclosed record" <<<"$out" \
  && ok "5.5 an open RECORD reds even when the API is unreadable — the offline authority survives a D49 outage" \
  || bad "5.5 expected exit 1 from the log authority, got $rc: $out"

world w3
: > "$STUB/calls.log"
echo '{"enforce_admins":{"enabled":true}}' > "$STUB/protection.json"
echo 3 > "$STUB/protection.errs"
out="$(bash "$WATCH" --spec "$SPEC" --log "$BG_LOG" --attempts 3 2>&1)"; rc=$?
n="$(ncalls)"
[ "$rc" -eq 0 ] && [ "$n" -eq 3 ] \
  && ok "5.6 two transport failures then an answer ⇒ 3 attempts, exit 0 (retry, then an authoritative verdict)" \
  || bad "5.6 expected exit 0 after 3 attempts; rc=$rc calls=$n"
if ! grep -qE "check-runs|/pulls|/commits|api user" <<<"$(calls)"; then
  ok "5.7 the watch touched the protection endpoint ONLY — no /check-runs, no /pulls, no actor read"
else bad "5.7 the watch touched more than protection: $(calls)"; fi
if ! grep -qE 'gh api' "$WATCH" || [ "$(grep -c 'gh api' "$WATCH")" -eq 1 ]; then
  ok "5.8 …and its source contains exactly ONE gh call site: $(grep -o 'gh api "[^"]*"' "$WATCH")"
else bad "5.8 breakglass-watch.sh has more than one gh call site: $(grep -n 'gh api' "$WATCH")"; fi

# ═══ 6. the workflow shape ═══════════════════════════════════════════════════
# D26: the script harness could not have caught either YAML defect this epic
# already shipped, so the YAML is asserted here too.
section "6. breakglass-watch.yml — the shape that makes the RUN fail"

grep -qE '^\s+- cron:' "$WF" && ok "6.1 schedule: cron present (a LEVEL trigger, not branch_protection_rule's edge)" \
  || bad "6.1 no cron schedule"
grep -q '^  workflow_dispatch:' "$WF" && ok "6.2 workflow_dispatch present (the manual re-arm)" || bad "6.2 no workflow_dispatch"
awk '/^  push:/{p=1} p && /branches: \[main\]/{found=1} END{exit !found}' "$WF" \
  && ok "6.3 push: branches [main] present" || bad "6.3 no push-to-main trigger"
awk '/^  pull_request:/{p=1} p && /^    paths:/{found=1} END{exit !found}' "$WF" \
  && ok "6.4 pull_request is paths-filtered (S4-excluded by construction)" || bad "6.4 pull_request is not paths-filtered"
if ! grep -qE '^\s*continue-on-error:' "$WF"; then
  ok "6.5 NO continue-on-error anywhere — job-level c-o-e renders a red check but launders the RUN to success, and the rollup is what notifications read"
else bad "6.5 a continue-on-error: directive appears in $WF"; fi
if grep -q "if: github.event_name != 'pull_request'" "$WF"; then
  ok "6.6 the watch job is excluded from pull_request runs"
else bad "6.6 the watch job has no pull_request exclusion"; fi
grep -q "bash scripts/breakglass.test.sh" "$WF" \
  && ok "6.7 this harness is invoked by the workflow — not an orphan (D26)" || bad "6.7 harness is orphaned"
if ! grep -qE '^\s*continue-on-error: true' "$REPO_ROOT/.github/workflows/required-checks-drift.yml"; then
  bad "6.8 required-checks-drift.yml lost its continue-on-error — that makes an API-reading check eligible for the required set"
else ok "6.8 required-checks-drift.yml still carries continue-on-error (untouched on purpose)"; fi

section "6b. the generator can never sample these names into the required set"
GWF="$TMP/wf"; GFX="$TMP/fx"; mkdir -p "$GWF" "$GFX"
cp "$WF" "$GWF/breakglass-watch.yml"
cat > "$GWF/keeper.yml" <<'YAML'
name: keeper
on:
  pull_request:
jobs:
  keeper:
    name: Keeper gate
    runs-on: ubuntu-latest
YAML
runs() { cat <<'JSON'
{ "check_runs": [
  { "name": "Keeper gate",         "conclusion": "success", "started_at": "2026-07-28T01:00:00Z", "app": { "id": 15368 } },
  { "name": "Break-glass watch",   "conclusion": "success", "started_at": "2026-07-28T01:00:00Z", "app": { "id": 15368 } },
  { "name": "Break-glass harness", "conclusion": "success", "started_at": "2026-07-28T01:00:00Z", "app": { "id": 15368 } }
] }
JSON
}
runs > "$GFX/checkruns-A.json"; runs > "$GFX/checkruns-B.json"; runs > "$GFX/checkruns-M.json"
echo "M" > "$GFX/main-shas.txt"
genout="$(bash "$GEN" --repo FRIKKern/barkpark --branch main --workflows "$GWF" \
  --fixture-dir "$GFX" --sha A --sha B 2>&1)"
spec_only="$(printf '%s' "$genout" | sed -n '/^{/,$p')"
ctxs="$(printf '%s' "$spec_only" | jq -r '.protection.required_status_checks.checks[].context' 2>/dev/null)"
if [ -n "$ctxs" ] && ! grep -q "Break-glass" <<<"$ctxs"; then
  ok "6.9 a generator run that was FED both names selected neither: [$(printf '%s' "$ctxs" | tr '\n' ' ')]"
else bad "6.9 the generator selected a break-glass name (or produced nothing): $ctxs"; fi
if printf '%s' "$spec_only" | jq -e '[.exclusions[] | select(.context | startswith("Break-glass"))] | length == 2' >/dev/null 2>&1; then
  ok "6.10 both names are recorded as EXCLUSIONS with a reason, not silently dropped: $(printf '%s' "$spec_only" | jq -r '[.exclusions[] | select(.context|startswith("Break-glass")) | .reason] | .[0]' | cut -c1-60)…"
else bad "6.10 the exclusion ledger does not carry both names"; fi

# ═══ 7. the runbook states the residual ══════════════════════════════════════
section "7. the residual is stated in numbers"
grep -q "30-minute observation window" "$DOC" && ok "7.1 the 30-minute window is stated" || bad "7.1 no 30-minute window"
grep -q "Actions outage silences it" "$DOC" && ok "7.2 the Actions-outage silence is stated" || bad "7.2 no Actions-outage line"
grep -q "60 days" "$DOC" && ok "7.3 the 60-day scheduled-workflow auto-disable is stated" || bad "7.3 no 60-day line"

# ═══ 8. mutation proofs ══════════════════════════════════════════════════════
# A guard that cannot be shown to be load-bearing is decoration. Each mutant
# removes exactly one clause and the specimen is watched turning ACCEPTED.
section "8. every guard proven load-bearing by disarming it"

MUT="$TMP/mutant.sh"

world m1
sed 's@^  \[ -n "$REASON" \] || fail.*@  :@; s@^  \[ -n "$TASK" \]   || fail.*@  :@' "$GLASS" > "$MUT"
out="$(bash "$MUT" --spec "$SPEC" --log "$BG_LOG" --open 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q "DELETE" <<<"$(calls)"; then
  ok "8.1 disarm the --reason/--task refusal ⇒ an unexplained open is ACCEPTED and DELETEs. The refusal is load-bearing."
else bad "8.1 the mutant did not open (rc $rc) — the clean-run refusal proves nothing"; fi

world m2
mkdir -p "$STUB/logdir"
sed 's@^    || fail "the record could not be written.*@    || true@' "$GLASS" > "$MUT"
out="$(bash "$MUT" --spec "$SPEC" --log "$STUB/logdir" --open --reason x --task t 2>&1)"; rc=$?
if grep -q "DELETE" <<<"$(calls)"; then
  ok "8.2 disarm the record acknowledgement ⇒ the DELETE fires with NO record on disk. The ordering gate is load-bearing."
else bad "8.2 the mutant never DELETEd; 2.5 proves nothing"; fi

world m3
echo '{"enforce_admins":{"enabled":false}}' > "$STUB/protection.json"
sed 's@^    false) fail "enforce_admins is ALREADY false.*@    false) : ;;@' "$GLASS" > "$MUT"
out="$(bash "$MUT" --spec "$SPEC" --log "$BG_LOG" --open --reason x --task t 2>&1)"; rc=$?
if grep -q "DELETE" <<<"$(calls)"; then
  ok "8.3 disarm the pre-state check ⇒ a second glass opens over the first. The pre-state read is load-bearing."
else bad "8.3 the mutant refused anyway (rc $rc): $out"; fi

world m4
glass --open --reason "open it" --task t >/dev/null 2>&1
sed 's@^  if \[ -n "$standing" \]; then@  if false; then@' "$WATCH" > "$MUT"
out="$(bash "$MUT" --spec "$SPEC" --log "$BG_LOG" --protection-file "$TMP/nope.json" 2>&1)"; rc=$?
if [ "$rc" -ne 1 ]; then
  ok "8.4 disarm the committed-log authority ⇒ an open glass goes UNSEEN when the API is unreadable (exit $rc, not 1). The offline authority is load-bearing."
else bad "8.4 the mutant still red; 5.5 proves nothing"; fi

echo
echo "── tally ──"
echo "  pass $PASS   fail $FAIL"
[ "$FAIL" -eq 0 ] || { echo "BREAK-GLASS HARNESS FAILED" >&2; exit 1; }
echo "BREAK-GLASS HARNESS OK — every refusal disarmed and watched accepting, every ordering claim snapshotted at the API call."
