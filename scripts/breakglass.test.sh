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
    --input) shift 2 ;;
    --jq) shift 2 ;;
    *) url="$1"; shift ;;
  esac
done

case "$method/$url" in
  PUT/*branches/*/protection)
    # The full-replace restore. Body is read (and kept) so a case can assert
    # WHAT was PUT, not merely that a PUT happened.
    cat > "$STUB/put-body.json"
    cp "$BG_LOG" "$STUB/log-at-put.txt" 2>/dev/null || echo "(no log)" > "$STUB/log-at-put.txt"
    rc="$(cat "$STUB/put.rc" 2>/dev/null || echo 0)"
    if [ "$rc" = "0" ]; then
      rm -f "$STUB/protection.err"
      echo '{"enforce_admins":{"enabled":true}}' > "$STUB/protection.json"
    fi
    exit "$rc" ;;
  DELETE/*branches/*/protection)
    # THE TOTAL HAMMER. Same ordering probe as the narrow path below: snapshot
    # the log exactly as it stands at the instant the API call is issued.
    cp "$BG_LOG" "$STUB/log-at-delete.txt" 2>/dev/null || echo "(no log)" > "$STUB/log-at-delete.txt"
    rc="$(cat "$STUB/delete.rc" 2>/dev/null || echo 0)"
    if [ "$rc" = "0" ]; then
      rm -f "$STUB/protection.json"
      echo '{"message":"Branch not protected"}' > "$STUB/protection.err"
    fi
    exit "$rc" ;;
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
# The committed log's standing-open set, computed by the SAME awk breakglass.sh
# uses — a hand-written retrospective row that the real parser reads as OPEN
# would red main every 30 minutes, so it is checked with the real parser.
open_glasses_in_doc() {
  awk '
    /^### BG-/       { id = $2; next }
    /^- event: open/ { if (id != "") opens[id] = 1; next }
    /^- closes: /    { closed[$3] = 1; next }
    END { for (i in opens) if (!(i in closed)) print i }
  ' "$DOC" | sort
}
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

# 6.9 (wave 4 review). The scream shipped with `administration: read` under
# `permissions:`. That scope is NOT accepted for GITHUB_TOKEN — GitHub rejects
# the file as invalid and the workflow never runs at all, which is a scream that
# is silent by construction. bash -n and every script assertion above stay green
# through it, so it gets its own row. The allow-set below is GitHub's documented
# GITHUB_TOKEN scope list; a scope outside it fails here rather than on the
# runner. The live-protection authority is armed by the BREAKGLASS_TOKEN secret,
# not by a permissions key.
BG_BAD_SCOPES=""
while IFS= read -r scope; do
  case "$scope" in
    actions|attestations|checks|contents|deployments|discussions|id-token|issues|models|packages|pages|pull-requests|repository-projects|security-events|statuses) ;;
    "") ;;
    *) BG_BAD_SCOPES="$BG_BAD_SCOPES $scope" ;;
  esac
done <<EOF
$(awk '/^permissions:/{p=1;next} p && /^[a-z]/{p=0} p && /^  [a-z-]+:/{gsub(/^  /,"");sub(/:.*/,"");print}' "$WF")
EOF
if [ -z "$BG_BAD_SCOPES" ]; then
  ok "6.8b every permissions: scope is one GITHUB_TOKEN actually accepts (an invalid scope makes the whole workflow unparseable, i.e. a scream that never runs)"
else bad "6.8b unsupported permissions scope(s) in $WF:$BG_BAD_SCOPES — GitHub rejects the workflow file outright"; fi

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
# `--no-merge` because 6.9/6.10 test SELECTION, not merge semantics. Without it
# the generator's by-name S1-LOSS refusal (#8394) fires and emits nothing at all,
# which fails both assertions for a reason that has nothing to do with what they
# measure: this fixture's `$GWF` holds two synthetic workflows, so not one of the
# four contexts the committed spec requires can render, and refusing that sample
# is the guard behaving CORRECTLY. Isolating selection keeps both assertions
# about the thing they name — that a break-glass name can never be sampled into
# the required set, and that both are recorded as exclusions rather than dropped.
genout="$(bash "$GEN" --repo FRIKKern/barkpark --branch main --workflows "$GWF" \
  --fixture-dir "$GFX" --sha A --sha B --no-merge 2>&1)"
