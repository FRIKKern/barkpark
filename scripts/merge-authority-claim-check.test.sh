#!/usr/bin/env bash
#
# merge-authority-claim-check.test.sh — the mutation harness for
# scripts/merge-authority-claim-check.sh, and the file that PROVES the guard is
# not a fourth phantom.
#
# A guard nobody ever watched fail is a claim, not a check. This harness makes
# the failure happen on every run, in the two places a merge-authority guard can
# be vacuous:
#
#   § A. THE PROBE-RE-EXEC VACUITY (cgsiw-bl-verify-probe-reexec-vacuity).
#        required-checks-verify.sh's own probe re-execs the ABSOLUTE path
#        "$REPO_ROOT/scripts/required-checks-verify.sh", never "$0" — so a
#        DISARMED COPY of that file still prints SELFTEST OK, and the copy's
#        selftest is measuring the pristine original. Here the proof is run, not
#        promised: this harness copies the guard to a RENAMED SIBLING inside
#        scripts/, disarms the copy with sed, runs THE COPY's --selftest, and
#        REQUIRES it to red — then runs the pristine original's --selftest in the
#        same breath and requires it to stay green. Three separate disarms, each
#        hitting a different load-bearing part of the scan, because a single
#        mutation only proves that one line matters.
#
#   § B. THE VENUE. A merge-authority guard mounted on a context that cannot
#        stop a merge is the exact disease it exists to catch. These assertions
#        read .github/workflows/elixir.yml and .github/required-checks.json and
#        require, mechanically: the guard runs as a STEP of the `path-escape`
#        job; `path-escape` is in `elixir-gate`'s `needs`; `elixir-gate` renders
#        `Elixir gate`, which .github/required-checks.json lists as required;
#        elixir.yml carries no workflow-level `on: … paths:` key; `path-escape`
#        carries neither `if:` nor `continue-on-error:`; and the guard appears
#        in NO step of doc-gates.yml, whose context is an S4 PATHS-FILTERED
#        exclusion row and therefore cannot stop anything.
#
# It deliberately does NOT re-implement the scan (cgsi-s3: a link-lint selftest
# greened with its gate fully disarmed because it had re-typed the logic it was
# proving). Everything about scanning is delegated to the guard's own
# --selftest; this file only mutates and observes.
#
#   bash scripts/merge-authority-claim-check.test.sh
#
# An unknown flag exits 2 with a named usage line, for the reason the subject
# file states: the neighbouring harness on this very job swallows one at rc=0.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/.." && pwd)"
SUBJECT="$HERE/merge-authority-claim-check.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/elixir.yml"
DOC_GATES="$REPO_ROOT/.github/workflows/doc-gates.yml"
SPEC="$REPO_ROOT/.github/required-checks.json"

usage() {
  cat >&2 <<'USAGE'
usage: merge-authority-claim-check.test.sh
  no flags. Runs the disarm proofs against a renamed sibling copy of
  scripts/merge-authority-claim-check.sh, then the venue assertions.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *)
      echo "merge-authority-claim-check.test.sh: unknown flag '$1' — refusing to run" >&2
      usage
      exit 2
      ;;
  esac
done

pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok   - $1"; }
no() { fail=$((fail + 1)); echo "FAIL - $1" >&2; }

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then ok "$label"; else no "$label: wanted '$want', got '$got'"; fi
}

[ -f "$SUBJECT" ] || { echo "FAIL - subject $SUBJECT is missing" >&2; exit 1; }
[ -f "$WORKFLOW" ] || { echo "FAIL - $WORKFLOW is missing" >&2; exit 1; }
[ -f "$SPEC" ] || { echo "FAIL - $SPEC is missing" >&2; exit 1; }

# ── § A — THE DISARM PROOFS ──────────────────────────────────────────────────
# The copy lands INSIDE scripts/ under a name of its own, so it resolves HERE
# and REPO_ROOT exactly as the original does. Anything less and the proof is
# about a different file living somewhere else.
COPY=""
# An `&&` one-liner here would leave the EXIT trap returning 1 when COPY is
# already cleared, and bash would hand that back as the harness exit code — a
# green run reporting red.
cleanup() { if [ -n "$COPY" ]; then rm -f "$COPY"; fi; }
trap cleanup EXIT

