#!/usr/bin/env bash
# main-gate-watch.test.sh — the both-ways proofs for the main-tip watch.
#
# Nothing here asserts "the script ran". Every verdict is proven against
# RECORDED fixtures from four real shas, and the two ways it could lose are
# proven separately:
#
#   * it must SCREAM on a RED tip                    (0e9246447, Cloud gate = failure)
#   * it must SCREAM on a tip with NO verdict at all (a5260f609, cancelled: three
#     check runs total, none of them a required context) — the case a watch
#     phrased as "find a failing required row" reports GREEN on
#   * it must PASS on two independent known-green shas (f4abf4369, 0239dd4ee)
#   * WAITING must be NEITHER                        (synthetic: status != completed)
#
# The exclusion is proven by MUTATION rather than by reading the source: the
# script is copied with EXCLUDED_CONTEXTS blanked, and the known-green sha is
# watched turning RED on the PR-scoped context. That is what makes the exclusion
# load-bearing rather than decorative.
#
# FULLY OFFLINE. `gh` is replaced by a stub that fails loudly, so any accidental
# network path in the script under test shows up as a failing case rather than
# as a hidden dependency on GitHub being up.
#
#   sh scripts/main-gate-watch.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WATCH="$REPO_ROOT/scripts/main-gate-watch.sh"
WF="$REPO_ROOT/.github/workflows/main-gate-watch.yml"
SPEC="$REPO_ROOT/.github/required-checks.json"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*" >&2; }
section() { echo; echo "── $* ──"; }

# ═══ no network, ever ════════════════════════════════════════════════════════
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh: this test is offline and must never call the network (args: $*)" >&2
exit 97
STUB
chmod +x "$BIN/gh"
PATH="$BIN:$PATH"; export PATH

# ═══ recorded fixtures ═══════════════════════════════════════════════════════
# Protection, recorded 2026-08-09 from repos/FRIKKern/barkpark/branches/main:
# four required contexts, one of which is PR-scoped.
FX="$TMP/fx"; mkdir -p "$FX"

cat > "$FX/protection.json" <<'JSON'
{
  "required_status_checks": {
    "strict": false,
    "checks": [
      {"app_id": 15368, "context": "Elixir gate"},
      {"app_id": 15368, "context": "PR references an active task"},
      {"app_id": 15368, "context": "Cloud gate"},
      {"app_id": 15368, "context": "Console gate"}
    ]
  },
  "enforce_admins": {"enabled": true}
}
JSON

# f4abf4369 — known-green. Note what is NOT here: "PR references an active
# task" never rendered post-merge. That absence is why the exclusion exists.
cat > "$FX/f4abf4369.json" <<'JSON'
{"check_runs": [
  {"name": "Elixir gate",  "status": "completed", "conclusion": "success"},
  {"name": "Cloud gate",   "status": "completed", "conclusion": "success"},
  {"name": "Console gate", "status": "completed", "conclusion": "success"},
  {"name": "Security gate","status": "completed", "conclusion": "success"},
  {"name": "Sobelow static analysis (regression gate, baseline .sobelow-skips) (27.0, 1.18.1)", "status": "completed", "conclusion": "failure"}
]}
JSON

# 0239dd4ee — second independent known-green sha.
cat > "$FX/0239dd4ee.json" <<'JSON'
{"check_runs": [
  {"name": "Elixir gate",  "status": "completed", "conclusion": "success"},
  {"name": "Cloud gate",   "status": "completed", "conclusion": "success"},
  {"name": "Console gate", "status": "completed", "conclusion": "success"}
]}
JSON

# 0e9246447 — main's tip at survey time. Cloud gate RED.
cat > "$FX/0e9246447.json" <<'JSON'
{"check_runs": [
  {"name": "Elixir gate",  "status": "completed", "conclusion": "success"},
  {"name": "Cloud gate",   "status": "completed", "conclusion": "failure"},
  {"name": "Console gate", "status": "completed", "conclusion": "success"}
]}
JSON