spec_only="$(printf '%s' "$genout" | sed -n '/^{/,$p')"
ctxs="$(printf '%s' "$spec_only" | jq -r '.protection.required_status_checks.checks[].context' 2>/dev/null)"
if [ -n "$ctxs" ] && ! grep -q "Break-glass" <<<"$ctxs"; then
  ok "6.9 a generator run that was FED both names selected neither: [$(printf '%s' "$ctxs" | tr '\n' ' ')]"
else bad "6.9 the generator selected a break-glass name (or produced nothing): $ctxs"; fi
if printf '%s' "$spec_only" | jq -e '[.exclusions[] | select(.context | startswith("Break-glass"))] | length == 2' >/dev/null 2>&1; then
  ok "6.10 both names are recorded as EXCLUSIONS with a reason, not silently dropped: $(printf '%s' "$spec_only" | jq -r '[.exclusions[] | select(.context|startswith("Break-glass")) | .reason] | .[0]' | cut -c1-60)…"
else bad "6.10 the exclusion ledger does not carry both names"; fi

# ═══ 7. the runbook states the residual ══════════════════════════════════════
section "7. the residual is stated in numbers, bounded rather than absolute"
grep -q "30-minute observation window" "$DOC" && ok "7.1 the 30-minute window is stated" || bad "7.1 no 30-minute window"
grep -q "Actions outage silences it" "$DOC" && ok "7.2 the Actions-outage silence is stated" || bad "7.2 no Actions-outage line"
grep -q "60 days" "$DOC" && ok "7.3 the 60-day scheduled-workflow auto-disable is stated" || bad "7.3 no 60-day line"
grep -q "COMMITTED AND PUSHED" "$DOC" \
  && ok "7.4 the append-to-push window is stated (the record is only an authority once pushed)" \
  || bad "7.4 no append-to-push window"
grep -q "pt-w1-scheduled-gate-alerting" "$DOC" \
  && ok "7.5 the fifth residual — a red run only screams if it REACHES a human, and this repo has zero webhooks — names its prior-art task rather than re-filing it" \
  || bad "7.5 the alerting residual does not reference pt-w1-scheduled-gate-alerting"
if grep -q "zero webhooks on this repository" "$DOC"; then
  ok "7.6 …and states the mechanism (zero webhooks), not just the task id"
else bad "7.6 the alerting residual does not state the zero-webhook mechanism"; fi
# BOUNDED, not absolute: the claim must be scoped to what was actually measured.
if grep -q "Bounded claim" "$DOC" && grep -q "more than one watch interval" "$DOC"; then
  ok "7.7 the shippable claim is stated in bounded, checkable form (every lowering of main's admin gate is refused or observed; no open glass survives more than one watch interval without a FAILING run)"
else bad "7.7 the runbook does not state a bounded claim"; fi
# D39: the narrow glass DOES restore direct push for an admin. The doc used to
# imply only --disable did. That sentence is what a human reads at 03:00.
if grep -q "Bypassed rule violations" "$DOC"; then
  ok "7.8 the push contradiction is fixed per D39 — the doc quotes the measured 'remote: Bypassed rule violations' rather than implying only --disable restores push"
else bad "7.8 the runbook still does not say that an admin push lands with the NARROW glass open (D39)"; fi
if grep -q "breakglass.sh --open --total" "$DOC"; then
  ok "7.9 the runbook teaches the recorded total form, not a raw gh api line"
else bad "7.9 the runbook does not point --disable's users at breakglass.sh --open --total"; fi

# ═══ 7b. the flip's own tooling stops teaching the unrecorded path ════════════
section "7b. required-checks-apply.sh no longer documents or performs a silent open"
APPLY="$REPO_ROOT/scripts/required-checks-apply.sh"
if ! grep -qE 'gh api -X (DELETE|POST) +repos/<' "$APPLY"; then
  ok "7b.1 the raw two-line unrecorded recipe is GONE from the header"
