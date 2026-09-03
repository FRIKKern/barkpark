#!/usr/bin/env bash
# main-red-breaker.test.sh — hermetic harness for scripts/main-red-breaker.sh.
# Main's jobs come from a fixture file; a stub curl on PATH proves no network
# call is made when the fixture is present, and drives the unreadable arm.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="${MAIN_RED_BREAKER_SUBJECT:-$ROOT/scripts/main-red-breaker.sh}"  # override = run these arms against another copy (mutation proof)
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

run() { # $1 outcomes, $2 event, $3 jobs fixture (or ""), $4 OUR raw capture file (or ""), $5 MAIN raw job log (or "")
  ( export PATH="$TMP/bin:$PATH" STEP_OUTCOMES="$1" STEP_NAMES="$NAMES" JOB_NAME="Doc budgets + anchors" WORKFLOW_FILE="doc-gates.yml" GITHUB_EVENT_NAME="$2" GITHUB_REPOSITORY="o/r" GITHUB_TOKEN="t" GITHUB_STEP_SUMMARY="$TMP/summary.md"
    [ -n "$3" ] && export MAIN_RED_BREAKER_FIXTURE="$3"
    [ -n "${4:-}" ] && export BREAKER_ERROR_LOG="$4"
    [ -n "${5:-}" ] && export MAIN_RED_BREAKER_LOG_FIXTURE="$5"
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
# ── 11-14. THE FAILURE SIGNATURE (task-cf774c315a1deca0) ────────────────────
# Step name alone waved a fresh defect through on 2026-09-03: PR #15784 tripped
# required-checks-verify.sh's advisory-prose clause on a file it had just
# edited, while main was red at the SAME step from a DIFFERENT file (#15650).
# The `FAIL:` header was byte-identical; only the indented file:line differed.
# These fixtures are RAW runner log lines — timestamps, annotations and all —
# because the normaliser, not the caller, is the thing under test.
main_log_15650="$TMP/main-15650.log"; cat > "$main_log_15650" <<'L'
2026-09-03T00:11:39.1002100Z ##[group]Run bash "$GITHUB_WORKSPACE/scripts/required-checks-verify.sh"
2026-09-03T00:11:39.1003011Z ##[endgroup]
2026-09-03T00:11:52.4410099Z   ok     the committed spec parses
2026-09-03T00:11:52.4410599Z FAIL: a workflow describes a REQUIRED context as advisory / non-blocking.
2026-09-03T00:11:52.4411203Z       The committed spec (docs/ci/required-checks.json) says these contexts BLOCK the merge.
2026-09-03T00:11:52.4412508Z       .github/workflows/compose-smoke.yml:64  claims "<a redacted context>" is not blocking
2026-09-03T00:11:52.4413900Z         … the sidecar sentence #15650 added …
2026-09-03T00:11:53.0011000Z ##[error]Process completed with exit code 1.
L
# What PR #15784's own gate step wrote while it was failing. Same step, same
# script, same header line — a DIFFERENT file. This must NOT inherit.
our_15784="$TMP/our-15784.txt"; cat > "$our_15784" <<'L'
2026-09-03T09:52:11.7710050Z FAIL: a workflow describes a REQUIRED context as advisory / non-blocking.
2026-09-03T09:52:11.7711422Z       The committed spec (docs/ci/required-checks.json) says these contexts BLOCK the merge.
2026-09-03T09:52:11.7712900Z       .github/workflows/architecture.yml:111  claims "<a redacted context>" is not blocking
2026-09-03T09:52:11.7714100Z         … the comment #15784 added …
L
# A genuinely inherited red: the SAME defect in the SAME file, seen on a later
# run — different clock, and the line has drifted 64 -> 66. Must still inherit.
our_inherited="$TMP/our-inherited.txt"; cat > "$our_inherited" <<'L'
2026-09-03T10:41:02.9990001Z FAIL: a workflow describes a REQUIRED context as advisory / non-blocking.
2026-09-03T10:41:02.9991002Z       The committed spec (docs/ci/required-checks.json) says these contexts BLOCK the merge.
2026-09-03T10:41:02.9992003Z       .github/workflows/compose-smoke.yml:66  claims "<a redacted context>" is not blocking
2026-09-03T10:41:02.9993004Z         … the sidecar sentence #15650 added …
L
# 11. THE 2026-09-03 REPLAY: same step, different signature -> the PR's OWN red,
#     with BOTH signatures printed so the reader sees what changed.
out="$(run "$out_s2" pull_request "$main_red_s2" "$our_15784" "$main_log_15650")"
has "$out" "NOT with the same failure signature" "11) same step + different signature => the PR's own red"
has "$out" "RC=1" "11) rc 1"
has "$out" "architecture.yml:#" "11) prints THIS PR's signature (normalised file:line)"
has "$out" "compose-smoke.yml:#" "11) prints MAIN's signature too"
case "$out" in *INHERITED-FROM-MAIN*) bad "11) still claimed INHERITED" ;; *) ok "11) does not claim INHERITED" ;; esac
# 12. same step, byte-identical raw lines -> inherited.
out="$(run "$out_s2" pull_request "$main_red_s2" "$main_log_15650" "$main_log_15650")"
has "$out" "INHERITED-FROM-MAIN" "12) same step + same signature => inherited"
has "$out" "Signature matched too" "12) the notice says the signature was checked, not assumed"
has "$out" "RC=0" "12) rc 0"
# 13. same defect, new clock and the line drifted 64 -> 66 -> STILL inherited.
#     Digits are normalised away on purpose: line drift must not manufacture a
#     fresh red, which would be this fix eating the breaker it is sharpening.
out="$(run "$out_s2" pull_request "$main_red_s2" "$our_inherited" "$main_log_15650")"
has "$out" "INHERITED-FROM-MAIN" "13) shifted file:line + new timestamp still inherits"
has "$out" "RC=0" "13) rc 0"
# 14. no gate step captured anything -> v1 step-name verdict, but SAID OUT LOUD.
#     Failing closed here would switch 631 known-inherited reds back on at once.
out="$(run "$out_s2" pull_request "$main_red_s2" "$TMP/absent-capture.txt" "$main_log_15650")"
has "$out" "INHERITED-FROM-MAIN" "14) no capture file => v1 behaviour preserved"
has "$out" "SIGNATURE-UNVERIFIED" "14) and the notice admits the signature was not checked"
has "$out" "RC=0" "14) rc 0"

