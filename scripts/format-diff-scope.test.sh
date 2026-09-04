#!/usr/bin/env bash
#
# format-diff-scope.test.sh — the harness for the DIFF-SCOPED FORMAT VERDICT
# (task-e31b816b4b416db6), end to end: the reader, the workflow wiring that
# feeds it, and the `Elixir gate` Decide step that publishes its answer.
#
# WHAT MAKES THIS MORE THAN scripts/format-diff-scope.sh --selftest.
# The selftest proves the READER is right. It cannot prove the reader is
# REACHED. Three separate things have to hold for a touched unformatted file to
# actually red the required context, and each of them has failed in this repo
# before:
#
#   1. the reader decides correctly                (--selftest, re-run here)
#   2. the FORMAT JOB is wired so its verdict is the job's exit status —
#      the guard step captured (continue-on-error) and the scope step deciding,
#      with no continue-on-error at JOB level (which would launder the red)
#   3. the AGGREGATOR judges that job — in `needs`, bound to an env var, and
#      passed to `decide` — and its ::error:: NAMES THE FILE
#
# Part 3 is executed, not read: the real `Elixir gate` Decide step body is
# extracted out of the committed elixir.yml and run under a stub environment,
# so an assertion here is about the code that will run in CI, never about a
# paraphrase of it.
#
# THE ONE FACT THE WHOLE FILE EXISTS FOR, and it is a PAIR — the same
# unformatted state, two diffs:
#     touched   -> the gate REDS and the error names the file
#     untouched -> the gate is GREEN and the file is merely printed
# A harness that only proved the red would pass just as happily on a gate that
# reds on everything, which is the permanently-red advisory job this slice
# replaced.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WF="${FORMAT_DIFF_SCOPE_TEST_WORKFLOW:-$ROOT/.github/workflows/elixir.yml}"
SCOPE="$ROOT/scripts/format-diff-scope.sh"
TMP="$(mktemp -d -t format-diff-scope-test.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "  ok   — $1"; }
no() { fail=$((fail + 1)); echo "  FAIL — $1"; }
says()  { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 — never said '$3'" ;; esac; }
mute()  { case "$2" in *"$3"*) no "$1 — it DID say '$3'" ;; *) ok "$1" ;; esac; }

echo "=== A. the reader itself (its own mutation matrix, re-run in this lane) ==="
if out="$(bash "$SCOPE" --selftest 2>&1)"; then
  ok "format-diff-scope.sh --selftest passes ($(printf '%s' "$out" | grep -c '^  ok') cases)"
else
  no "format-diff-scope.sh --selftest FAILED:"; printf '%s\n' "$out" | sed 's/^/        /'
fi
echo

echo "=== B. the format job's wiring — the verdict must be able to reach the job's exit status ==="
FACTS="$TMP/facts.txt"
python3 - "$WF" "$FACTS" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1])); out = open(sys.argv[2], "w")
def emit(k, v): out.write(f"{k}={v}\n")
jobs = wf["jobs"]; fmt = jobs.get("format", {})
emit("format_present", bool(fmt))
emit("format_coe", fmt.get("continue-on-error") is True)
emit("format_if", str(fmt.get("if", "")))
emit("format_outputs", ",".join(sorted(fmt.get("outputs", {}))))
steps = fmt.get("steps", [])
guard = next((s for s in steps if s.get("id") == "guard"), {})
scope = next((s for s in steps if s.get("id") == "scope"), {})
emit("guard_present", bool(guard)); emit("guard_coe", guard.get("continue-on-error") is True)
emit("scope_present", bool(scope)); emit("scope_coe", scope.get("continue-on-error") is True)
emit("scope_if", str(scope.get("if", "")))
emit("scope_calls_reader", "format-diff-scope.sh" in str(scope.get("run", "")))
emit("scope_index_after_guard", steps.index(scope) > steps.index(guard) if guard and scope else False)
# the selftest of the reader must ride the same job
emit("job_runs_reader_selftest",
     any("format-diff-scope.sh --selftest" in str(s.get("run", "")) for s in steps))