# LITERAL substitution, done in python3 (already a hard dependency of the
# subject) rather than sed: no BSD-vs-GNU `-i` split, and no regex escaping
# between this file and the line it is mutating — the disarm says exactly which
# bytes it replaces, and refuses if they are not there.
disarm_proof() {
  local label="$1" old="$2" new="$3"
  COPY="$HERE/_merge_authority_disarmed_probe_$$.sh"
  cp "$SUBJECT" "$COPY"
  python3 -c '
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path, encoding="utf-8").read()
if src.count(old) != 1:
    sys.stderr.write("disarm target appears %d times, wanted exactly 1\n" % src.count(old))
    sys.exit(1)
open(path, "w", encoding="utf-8").write(src.replace(old, new))
' "$COPY" "$old" "$new" || {
    no "$label: could not apply the disarm (the target bytes are gone — this proof is stale)"
    rm -f "$COPY"; COPY=""
    return
  }
  if cmp -s "$SUBJECT" "$COPY"; then
    no "$label: the disarm changed NOTHING — the expression no longer matches the guard, so this proof was measuring an unmutated copy"
    rm -f "$COPY"; COPY=""
    return
  fi
  if bash "$COPY" --selftest >/dev/null 2>&1; then
    no "$label: the DISARMED COPY still passed its own --selftest (this is exactly the probe-re-exec vacuity)"
  else
    ok "$label: the disarmed copy reds its OWN --selftest"
  fi
  rm -f "$COPY"; COPY=""
}

echo "== § A. disarm proofs (a renamed sibling copy, disarmed, must red) =="

# A1. Neuter the STRONG vocabulary. Every `(blocking)` fixture must stop firing.
disarm_proof "A1 strong vocabulary neutered" \
  'r"(?:\(blocking\)"' \
  'r"(?:@@NEVER@@"'

# A2. Neuter the WIDE-tier conjunction by making the merge object unmatchable.
#     The five widened-vocabulary fixtures depend on it.
disarm_proof "A2 wide-tier merge object neutered" \
  'r"(?:(?<![A-Za-z])merges?(?![A-Za-z])|(?<![A-Za-z])merging(?![A-Za-z])"' \
  'r"(?:@@NEVER@@"'

# A3. Neuter the SPEC READ — pretend every file is authoritative. Every denied
#     scope would then resolve, and the guard would have no opinion at all.
disarm_proof "A3 spec-derived authority neutered" \
  'file_authoritative = bool(authoritative)' \
  'file_authoritative = True'

# A4. THE CONTROL. The pristine original, run at the same moment, must be GREEN
#     — otherwise the three reds above prove nothing about the mutation.
if bash "$SUBJECT" --selftest >/dev/null 2>&1; then
  ok "A4 the pristine original passes its own --selftest at the same moment"
else
  no "A4 the pristine original FAILED its own --selftest — the disarm proofs above are meaningless"
fi

# A5. The guard's selftest must actually assert something. A harness of zero
#     cases is the vacuity one layer up.
st_cases="$(bash "$SUBJECT" --selftest 2>/dev/null | sed -n 's/^\([0-9][0-9]*\) passed.*/\1/p')"
if [ "${st_cases:-0}" -ge 15 ]; then
  ok "A5 the guard --selftest runs ${st_cases} assertions"
else
  no "A5 the guard --selftest runs only ${st_cases:-0} assertions"
fi

# ── § B — THE VENUE ──────────────────────────────────────────────────────────
echo
echo "== § B. venue (the guard must ride a context that can stop a merge) =="

# B1. The guard is invoked by a STEP of elixir.yml, and inside `path-escape`.
step_job="$(awk '
  /^  [a-z-]+:[ \t]*$/ { job = $0; sub(/^  /, "", job); sub(/:.*$/, "", job) }
  /merge-authority-claim-check/ { print job }
' "$WORKFLOW" | sort -u | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "B1 the guard is invoked from elixir.yml job 'path-escape'" "path-escape" "$step_job"