# ── 15-16. THE CAPTURE HALF (task-2dbe8808f2a6f7b5) ─────────────────────────
# Arms 11-14 prove the signature clause DECIDES correctly once it has this PR's
# error block. Arm 14 is why these two exist: for the whole of PR #15842 NO gate
# step wrote the capture, so every LIVE verdict took arm 14's
# SIGNATURE-UNVERIFIED path and behaved exactly like the step-name-only v1 the
# 2026-09-03 miss came from. A shipped-inert discriminator is invisible to arms
# 11-14 — they hand it the file. So arm 15 derives the gate steps from the
# WORKFLOW TREE and asserts each one arms scripts/breaker-capture.sh.
#
# Derived, not listed: a hardcoded 9 in arm 10 reddened main when compose-smoke's
# two arm jobs became one. A gate step is a step carrying the breaker's own
# continue-on-error marker inside a workflow that has a Decide step, so a step
# that becomes a gate step tomorrow is counted tomorrow with no edit here.
gate_capture_audit() { # $1 = workflows dir -> "OK <n>" (rc 0) or "<m> of <n> … UNWIRED" (rc 1)
  python3 - "$1" <<'AUDIT'
import os, re, sys
MARK = "main-red breaker: the Decide step below owns the verdict"
ARM  = "scripts/breaker-capture.sh"
d = sys.argv[1]
gates = missing = 0
for fn in sorted(os.listdir(d)):
    if not fn.endswith((".yml", ".yaml")):
        continue
    lines = open(os.path.join(d, fn), errors="replace").read().split("\n")
    if not any("main-red-breaker.sh" in l and "run:" in l for l in lines):
        continue  # not one of the breaker workflows
    for i, l in enumerate(lines):
        if MARK not in l:
            continue
        gates += 1
        j = i
        while j < len(lines) and not re.match(r"(\s+)run:", lines[j]):
            j += 1
        if j >= len(lines):
            print("MISSING %s:%d - gate step has no run: block" % (fn, i + 1)); missing += 1; continue
        ind = len(re.match(r"(\s+)run:", lines[j]).group(1))
        body, k = [lines[j]], j + 1
        while k < len(lines) and (not lines[k].strip() or len(lines[k]) - len(lines[k].lstrip()) > ind):
            body.append(lines[k]); k += 1
        if not any(ARM in b for b in body):
            name = next((lines[x].split("- name:")[1].strip() for x in range(i, max(i - 6, -1), -1) if "- name:" in lines[x]), "?")
            print("MISSING %s:%d - gate step %r does not arm %s" % (fn, j + 1, name, ARM)); missing += 1
print("OK %d gate step(s) arm the capture" % gates if not missing else "%d of %d gate step(s) UNWIRED" % (missing, gates))
sys.exit(1 if missing or gates == 0 else 0)
AUDIT
}
out="$(gate_capture_audit "$ROOT/.github/workflows" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "15) every gate step of every breaker job arms the capture — $out"; else bad "15) unwired gate step(s): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"; fi
# 15b. MUTATION: strip ONE step's capture in a COPY of the tree. The audit must
#      red and name it — a derivation that cannot fail is not a check.
mut="$TMP/wf-mut"; rm -rf "$mut"; mkdir -p "$mut"; cp "$ROOT"/.github/workflows/*.yml "$mut/" 2>/dev/null
victim="$(grep -ln 'main-red breaker: the Decide step below owns the verdict' "$mut"/*.yml 2>/dev/null | head -1)"
if [ -n "$victim" ] && grep -q 'scripts/breaker-capture.sh' "$victim"; then
  python3 - "$victim" <<'MUTATE'
import sys
p = sys.argv[1]; lines = open(p).read().split("\n")
for i, l in enumerate(lines):
    if "scripts/breaker-capture.sh" in l and "exec bash" in l:
        del lines[i]; break
open(p, "w").write("\n".join(lines))
MUTATE
  mout="$(gate_capture_audit "$mut" 2>&1)"; mrc=$?
  if [ "$mrc" -ne 0 ]; then ok "15b) MUTATION: removing one gate step's capture reds the audit"; else bad "15b) MUTATION SURVIVED: audit green with a capture removed — $mout"; fi
  has "$mout" "UNWIRED" "15b) and it names how many"
else
  bad "15b) could not build the mutation (no wired gate step found in $victim)"
fi
# 16. THE EXIT-CODE INVARIANT. A capture wrapper that swallows a red is worse
#     than no capture, so breaker-capture.sh re-raises the step's status
#     verbatim, and appends ONLY when the step failed: a GREEN tripwire
#     self-test that prints the word FAIL would otherwise poison the signature
#     set and turn a genuinely inherited red into the author's own.
CAPSH="$ROOT/scripts/breaker-capture.sh"
if [ -f "$CAPSH" ]; then
  cap="$TMP/cap.txt"; : > "$cap"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "FAIL: planted red at docs/x.md:41"' 'exit 3' > "$TMP/red-step.sh"
  o="$( (BREAKER_ERROR_LOG="$cap" bash "$CAPSH" "$TMP/red-step.sh" 2>&1; echo "RC=$?") )"
  has "$o" "RC=3" "16) a failing step's exit code passes through UNCHANGED (3, not 0 and not 1)"
  has "$o" "FAIL: planted red" "16) the step's own output still reaches the job log"
  grep -q 'FAIL: planted red at docs/x.md:41' "$cap" && ok "16) the failing step's error block landed in the capture" || bad "16) capture empty after a red"
  : > "$cap"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "tripwire OK — FAIL was never planted"' 'exit 0' > "$TMP/green-step.sh"
  o="$( (BREAKER_ERROR_LOG="$cap" bash "$CAPSH" "$TMP/green-step.sh" 2>&1; echo "RC=$?") )"
  has "$o" "RC=0" "16) a passing step still exits 0"
  [ ! -s "$cap" ] && ok "16) a PASSING step writes nothing (green output cannot poison the signature)" || bad "16) a passing step polluted the capture: $(cat "$cap")"
  : > "$cap"; printf '%s\n' '#!/usr/bin/env bash' 'echo "armed=${BREAKER_CAPTURE_ARMED:-unset}"' > "$TMP/armed-step.sh"
  o="$(BREAKER_ERROR_LOG="$cap" bash "$CAPSH" "$TMP/armed-step.sh" 2>&1)"
  has "$o" "armed=1" "16) the child sees BREAKER_CAPTURE_ARMED, so the workflow guard cannot recurse"
else
  bad "16) scripts/breaker-capture.sh is missing"
fi


# ── 17. MAIN'S SIDE, AS THE API ACTUALLY RENDERS IT (task-2dbe8808f2a6f7b5) ──
# Arms 2-5 and 11-14 feed main's jobs JSON with gate steps marked
# `"conclusion": "failure"`. A real runner NEVER writes that: every gate step
# carries `continue-on-error: true`, and such a step reports conclusion
# "success" even when it failed — only its `outcome` is "failure", and `outcome`
# is not in the jobs API. MEASURED on run 33788784458 job 100759983487 ('Doc
# budgets + anchors'): 33 gate steps all `conclusion: success`, one `failure`,
# the Decide step. So on every real run the step-name clause found a step "main
# does not fail on" and exited one clause BEFORE the signature test — PR
# #15854's own doc-gates job 100761669105 printed exactly that while main's log
# said, in the breaker's own words, that main failed on that same step.
# This fixture is main's shape as it really is.
main_real="$TMP/main-real.json"; cat > "$main_real" <<'J'
{"jobs":[{"id":100759983487,"name":"Doc budgets + anchors","conclusion":"failure","steps":[{"name":"Doc byte budgets (fails this job)","conclusion":"success"},{"name":"Code-comment citation guard (fails this job)","conclusion":"success"},{"name":"Tenant fail-open read baseline gate (fails this job)","conclusion":"success"},{"name":"Decide (main-red breaker — inherited reds are neutral, own reds fail)","conclusion":"failure"}]}]}
J
# Main's job log — its Decide step PRINTS the gate step names the API withholds.
main_log_real="$TMP/main-real.log"; cat > "$main_log_real" <<'L'
2026-09-03T18:14:43.4410599Z FAIL: lineref drift
2026-09-03T18:14:43.4411203Z   ✗ NOVEL api/lib/barkpark/content/query.ex:661
2026-09-03T18:14:43.8939295Z main-red-breaker: FAIL — 'Doc budgets + anchors' failed on: Code-comment citation guard (fails this job). This is not a pull_request run, so the red is main's state and stands.
2026-09-03T18:14:43.8955306Z ##[error]Process completed with exit code 1.
L
our_same="$TMP/our-same.txt"; cat > "$our_same" <<'L'
FAIL: lineref drift
  ✗ NOVEL api/lib/barkpark/content/query.ex:663
L
our_diff="$TMP/our-diff.txt"; cat > "$our_diff" <<'L'
FAIL: lineref drift
  ✗ NOVEL web/app/page.tsx:12
L
# 17a. main red on the same step, recovered from its LOG, and the signature
#      matches (the line drifted 661 -> 663) -> inherited. This is the verdict
#      the breaker could not reach on any real run before.
out="$(run "$out_s2" pull_request "$main_real" "$our_same" "$main_log_real")"
has "$out" "INHERITED-FROM-MAIN" "17a) main's gate step read from its own Decide line => inherited"
has "$out" "Signature matched too" "17a) and only because the signature agreed"
has "$out" "RC=0" "17a) rc 0"
# 17b. same step, DIFFERENT defect -> the PR's own red (the 2026-09-03 shape,
#      now on main's real API shape rather than a hand-marked fixture).
out="$(run "$out_s2" pull_request "$main_real" "$our_diff" "$main_log_real")"
has "$out" "NOT with the same failure signature" "17b) a different defect in the same step is still the PR's own"
has "$out" "RC=1" "17b) rc 1"
# 17c. THE FAIL-CLOSED CLAUSE. A step name recovered only from main's log, with
#      NO signature to check, must NOT inherit: turning the step-name clause on
#      by itself would neutralise every known-inherited red in one commit on
#      step name alone — precisely what #15842's SIGNATURE-UNVERIFIED fallback
#      was chosen to avoid. The capture wiring is what unlocks inheritance.
out="$(run "$out_s2" pull_request "$main_real" "$TMP/absent-capture.txt" "$main_log_real")"
has "$out" "ONLY per its own Decide line" "17c) a log-derived match with no signature does NOT inherit"
has "$out" "SIGNATURE-UNVERIFIED" "17c) and says which half was missing"
has "$out" "RC=1" "17c) rc 1"
case "$out" in *INHERITED-FROM-MAIN*) bad "17c) waved a red through on step name alone" ;; *) ok "17c) never claims INHERITED without a signature" ;; esac
# 17d. the API path is untouched: when main's JSON DOES mark the gate step
#      failed (arms 2/12/13/14's shape), an unverified signature still inherits.
out="$(run "$out_s2" pull_request "$main_red_s2" "$TMP/absent-capture.txt" "$main_log_15650")"
has "$out" "INHERITED-FROM-MAIN" "17d) the pre-existing API path keeps v1's fallback"
has "$out" "RC=0" "17d) rc 0"

echo; echo "main-red-breaker.test.sh: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