else bad "7b.1 the header still teaches a raw gh api break-glass: $(grep -nE 'gh api -X (DELETE|POST) +repos/<' "$APPLY")"; fi
if grep -q 'scripts/breakglass.sh --open' "$APPLY"; then
  ok "7b.2 …and the header points at scripts/breakglass.sh --open instead"
else bad "7b.2 the header does not point at breakglass.sh"; fi
if ! grep -q 'echo UNKNOWN' "$APPLY"; then
  ok "7b.3 the 'gh api user … || echo UNKNOWN' fallback is gone — an unattributable break-glass is not a break-glass"
else bad "7b.3 required-checks-apply.sh still falls back to UNKNOWN: $(grep -n 'echo UNKNOWN' "$APPLY")"; fi
if ! grep -qF 'gh api -X DELETE "repos/$repo/branches/$branch/protection"' "$APPLY"; then
  ok "7b.4 --disable no longer issues its own DELETE anywhere in the script"
else bad "7b.4 required-checks-apply.sh still deletes protection itself"; fi
if grep -q 'exec bash "$REPO_ROOT/scripts/breakglass.sh"' "$APPLY"; then
  ok "7b.5 …it delegates to the one recorder (exec breakglass.sh --open --total)"
else bad "7b.5 --disable does not delegate to breakglass.sh"; fi

# ═══ 8. mutation proofs ══════════════════════════════════════════════════════
# A guard that cannot be shown to be load-bearing is decoration. Each mutant
# removes exactly one clause and the specimen is watched turning ACCEPTED.
section "8. every guard proven load-bearing by disarming it"

# Mutants live in a REPO-SHAPED tree, not loose in $TMP. `breakglass.sh`
# derives REPO_ROOT from its own dirname/.., and the stale-checkout guard reads
# the sibling scripts/required-checks-apply.sh out of it — a mutant run from a
# bare temp dir would be refused as a partial checkout before its disarmed
# clause could be watched accepting, and every proof below would go vacuous.
MUTREPO="$TMP/mutrepo"
mkdir -p "$MUTREPO/scripts"
cp "$APPLY" "$GLASS" "$MUTREPO/scripts/"
MUT="$MUTREPO/scripts/mutant.sh"

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

# ═══ 9. the TOTAL hammer records, on the same path as the narrow one ═════════
# `required-checks-apply.sh --disable` used to gate on nothing but --confirm,
# write no record, and DELETE the whole protection object. Every claim below is
# behaviour: the ordering row snapshots the log INSIDE the stub at the instant
# of the DELETE, exactly as 2.2 does for the narrow path.
section "9. required-checks-apply.sh --disable is a RECORDED break-glass"

apply() { bash "$APPLY" --spec "$SPEC" --log "$BG_LOG" "$@"; }

world d1
out="$(apply --disable --confirm --task hgw5-s4 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q -- "--disable needs --reason" <<<"$out"; then
  ok "9.1 --disable without --reason refuses (exit $rc): $(head -1 <<<"$out")"
else bad "9.1 --disable without --reason should refuse; exit $rc: $out"; fi
[ "$(ncalls)" -eq 0 ] && ok "9.2 …and made ZERO API calls" || bad "9.2 saw calls: $(calls)"

world d2
out="$(apply --disable --confirm --reason "the fleet is stuck" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q -- "--disable needs --task" <<<"$out"; then
  ok "9.3 --disable without --task refuses (exit $rc): $(head -1 <<<"$out")"
else bad "9.3 --disable without --task should refuse; exit $rc: $out"; fi
[ "$(ncalls)" -eq 0 ] && ok "9.4 …and made ZERO API calls" || bad "9.4 saw calls: $(calls)"

world d3
out="$(apply --disable --confirm --reason "the fleet is stuck" --task hgw5-s4 2>&1)"; rc=$?
id="$(grep -o 'BG-[0-9TZ]*-[0-9a-f]*' "$BG_LOG" | head -1)"
if [ "$rc" -eq 0 ] && [ -n "$id" ]; then
  ok "9.5 --disable --confirm --reason --task opens the TOTAL glass and wrote record $id"