agg = jobs.get("elixir-gate", {})
emit("agg_needs_format", "format" in agg.get("needs", []))
step = next((s for s in agg.get("steps", []) if "run" in s), {})
env = step.get("env") or {}
emit("agg_binds_result", any(str(v) == "${{ needs.format.result }}" for v in env.values()))
emit("agg_binds_names",
     any("needs.format.outputs.unformatted_in_diff" in str(v) for v in env.values()))
emit("agg_decides_format", 'decide "format (diff-scoped)"' in str(step.get("run", "")))
out.close()
PY
fact() { sed -n "s|^$1=||p" "$FACTS"; }
want() { if [ "$(fact "$1")" = "$2" ]; then ok "$1 = $2"; else no "$1 = '$(fact "$1")', wanted '$2'"; fi; }
want format_present True
# THE ORDER IS THE RULE: coe had to go BEFORE `format` could enter the
# aggregator's needs, because needs.<job>.result reads `success` for a FAILED
# coe job. Both halves are asserted, so neither can be reintroduced alone.
want format_coe False
want format_if "needs.changes.outputs.compile == 'true'"
want format_outputs "unformatted_in_diff,unformatted_total"
want guard_present True
want guard_coe True      # the WHOLE-TREE read is data, never the verdict
want scope_present True
want scope_coe False     # …and the DIFF-SCOPED read is the verdict
want scope_if "always()" # a failing guard must not skip the step that scopes it
want scope_calls_reader True
want scope_index_after_guard True
want job_runs_reader_selftest True
want agg_needs_format True
want agg_binds_result True
want agg_binds_names True
want agg_decides_format True
echo

echo "=== C. THE PAIR — the REAL Decide step, executed, on one unformatted state ==="
STEP="$TMP/decide.sh"
python3 - "$WF" "$STEP" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = next(s for s in wf["jobs"]["elixir-gate"]["steps"] if "run" in s)
open(sys.argv[2], "w").write(step["run"])
PY
[ -s "$STEP" ] && ok "extracted the real Decide step body ($(wc -l < "$STEP" | tr -d ' ') lines)" \
                || no "the Decide step body extracted EMPTY — every case below would be a straw man"

OUT="$TMP/decide.out"
decide() { # decide <R_FORMAT> <F_IN_DIFF>; leaves rc in $rc, output in $OUT
  env -i PATH="$PATH" HOME="$HOME" \
    R_CHANGES=success R_TEST=success R_PROD=success R_PERF=success R_ESCAPE=success \
    R_FORMAT="$1" F_IN_DIFF="$2" O_COMPILE=true O_TEST=true \
    bash --noprofile --norc "$STEP" >"$OUT" 2>&1 && rc=0 || rc=$?
}
F=api/lib/barkpark/content/papers/block_ops.ex

# C1 — THE RED. The PR touched block_ops.ex and it is unformatted: the format
#      job failed, so the gate reds, AND the ::error:: names the file.
decide failure "$F"
[ "$rc" = 1 ] && ok "C1 a diff-scoped format failure REDS the Elixir gate (exit 1)" \
              || no "C1 expected exit 1, got $rc: $(cat "$OUT")"
o="$(cat "$OUT")"
says "C1 …the error names the format arm"        "$o" "format (diff-scoped)"
says "C1 …the ::error:: NAMES THE FILE"          "$o" "::error::"
says "C1 …and the filename is in it, not just 'format failed'" "$o" "$F"
mute "C1 …no reassuring 'nothing ran' notice"    "$o" "::notice"

# C2 — THE NEUTRAL, and the reason this is not just "a gate that reds". SAME
#      unformatted file on main, but this PR does not touch it: the format job
#      succeeded and named nothing, so the gate is GREEN.
decide success ""
[ "$rc" = 0 ] && ok "C2 inherited drift the diff never touched leaves the gate GREEN (exit 0)" \
              || no "C2 expected exit 0, got $rc: $(cat "$OUT")"
o="$(cat "$OUT")"
says "C2 …and it says so"                        "$o" "format (diff-scoped): success"
mute "C2 …the gate emits no ::error::"           "$o" "::error::"
mute "C2 …and never names a file it is not enforcing" "$o" "$F"

# C3 — push:main. No PR diff exists, so nothing is diff-scoped: the format job
#      prints the standing debt and succeeds. Main is where the debt is VISIBLE,
#      never where it is enforced.
decide success ""
[ "$rc" = 0 ] && ok "C3 push:main (no PR diff) is neutral — the gate does not red on standing debt" \
              || no "C3 expected exit 0, got $rc"