# a5260f609 — a `cancelled` main sha. THREE check runs in total, and not one of
# them is a required context. Recorded verbatim: this is the whole point.
cat > "$FX/a5260f609.json" <<'JSON'
{"check_runs": [
  {"name": "go vet + test",       "status": "completed", "conclusion": "success"},
  {"name": "Break-glass harness", "status": "completed", "conclusion": "skipped"},
  {"name": "Break-glass watch",   "status": "completed", "conclusion": "success"}
]}
JSON

# Synthetic: a fresh push to main, Cloud gate still running. Nobody could
# observe this live at probe time (no in-flight run existed), so it is TESTED
# rather than assumed — it is exactly the shape that gets a watch muted.
cat > "$FX/waiting.json" <<'JSON'
{"check_runs": [
  {"name": "Elixir gate",  "status": "completed",  "conclusion": "success"},
  {"name": "Cloud gate",   "status": "in_progress","conclusion": null},
  {"name": "Console gate", "status": "queued",     "conclusion": null}
]}
JSON

# Waiting AND red together: the scream must win.
cat > "$FX/waiting-and-red.json" <<'JSON'
{"check_runs": [
  {"name": "Elixir gate",  "status": "completed",  "conclusion": "failure"},
  {"name": "Cloud gate",   "status": "in_progress","conclusion": null},
  {"name": "Console gate", "status": "completed",  "conclusion": "success"}
]}
JSON

# A re-run: the same name twice, the LATEST row deciding.
cat > "$FX/rerun-green-last.json" <<'JSON'
{"check_runs": [
  {"name": "Cloud gate",   "status": "completed", "conclusion": "failure", "started_at": "2026-08-09T01:00:00Z", "id": 1},
  {"name": "Cloud gate",   "status": "completed", "conclusion": "success", "started_at": "2026-08-09T02:00:00Z", "id": 2},
  {"name": "Elixir gate",  "status": "completed", "conclusion": "success"},
  {"name": "Console gate", "status": "completed", "conclusion": "success"}
]}
JSON

cat > "$FX/rerun-red-last.json" <<'JSON'
{"check_runs": [
  {"name": "Cloud gate",   "status": "completed", "conclusion": "success", "started_at": "2026-08-09T01:00:00Z", "id": 1},
  {"name": "Cloud gate",   "status": "completed", "conclusion": "failure", "started_at": "2026-08-09T02:00:00Z", "id": 2},
  {"name": "Elixir gate",  "status": "completed", "conclusion": "success"},
  {"name": "Console gate", "status": "completed", "conclusion": "success"}
]}
JSON

# Protection carrying a context nobody classified.
cat > "$FX/protection-unclassified.json" <<'JSON'
{
  "required_status_checks": {
    "strict": false,
    "checks": [
      {"app_id": 15368, "context": "Elixir gate"},
      {"app_id": 15368, "context": "PR references an active task"},
      {"app_id": 15368, "context": "Cloud gate"},
      {"app_id": 15368, "context": "Console gate"},
      {"app_id": 15368, "context": "Brand new gate"}
    ]
  }
}
JSON

# A 403 body, as `gh` actually emits it.
cat > "$FX/protection-forbidden.json" <<'JSON'
gh: Resource not accessible by integration (HTTP 403)
JSON

OUT="$TMP/out.txt"
run_watch() { # sha, check-runs fixture, [protection fixture], [script]
  local sha="$1" runs="$2" prot="${3:-$FX/protection.json}" script="${4:-$WATCH}"
  bash "$script" --sha "$sha" --protection-file "$prot" --check-runs-file "$runs" \
    > "$OUT" 2>&1
  echo $?
}

# ═══ 1. the two known-green shas PASS ════════════════════════════════════════
section "1. PASS on the known-green shas"