else bad "9.5 --disable failed (exit $rc): $out"; fi
if [ -f "$STUB/log-at-delete.txt" ] && grep -q "$id" "$STUB/log-at-delete.txt"; then
  ok "9.6 the log ALREADY contained $id at the instant the total DELETE was issued (snapshot taken inside the stub, not read from source)"
else bad "9.6 the record was not on disk when the total DELETE fired"; fi
if grep -qE 'DELETE .*branches/main/protection( |$)' <<<"$(calls)" \
   && ! grep -q "enforce_admins" <<<"$(calls)"; then
  ok "9.7 the WHOLE protection object is the endpoint deleted, not enforce_admins"
else bad "9.7 wrong endpoint for the total hammer: $(calls)"; fi
grep -q -- "- scope: total" "$BG_LOG" \
  && ok "9.8 the record carries 'scope: total' — --close reads it back to decide how much to restore" \
  || bad "9.8 the record has no scope: total"
grep -q -- "- actor: pelle (id 4242)" "$BG_LOG" \
  && ok "9.9 …and an attributable actor, read through breakglass.sh's read_actor" \
  || bad "9.9 the record has no actor"

world d4
rm -f "$STUB/user.json"     # gh api user now 401s
out="$(apply --disable --confirm --reason "x" --task t 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && ! grep -q "DELETE" <<<"$(calls)"; then
  ok "9.10 an UNREADABLE actor refuses and never DELETEs (exit $rc) — the old code printed 'UNKNOWN' and deleted anyway"
else bad "9.10 an unattributable --disable still deleted: rc=$rc calls=$(calls)"; fi

# ═══ 9b. the total glass is closed by restoring the FULL object ══════════════
section "9b. a total glass closes with a full-spec PUT, never a narrow POST"

world d5
apply --disable --confirm --reason "stuck" --task t >/dev/null 2>&1
id="$(grep -o 'BG-[0-9TZ]*-[0-9a-f]*' "$BG_LOG" | head -1)"
: > "$STUB/calls.log"
out="$(glass --close --reason "unstuck" --task t 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q -- "- closes: $id" "$BG_LOG"; then
  ok "9b.1 --close closed the total record $id"
else bad "9b.1 close of a total glass failed (exit $rc): $out"; fi
if grep -q "PUT" <<<"$(calls)" && ! grep -q "POST" <<<"$(calls)"; then
  ok "9b.2 it PUT the whole protection object and issued NO enforce_admins POST — a partial restore followed by a close record would be a new lie"
else bad "9b.2 the total close did not full-restore: $(calls)"; fi
if [ -f "$STUB/put-body.json" ] \
   && jq -e '.required_status_checks.checks[0].context == "Elixir gate"' "$STUB/put-body.json" >/dev/null 2>&1; then
  ok "9b.3 the PUT body is the COMMITTED SPEC (required contexts included), not a hand-built fragment"
else bad "9b.3 the PUT body did not carry the spec's required checks: $(cat "$STUB/put-body.json" 2>/dev/null)"; fi
if [ "$(grep -c -- "- scope: total" "$BG_LOG")" -eq 2 ]; then
  ok "9b.4 BOTH blocks carry scope: total — the open record and the close record that answers it"
else bad "9b.4 the close record lost the scope: $(grep -c -- "- scope: total" "$BG_LOG") occurrence(s)"; fi
if [ -f "$STUB/log-at-put.txt" ] && ! grep -q -- "- closes: $id" "$STUB/log-at-put.txt"; then
  ok "9b.5 the close record was written AFTER the restore — the deliberate ordering inversion survives the total path too"
else bad "9b.5 the total close wrote its record before restoring"; fi

