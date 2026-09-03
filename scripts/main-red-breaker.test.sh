#!/usr/bin/env bash
# main-red-breaker.test.sh — hermetic harness for scripts/main-red-breaker.sh.
# Main's jobs come from a fixture file; a stub curl on PATH proves no network
# call is made when the fixture is present, and drives the unreadable arm.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/scripts/main-red-breaker.sh"
TMP="$(mktemp -d -t main-red-breaker-test.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 — '$2' not in: $(printf '%s' "$1" | tr '\n' ' ' | cut -c1-240)" ;; esac; }
mkdir -p "$TMP/bin"; printf '#!/usr/bin/env bash\necho "curl called: $*" >> "%s/curl.log"; exit 7\n' "$TMP" > "$TMP/bin/curl"; chmod +x "$TMP/bin/curl"

NAMES='{"s1":"Doc byte budgets (fails this job)","s2":"Code-comment citation guard (fails this job)","s3":"Tenant fail-open read baseline gate (fails this job)"}'
out_all_green='{"s1":{"outcome":"success"},"s2":{"outcome":"success"},"s3":{"outcome":"success"}}'
out_s2='{"s1":{"outcome":"success"},"s2":{"outcome":"failure"},"s3":{"outcome":"success"}}'
out_s2_s3='{"s1":{"outcome":"success"},"s2":{"outcome":"failure"},"s3":{"outcome":"failure"}}'
main_red_s2="$TMP/main-red-s2.json"; cat > "$main_red_s2" <<'J'
{"jobs":[{"name":"Doc budgets + anchors","conclusion":"failure","steps":[{"name":"Doc byte budgets (fails this job)","conclusion":"success"},{"name":"Code-comment citation guard (fails this job)","conclusion":"failure"},{"name":"Tenant fail-open read baseline gate (fails this job)","conclusion":"success"}]}]}
J
main_green="$TMP/main-green.json"; echo '{"jobs":[{"name":"Doc budgets + anchors","conclusion":"success","steps":[{"name":"Code-comment citation guard (fails this job)","conclusion":"success"}]}]}' > "$main_green"
main_other_job="$TMP/main-other.json"; echo '{"jobs":[{"name":"Some other job","conclusion":"failure","steps":[{"name":"Code-comment citation guard (fails this job)","conclusion":"failure"}]}]}' > "$main_other_job"

run() { # $1 outcomes, $2 event, $3 fixture (or ""), extra env via $4
  ( export PATH="$TMP/bin:$PATH" STEP_OUTCOMES="$1" STEP_NAMES="$NAMES" JOB_NAME="Doc budgets + anchors" WORKFLOW_FILE="doc-gates.yml" GITHUB_EVENT_NAME="$2" GITHUB_REPOSITORY="o/r" GITHUB_TOKEN="t" GITHUB_STEP_SUMMARY="$TMP/summary.md"
    [ -n "$3" ] && export MAIN_RED_BREAKER_FIXTURE="$3"
    : > "$TMP/curl.log"; bash "$SUBJECT" 2>&1; echo "RC=$?" )
}

# 1. nothing failed -> exit 0, no API read
out="$(run "$out_all_green" pull_request "")"; has "$out" "nothing to decide" "1) all green: nothing to decide"; has "$out" "RC=0" "1) rc 0"; [ ! -s "$TMP/curl.log" ] && ok "1) no API call when nothing failed" || bad "1) API was called"
# 2. THE INHERITED PATH (mutation: fake a main red on the same step) -> exit 0 + notice
out="$(run "$out_s2" pull_request "$main_red_s2")"; has "$out" "INHERITED-FROM-MAIN" "2) same step red on main => inherited"; has "$out" "RC=0" "2) rc 0"; has "$out" "::notice" "2) a notice annotation is emitted"; grep -q 'Inherited from main' "$TMP/summary.md" && ok "2) step summary written" || bad "2) no step summary"
# 3. THE OWN-FAILURE PATH (mutation: fake main green) -> exit 1 naming our step
out="$(run "$out_s2" pull_request "$main_green")"; has "$out" "FAIL" "3) main green => the red is ours"; has "$out" "Code-comment citation guard" "3) names our failed step"; has "$out" "RC=1" "3) rc 1"
# 4. main red on the same step AND we fail an extra step -> exit 1 naming only the extra
out="$(run "$out_s2_s3" pull_request "$main_red_s2")"; has "$out" "failed on a step main does not: Tenant fail-open" "4) the extra step is ours"; has "$out" "RC=1" "4) rc 1"
# 5. main red on a different JOB -> not inherited
out="$(run "$out_s2" pull_request "$main_other_job")"; has "$out" "GREEN or absent" "5) a red on another job does not transfer"; has "$out" "RC=1" "5) rc 1"
# 6. not a pull_request (push to main) -> never inherited, even with main red
out="$(run "$out_s2" push "$main_red_s2")"; has "$out" "not a pull_request run" "6) on main the red stands"; has "$out" "RC=1" "6) rc 1"
# 7. main unreadable (no fixture, stub curl fails) -> exit 1, says so
out="$(run "$out_s2" pull_request "")"; has "$out" "Could not read main" "7) unreadable main is not inherited"; has "$out" "RC=1" "7) rc 1"; grep -q 'curl called' "$TMP/curl.log" && ok "7) the API was attempted" || bad "7) API not attempted"
# 8. malformed inputs -> exit 2, never 0
out="$( (export PATH="$TMP/bin:$PATH" STEP_OUTCOMES='not json' STEP_NAMES="$NAMES" JOB_NAME=j WORKFLOW_FILE=w.yml GITHUB_EVENT_NAME=pull_request; bash "$SUBJECT" 2>&1; echo "RC=$?") )"; has "$out" "CANNOT DECIDE" "8) unparsable outcomes cannot decide"; has "$out" "RC=2" "8) rc 2"
# 9. the subject never names a required context
for ctx in "Elixir gate" "Cloud gate" "Console gate" "PR references an active task"; do grep -qF "$ctx" "$SUBJECT" && bad "9) subject mentions required context '$ctx'" ; done; ok "9) subject names no required context"
# 10. every Decide step in the wired workflows calls the script by ABSOLUTE path.
#     Jobs with `defaults.run.working-directory: api` (sobelow, mix-audit) ran
#     `bash scripts/main-red-breaker.sh` from api/ and died with exit 127 on
#     main 0f6c9937 (2026-09-03 05:30Z) — a red the breaker itself caused.
rel="$(grep -lE '^\s+run: bash scripts/main-red-breaker\.sh' "$ROOT"/.github/workflows/*.yml 2>/dev/null || true)"
abs_n="$(grep -c 'GITHUB_WORKSPACE/scripts/main-red-breaker.sh' "$ROOT"/.github/workflows/*.yml 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"
# Expected = every `run:` line that invokes the script, however it is spelled;
# a hardcoded 9 reddened main when compose-smoke's two arm jobs became one.
all_n="$(grep -cE '^\s+run: bash .*main-red-breaker\.sh' "$ROOT"/.github/workflows/*.yml 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"
if [ -z "$rel" ] && [ "$all_n" -ge 1 ] && [ "$abs_n" = "$all_n" ]; then ok "10) all $abs_n Decide steps call the script via \$GITHUB_WORKSPACE (no relative invocation)"; else bad "10) relative invocation present in: $rel (absolute $abs_n of $all_n invocations)"; fi
echo; echo "main-red-breaker.test.sh: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