rc="$(run_watch f4abf4369 "$FX/f4abf4369.json")"
if [ "$rc" = "0" ]; then ok "f4abf4369 -> PASS (exit 0)"; else bad "f4abf4369 -> expected exit 0, got $rc"; cat "$OUT" >&2; fi
grep -q "f4abf4369" "$OUT" && ok "f4abf4369 output names the sha" || bad "f4abf4369 output does not name the sha"
grep -q "skipped (named exclusion): PR references an active task" "$OUT" \
  && ok "f4abf4369 output names the exclusion it applied" \
  || bad "f4abf4369 output does not name the exclusion"

rc="$(run_watch 0239dd4ee "$FX/0239dd4ee.json")"
if [ "$rc" = "0" ]; then ok "0239dd4ee -> PASS (exit 0)"; else bad "0239dd4ee -> expected exit 0, got $rc"; cat "$OUT" >&2; fi
grep -q "0239dd4ee" "$OUT" && ok "0239dd4ee output names the sha" || bad "0239dd4ee output does not name the sha"

# ═══ 2. RED screams ══════════════════════════════════════════════════════════
section "2. FAIL/RED on 0e9246447 (Cloud gate = failure)"

rc="$(run_watch 0e9246447 "$FX/0e9246447.json")"
if [ "$rc" = "1" ]; then ok "0e9246447 -> FAIL/RED (exit 1)"; else bad "0e9246447 -> expected exit 1, got $rc"; cat "$OUT" >&2; fi
grep -q "RED      Cloud gate" "$OUT" && ok "0e9246447 names Cloud gate as the red row" || bad "0e9246447 does not name Cloud gate"
grep -q "conclusion=failure" "$OUT" && ok "0e9246447 reports the actual conclusion" || bad "0e9246447 does not report the conclusion"
grep -q "0e9246447" "$OUT" && ok "0e9246447 output names the sha" || bad "0e9246447 output does not name the sha"

# ═══ 3. THE PRESENCE ASSERTION — no verdict at all screams ═══════════════════
section "3. FAIL/MISSING x3 on the cancelled sha a5260f609"

rc="$(run_watch a5260f609 "$FX/a5260f609.json")"
if [ "$rc" = "1" ]; then ok "a5260f609 -> FAIL/MISSING (exit 1)"; else bad "a5260f609 -> expected exit 1, got $rc"; cat "$OUT" >&2; fi
n="$(grep -c "MISSING  " "$OUT")"
if [ "$n" = "3" ]; then ok "a5260f609 reports MISSING on all THREE watched contexts"; else bad "a5260f609 expected 3 MISSING rows, got $n"; cat "$OUT" >&2; fi
for c in "Cloud gate" "Console gate" "Elixir gate"; do
  grep -q "MISSING  $c" "$OUT" && ok "a5260f609 names $c as MISSING" || bad "a5260f609 does not name $c as MISSING"
done
# The mutation this whole design turns on: an absence-of-failure watch finds
# ZERO failing rows here and reports green.
if ! grep -q "RED      " "$OUT"; then
  ok "a5260f609 carries NO red row at all — an 'is any required row failing?' watch would report GREEN here"
else
  bad "a5260f609 unexpectedly produced a RED row; the fixture no longer proves the vacuous-green case"
fi
grep -q "a5260f609" "$OUT" && ok "a5260f609 output names the sha" || bad "a5260f609 output does not name the sha"

# ── 3b. THE EMPTY PAYLOAD — a tip nothing has registered on YET (cch-w60) ────
# The fixture this file never had. The deleted `push:` trigger evaluated main's
# tip ~19 seconds after a merge, when GitHub had created NO check-run rows on it
# at all — the payload really is `{"check_runs": []}`. The three required rows
# were created at +7m15s (Console), +9m52s (Cloud) and +25m27s (Elixir); 2 of 2
# production push runs failed on tip 026c5b1d78 while main was in fact green.
#
# WHAT THIS SECTION REPORTS, STATED PLAINLY SO NOBODY MISREADS IT: on an empty
# payload the script prints MISSING x3 and exits 1 — byte-identical to the
# a5260f609 case above, which is a tip that WAS judged and simply never produced
# a required row. The script's vocabulary does NOT distinguish "absent because
# no row has been created yet" from "absent because the commit was never
# judged". This section PINS that as the current behaviour; it does not endorse
# it as correct. A MISSING row is therefore not evidence that a commit was
# judged, and the fix for the trigger that made it fire on every merge is the
# deletion asserted in §11 below, not a grace constant.
section "3b. an EMPTY check-runs payload (a tip no workflow has registered on yet)"