# B2. It is a STEP, never a JOB. A new job would red the sibling ratchets
#     (blocking_not_in_needs) and would add a rendered check name to the roster.
job_named="$(grep -c '^  merge-authority[a-z-]*:' "$WORKFLOW" || true)"
assert_eq "B2 no new JOB was added for it" "0" "$job_named"

# B3. `path-escape` is in `elixir-gate`'s needs — that is what carries the red
#     into the required context.
needs_line="$(awk '/^  elixir-gate:/ { g = 1 } g && /^    needs:/ { print; exit }' "$WORKFLOW")"
case "$needs_line" in
  *path-escape*) ok "B3 path-escape is in elixir-gate needs: $needs_line" ;;
  *) no "B3 path-escape is NOT in elixir-gate needs (read: '$needs_line')" ;;
esac

# B4. The aggregator renders `Elixir gate`, and the committed spec REQUIRES it.
gate_name="$(awk '/^  elixir-gate:/ { g = 1 } g && /^    name:/ { sub(/^    name:[ \t]*/, ""); print; exit }' "$WORKFLOW")"
assert_eq "B4a elixir-gate renders the constant name" "Elixir gate" "$gate_name"
if grep -q '"context": "Elixir gate"' "$SPEC"; then
  ok "B4b .github/required-checks.json lists 'Elixir gate' as a required context"
else
  no "B4b 'Elixir gate' is NOT in the committed required set — the venue claim is false"
fi

# B5. path-escape carries the gate value NEVER in the aggregator's decide body,
#     so it cannot be skipped into a green.
if grep 'decide "path-escape ratchet"' "$WORKFLOW" | grep -q 'NEVER'; then
  ok "B5 the aggregator judges path-escape with gate value NEVER"
else
  no "B5 the aggregator no longer judges path-escape with gate value NEVER"
fi

# B6. path-escape is unfiltered and blocking: no job-level `if:`, no
#     continue-on-error. Either one would make this whole venue a lie.
pe_body="$(awk '/^  path-escape:/ { p = 1; next } p && /^  [a-z-]+:[ \t]*$/ { exit } p' "$WORKFLOW")"
if printf '%s\n' "$pe_body" | grep -qE '^    (if|continue-on-error):'; then
  no "B6 path-escape gained an 'if:' or 'continue-on-error:' — it can now go dark or launder a red"
else
  ok "B6 path-escape carries no job-level 'if:' and no continue-on-error"
fi

# B7. elixir.yml carries no workflow-level `on: … paths:` key — the rule its own
#     header states as an absolute. A paths filter emits NO check run at all.
on_body="$(awk '/^on:/ { o = 1; next } o && /^[a-zA-Z]/ { exit } o' "$WORKFLOW")"
if printf '%s\n' "$on_body" | grep -qE '^[ \t]+paths(-ignore)?:'; then
  no "B7 elixir.yml gained a workflow-level paths filter — the required context can now be ABSENT, which reports 'expected' forever"
else
  ok "B7 elixir.yml carries no workflow-level 'paths:' key"
fi

# B8. NOT in doc-gates.yml. Its context is an S4 PATHS-FILTERED exclusion row,
#     so a guard landed there joins the dead ones.
if [ -f "$DOC_GATES" ] && grep -q 'merge-authority-claim-check' "$DOC_GATES"; then
  no "B8 the guard is wired into doc-gates.yml, whose context 'Doc budgets + anchors' is an S4 exclusion and cannot stop a merge"
else
  ok "B8 the guard is not wired into doc-gates.yml"
fi

# B9. The step ids on path-escape must stay unique — `selftest` and `ratchet`
#     are already taken on that job elsewhere in the fleet's conventions.
dupe_ids="$(printf '%s\n' "$pe_body" | sed -n 's/^ *id: *//p' | sort | uniq -d | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "B9 no duplicate step ids on path-escape" "" "$dupe_ids"

# B10. And the guard itself must be green on this tree, or the step is a red
#      nobody meant to ship.
if bash "$SUBJECT" >/dev/null 2>&1; then
  ok "B10 the guard is green on this tree at its committed baseline"
else
  no "B10 the guard is RED on this tree"
fi

echo
echo "----"
echo "$pass passed, $fail failed"
if [ "$fail" -eq 0 ]; then exit 0; fi
exit 1