# C4 — the format job SKIPPED. Legitimate only when the dispatcher said this
#      path set was untouched; on a compile=true diff a skip means it never ran.
env -i PATH="$PATH" HOME="$HOME" \
  R_CHANGES=success R_TEST=skipped R_PROD=skipped R_PERF=skipped R_ESCAPE=success \
  R_FORMAT=skipped F_IN_DIFF= O_COMPILE=false O_TEST=false \
  bash --noprofile --norc "$STEP" >"$OUT" 2>&1 && rc=0 || rc=$?
[ "$rc" = 0 ] && ok "C4 a docs-only diff legitimately skips format (gate='false') — green" \
              || no "C4 expected exit 0, got $rc: $(cat "$OUT")"
env -i PATH="$PATH" HOME="$HOME" \
  R_CHANGES=success R_TEST=success R_PROD=success R_PERF=success R_ESCAPE=success \
  R_FORMAT=skipped F_IN_DIFF= O_COMPILE=true O_TEST=true \
  bash --noprofile --norc "$STEP" >"$OUT" 2>&1 && rc=0 || rc=$?
[ "$rc" = 1 ] && ok "C5 format SKIPPED while its gate is 'true' is RED — it never ran" \
              || no "C5 expected exit 1, got $rc: $(cat "$OUT")"
says "C5 …and the gate names format as the offender" "$(cat "$OUT")" "format (diff-scoped)"

# C6 — a cancelled format arm keeps the cancellation vocabulary (charter D57):
#      a superseded head must not send anyone to read a diff that is fine.
decide cancelled ""
[ "$rc" = 1 ] && ok "C6 a CANCELLED format arm is red" || no "C6 expected exit 1, got $rc"
says "C6 …and is told apart from a failure" "$(cat "$OUT")" "cancelled, not failed"
echo

echo "=== D. mutation: unwire the arm and the pair must STOP holding ==="
# A green in C is only evidence if a broken wiring would have been caught. Two
# mutants of the REAL step, each removing one link of needs -> env -> decide.
MUT="$TMP/mutant.sh"
sed '/decide "format (diff-scoped)"/d' "$STEP" > "$MUT"
if ! grep -q 'decide "format (diff-scoped)"' "$MUT" && [ "$(wc -l < "$MUT")" -lt "$(wc -l < "$STEP")" ]; then
  ok "D0 the mutation APPLIED (the decide line is gone, the body is shorter)"
else
  no "D0 the mutation did NOT apply — every case below is vacuous"
fi
env -i PATH="$PATH" HOME="$HOME" \
  R_CHANGES=success R_TEST=success R_PROD=success R_PERF=success R_ESCAPE=success \
  R_FORMAT=failure F_IN_DIFF="$F" O_COMPILE=true O_TEST=true \
  bash --noprofile --norc "$MUT" >"$OUT" 2>&1 && rc=0 || rc=$?
if [ "$rc" = 0 ]; then
  ok "D1 without the decide line a FAILED format arm greens the gate — so C1 is a real catch"
else
  no "D1 the mutant still exited $rc; C1 proves nothing about the decide line"
fi
MUT2="$TMP/mutant2.sh"
sed 's/^\( *\)if \[ -n "\${F_IN_DIFF:-}" \]; then/\1if false; then/' "$STEP" > "$MUT2"
if grep -q 'if false; then' "$MUT2"; then ok "D2 the name-carrying mutation APPLIED"; else no "D2 mutation did not apply"; fi
env -i PATH="$PATH" HOME="$HOME" \
  R_CHANGES=success R_TEST=success R_PROD=success R_PERF=success R_ESCAPE=success \
  R_FORMAT=failure F_IN_DIFF="$F" O_COMPILE=true O_TEST=true \
  bash --noprofile --norc "$MUT2" >"$OUT" 2>&1 && rc=0 || rc=$?
if [ "$rc" = 1 ] && ! grep -qF "$F" "$OUT"; then
  ok "D3 without that branch the gate still reds but names NO file — so C1's name assertion is a real catch"
else
  no "D3 the mutant exited $rc and the filename presence did not flip"
fi
echo

echo "──────────────────────────────────────────────────────────────"
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