world d6
apply --disable --confirm --reason "stuck" --task t >/dev/null 2>&1
: > "$STUB/calls.log"
# Disarm the scope read-back: the close then believes every glass is narrow.
sed 's@^  scope="$(record_field "$target" scope)"@  scope=""@' "$GLASS" > "$MUT"
out="$(bash "$MUT" --spec "$SPEC" --log "$BG_LOG" --close --reason "x" --task t 2>&1)"; rc=$?
if grep -q "POST" <<<"$(calls)" && ! grep -q "PUT" <<<"$(calls)"; then
  ok "9b.6 disarm the scope read-back ⇒ a TOTAL glass is 'closed' with the narrow POST, leaving a branch with no required checks and a close record saying it is shut. The scope field is load-bearing."
else bad "9b.6 the mutant did not take the narrow path; 9b.2 proves nothing: rc=$rc calls=$(calls)"; fi

world d7
# Disarm the delegation itself: --disable goes back to deleting protection by
# hand. The record is what disappears — which is the whole point of the routing.
# The delegation is ONE line — `exec bash … "${glass_args[@]}"` — so the mutant
# is a single substitution. (It used to be a multi-line exec and this was an awk
# skip-range; a range that never finds its terminator silently eats the rest of
# the file and the mutant then "passes" for the wrong reason.)
sed 's@^    exec bash "\$REPO_ROOT/scripts/breakglass.sh" .*@    gh api -X DELETE "repos/$repo/branches/$branch/protection" >/dev/null 2>\&1; return 0@' \
  "$APPLY" > "$MUT"
grep -q 'gh api -X DELETE "repos/\$repo' "$MUT" \
  || bad "9b.7 SETUP: the delegation mutant did not apply — the exec line's shape changed and this proof is vacuous"
out="$(bash "$MUT" --spec "$SPEC" --log "$BG_LOG" --disable --confirm --reason x --task t 2>&1)"; rc=$?
if grep -q "DELETE" <<<"$(calls)" && ! grep -q "BG-" "$BG_LOG"; then
  ok "9b.7 disarm the delegation ⇒ the total DELETE fires with NO record on disk — exactly the silent open that shipped on main. The routing is load-bearing."
else bad "9b.7 the mutant did not open silently (rc $rc); 9.6 proves nothing: calls=$(calls)"; fi

# ═══ 10. a revoked token REDS ════════════════════════════════════════════════
# Measured on main: a 403 'Resource not accessible by integration' returned
# UNKNOWN (rc 2), the workflow mapped rc 2 to exit 0, and the run concluded
# SUCCESS — a watch with no live authority reporting green.
section "10. 401/403 is a CONFIGURATION fault, not a transport blip"

world t1
printf 'gh: HTTP 401: Bad credentials (https://api.github.com/repos/x/branches/main/protection)\n' > "$STUB/protection.err"
rm -f "$STUB/protection.json"
out="$(bash "$WATCH" --spec "$SPEC" --log "$BG_LOG" --attempts 3 2>&1)"; rc=$?
if [ "$rc" -eq 3 ] && grep -q "CONFIGURATION FAULT" <<<"$out"; then
  ok "10.1 a revoked/garbage token (401 Bad credentials) exits 3, not 2 — the verdict the workflow reds on"
else bad "10.1 expected exit 3 from a 401; got $rc: $out"; fi
if [ "$(ncalls)" -eq 1 ]; then
  ok "10.2 …and it was NOT retried (1 call, not 3): a permanent fault does not clear by waiting 20 seconds"
else bad "10.2 the 401 was retried $(ncalls) times"; fi

world t2
printf 'gh: HTTP 403: Resource not accessible by integration\n' > "$STUB/protection.err"
rm -f "$STUB/protection.json"
out="$(bash "$WATCH" --spec "$SPEC" --log "$BG_LOG" --attempts 3 2>&1)"; rc=$?
[ "$rc" -eq 3 ] \
  && ok "10.3 the EXACT body the live scheduled run got (403 'Resource not accessible by integration', run 30395930365) now exits 3" \
  || bad "10.3 expected exit 3 from the measured 403; got $rc: $out"

world t3
printf 'gh: HTTP 502 bad gateway\n' > "$STUB/protection.err"
rm -f "$STUB/protection.json"
out="$(bash "$WATCH" --spec "$SPEC" --log "$BG_LOG" --attempts 3 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ "$(ncalls)" -eq 3 ]; then
  ok "10.4 a 5xx still retries 3 times and stays UNKNOWN (exit 2) — the split did not swallow the transport case it was carved out of"