cat > "$FX/empty-payload.json" <<'JSON'
{"check_runs": []}
JSON

if grep -q '"check_runs": \[\]' "$FX/empty-payload.json"; then
  ok "empty-payload fixture is a literal {\"check_runs\": []} — the shape a fresh merge tip really has"
else
  bad "empty-payload fixture is not a literal empty check_runs array"
fi

rc="$(run_watch 026c5b1d7 "$FX/empty-payload.json")"
if [ "$rc" = "1" ]; then
  ok "empty payload -> MISSING/scream (exit 1) — this is the CURRENT behaviour, pinned, not endorsed"
else
  bad "empty payload -> expected exit 1 (the documented current behaviour), got $rc"; cat "$OUT" >&2
fi
if [ "$rc" != "2" ]; then
  ok "empty payload is NOT WAITING — exit 2 is keyed on the .status of an EXISTING row, so no row means no wait"
else
  bad "empty payload reported WAITING; §3b's prose and the workflow comment in main-gate-watch.yml are now stale"
fi
n="$(grep -c "MISSING  " "$OUT")"
if [ "$n" = "3" ]; then
  ok "empty payload reports MISSING on all THREE watched contexts"
else
  bad "empty payload expected 3 MISSING rows, got $n"; cat "$OUT" >&2
fi
if ! grep -qE "^  ok       " "$OUT"; then
  ok "empty payload produces no green row at all"
else
  bad "empty payload produced a green row — a payload with zero rows cannot green anything"
fi
# The conflation, asserted rather than described: the empty-payload verdict is
# indistinguishable from the genuinely-never-judged verdict.
if grep -q "MAIN'S TIP DOES NOT CARRY A GREEN VERDICT" "$OUT"; then
  ok "empty payload is INDISTINGUISHABLE from the never-judged sha a5260f609 — same MISSING vocabulary, same exit 1"
else
  bad "empty payload no longer reaches the MISSING verdict; §3b's prose is stale"
fi

# ═══ 4. WAITING is neither a pass nor a scream ═══════════════════════════════
section "4. WAITING (keyed on .status, conclusion null)"

rc="$(run_watch deadbeef1 "$FX/waiting.json")"
if [ "$rc" = "2" ]; then ok "in-flight tip -> WAITING (exit 2)"; else bad "in-flight tip -> expected exit 2, got $rc"; cat "$OUT" >&2; fi
[ "$rc" != "0" ] && ok "WAITING is NOT a pass (exit != 0)" || bad "WAITING was treated as a pass"
[ "$rc" != "1" ] && ok "WAITING is NOT a scream (exit != 1)" || bad "WAITING was treated as a scream"
grep -q "WAITING  Cloud gate" "$OUT" && ok "WAITING names the in-flight context" || bad "WAITING does not name the in-flight context"
if ! grep -q "MISSING  Cloud gate" "$OUT"; then
  ok "an in-flight context is NOT misread as MISSING (the false-red every fresh push would produce)"
else
  bad "an in-flight context was misread as MISSING"
fi

rc="$(run_watch deadbeef2 "$FX/waiting-and-red.json")"
if [ "$rc" = "1" ]; then ok "waiting + red -> the scream wins (exit 1)"; else bad "waiting + red -> expected exit 1, got $rc"; cat "$OUT" >&2; fi

# ═══ 5. the exclusion is load-bearing, proven by MUTATION ════════════════════
section "5. mutation: blank the exclusion and the known-green sha turns RED"

