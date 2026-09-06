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
# 5. main red on a different JOB -> not inherited, and NOT blamed on the author:
#    main's run holding no job of this name is indistinguishable from the name
#    having drifted (see arm 18a), so it is UNDETERMINED, never "yours".
out="$(run "$out_s2" pull_request "$main_other_job")"; has "$out" "OWNERSHIP-UNDETERMINED" "5) a red on another job does not transfer"; has "$out" "NO job named" "5) and says main's run has no job of this name"; has "$out" "RC=1" "5) rc 1"
case "$out" in *"the red is this PR's own"*) bad "5) blamed the author for a job it could not find" ;; *) ok "5) makes no ownership claim" ;; esac
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
gate_capture_audit() { # $1 = workflows dir -> "OK <n> … <j> breaker job(s)" (rc 0) or "<m> of <n> … UNWIRED" (rc 1)
  python3 - "$1" <<'AUDIT'
import os, re, sys
MARK = "main-red breaker: the Decide step below owns the verdict"
ARM  = "scripts/breaker-capture.sh"
DECIDE = "main-red-breaker.sh"
d = sys.argv[1]
gates = missing = 0
# The JOB census (task-50b343c0403f8b06). Arm 15 counted gate STEPS, which is
# the right unit for the capture half and the wrong one for the question "is
# this job a breaker job at all" — required-checks-drift's `spec-gate` had
# three unarmed gate steps and no Decide step, so it contributed ZERO to the
# step count and its absence was invisible here. A job that carries the marker
# but no Decide step is the exact shape that reds a PR author for main's defect
# with no verdict line, so it is now a MISSING, and the job tally is printed so
# a job entering or leaving the breaker set is visible in one line.
jobs = []           # (fn, jobkey, gate_steps, decide_steps) for jobs with either
def flush(fn, key, g, dec):
    if key is not None and (g or dec):
        jobs.append((fn, key, g, dec))
for fn in sorted(os.listdir(d)):
    if not fn.endswith((".yml", ".yaml")):
        continue
    lines = open(os.path.join(d, fn), errors="replace").read().split("\n")
    # A breaker workflow is one carrying EITHER half. Keying this filter on the
    # Decide step alone made the job clause below unreachable in the one case it
    # exists for: delete the last Decide step from a file and the whole file
    # stopped being audited, so its now-orphaned gate steps left the tally
    # SILENTLY (measured 53 -> 50 steps, 9 -> 8 jobs, rc 0). The marker is the
    # opt-in; a file that carries it is audited whether or not anyone owns the
    # verdict.
    if not any(MARK in l or ("main-red-breaker.sh" in l and "run:" in l) for l in lines):
        continue  # not one of the breaker workflows
    injobs = False; key = None; g = dec = 0
    for l in lines:
        if re.match(r"^jobs:\s*$", l):
            injobs = True; continue
        if injobs and re.match(r"^  [A-Za-z0-9_.-]+:\s*$", l):
            flush(fn, key, g, dec); key = l.strip()[:-1]; g = dec = 0; continue
        if key is not None and MARK in l:
            g += 1
        if key is not None and DECIDE in l and "run:" in l:
            dec += 1
    flush(fn, key, g, dec)
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
armed_jobs = 0
for fn, key, g, dec in jobs:
    if g and not dec:
        print("MISSING %s job %r - %d gate step(s) marked but NO Decide step: main's own red lands on the PR author with no verdict line" % (fn, key, g)); missing += 1
    elif dec and not g:
        print("MISSING %s job %r - a Decide step with no gate step: it can only ever judge steps that never opted in" % (fn, key)); missing += 1
    elif g and dec:
        armed_jobs += 1
print(("OK %d gate step(s) arm the capture across %d breaker job(s)" % (gates, armed_jobs))
      if not missing else "%d of %d gate step(s) UNWIRED (%d breaker job(s) intact)" % (missing, gates, armed_jobs))
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
# 15c. MUTATION on the JOB half (task-50b343c0403f8b06). 15b proves a gate step
#      that stops arming the capture is caught. This proves the other direction:
#      a job whose Decide step is DELETED — the exact state `spec-gate` shipped
#      in, gate steps present, nobody owning the verdict — must red too. Without
#      this the job clause is a derivation that cannot fail.
mut2="$TMP/wf-mut-decide"; rm -rf "$mut2"; mkdir -p "$mut2"; cp "$ROOT"/.github/workflows/*.yml "$mut2/" 2>/dev/null
dvictim="$mut2/required-checks-drift.yml"
if [ -f "$dvictim" ]; then
  python3 - "$dvictim" > "$TMP/decide-mut.count" <<'MUTATE'
import re, sys
p = sys.argv[1]; lines = open(p).read().split("\n")
# Drop the LAST Decide step's run line (and its `- name:` header) — enough to
# make the job that owns it carry gate steps with no verdict owner.
hits = [i for i, l in enumerate(lines) if "main-red-breaker.sh" in l and "run:" in l]
if not hits:
    print("0"); raise SystemExit
i = hits[-1]
j = i
while j >= 0 and "- name: Decide" not in lines[j]:
    j -= 1
del lines[(j if j >= 0 else i):i + 1]
open(p, "w").write("\n".join(lines))
print(str(len(hits)))
MUTATE
  dcount="$(cat "$TMP/decide-mut.count" 2>/dev/null || echo 0)"
  if [ "$dcount" != "0" ]; then
    dout="$(gate_capture_audit "$mut2" 2>&1)"; drc=$?
    if [ "$drc" -ne 0 ]; then ok "15c) MUTATION: deleting a job's Decide step reds the audit"; else bad "15c) MUTATION SURVIVED: a job kept its gate steps with no Decide step and the audit stayed green — $dout"; fi
    has "$dout" "NO Decide step" "15c) and it says which job lost its verdict owner"
  else
    bad "15c) could not build the mutation (no Decide step found in $dvictim)"
  fi
else
  bad "15c) could not build the mutation (required-checks-drift.yml absent from the copy)"
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

# ── 18. THE THREE MISLABELS (task-e638b950726fea51) ─────────────────────────
# All three were observed on live PRs on 2026-09-05/06 and all three produced
# the SAME confident sentence — "the red is this PR's own" — from three
# different mechanisms. Each arm below replays one, and each has a MUTATION
# under 19 proving the arm can still fail.

# 18a. M1 — MAIN'S JOB IS A MATRIX LEG. GitHub publishes a matrixed job as
#      "<name> (27.0, 1.18.1)"; security.yml passes JOB_NAME without the tuple.
#      MEASURED on main run 33968984175: RUN conclusion "success", JOB
#      'Sobelow … (27.0, 1.18.1)' conclusion "failure". v1 matched by exact name,
#      found nothing, and told #16189/#16136 the red was theirs.
main_matrix="$TMP/main-matrix.json"; cat > "$main_matrix" <<'J'
{"jobs":[{"id":42,"name":"Doc budgets + anchors (27.0, 1.18.1)","conclusion":"failure","steps":[{"name":"Doc byte budgets (fails this job)","conclusion":"success"},{"name":"Code-comment citation guard (fails this job)","conclusion":"failure"},{"name":"Tenant fail-open read baseline gate (fails this job)","conclusion":"success"}]}]}
J
out="$(run "$out_s2" pull_request "$main_matrix")"
has "$out" "INHERITED-FROM-MAIN" "18a) M1: a matrix leg of main's job is found, so the red is inherited"
has "$out" "RC=0" "18a) rc 0"
case "$out" in *"the red is this PR's own"*) bad "18a) still blamed the author for main's matrixed red" ;; *) ok "18a) does not blame the author" ;; esac

# 18b. M2 — MAIN NEVER REACHED THE STEP. Steps are sequential and unconditional,
#      so main's first red stamps every later step `skipped`. PR #15517's
#      `Smoke arms` crash was labelled the PR's own on exactly this shape:
#      "not failing on main" was VACUOUSLY true because main never ran it.
main_notreached="$TMP/main-notreached.json"; cat > "$main_notreached" <<'J'
{"jobs":[{"id":43,"name":"Doc budgets + anchors","conclusion":"failure","steps":[{"name":"Doc byte budgets (fails this job)","conclusion":"failure"},{"name":"Code-comment citation guard (fails this job)","conclusion":"skipped"},{"name":"Tenant fail-open read baseline gate (fails this job)","conclusion":"skipped"}]}]}
J
out="$(run "$out_s2" pull_request "$main_notreached")"
has "$out" "OWNERSHIP-UNDETERMINED" "18b) M2: a step main SKIPPED is undetermined, not the author's"
has "$out" "did NOT REACH" "18b) and says main never ran it"
has "$out" "RC=1" "18b) rc 1 — the red still stands, nothing is waved through"
has "$out" "::warning" "18b) a warning annotation, distinct from an error and from a notice"
case "$out" in *"the red is this PR's own"*) bad "18b) blamed the author for a step main never ran" ;; *) ok "18b) makes no ownership claim" ;; esac
case "$out" in *INHERITED-FROM-MAIN*) bad "18b) waved a red through as inherited on no evidence" ;; *) ok "18b) does not inherit either" ;; esac

# 18b2. THE ORDER MATTERS. Main provably PASSED one of our two failed steps and
#       never reached the other. A guard that answered UNDETERMINED here would
#       be the same defect with the opposite sign — it would hide a real PR red.
#       The pass is reported AND the unsettled step is named, not folded in.
main_mixed="$TMP/main-mixed.json"; cat > "$main_mixed" <<'J'
{"jobs":[{"id":44,"name":"Doc budgets + anchors","conclusion":"failure","steps":[{"name":"Doc byte budgets (fails this job)","conclusion":"failure"},{"name":"Code-comment citation guard (fails this job)","conclusion":"success"},{"name":"Tenant fail-open read baseline gate (fails this job)","conclusion":"skipped"}]}]}
J
out="$(run "$out_s2_s3" pull_request "$main_mixed")"
has "$out" "failed on a step main does not: Code-comment citation guard" "18b2) a step main RAN and PASSED is still reported as the PR's own"
has "$out" "UNDETERMINED, not attributed to you: Tenant fail-open" "18b2) and the unreached step is named as undetermined in the same line"
has "$out" "RC=1" "18b2) rc 1"

# 18c. M3(i) — MAIN'S JOBS LISTING IS AN API ERROR BODY. v1 read the empty
#      result as "GREEN or absent" and blamed the author. A 404/403 envelope is
#      not evidence about anybody.
main_err="$TMP/main-err.json"; echo '{"message":"Not Found","status":"404"}' > "$main_err"
out="$(run "$out_s2" pull_request "$main_err")"
has "$out" "OWNERSHIP-UNDETERMINED" "18c) M3: an API error body is undetermined, not green"
has "$out" "did not parse as JSON" "18c) and says the listing was unreadable"
has "$out" "RC=1" "18c) rc 1"
case "$out" in *"the red is this PR's own"*) bad "18c) called an API error body 'main is green'" ;; *) ok "18c) makes no ownership claim" ;; esac

# 18d. M3(ii) — MAIN'S JOB WAS CANCELLED. This fleet cancels superseded main
#      runs constantly (21 of 60 doc-gates runs, measured 2026-09-01). A
#      cancelled job has nothing to compare against.
main_cancelled="$TMP/main-cancelled.json"; cat > "$main_cancelled" <<'J'
{"jobs":[{"id":45,"name":"Doc budgets + anchors","conclusion":"cancelled","steps":[{"name":"Code-comment citation guard (fails this job)","conclusion":"cancelled"}]}]}
J
out="$(run "$out_s2" pull_request "$main_cancelled")"
has "$out" "OWNERSHIP-UNDETERMINED" "18d) M3: a cancelled main job is undetermined"
has "$out" "RC=1" "18d) rc 1"

# 18e. M3(iii) — RUN SELECTION SKIPS UNINFORMATIVE RUNS, and every verdict
#      carries the chosen run's id, head sha, conclusion and AGE, so a stale
#      comparison is visible instead of implied. (No jobs fixture here: the
#      stub curl fails the jobs fetch, so this lands on 18c's clause — what is
#      under test is WHICH run was picked and what the line says about it.)
runs_fx="$TMP/main-runs.json"; cat > "$runs_fx" <<'J'
{"workflow_runs":[{"id":999001,"conclusion":"cancelled","head_sha":"aaaaaaaabbbb","updated_at":"2026-01-01T00:00:00Z"},{"id":999002,"conclusion":"failure","head_sha":"deadbeefcafe","updated_at":"2026-01-01T00:00:00Z"}]}
J
out="$( (export PATH="$TMP/bin:$PATH" STEP_OUTCOMES="$out_s2" STEP_NAMES="$NAMES" JOB_NAME="Doc budgets + anchors" WORKFLOW_FILE="doc-gates.yml" GITHUB_EVENT_NAME=pull_request GITHUB_REPOSITORY=o/r GITHUB_TOKEN=t GITHUB_STEP_SUMMARY="$TMP/summary.md" MAIN_RED_BREAKER_RUNS_FIXTURE="$runs_fx"; bash "$SUBJECT" 2>&1; echo "RC=$?") )"
has "$out" "Main run 999002" "18e) the newest CANCELLED run is skipped for the newest informative one"
has "$out" "head deadbeef" "18e) the verdict names main's head sha"
has "$out" "concluded failure" "18e) and main's run conclusion"
has "$out" "min ago" "18e) and how stale the comparison is"
has "$out" "skipping 1 uninformative" "18e) and that it walked past an uninformative run"
has "$out" "RC=1" "18e) rc 1"

# 18f. every candidate run is uninformative -> undetermined, and it says main's
#      state is unknown rather than inventing a green.
runs_all_cancelled="$TMP/main-runs-cancelled.json"; echo '{"workflow_runs":[{"id":1,"conclusion":"cancelled","head_sha":"aa","updated_at":"2026-01-01T00:00:00Z"}]}' > "$runs_all_cancelled"
out="$( (export PATH="$TMP/bin:$PATH" STEP_OUTCOMES="$out_s2" STEP_NAMES="$NAMES" JOB_NAME="Doc budgets + anchors" WORKFLOW_FILE="doc-gates.yml" GITHUB_EVENT_NAME=pull_request GITHUB_REPOSITORY=o/r GITHUB_TOKEN=t GITHUB_STEP_SUMMARY="$TMP/summary.md" MAIN_RED_BREAKER_RUNS_FIXTURE="$runs_all_cancelled"; bash "$SUBJECT" 2>&1; echo "RC=$?") )"
has "$out" "OWNERSHIP-UNDETERMINED" "18f) no informative run at all is undetermined"
has "$out" "Could not read main" "18f) and says so"
has "$out" "RC=1" "18f) rc 1"

# 18g. THE THREE VERDICTS ARE THREE DIFFERENT ANNOTATIONS. A reader (and any
#      log scraper) must be able to tell them apart without parsing prose.
out="$(run "$out_s2" pull_request "$main_red_s2")";        has "$out" "::notice"  "18g) inherited emits ::notice"
out="$(run "$out_s2" pull_request "$main_green")";         has "$out" "::error"   "18g) the PR's own red emits ::error"
out="$(run "$out_s2" pull_request "$main_notreached")";    has "$out" "::warning" "18g) undetermined emits ::warning"

# 18h. M4 — A STEP NAME THAT CONTAINS THE DELIMITER. Found on 2026-09-06 by
#      replaying main run 33968984175 (security.yml) through v1 and v2 rather
#      than through a fixture. Main's verdict sentence joins its failed step
#      names with ';', and security.yml's gate step is literally named
#        "Sobelow (--skip reads api/.sobelow-skips baseline; --exit Low reds …)".
#      Split back on ';' that yields two names matching nothing, so a PR failing
#      the EXACT step main fails read as "a step main does not" — a fourth route
#      to the same wrong sentence. Main now also prints ONE UNAMBIGUOUS LINE PER
#      STEP; until main has run the new script, the ';'-shredded recovery is
#      treated as AMBIGUOUS and can never license a blame verdict.
SEMI_STEP='Sobelow (--skip reads api/.sobelow-skips baseline; --exit Low reds on any NEW finding)'
semi_names="$(python3 -c 'import json,sys; print(json.dumps({"s1":"Fetch deps","s2":sys.argv[1]}))' "$SEMI_STEP")"
semi_out='{"s1":{"outcome":"success"},"s2":{"outcome":"failure"}}'
# main's REAL API shape: every gate step "success" (continue-on-error), Decide red.
semi_jobs="$TMP/semi-jobs.json"; python3 - "$SEMI_STEP" > "$semi_jobs" <<'J'
import json, sys
print(json.dumps({"jobs":[{"id":77,"name":"Sobelow static analysis (regression gate, baseline .sobelow-skips) (27.0, 1.18.1)","conclusion":"failure","steps":[
  {"name":"Fetch deps","conclusion":"success"},
  {"name":sys.argv[1],"conclusion":"success"},
  {"name":"Decide (main-red breaker — inherited reds are neutral, own reds fail)","conclusion":"failure"}]}]}))
J
semi_run() { # $1 main log fixture, $2 our capture (or "")
  ( export PATH="$TMP/bin:$PATH" STEP_OUTCOMES="$semi_out" STEP_NAMES="$semi_names" \
      JOB_NAME="Sobelow static analysis (regression gate, baseline .sobelow-skips)" \
      WORKFLOW_FILE=security.yml GITHUB_EVENT_NAME=pull_request GITHUB_REPOSITORY=o/r GITHUB_TOKEN=t \
      GITHUB_STEP_SUMMARY="$TMP/summary.md" MAIN_RED_BREAKER_FIXTURE="$semi_jobs" MAIN_RED_BREAKER_LOG_FIXTURE="$1"
    [ -n "${2:-}" ] && export BREAKER_ERROR_LOG="$2"
    bash "$SUBJECT" 2>&1; echo "RC=$?" )
}
# main's log as it exists TODAY: the ';'-joined sentence and nothing else.
# TWO failed steps on main, so the ';'-shred is genuinely unrecoverable: with
# one step the whole unsplit blob is itself a valid candidate and the marker
# buys nothing (measured — the first draft of mutation 19f survived on exactly
# that). Two steps is the shape the marker exists for.
semi_log_legacy="$TMP/semi-legacy.log"; { printf '2026-09-05T13:31:00.0Z FAIL: DOS.StringToAtom api/lib/barkpark/validation.ex:188\n'
  printf "2026-09-05T13:31:00.1Z main-red-breaker: FAIL — 'Sobelow static analysis (regression gate, baseline .sobelow-skips)' failed on: Fetch deps;%s. This is not a pull_request run, so the red is main's state and stands.\n" "$SEMI_STEP"; } > "$semi_log_legacy"
out="$(semi_run "$semi_log_legacy")"
case "$out" in *"a step main does not"*) bad "18h1) M4: a ';' in the step name still shreds main's list and blames the author" ;; *) ok "18h1) M4: a ';'-bearing step name is not blamed on the author" ;; esac
has "$out" "OWNERSHIP-UNDETERMINED" "18h1) and the shredded legacy recovery is reported as undetermined"
has "$out" "RC=1" "18h1) rc 1"
# main's log once main has RUN the new script: one unambiguous line per step.
semi_log_marked="$TMP/semi-marked.log"; cp "$semi_log_legacy" "$semi_log_marked"
printf "2026-09-05T13:31:00.2Z main-red-breaker: MAIN-FAILED-STEP in 'Sobelow static analysis (regression gate, baseline .sobelow-skips)': Fetch deps\n" >> "$semi_log_marked"
printf "2026-09-05T13:31:00.3Z main-red-breaker: MAIN-FAILED-STEP in 'Sobelow static analysis (regression gate, baseline .sobelow-skips)': %s\n" "$SEMI_STEP" >> "$semi_log_marked"
semi_cap="$TMP/semi-ours.txt"; printf 'FAIL: DOS.StringToAtom api/lib/barkpark/validation.ex:190\n' > "$semi_cap"
out="$(semi_run "$semi_log_marked" "$semi_cap")"
has "$out" "INHERITED-FROM-MAIN" "18h2) the marker line recovers the name intact, so the same defect inherits"
has "$out" "Signature matched too" "18h2) and only because the signature agreed (line drifted 188 -> 190)"
has "$out" "RC=0" "18h2) rc 0"
# and a DIFFERENT defect in that same step is still the author's.
semi_cap2="$TMP/semi-ours2.txt"; printf 'FAIL: DOS.StringToAtom web/app/page.tsx:12\n' > "$semi_cap2"
out="$(semi_run "$semi_log_marked" "$semi_cap2")"
has "$out" "NOT with the same failure signature" "18h3) a different defect in the same ';'-named step is still the PR's own"
has "$out" "RC=1" "18h3) rc 1"

# 18h4. M4b — THE MARKERS WERE PARSED AND THE LEGACY SENTENCE STILL GAGGED THE
#       VERDICT. MEASURED 2026-09-06: 7 of 8 failed doc-gates PR runs
#       (34048731323 34048702712 34048598999 34048312911 34048184632 34047628152
#       34046862261) printed OWNERSHIP-UNDETERMINED for a red that was their own.
#       Fixture below is the REAL specimen: PR run 34046862261's four failed
#       steps, and main run 34046086072's Decide lines COPIED VERBATIM — it
#       prints BOTH the legacy ';'-joined sentence (three names) AND one
#       MAIN-FAILED-STEP marker per step. log_ambiguous was set from the
#       sentence and never cleared by log_marked, so the UNKNOWN clause outrank-
#       ed PASSED and the fourth step — which main ran and passed — was reported
#       as "main's state is UNKNOWN" instead of "a step main does not fail".
DOC_D='New file:line citations in comments (fails this job)'
doc_names="$(python3 -c 'import json; print(json.dumps({"s1":"Code-comment citation guard (fails this job)","s2":"Doc byte budgets (fails this job)","s3":"Tenant fail-open read baseline gate (fails this job)","s4":"New file:line citations in comments (fails this job)"}))')"
doc_out='{"s1":{"outcome":"failure"},"s2":{"outcome":"failure"},"s3":{"outcome":"failure"},"s4":{"outcome":"failure"}}'
# main's REAL jobs shape for run 34046086072: every gate step reads "success"
# (continue-on-error masks them), only Decide carries the failure.
doc_jobs="$TMP/doc-jobs.json"; cat > "$doc_jobs" <<'J'
{"jobs":[{"id":91,"name":"Doc budgets + anchors","conclusion":"failure","steps":[
  {"name":"Doc byte budgets (fails this job)","conclusion":"success"},
  {"name":"Code-comment citation guard (fails this job)","conclusion":"success"},
  {"name":"New file:line citations in comments (fails this job)","conclusion":"success"},
  {"name":"Tenant fail-open read baseline gate (fails this job)","conclusion":"success"},
  {"name":"Decide (main-red breaker — inherited reds are neutral, own reds fail)","conclusion":"failure"}]}]}
J
doc_run() { # $1 main log fixture
  ( export PATH="$TMP/bin:$PATH" STEP_OUTCOMES="$doc_out" STEP_NAMES="$doc_names" \
      JOB_NAME="Doc budgets + anchors" WORKFLOW_FILE=doc-gates.yml \
      GITHUB_EVENT_NAME=pull_request GITHUB_REPOSITORY=o/r GITHUB_TOKEN=t \
      GITHUB_STEP_SUMMARY="$TMP/summary.md" MAIN_RED_BREAKER_FIXTURE="$doc_jobs" MAIN_RED_BREAKER_LOG_FIXTURE="$1"
    bash "$SUBJECT" 2>&1; echo "RC=$?" )
}
# VERBATIM from main run 34046086072's Decide step (timestamps included).
doc_log_marked="$TMP/doc-marked.log"; cat > "$doc_log_marked" <<'L'
2026-09-06T16:40:38.6317013Z main-red-breaker: FAIL — 'Doc budgets + anchors' failed on: Code-comment citation guard (fails this job);Doc byte budgets (fails this job);Tenant fail-open read baseline gate (fails this job). This is not a pull_request run, so the red is main's state and stands.
2026-09-06T16:40:38.6319555Z main-red-breaker: MAIN-FAILED-STEP in 'Doc budgets + anchors': Code-comment citation guard (fails this job)
2026-09-06T16:40:38.6320426Z main-red-breaker: MAIN-FAILED-STEP in 'Doc budgets + anchors': Doc byte budgets (fails this job)
2026-09-06T16:40:38.6321928Z main-red-breaker: MAIN-FAILED-STEP in 'Doc budgets + anchors': Tenant fail-open read baseline gate (fails this job)
L
out="$(doc_run "$doc_log_marked")"
has "$out" "failed on a step main does not: $DOC_D" "18h4) M4b: markers parsed => the step main passed is named as the PR's own"
case "$out" in *OWNERSHIP-UNDETERMINED*) bad "18h4) M4b: still OWNERSHIP-UNDETERMINED with main's markers in the log" ;; *) ok "18h4) M4b: no longer refuses to decide" ;; esac
case "$out" in *"Main's state for these step(s) is UNKNOWN"*) bad "18h4) M4b: still reported main's state as UNKNOWN for a step the markers settle" ;; *) ok "18h4) M4b: main's state for that step is settled, not UNKNOWN" ;; esac
has "$out" "Code-comment citation guard (fails this job)" "18h4) and main's three steps are named as inherited"
has "$out" "Doc byte budgets (fails this job)" "18h4) inherited: doc byte budgets"
has "$out" "Tenant fail-open read baseline gate (fails this job)" "18h4) inherited: tenant fail-open baseline"
has "$out" "RC=1" "18h4) rc 1"
# 18h5. M4's protection is UNTOUCHED: strip the marker lines from the SAME
#       fixture and the same fourth step must go back to UNDETERMINED — the
#       ';'-joined sentence alone cannot license a blame verdict.
doc_log_legacy="$TMP/doc-legacy.log"; grep -vF 'MAIN-FAILED-STEP' "$doc_log_marked" > "$doc_log_legacy"
out="$(doc_run "$doc_log_legacy")"
has "$out" "OWNERSHIP-UNDETERMINED" "18h5) M4 intact: a legacy-only ';' log still refuses to blame"
case "$out" in *"failed on a step main does not"*) bad "18h5) M4 BROKEN: the legacy-only ';' log blamed the author" ;; *) ok "18h5) M4 intact: no blame from the shredded sentence" ;; esac
has "$out" "RC=1" "18h5) rc 1"

# ── 19. MUTATIONS — the ownership decision lives in FOUR places, and a partial
#       mutation returns a confident green for the opposite conclusion. Each
#       mutation is asserted to have APPLIED (anchor matched exactly once, diff
#       non-empty) before its arm is believed.
mutate() { # $1 label, $2 anchor, $3 replacement, $4 EXPECTED occurrence count (default 1)
  #          -> writes $TMP/mut-subject.sh, rc 0 only if the mutation demonstrably applied.
  # $4 is not a convenience. The matrix-leg match lives in TWO python blocks
  # (the job-id lookup and the classifier); a mutation that reached only one of
  # them left the arm GREEN and would have certified a fix that was half
  # present. Stating the count makes a new copy of the behaviour a test failure
  # instead of a silent survival.
  local lbl="$1" anchor="$2" repl="$3" want="${4:-1}" n
  cp "$SUBJECT" "$TMP/mut-subject.sh"
  n="$(grep -cF "$anchor" "$TMP/mut-subject.sh")"
  if [ "$n" != "$want" ]; then bad "19) MUTATION $lbl anchor matched $n time(s), not the declared $want — the mutation is not aimed at every place the behaviour lives"; return 1; fi
  ANCHOR="$anchor" REPL="$repl" WANT="$want" python3 - "$TMP/mut-subject.sh" <<'M'
import os, sys
p = sys.argv[1]; s = open(p).read()
assert s.count(os.environ["ANCHOR"]) == int(os.environ["WANT"])
open(p, "w").write(s.replace(os.environ["ANCHOR"], os.environ["REPL"]))
M
  if diff -q "$SUBJECT" "$TMP/mut-subject.sh" >/dev/null 2>&1; then bad "19) MUTATION $lbl produced an EMPTY diff — it did not apply"; return 1; fi
  if ! bash -n "$TMP/mut-subject.sh" 2>/dev/null; then bad "19) MUTATION $lbl broke the syntax — the arm below would fail for the wrong reason"; return 1; fi
  ok "19) MUTATION $lbl applied (anchor matched once, diff non-empty, still parses)"
  return 0
}
mutrun() { MAIN_RED_BREAKER_SUBJECT="$TMP/mut-subject.sh" SUBJECT="$TMP/mut-subject.sh" run "$@"; }

# 19a. Kill the matrix-leg match (M1's fix) -> 18a must stop inheriting.
if mutate "19a matrix-leg match (BOTH copies)" 'return n == want or (isinstance(n, str) and n.startswith(want + " ("))' 'return n == want' 2; then
  ( SUBJECT="$TMP/mut-subject.sh"; out="$(run "$out_s2" pull_request "$main_matrix")"
    case "$out" in *INHERITED-FROM-MAIN*) echo "  FAIL  19a) MUTATION SURVIVED: still inherited with the matrix match removed"; exit 1 ;; *) echo "  PASS  19a) removing the matrix-leg match breaks 18a — the arm is not vacuous" ;; esac ) || FAIL=$((FAIL+1))
  [ $? -eq 0 ] && PASS=$((PASS+1))
fi
# 19b. Treat a SKIPPED step as a pass (v1's M2 bug) -> 18b must stop being
#      undetermined and start blaming the author again.
# 19b's first draft flipped the `if st in ("skipped","cancelled")` test and the
# arm STAYED GREEN — a skipped step then fell through to UNKNOWN, which is ALSO
# undetermined. A partial mutation returns a confident green for the opposite
# conclusion. The aimed mutation is the verdict itself: call a skipped step a
# pass, which is precisely what v1 did.
if mutate "19b not-reached classification" 'cls = "NOTREACHED"            # M2: main never executed it' 'cls = "PASSED"'; then
  ( SUBJECT="$TMP/mut-subject.sh"; out="$(run "$out_s2" pull_request "$main_notreached")"
    case "$out" in *OWNERSHIP-UNDETERMINED*) echo "  FAIL  19b) MUTATION SURVIVED: still undetermined with the not-reached rule removed"; exit 1 ;; *) echo "  PASS  19b) removing the not-reached rule breaks 18b — the arm is not vacuous" ;; esac ) || FAIL=$((FAIL+1))
  [ $? -eq 0 ] && PASS=$((PASS+1))
fi
# 19c. THE OPPOSITE DEFECT. Never emit PASSED — the breaker would then answer
#      UNDETERMINED to everything and never accuse anyone, which is the same
#      failure wearing the other mask. Arms 3 and 4 must both go red.
if mutate "19c the accusing path" 'cls = "PASSED"                 # the ONLY accusing evidence' 'cls = "UNKNOWN"'; then
  ( SUBJECT="$TMP/mut-subject.sh"
    o3="$(run "$out_s2" pull_request "$main_green")"; o4="$(run "$out_s2_s3" pull_request "$main_red_s2")"
    bad3=1; bad4=1
    case "$o3" in *"the red is this PR's own"*) bad3=0 ;; esac
    case "$o4" in *"failed on a step main does not"*) bad4=0 ;; esac
    if [ "$bad3" = 1 ] && [ "$bad4" = 1 ]; then echo "  PASS  19c) with PASSED removed the breaker stops accusing anyone — the accusing path is live, not decorative"; else echo "  FAIL  19c) MUTATION SURVIVED: still accused (arm3=$bad3 arm4=$bad4)"; exit 1; fi ) || FAIL=$((FAIL+1))
  [ $? -eq 0 ] && PASS=$((PASS+1))
fi
# 19d. Treat an unparsable jobs listing as an empty one (v1's M3 bug) -> 18c
#      must stop being undetermined.
if mutate "19d unparsable-JSON status" 'status = "NOJSON"' 'status = "OK"'; then
  ( SUBJECT="$TMP/mut-subject.sh"; out="$(run "$out_s2" pull_request "$main_err")"
    case "$out" in *"did not parse as JSON"*) echo "  FAIL  19d) MUTATION SURVIVED: still reported the parse failure"; exit 1 ;; *) echo "  PASS  19d) removing the NOJSON status breaks 18c — the arm is not vacuous" ;; esac ) || FAIL=$((FAIL+1))
  [ $? -eq 0 ] && PASS=$((PASS+1))
fi
# 19e. Stop skipping uninformative runs -> 18e must pick the cancelled run.
if mutate "19e uninformative-run filter" 'UNINFORMATIVE = {"cancelled", "skipped", "startup_failure", "stale", None, ""}' 'UNINFORMATIVE = {None, ""}'; then
  ( out="$( (export PATH="$TMP/bin:$PATH" STEP_OUTCOMES="$out_s2" STEP_NAMES="$NAMES" JOB_NAME="Doc budgets + anchors" WORKFLOW_FILE="doc-gates.yml" GITHUB_EVENT_NAME=pull_request GITHUB_REPOSITORY=o/r GITHUB_TOKEN=t GITHUB_STEP_SUMMARY="$TMP/summary.md" MAIN_RED_BREAKER_RUNS_FIXTURE="$runs_fx"; bash "$TMP/mut-subject.sh" 2>&1) )"
    case "$out" in *"Main run 999001"*) echo "  PASS  19e) without the filter the cancelled run IS chosen — 18e is not vacuous" ;; *) echo "  FAIL  19e) MUTATION SURVIVED: still chose the informative run"; exit 1 ;; esac ) || FAIL=$((FAIL+1))
  [ $? -eq 0 ] && PASS=$((PASS+1))
fi

# 19f. Drop the unambiguous marker parse (M4's fix) -> 18h2 must stop inheriting
#      and fall back to the shredded ';' recovery.
if mutate "19f MAIN-FAILED-STEP marker parse" "mark = \"main-red-breaker: MAIN-FAILED-STEP in '%s': \" % want" "mark = \"__no_such_marker__\"" 1; then
  ( SUBJECT="$TMP/mut-subject.sh"; out="$(semi_run "$semi_log_marked" "$semi_cap")"
    case "$out" in *INHERITED-FROM-MAIN*) echo "  FAIL  19f) MUTATION SURVIVED: still inherited with the marker parse removed"; exit 1 ;; *) echo "  PASS  19f) removing the marker parse breaks 18h2 — the arm is not vacuous" ;; esac ) || FAIL=$((FAIL+1))
  [ $? -eq 0 ] && PASS=$((PASS+1))
fi
# 19g. Drop the AMBIGUITY guard -> 18h1 must go back to blaming the author,
#      which is exactly the sentence #16189/#16136 got.
if mutate "19g legacy ';' ambiguity guard" '            log_ambiguous = True' '            log_ambiguous = False' 1; then
  ( SUBJECT="$TMP/mut-subject.sh"; out="$(semi_run "$semi_log_legacy")"
    case "$out" in *"a step main does not"*) echo "  PASS  19g) without the ambiguity guard the shredded name blames the author — 18h1 is not vacuous" ;; *) echo "  FAIL  19g) MUTATION SURVIVED: still refused to blame"; exit 1 ;; esac ) || FAIL=$((FAIL+1))
  [ $? -eq 0 ] && PASS=$((PASS+1))
fi
# 19m. Drop M4b's clear (this fix) -> 18h4 must go back to OWNERSHIP-UNDETERMINED.
#      Without it the legacy sentence's ambiguity survives the markers that
#      settle it, and the UNKNOWN clause outranks PASSED again.
if mutate "19m M4b marker clears the legacy ambiguity" 'if log_marked:' 'if False:' 1; then
  ( SUBJECT="$TMP/mut-subject.sh"; out="$(doc_run "$doc_log_marked")"
    case "$out" in *OWNERSHIP-UNDETERMINED*) echo "  PASS  19m) without the clear the marker-settled step is UNDETERMINED again — 18h4 is not vacuous" ;; *) echo "  FAIL  19m) MUTATION SURVIVED: still decided with the clear removed"; exit 1 ;; esac ) || FAIL=$((FAIL+1))
  [ $? -eq 0 ] && PASS=$((PASS+1))
fi


# ── 20. M5(i) — MAIN'S NEWEST RUN SKIPPED THE JOB (task-e65c78b1cd214237 c1) ─
# security.yml's sobelow job carries `if: needs.changes.outputs.api == 'true'`,
# and security.yml's own header records that a job skipped by a job-level `if:`
# PUBLISHES a check run with conclusion `skipped`. So one non-api merge to main
# is enough for main's NEWEST completed run to hold this job as `skipped` while
# the run one merge older was failing the very step the PR fails. `skipped` is
# neither a pass nor an absence — it is a run with nothing to say — so the
# selection now WALKS BACK (bounded) to the newest run in which a job of this
# name actually EXECUTED (conclusion success or failure).
# MEASURED 2026-09-06: 160 of 160 newest completed security.yml push runs on
# main ran the job, so this shape is LATENT today rather than the mechanism
# behind the six mislabels of 2026-09-05 (those were M1, the matrix-leg name).
runs_walk="$TMP/runs-walk.json"; cat > "$runs_walk" <<'J'
{"workflow_runs":[{"id":900001,"conclusion":"success","head_sha":"1111aaaabbbb","updated_at":"2026-09-06T07:00:00Z"},{"id":900002,"conclusion":"failure","head_sha":"2222ccccdddd","updated_at":"2026-09-06T06:00:00Z"}]}
J
jobsdir="$TMP/jobsdir"; mkdir -p "$jobsdir"
# 900001 — the newest run: the job is PRESENT and `skipped` (its dispatcher said
# no api/ path changed). Zero evidence about main at that step.
cat > "$jobsdir/900001.json" <<'J'
{"jobs":[{"id":9001,"name":"Doc budgets + anchors","conclusion":"skipped","steps":[]}]}
J
# 900002 — one merge older: the job RAN and failed on our step.
cp "$main_red_s2" "$jobsdir/900002.json"
walk_run() { # $1 = subject override (or "")
  ( export PATH="$TMP/bin:$PATH" STEP_OUTCOMES="$out_s2" STEP_NAMES="$NAMES" JOB_NAME="Doc budgets + anchors" \
      WORKFLOW_FILE="doc-gates.yml" GITHUB_EVENT_NAME=pull_request GITHUB_REPOSITORY=o/r GITHUB_TOKEN=t \
      GITHUB_STEP_SUMMARY="$TMP/summary.md" MAIN_RED_BREAKER_RUNS_FIXTURE="$runs_walk" MAIN_RED_BREAKER_JOBS_DIR="$jobsdir"
    bash "${1:-$SUBJECT}" 2>&1; echo "RC=$?" )
}
out="$(walk_run)"
has "$out" "INHERITED-FROM-MAIN" "20) M5: a job SKIPPED on main's newest run is walked past to the run that ran it => inherited"
has "$out" "Main run 900002" "20) and the verdict names the run it actually compared against"
has "$out" "Walked back past 1 newer main run" "20) and says how many runs it walked past, and why"
has "$out" "RC=0" "20) rc 0"
case "$out" in *"the red is this PR's own"*) bad "20) blamed the author over a skipped job" ;; *) ok "20) does not blame the author" ;; esac
# 20b. the walk is BOUNDED and it FAILS HONESTLY: if no run in the window ran
#      the job, the newest informative run is kept and the verdict is
#      undetermined — never an invented green.
jobsdir2="$TMP/jobsdir2"; mkdir -p "$jobsdir2"
cp "$jobsdir/900001.json" "$jobsdir2/900001.json"; cp "$jobsdir/900001.json" "$jobsdir2/900002.json"
out="$( (export PATH="$TMP/bin:$PATH" STEP_OUTCOMES="$out_s2" STEP_NAMES="$NAMES" JOB_NAME="Doc budgets + anchors" WORKFLOW_FILE="doc-gates.yml" GITHUB_EVENT_NAME=pull_request GITHUB_REPOSITORY=o/r GITHUB_TOKEN=t GITHUB_STEP_SUMMARY="$TMP/summary.md" MAIN_RED_BREAKER_RUNS_FIXTURE="$runs_walk" MAIN_RED_BREAKER_JOBS_DIR="$jobsdir2"; bash "$SUBJECT" 2>&1; echo "RC=$?") )"
has "$out" "OWNERSHIP-UNDETERMINED" "20b) no run in the window executed the job => undetermined, not green"
has "$out" "EXECUTED in any of the newest 2 informative main run" "20b) and the walk says it found none"
has "$out" "RC=1" "20b) rc 1"

# ── 21. M5(ii) — THE SOBELOW FINDING SHAPE IS INVISIBLE TO THE NORMALISER ────
# (task-e65c78b1cd214237 c2.) Sobelow prints neither FAIL nor ERROR nor an
# ##[error] annotation for a finding — it prints a `<Detector>: <message> - <N>
# Confidence` header and four UNINDENTED File:/Line:/Function:/Variable: rows,
# so the START regex missed the header and the indentation rule dropped the
# rows. The signature set for the whole sobelow job collapsed to the runner's
# own `Process completed with exit code 1`, which is byte-identical on every red
# anywhere: the subset test then found nothing our side had that main lacked and
# a BRAND-NEW finding inherited main's unrelated red. Vacuous, and vacuous in
# the dangerous direction.
# These two fixtures are the REAL logs, byte-for-byte including the ANSI colour:
#   main run 33968984175 job 101314071568 (the red main carried on 2026-09-05)
#   PR   run 33969823799 job 101316469061 (plugins3/writes-failclosed)
# Both report DOS.StringToAtom in lib/barkpark/content/validation.ex, at the
# same Sobelow-reported line (the normaliser erases the digits either way).
sob_main_log="$TMP/sob-main.log"; sob_ours_same="$TMP/sob-ours-same.txt"; sob_ours_diff="$TMP/sob-ours-diff.txt"
python3 - "$SEMI_STEP" "$sob_main_log" "$sob_ours_same" "$sob_ours_diff" <<'PY'
import io, sys
step = sys.argv[1]
job = "Sobelow static analysis (regression gate, baseline .sobelow-skips)"
E = "\x1b"
def w(path, lines):
    io.open(path, "w", encoding="utf-8").write("".join(l + "\n" for l in lines))
w(sys.argv[2], [
  "2026-09-05T13:29:19.4819840Z %s[32mDOS.StringToAtom: Unsafe `String.to_atom` - Low Confidence%s[0m" % (E, E),
  "2026-09-05T13:29:19.4821335Z File: lib/barkpark/content/validation.ex",
  "2026-09-05T13:29:19.4822496Z Line: 188",
  "2026-09-05T13:29:19.4823318Z Function: get_in_field:187",
  "2026-09-05T13:29:19.4823799Z Variable: key",
  "2026-09-05T13:29:20.0000000Z ##[error]Process completed with exit code 1.",
  "2026-09-05T13:29:21.0000000Z main-red-breaker: MAIN-FAILED-STEP in '%s': %s" % (job, step),
])
# the PR's own capture: the SAME finding, a later clock, the line drifted 188->190.
w(sys.argv[3], [
  "2026-09-05T13:48:00.0136121Z %s[32mDOS.StringToAtom: Unsafe `String.to_atom` - Low Confidence%s[0m" % (E, E),
  "2026-09-05T13:48:00.0137235Z File: lib/barkpark/content/validation.ex",
  "2026-09-05T13:48:00.0138180Z Line: 190",
  "2026-09-05T13:48:00.0138850Z Function: get_in_field:187",
  "2026-09-05T13:48:00.0139280Z Variable: key",
  "2026-09-05T13:48:22.0000000Z ##[error]Process completed with exit code 1.",
])
# a DIFFERENT finding, also real: PR #16339 run 34018729630 job 101448180182,
# SQL.Query in a function (relation_bytes) that does not exist on main at all.
w(sys.argv[4], [
  "2026-09-06T07:34:12.1245117Z %s[32mSQL.Query: SQL injection - Low Confidence%s[0m" % (E, E),
  "2026-09-06T07:34:12.1245818Z File: lib/barkpark/tenancy/workspace_bundle.ex",
  "2026-09-06T07:34:12.1246288Z Line: 972",
  "2026-09-06T07:34:12.1246669Z Function: relation_bytes:962",
  "2026-09-06T07:34:12.1247119Z Variable: sql",
  "2026-09-06T07:34:22.5925004Z ##[error]Process completed with exit code 1.",
])
PY
out="$(semi_run "$sob_main_log" "$sob_ours_same")"
has "$out" "INHERITED-FROM-MAIN" "21a) the SAME Sobelow finding on both sides inherits"
has "$out" "Signature matched too" "21a) and the signature was actually compared, not assumed"
has "$out" "RC=0" "21a) rc 0"
out="$(semi_run "$sob_main_log" "$sob_ours_diff")"
has "$out" "NOT with the same failure signature" "21b) a DIFFERENT Sobelow finding in the same step is the PR's own"
has "$out" "workspace_bundle.ex" "21b) and it prints the finding that differs"
has "$out" "RC=1" "21b) rc 1"
case "$out" in *INHERITED-FROM-MAIN*) bad "21b) waved a fresh Sobelow finding through as inherited" ;; *) ok "21b) does not inherit a fresh finding" ;; esac

# 19h. MUTATION on M5's walk-back: always take the newest informative run (the
#      pre-M5 selection) -> arm 20 must stop inheriting.
if mutate "19h M5 run walk-back" 'if job_executed "$MAIN_JOBS" "$JOB_NAME"; then' 'if true; then' 1; then
  ( out="$(walk_run "$TMP/mut-subject.sh")"
    case "$out" in *INHERITED-FROM-MAIN*) echo "  FAIL  19h) MUTATION SURVIVED: still inherited with the walk-back removed"; exit 1 ;; *) echo "  PASS  19h) without the walk-back the SKIPPED job is taken and arm 20 breaks — the arm is not vacuous" ;; esac ) || FAIL=$((FAIL+1))
  [ $? -eq 0 ] && PASS=$((PASS+1))
fi
# 19i. MUTATION on the Sobelow fold: make the finding header unmatchable (the
#      pre-M5 normaliser) -> arm 21b must stop calling the fresh finding OWN,
#      because both sides collapse to `Process completed with exit code #`.
if mutate "19i Sobelow finding-shape fold" "SOBELOW = re.compile(r'^[A-Z][A-Za-z0-9]*\.[A-Za-z0-9_]+:\s.+\s-\s(?:High|Medium|Low) Confidence\s*\$')" "SOBELOW = re.compile(r'^(?!x)x')" 1; then
  ( SUBJECT="$TMP/mut-subject.sh"; out="$(semi_run "$sob_main_log" "$sob_ours_diff")"
    case "$out" in *"NOT with the same failure signature"*) echo "  FAIL  19i) MUTATION SURVIVED: still caught the fresh finding without the fold"; exit 1 ;; *) echo "  PASS  19i) without the Sobelow fold a BRAND-NEW finding inherits main's red — the fold is load-bearing, arm 21b is not vacuous" ;; esac ) || FAIL=$((FAIL+1))
  [ $? -eq 0 ] && PASS=$((PASS+1))
fi

# ── 22. M6 — A RED THE HOST CAUSED IS NEITHER INHERITED NOR OWN ─────────────
# (task-572a62485cb1f8da; the measurement is task-f21e6a627ca13ef8's.)
# compose-smoke's green/refusal arms die intermittently at BEAM boot with
# `sys_sigaltstack(): Internal error: Failed to set alternate signal stack`.
# It is a HOST property: every crash since the hardware census step landed ran
# on INTEL(R) XEON(R) PLATINUM 8573C (34020171927, 34020897938, 34020905909),
# 0 of 7 clean census runs did; over 85 runs, 9 of 16 in Azure westus3+
# centralus crashed and 0 of 69 elsewhere. Six PR runs were told the red was
# theirs — and TWO of the three accused arms took the PASSED path, which never
# compares signatures at all. So the check cannot live inside the signature
# clause: it has to run BEFORE both attribution routes, on this PR's own body.
#
# The capture below is the REAL one, verbatim from run 33981944988's job
# 'Smoke arms (census, green boot, refusal boot — one image build)', step
# 'Green arm (compose up → healthy → exec wget /api/schemas + /login)'.
RL_DATA="$ROOT/scripts/main-red-breaker.runner-local.json"
sigalt_cap="$TMP/our-sigaltstack.txt"; cat > "$sigalt_cap" <<'L'
2026-09-05T17:48:38.4918340Z »» green arm: waiting up to 600s for the api healthcheck (first boot = migrations + seeds)
2026-09-05T17:48:38.7472355Z ── api container logs ──
2026-09-05T17:48:38.7599882Z sys/unix/sys_signal_stack.c:101:sys_sigaltstack(): Internal error: Failed to set alternate signal stack
2026-09-05T17:48:38.7600992Z Aborted (core dumped)
2026-09-05T17:48:38.7601807Z sys/unix/sys_signal_stack.c:101:sys_sigaltstack(): Internal error: Failed to set alternate signal stack
2026-09-05T17:48:38.7603582Z ────────────────────────
2026-09-05T17:48:38.7604555Z FAIL  green arm: api container is not cleanly running (running=true restarts=1 health=starting) — with valid generated secrets a boot must never crash or restart
2026-09-05T17:48:38.7605263Z »» cleanup: docker compose -p bp-smoke-green down
2026-09-05T17:48:39.1238005Z ##[error]Process completed with exit code 1.
L
# The SAME step failing for a reason the tree owns: same wording, same shape,
# NO sigaltstack lines. Nothing about this may change.
plain_cap="$TMP/our-plain-greenarm.txt"; cat > "$plain_cap" <<'L'
2026-09-05T17:48:38.4918340Z »» green arm: waiting up to 600s for the api healthcheck (first boot = migrations + seeds)
2026-09-05T17:48:38.7472355Z ── api container logs ──
2026-09-05T17:48:38.7599882Z ** (Mix) Could not start application barkpark: exited in: Barkpark.Application.start(:normal, [])
2026-09-05T17:48:38.7603582Z ────────────────────────
2026-09-05T17:48:38.7604555Z FAIL  green arm: api container is not cleanly running (running=true restarts=1 health=starting) — with valid generated secrets a boot must never crash or restart
2026-09-05T17:48:39.1238005Z ##[error]Process completed with exit code 1.
L
# An entry with the RIGHT pattern and no date, no measurement. The tripwire: an
# allowlist that grows stops discriminating, so an entry that cannot say WHEN
# and HOW it was measured must buy its author nothing at all.
bad_data="$TMP/runner-local-bad.json"; cat > "$bad_data" <<'J'
{"signatures":[{"id":"undated-sigaltstack","pattern":"sys_sigaltstack\\(\\): Internal error: Failed to set alternate signal stack"}]}
J
rl_run() { # $1 outcomes, $2 main jobs fixture, $3 OUR capture, $4 MAIN job log (or ""), $5 data file, $6 subject override
  ( export PATH="$TMP/bin:$PATH" STEP_OUTCOMES="$1" STEP_NAMES="$NAMES" JOB_NAME="Doc budgets + anchors" \
      WORKFLOW_FILE="compose-smoke.yml" GITHUB_EVENT_NAME=pull_request GITHUB_REPOSITORY=o/r GITHUB_TOKEN=t \
      GITHUB_STEP_SUMMARY="$TMP/summary.md" MAIN_RED_BREAKER_FIXTURE="$2" BREAKER_ERROR_LOG="$3" \
      MAIN_RED_BREAKER_RUNNER_LOCAL_DATA="$5"
    [ -n "${4:-}" ] && export MAIN_RED_BREAKER_LOG_FIXTURE="$4"
    bash "${6:-$SUBJECT}" 2>&1; echo "RC=$?" )
}
# 22a. THE PASSED PATH — main RAN this step and PASSED it. This is the branch
#      that accused runs 34018218144 and 34018443211, and it reaches its verdict
#      without ever reading an error message.
out="$(rl_run "$out_s2" "$main_green" "$sigalt_cap" "" "$RL_DATA")"
has "$out" "RUNNER-LOCAL" "22a) real sigaltstack capture + main GREEN on the step => RUNNER-LOCAL"
has "$out" "beam-sigaltstack-boot-abort" "22a) names the data-file entry that matched"
has "$out" "PLATINUM 8573C" "22a) and the host measurement that justified the entry"
has "$out" "task-572a62485cb1f8da" "22a) and the row that filed it"
has "$out" "::warning" "22a) a warning annotation, so it is not silently green"
has "$out" "RC=0" "22a) rc 0 — a host crash does not red the PR's check"
case "$out" in *"the red is this PR's own"*|*"a step main does not"*) bad "22a) ACCUSED THE PR of a runner-local crash" ;; *) ok "22a) makes no ownership claim against the PR" ;; esac
case "$out" in *INHERITED-FROM-MAIN*) bad "22a) claimed INHERITED — it is neither" ;; *) ok "22a) does not claim INHERITED either" ;; esac
# 22a2. THE SIGNATURE PATH — main is red on the very same step, with a different
#       failure body (crash log lines vary run to run: that is how run
#       34019839592 was accused). Same verdict, and no comparison was needed.
out="$(rl_run "$out_s2" "$main_red_s2" "$sigalt_cap" "$main_log_15650" "$RL_DATA")"
has "$out" "RUNNER-LOCAL" "22a2) same step red on main with a DIFFERENT body => still RUNNER-LOCAL"
has "$out" "RC=0" "22a2) rc 0"
case "$out" in *"NOT with the same failure signature"*) bad "22a2) fell through to the signature clause and blamed the PR" ;; *) ok "22a2) settled before the signature comparison" ;; esac
# 22b. THE CONTROL — the same step, the same wording, WITHOUT the signature.
#      Attributed exactly as before this change. If this ever stops failing, M6
#      has become an 'ignore compose-smoke' switch.
out="$(rl_run "$out_s2" "$main_green" "$plain_cap" "" "$RL_DATA")"
has "$out" "failed on a step main does not" "22b) no signature => attributed exactly as today"
has "$out" "RC=1" "22b) rc 1"
case "$out" in *RUNNER-LOCAL*) bad "22b) excused a red that carries no runner-local signature" ;; *) ok "22b) does not excuse an unsigned red" ;; esac
# 22c. THE TRIPWIRE — an entry with the right pattern but no date and no
#      measurement is REFUSED, and it buys nothing: the red is attributed
#      exactly as it would have been with no data file at all.
out="$(rl_run "$out_s2" "$main_green" "$sigalt_cap" "" "$bad_data")"
has "$out" "REFUSED entry 'undated-sigaltstack'" "22c) an entry with no date/measurement is refused by name"
has "$out" "no ISO date" "22c) and says the date is missing"
has "$out" "no measurement" "22c) and says the measurement is missing"
has "$out" "failed on a step main does not" "22c) the refused entry suppresses nothing"
has "$out" "RC=1" "22c) rc 1"
case "$out" in *"RUNNER-LOCAL —"*) bad "22c) a dateless, measurement-free entry silenced an accusation" ;; *) ok "22c) the allowlist cannot be widened without a measurement" ;; esac
# 22d. ORDERING AS A TEXTUAL INVARIANT. 22a/22a2 pass only because the M6 block
#      runs before BOTH attribution routes; a later refactor could move it and
#      still leave those arms green on one path. Pin the order in the file.
rl_ln="$(grep -n 'RUNNER-LOCAL — ' "$SUBJECT" | head -1 | cut -d: -f1)"
own_ln="$(grep -n "failed on a step main does not" "$SUBJECT" | tail -1 | cut -d: -f1)"
sig_ln="$(grep -n "NOT with the same failure signature" "$SUBJECT" | tail -1 | cut -d: -f1)"
if [ -n "$rl_ln" ] && [ "$rl_ln" -lt "$own_ln" ] && [ "$rl_ln" -lt "$sig_ln" ]; then ok "22d) the RUNNER-LOCAL verdict (line $rl_ln) precedes BOTH the PASSED path ($own_ln) and the signature path ($sig_ln)"; else bad "22d) the RUNNER-LOCAL verdict does not precede both attribution routes (rl=$rl_ln passed=$own_ln sig=$sig_ln)"; fi
# 22e. every shipped entry carries a date and a measurement — the data file the
#      repo ships must itself pass the loader's tripwire.
python3 - "$RL_DATA" <<'PY' && ok "22e) every entry in the shipped data file carries an ISO date and a measurement" || bad "22e) the shipped data file has an entry the loader would refuse"
import json, re, sys
d = json.load(open(sys.argv[1]))
sigs = d["signatures"]
assert sigs, "no signatures"
for e in sigs:
    assert re.match(r'^\d{4}-\d{2}-\d{2}$', e.get("date", "")), e.get("id")
    assert len(e.get("measurement", "")) >= 40, e.get("id")
    assert e.get("pattern"), e.get("id")
    re.compile(e["pattern"])
PY

# 19j. MUTATION — delete the check IN THE WRONG DIRECTION: make the signature
#      match everything. 22b must go red, i.e. an ordinary red gets excused.
if mutate "19j runner-local signature match" '        if rx.search(body):' '        if True:' 1; then
  ( out="$(rl_run "$out_s2" "$main_green" "$plain_cap" "" "$RL_DATA" "$TMP/mut-subject.sh")"
    case "$out" in *RUNNER-LOCAL*) echo "  PASS  19j) matching everything excuses a red with no signature — 22b is not vacuous" ;; *) echo "  FAIL  19j) MUTATION SURVIVED: still attributed the unsigned red"; exit 1 ;; esac ) || FAIL=$((FAIL+1))
  [ $? -eq 0 ] && PASS=$((PASS+1))
fi
# 19k. MUTATION — remove the RUNNER-LOCAL verdict entirely. 22a must go back to
#      the sentence that accused four PRs.
if mutate "19k runner-local verdict" 'if [ -n "$RL_ID" ]; then' 'if false; then' 1; then
  ( out="$(rl_run "$out_s2" "$main_green" "$sigalt_cap" "" "$RL_DATA" "$TMP/mut-subject.sh")"
    case "$out" in *"a step main does not"*) echo "  PASS  19k) without the verdict the sigaltstack crash is blamed on the PR — 22a is not vacuous" ;; *) echo "  FAIL  19k) MUTATION SURVIVED: still refused to blame"; exit 1 ;; esac ) || FAIL=$((FAIL+1))
  [ $? -eq 0 ] && PASS=$((PASS+1))
fi
# 19l. MUTATION — drop the date/measurement tripwire. 22c must go red: the
#      undated entry would then silence a real accusation.
if mutate "19l runner-local data tripwire" '    if why:' '    if False:' 1; then
  ( out="$(rl_run "$out_s2" "$main_green" "$sigalt_cap" "" "$bad_data" "$TMP/mut-subject.sh")"
    case "$out" in *RUNNER-LOCAL*) echo "  PASS  19l) without the tripwire an undated entry DOES suppress the accusation — 22c is not vacuous" ;; *) echo "  FAIL  19l) MUTATION SURVIVED: the undated entry still bought nothing"; exit 1 ;; esac ) || FAIL=$((FAIL+1))
  [ $? -eq 0 ] && PASS=$((PASS+1))
fi

echo; echo "main-red-breaker.test.sh: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