else bad "10.4 expected exit 2 after 3 attempts for a 502; rc=$rc calls=$(ncalls)"; fi

world t3b
# GitHub answers 403 for RATE LIMITING too, and that one clears on its own.
# Classifying it as permanent would red main every 30 minutes on a busy
# afternoon — the fatigue this epic refuses. It must stay in the retry lane.
printf 'gh: HTTP 403: API rate limit exceeded for user ID 4242.\n' > "$STUB/protection.err"
rm -f "$STUB/protection.json"
out="$(bash "$WATCH" --spec "$SPEC" --log "$BG_LOG" --attempts 3 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ "$(ncalls)" -eq 3 ]; then
  ok "10.4b a 403 RATE LIMIT is NOT a configuration fault — 3 attempts then UNKNOWN (exit 2), because it clears on its own"
else bad "10.4b a rate-limit 403 was misclassified as permanent; rc=$rc calls=$(ncalls): $out"; fi

world t4
printf 'gh: HTTP 401: Bad credentials\n' > "$STUB/protection.err"
rm -f "$STUB/protection.json"
sed 's@^is_config_fault() { # body@is_config_fault() { return 1; } # disarmed\nis_config_fault_orig() {@' "$WATCH" > "$MUT"
out="$(bash "$MUT" --spec "$SPEC" --log "$BG_LOG" --attempts 3 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q "::warning" <<<"$out"; then
  ok "10.5 disarm the fault classifier ⇒ the SAME 401 collapses back to UNKNOWN (exit 2) with only a ::warning, which the workflow maps to exit 0 and a SUCCESSFUL run. That is main's behaviour today, and the classifier is what removes it."
else bad "10.5 the mutant did not reproduce today's blind state (rc $rc): $out"; fi

if grep -q '3) echo "::error::CONFIGURATION FAULT' "$WF"; then
  ok "10.6 the workflow maps exit 3 to ::error + exit 1 — the RUN fails, and the run conclusion is what notifications read"
else bad "10.6 breakglass-watch.yml does not red on exit 3"; fi
if awk '/rc" in$/{p=1} p && /^ *2\)/ && /exit 0/{found=1} END{exit !found}' "$WF"; then
  ok "10.7 …while a transport UNKNOWN (2) still exits 0, so a GitHub blip does not train the fleet to dismiss the check"
else bad "10.7 the rc=2 branch no longer exits 0"; fi

# ═══ 11. the stale-checkout guard ════════════════════════════════════════════
# The 2026-07-31 incident: `required-checks-apply.sh --disable --confirm` run
# from the primary checkout, 131 commits behind origin/main and therefore
# PRE-b4ba2bdb1a (#6928). Protection was down ~74 seconds; the log gained zero
# rows; the offline authority — the leg trusted because it needs no API — saw
# nothing. Everything below is run from trees deliberately built stale.
section "11. a checkout that predates the record-first apply.sh cannot mutate protection"

RECORD_FIRST="b4ba2bdb1a8548fb6a3e5a13a4dea718c1cb4721"

# A repo-SHAPED tree carrying the real breakglass.sh and a RECONSTRUCTION of the
# pre-#6928 --disable block: one --confirm check, an echo, a bare DELETE. The
# reconstruction is byte-asserted to lack both markers below, so this case
# cannot pass for the wrong reason.
STALE="$TMP/stale-content"; mkdir -p "$STALE/scripts"
cp "$GLASS" "$STALE/scripts/breakglass.sh"
cat > "$STALE/scripts/required-checks-apply.sh" <<'PRE6928'
#!/usr/bin/env bash
# required-checks-apply.sh — the shape that shipped before b4ba2bdb1a.
set -euo pipefail
main() {
  if [ "$DISABLE" -eq 1 ]; then
    [ "$CONFIRM" -eq 1 ] || fail "--disable needs --confirm; disabling protection is never implicit"
    echo "BREAK-GLASS: removing protection from $repo/$branch as $(gh api user --jq .login 2>/dev/null || echo UNKNOWN)"
    gh api -X DELETE "repos/$repo/branches/$branch/protection" >/dev/null || fail "could not remove protection"
    return 0
  fi
}
main "$@"
PRE6928
if ! grep -q 'exec bash "$REPO_ROOT/scripts/breakglass.sh"' "$STALE/scripts/required-checks-apply.sh" \
   && ! grep -q -- '--disable needs --reason' "$STALE/scripts/required-checks-apply.sh"; then
  ok "11.0 SETUP: the stale tree's apply.sh carries neither the delegation nor the --reason refusal — it is genuinely the pre-#6928 shape"