sed 's/^EXCLUDED_CONTEXTS=.*/EXCLUDED_CONTEXTS=""/' "$WATCH" > "$TMP/no-exclusion.sh"
if grep -q 'EXCLUDED_CONTEXTS=""' "$TMP/no-exclusion.sh"; then
  ok "specimen built (EXCLUDED_CONTEXTS blanked)"
else
  bad "could not build the no-exclusion specimen — EXCLUDED_CONTEXTS is no longer a named constant on its own line"
fi
rc="$(run_watch f4abf4369 "$FX/f4abf4369.json" "$FX/protection.json" "$TMP/no-exclusion.sh")"
# Without the exclusion, "PR references an active task" is unclassified: the
# roster assertion catches it (exit 3) rather than letting it false-red as
# MISSING. Either way the specimen must NOT report green on the known-green sha.
if [ "$rc" != "0" ]; then
  ok "without the exclusion the KNOWN-GREEN sha stops being green (exit $rc) — the exclusion is load-bearing"
else
  bad "blanking the exclusion changed nothing; the exclusion is decorative"
fi

# ═══ 6. the roster assertion ═════════════════════════════════════════════════
section "6. an unclassified required context is a CONFIGURATION FAULT"

rc="$(run_watch f4abf4369 "$FX/f4abf4369.json" "$FX/protection-unclassified.json")"
if [ "$rc" = "3" ]; then ok "unclassified required context -> exit 3"; else bad "unclassified required context -> expected exit 3, got $rc"; cat "$OUT" >&2; fi
grep -q "Brand new gate" "$OUT" && ok "the fault names the unclassified context" || bad "the fault does not name the unclassified context"
grep -q "CONFIGURATION FAULT" "$OUT" && ok "the fault says CONFIGURATION FAULT" || bad "the fault is not labelled"

# ═══ 7. no authority is never green ══════════════════════════════════════════
section "7. unreadable / forbidden protection reds, even on a green sha"

rc="$(run_watch f4abf4369 "$FX/f4abf4369.json" "$FX/protection-forbidden.json")"
if [ "$rc" = "3" ]; then ok "403 on protection -> exit 3 even though the sha is green"; else bad "403 on protection -> expected exit 3, got $rc"; cat "$OUT" >&2; fi

echo '{"required_status_checks": null}' > "$FX/protection-empty.json"
rc="$(run_watch f4abf4369 "$FX/f4abf4369.json" "$FX/protection-empty.json")"
if [ "$rc" = "3" ]; then ok "protection with no required_status_checks -> exit 3, not an empty green"; else bad "empty protection -> expected exit 3, got $rc"; cat "$OUT" >&2; fi

# ═══ 8. the required set is read LIVE, not from the committed spec ═══════════
section "8. the watched set comes from protection, not .github/required-checks.json"

if grep -qE 'required_status_checks\.checks\[\]\.context' "$WATCH"; then
  ok "the required set is derived from the protection object"
else
  bad "the required set is not derived from the protection object"
fi
if grep -qE '\.github/required-checks\.json' "$WATCH" && ! grep -qE 'jq .* required_status_checks.*"\$SPEC"' "$WATCH"; then
  ok "the committed spec is used only for repo/branch identity, never for the watched contexts"
else
  bad "the committed spec appears to feed the watched contexts (it would go stale silently)"
fi

# ═══ 9. re-runs: the LATEST row decides ══════════════════════════════════════
section "9. a re-run's latest row decides the verdict"

rc="$(run_watch cafe0001 "$FX/rerun-green-last.json")"
if [ "$rc" = "0" ]; then ok "red-then-green re-run -> PASS"; else bad "red-then-green re-run -> expected exit 0, got $rc"; cat "$OUT" >&2; fi
rc="$(run_watch cafe0002 "$FX/rerun-red-last.json")"
if [ "$rc" = "1" ]; then ok "green-then-red re-run -> SCREAM"; else bad "green-then-red re-run -> expected exit 1, got $rc"; cat "$OUT" >&2; fi