else bad "11.0 SETUP: the 'stale' reconstruction already carries a record-first marker; every case below would be vacuous"; fi

stale_glass() { bash "$STALE/scripts/breakglass.sh" --spec "$SPEC" --log "$BG_LOG" "$@"; }

world s1
out="$(stale_glass --open --reason "guerrilla is 500ing" --task cch-w11 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(ncalls)" -eq 0 ]; then
  ok "11.1 --open from a pre-#6928 tree REFUSES (exit $rc) and made ZERO API calls — the guard runs before the actor read, the pre-state read and the DELETE"
else bad "11.1 a stale tree opened the glass; rc=$rc calls=$(calls)"; fi
if grep -q "$RECORD_FIRST" <<<"$out"; then
  ok "11.2 …and the refusal NAMES the commit ($RECORD_FIRST), not 'your checkout is old'"
else bad "11.2 the refusal does not name the record-first commit: $out"; fi
if grep -q "worktree add" <<<"$out" && grep -q "origin/main" <<<"$out"; then
  ok "11.3 …and states the remedy verbatim: cut a worktree from origin/main and run it from there"
else bad "11.3 the refusal does not state the worktree remedy: $out"; fi

world s2
out="$(stale_glass --close --reason "unstuck" --task cch-w11 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(ncalls)" -eq 0 ] && grep -q "$RECORD_FIRST" <<<"$out"; then
  ok "11.4 --close is guarded TOO — and it is the GUARD that refused, not the empty log: the refusal names $RECORD_FIRST (exit $rc, zero calls). A 131-commit-stale .github/required-checks.json would restore an outdated protection object and then record it as 'closed'."
else bad "11.4 a stale tree's --close was not stopped BY THE GUARD; rc=$rc calls=$(calls): $out"; fi

world s3
out="$(stale_glass --status 2>&1)"; rc=$?
if grep -q "LOG: no open break-glass records" <<<"$out"; then
  ok "11.5 --status is NOT guarded — the read-only diagnostic still works from a stale tree, because refusing to LOOK during an incident helps nobody"
else bad "11.5 --status was broken by the guard (rc $rc): $out"; fi

world s4
sed 's@^  require_record_first_checkout$@  :@' "$STALE/scripts/breakglass.sh" > "$STALE/scripts/mutant.sh"
grep -q '^  require_record_first_checkout$' "$STALE/scripts/breakglass.sh" \
  || bad "11.6 SETUP: the guard call site changed shape — this mutant is vacuous"
out="$(bash "$STALE/scripts/mutant.sh" --spec "$SPEC" --log "$BG_LOG" --open --reason x --task t 2>&1)"; rc=$?
if grep -q "DELETE" <<<"$(calls)"; then
  ok "11.6 disarm the guard ⇒ the SAME stale tree opens the glass and DELETEs. That is main's behaviour on 2026-07-31, and the guard is what removes it."
else bad "11.6 the mutant did not reproduce the stale open (rc $rc); 11.1 proves nothing: $(calls)"; fi

# ── the ANCESTRY leg, both ways, without needing the real object ─────────────
# A depth-1 CI clone does not carry the 2026-07-29 commit, so the leg is proven
# on a synthetic history with the pin RE-POINTED by sed: same code path, a SHA
# whose ancestry is known by construction. Hermetic at any clone depth.
ANC="$TMP/anc"
mkdir -p "$ANC/scripts"
git -C "$ANC" init -q 2>/dev/null
git -C "$ANC" config user.email t@t; git -C "$ANC" config user.name t
echo one > "$ANC/a"; git -C "$ANC" add a; git -C "$ANC" commit -qm one
SHA_OLD="$(git -C "$ANC" rev-parse HEAD)"
echo two > "$ANC/b"; git -C "$ANC" add b; git -C "$ANC" commit -qm two
SHA_NEW="$(git -C "$ANC" rev-parse HEAD)"
git -C "$ANC" checkout -q "$SHA_OLD"        # HEAD is now BEHIND SHA_NEW
cp "$APPLY" "$ANC/scripts/required-checks-apply.sh"   # content leg would PASS

world a1
sed "s@^RECORD_FIRST_COMMIT=.*@RECORD_FIRST_COMMIT=\"$SHA_NEW\"@" "$GLASS" > "$ANC/scripts/breakglass.sh"
grep -q "^RECORD_FIRST_COMMIT=\"$SHA_NEW\"$" "$ANC/scripts/breakglass.sh" \
  || bad "11.7 SETUP: the pin did not re-point — the ancestry proof is vacuous"
out="$(bash "$ANC/scripts/breakglass.sh" --spec "$SPEC" --log "$BG_LOG" --open --reason x --task t 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "does not contain $SHA_NEW" <<<"$out" && [ "$(ncalls)" -eq 0 ]; then
  ok "11.7 ANCESTRY leg: HEAD behind the pinned commit REFUSES (exit $rc, zero calls) even though the tree's apply.sh is the CURRENT record-first one — the two legs are independent"
else bad "11.7 the ancestry leg did not fire; rc=$rc calls=$(calls): $out"; fi

world a2
sed "s@^RECORD_FIRST_COMMIT=.*@RECORD_FIRST_COMMIT=\"$SHA_OLD\"@" "$GLASS" > "$ANC/scripts/breakglass.sh"
out="$(bash "$ANC/scripts/breakglass.sh" --spec "$SPEC" --log "$BG_LOG" --open --reason x --task t 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q "DELETE" <<<"$(calls)"; then
  ok "11.8 …and the SAME tree with the pin re-pointed at a commit HEAD DOES contain is ACCEPTED and opens. The leg discriminates; it does not simply always refuse."
else bad "11.8 the ancestry leg refused a tree that contains the pin (rc $rc): $out"; fi

# ── this checkout, the positive control ─────────────────────────────────────
world p1
out="$(glass --open --reason "the control" --task t --dry-run 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q "DRY RUN" <<<"$out"; then
  ok "11.9 the guard PASSES from this checkout (exit $rc) — it is a staleness tripwire, not a blanket refusal"
else bad "11.9 the guard refused the repo it ships in (rc $rc): $out"; fi

# ── the incident is on the record ───────────────────────────────────────────
if grep -q "BG-20260731-RETRO" "$DOC" && grep -q -- "- closes: BG-20260731-RETRO" "$DOC"; then
  ok "11.10 the 2026-07-31 glass is a RETROSPECTIVE pair in $DOC — an open row AND the close that answers it, so the committed-log authority stops reading that outage as 'never happened' without reding main forever"
else bad "11.10 the 2026-07-31 incident is still absent from the records section of $DOC"; fi
if [ -z "$(open_glasses_in_doc)" ]; then
  ok "11.11 …and the real log carries NO standing open record, so breakglass-watch.sh stays green on main"
else bad "11.11 the retrospective row left an OPEN glass standing in $DOC: $(open_glasses_in_doc)"; fi
if grep -q "hand-written" "$DOC" && grep -q "131 commits behind" "$DOC"; then
  ok "11.12 …and the row says out loud that it was hand-written and why the script could not have written it (the tree predated breakglass.sh)"
else bad "11.12 the retrospective row does not disclose its provenance"; fi

echo
echo "── tally ──"
echo "  pass $PASS   fail $FAIL"
[ "$FAIL" -eq 0 ] || { echo "BREAK-GLASS HARNESS FAILED" >&2; exit 1; }
echo "BREAK-GLASS HARNESS OK — every refusal disarmed and watched accepting, every ordering claim snapshotted at the API call."