# ── 9b. THE PAGINATED STREAM (added in review, cch-w59) ──────────────────────
# `gh api --paginate` on an OBJECT endpoint emits one JSON DOCUMENT PER PAGE,
# not one merged object. A dedup that groups per document lets an older re-run
# row on page 1 decide a context whose LATEST row is on page 2 — a permanent
# stale FALSE RED, which is exactly how a watch gets muted. The reader slurps
# the whole stream before grouping; these two fixtures are multi-document on
# purpose and would have failed the pre-review reader.
cat > "$FX/paged-rerun-green-last.json" <<'JSON'
{"check_runs": [
  {"name": "Elixir gate",  "status": "completed", "conclusion": "success", "started_at": "2026-08-09T01:00:00Z", "id": 1},
  {"name": "Cloud gate",   "status": "completed", "conclusion": "failure", "started_at": "2026-08-09T01:00:00Z", "id": 2}
]}
{"check_runs": [
  {"name": "Console gate", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T02:00:00Z", "id": 3},
  {"name": "Cloud gate",   "status": "completed", "conclusion": "success", "started_at": "2026-08-09T02:00:00Z", "id": 4}
]}
JSON

cat > "$FX/paged-rerun-red-last.json" <<'JSON'
{"check_runs": [
  {"name": "Elixir gate",  "status": "completed", "conclusion": "success", "started_at": "2026-08-09T01:00:00Z", "id": 1},
  {"name": "Cloud gate",   "status": "completed", "conclusion": "success", "started_at": "2026-08-09T01:00:00Z", "id": 2}
]}
{"check_runs": [
  {"name": "Console gate", "status": "completed", "conclusion": "success", "started_at": "2026-08-09T02:00:00Z", "id": 3},
  {"name": "Cloud gate",   "status": "completed", "conclusion": "failure", "started_at": "2026-08-09T02:00:00Z", "id": 4}
]}
JSON

rc="$(run_watch cafe0003 "$FX/paged-rerun-green-last.json")"
if [ "$rc" = "0" ]; then ok "PAGED red-then-green re-run (rows on two pages) -> PASS"; else bad "PAGED red-then-green -> expected exit 0, got $rc"; cat "$OUT" >&2; fi
rc="$(run_watch cafe0004 "$FX/paged-rerun-red-last.json")"
if [ "$rc" = "1" ]; then ok "PAGED green-then-red re-run (rows on two pages) -> SCREAM"; else bad "PAGED green-then-red -> expected exit 1, got $rc"; cat "$OUT" >&2; fi

# ═══ 10. it is offline ═══════════════════════════════════════════════════════
section "10. offline: the hermetic path makes no API call"

# The stub exits 97 and prints to stderr. If any case above had reached it, the
# exit codes would not have matched — but assert it directly too.
rc="$(run_watch f4abf4369 "$FX/f4abf4369.json")"
if ! grep -q "this test is offline" "$OUT"; then
  ok "no gh invocation on the hermetic path"
else
  bad "the script called gh despite --protection-file and --check-runs-file"
fi

# ═══ 11. the workflow can never enter the required set ═══════════════════════
section "11. workflow structure (the four breakglass-watch properties)"

[ -f "$WF" ] && ok "workflow exists: .github/workflows/main-gate-watch.yml" || bad "workflow missing"
grep -q "cron:" "$WF"                       && ok "schedule trigger"        || bad "no schedule trigger"
grep -q "workflow_dispatch:" "$WF"          && ok "workflow_dispatch"       || bad "no workflow_dispatch"

# THERE MUST BE NO push: TRIGGER (cch-w60, D721). It fired ~19s after a merge,
# reached the empty-payload case pinned in §3b, and red by construction: 2 of 2
# production push runs failed on tip 026c5b1d78 while main was in fact green.
# Comments are stripped first — this workflow's prose argues about push at
# length and a naive grep would red on its own explanation.
if sed 's/#.*//' "$WF" | grep -qE '^[[:space:]]*push:'; then
  bad "the workflow carries a push: trigger — it reds by construction on every merge (see 3b)"
else
  ok "no push: trigger at all — the merge-time false red cannot recur"
fi
# ...and prove that check can LOSE rather than trusting a grep that may simply
# never match anything.
sed 's/^  workflow_dispatch:/  push:\n    branches: [main]\n  workflow_dispatch:/' "$WF" > "$TMP/wf-push-readded.yml"
if sed 's/#.*//' "$TMP/wf-push-readded.yml" | grep -qE '^[[:space:]]*push:'; then
  ok "the no-push check catches a re-added push: trigger (it can lose)"
else
  bad "the no-push check did not catch a re-added push: trigger — it is vacuous"
fi

grep -q "if: github.event_name != 'pull_request'" "$WF" \
  && ok "watch job carries if: github.event_name != 'pull_request'" \
  || bad "watch job is missing the pull_request guard"

# The pull_request trigger must be paths-filtered — belt and braces with the if:.
if awk '/^  pull_request:/{f=1} f && /^    paths:/{print "yes"; exit}' "$WF" | grep -q yes; then
  ok "the pull_request trigger is paths-filtered"
else
  bad "the pull_request trigger is NOT paths-filtered"
fi

# Comments are stripped first: this file ARGUES about continue-on-error at
# length, and a naive grep would red on its own prose.
if sed 's/#.*//' "$WF" | grep -q "continue-on-error"; then
  bad "the workflow carries continue-on-error — it would launder the run conclusion to success"
else
  ok "no continue-on-error in any directive: the run conclusion IS the scream"
fi
# ...and prove that check can LOSE, rather than trusting a grep that may simply
# never match anything.
sed 's/^    runs-on: ubuntu-latest/    continue-on-error: true\n    runs-on: ubuntu-latest/' "$WF" > "$TMP/wf-laundered.yml"
if sed 's/#.*//' "$TMP/wf-laundered.yml" | grep -q "continue-on-error"; then
  ok "the continue-on-error check catches an injected specimen (it can lose)"
else
  bad "the continue-on-error check did not catch an injected specimen — it is vacuous"
fi

if grep -qE 'cancel-in-progress: true' "$WF"; then
  bad "cancel-in-progress is a literal true — a push to main would self-cancel the watch dark"
else
  ok "cancel-in-progress never self-cancels on main"
fi

# ═══ 12. the spec did not grow this workflow's names ═════════════════════════
section "12. the required-checks spec is unchanged by this slice"

if [ -f "$SPEC" ]; then
  if jq -e '[.protection.required_status_checks.checks[].context] | index("Main gate watch")' "$SPEC" >/dev/null 2>&1; then
    bad "'Main gate watch' entered the required set"
  else
    ok "'Main gate watch' is NOT in the required set"
  fi
  if jq -e '[.protection.required_status_checks.checks[].context] | index("Main gate watch harness")' "$SPEC" >/dev/null 2>&1; then
    bad "'Main gate watch harness' entered the required set"
  else
    ok "'Main gate watch harness' is NOT in the required set"
  fi
else
  bad "required-checks spec not found at $SPEC"
fi

# ═══ 13. the workflow is valid YAML ══════════════════════════════════════════
section "13. YAML parses"

if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
  if python3 -c "import yaml,sys; yaml.safe_load(open('$WF'))" >/dev/null 2>&1; then
    ok "main-gate-watch.yml parses as YAML"
  else
    bad "main-gate-watch.yml is not valid YAML"
  fi
else
  echo "  skip python3+pyyaml unavailable — YAML parse not checked here (CI parses it by running the workflow)"
fi

bash -n "$WATCH" && ok "main-gate-watch.sh passes bash -n" || bad "main-gate-watch.sh has a syntax error"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
