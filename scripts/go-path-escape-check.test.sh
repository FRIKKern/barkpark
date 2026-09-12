#!/usr/bin/env bash
# go-path-escape-check.test.sh — the ratchet's INVOCATION SITE, not its scanner.
#
# THE BUG THIS EXISTS FOR (task-1ea38e8e7fe44e09)
#
# `.github/workflows/go-tests.yml`'s `Dispatch (Go paths)` job checks out the PR
# HEAD on purpose (D34), then runs the cross-tree read ratchet out of that head:
#
#     bash scripts/go-path-escape-check.sh --selftest
#     bash scripts/go-path-escape-check.sh --check
#
# The workflow FILE comes from the merge ref; the SCRIPT comes from the head. On
# any PR based before #16520 added the script, bash exits 127, the step reds,
# `Compute the changed-path set` is SKIPPED, and the PR gets NO Go path verdict
# — a dispatcher red naming nothing but "exit code 127". Measured 2026-09-06: 5
# of the last 100 pull_request runs (34048645176, 34048476784, 34048436433,
# 34048184595, 34048038989).
#
# WHAT THIS HARNESS DOES
#
# It EXTRACTS the step body out of the live go-tests.yml and EXECUTES it — so it
# cannot paraphrase what CI runs — against two heads:
#
#   * a head WITHOUT the script: the step must exit 0, the absence must be NAMED
#     on stdout as a ::warning carrying both shas, and the job summary must
#     carry it too. Silence and a bare pass are both failures here.
#   * a head WITH the script (this repo): the step must exit 0, must print the
#     selftest's own count line, must print the check's OK line, and must NOT
#     print the absence warning — i.e. present heads behave exactly as before.
#
# Then it MUTATES a copy of the workflow back to the pre-fix two-liner and
# proves the absent-head case goes RED (127) with no absence line. A harness
# that has never been shown to fail is not a harness, it is a green line.
#
# Exit 2 = HARNESS UNAVAILABLE (python3 or PyYAML missing). Never a pass.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$REPO_ROOT/.github/workflows/go-tests.yml"
STEP_NAME="Go cross-tree read ratchet (selftest, then check)"
RATCHET_REL="scripts/go-path-escape-check.sh"

PASS=0
FAIL=0
ok() { printf '  ok: %s\n' "$1"; PASS=$((PASS + 1)); }
no() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

command -v python3 >/dev/null 2>&1 || {
  echo "HARNESS-UNAVAILABLE: python3 not on PATH — the workflow is yaml-PARSED, not grepped." >&2
  exit 2
}
python3 -c 'import yaml' 2>/dev/null || {
  echo "HARNESS-UNAVAILABLE: PyYAML missing (pip install pyyaml). A harness that cannot read" >&2
  echo "its subject must not certify it." >&2
  exit 2
}
[ -f "$WF" ] || { echo "HARNESS-UNAVAILABLE: $WF not found" >&2; exit 2; }
[ -f "$REPO_ROOT/$RATCHET_REL" ] || {
  echo "HARNESS-UNAVAILABLE: $RATCHET_REL not in this tree — the WITH-the-script case has no subject." >&2
  exit 2
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/godispatchratchet.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

FAKE_HEAD="0123456789abcdef0123456789abcdef01234567"
FAKE_BASE="fedcba9876543210fedcba9876543210fedcba98"

# ── extraction ───────────────────────────────────────────────────────────────
# Fails loudly if the step is gone, renamed, or duplicated, rather than writing
# an empty file that would "pass" every case below.
extract_step() { # extract_step <workflow.yml> <dest.sh>
  python3 - "$1" "$2" "$STEP_NAME" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
steps = [s for j in wf["jobs"].values() for s in j.get("steps", [])
         if s.get("name") == sys.argv[3] and "run" in s]
if len(steps) != 1:
    sys.exit("expected exactly 1 step named %r with a run body, found %d"
             % (sys.argv[3], len(steps)))
open(sys.argv[2], "w").write(steps[0]["run"])
PY
}

# run_step <step.sh> <cwd> -> stdout+stderr in $OUT, summary in $SUMMARY
OUT="$TMPROOT/out.txt"
SUMMARY="$TMPROOT/summary.md"
run_step() {
  : >"$OUT"; : >"$SUMMARY"
  ( cd "$2" \
    && RATCHET="$RATCHET_REL" HEAD_SHA="$FAKE_HEAD" BASE_SHA="$FAKE_BASE" \
       GITHUB_STEP_SUMMARY="$SUMMARY" \
       bash "$1" ) >"$OUT" 2>&1
}

# ── fixtures ─────────────────────────────────────────────────────────────────
# A head that predates #16520: a tree with the workflow but NO scripts/ ratchet.
STALE="$TMPROOT/stale-head"
mkdir -p "$STALE/scripts" "$STALE/.github/workflows" "$STALE/internal"
cp "$WF" "$STALE/.github/workflows/go-tests.yml"
printf 'unrelated\n' >"$STALE/scripts/other.sh"

STEP="$TMPROOT/step.sh"

echo "case 0/6: the step is extractable from the live workflow"
if ! extract_step "$WF" "$STEP"; then
  no "could not extract the step named '$STEP_NAME' — every case below is vacuous"
  echo; echo "passed: $PASS   failed: $FAIL"; exit 1
fi
ok "extracted '$STEP_NAME' ($(wc -l <"$STEP" | tr -d ' ') lines) from go-tests.yml"

echo
echo "case 1/6: the step declares the env the guard's message is built from"
envkeys="$(python3 - "$WF" "$STEP_NAME" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
s = [s for j in wf["jobs"].values() for s in j.get("steps", [])
     if s.get("name") == sys.argv[2] and "run" in s][0]
print("\n".join(sorted(s.get("env", {}))))
PY
)"
if [ "$envkeys" = "$(printf 'BASE_SHA\nHEAD_SHA\nRATCHET')" ]; then
  ok "step env is exactly BASE_SHA, HEAD_SHA, RATCHET"
else
  no "step env keys drifted (got: $(printf '%s' "$envkeys" | tr '\n' ' ')) — the absence message cannot name the shas"
fi

echo
echo "case 2/6: a head WITHOUT the ratchet — dispatch continues and the absence is NAMED"
rc=0; run_step "$STEP" "$STALE" || rc=$?
if [ "$rc" -ne 0 ]; then
  no "the step exited $rc on a head without the ratchet — 'Compute the changed-path set' would be SKIPPED again"
  sed -n '1,20p' "$OUT" >&2
else
  ok "the step exited 0, so the path verdict below it still runs"
fi
if grep -q '^::warning' "$OUT"; then
  ok "stdout carries a ::warning annotation"
else
  no "stdout carries NO ::warning — the absence is SILENT, which is the thing forbidden"
fi
if grep -qi 'ratchet' "$OUT" && grep -qiE 'not in this checkout|ABSENT' "$OUT"; then
  ok "the warning says the ratchet is absent, in words"
else
  no "the warning does not say what is absent"
fi
if grep -q "$FAKE_HEAD" "$OUT" && grep -q "$FAKE_BASE" "$OUT"; then
  ok "the warning names both the head and the base sha"
else
  no "the warning does not name head=$FAKE_HEAD and base=$FAKE_BASE"
fi
if grep -qiE 'not a pass|UNVERIFIED' "$OUT"; then
  ok "the warning refuses to read as a pass"
else
  no "the warning reads like a pass — absence must never render as a verdict"
fi
if [ -s "$SUMMARY" ] && grep -q "$FAKE_HEAD" "$SUMMARY"; then
  ok "the job summary carries the absence with the shas"
else
  no "GITHUB_STEP_SUMMARY is empty or shaless — a reader must open the log to learn the ratchet did not run"
fi

echo
echo "case 3/6: a head WITH the ratchet — unchanged, and it PRINTS its selftest count"
rc=0; run_step "$STEP" "$REPO_ROOT" || rc=$?
if [ "$rc" -ne 0 ]; then
  no "the step exited $rc against this tree, which carries the ratchet"
  tail -20 "$OUT" >&2
else
  ok "the step exited 0 against a tree carrying the ratchet"
fi
if grep -qE '^go-path-escape-check --selftest: [0-9]+ passed, 0 failed' "$OUT"; then
  ok "selftest count line printed: $(grep -oE 'go-path-escape-check --selftest: .*' "$OUT" | head -1)"
else
  no "no selftest count line — the scanner's liveness was never proven on this head"
fi
if grep -q '^OK: every cross-tree read' "$OUT"; then
  ok "the --check verdict line printed"
else
  no "no --check verdict line — the ratchet did not actually run"
fi
if grep -q '^::warning' "$OUT"; then
  no "the absence warning fired on a head that HAS the script — the guard misreads a present ratchet"
else
  ok "no absence warning on a head that has the script"
fi

echo
echo "case 4/6: RED-WITHOUT — the pre-fix step body dies 127 on the same stale head"
MUT="$TMPROOT/go-tests-prefix.yml"
python3 - "$WF" "$MUT" <<'PY'
import sys
s = open(sys.argv[1]).read()
anchor = "      - name: Go cross-tree read ratchet (selftest, then check)\n"
i = s.index(anchor)
j = s.index("\n      - id: sets\n", i)
pre = (anchor
       + "        run: |\n"
       + "          set -euo pipefail\n"
       + "          bash scripts/go-path-escape-check.sh --selftest\n"
       + "          bash scripts/go-path-escape-check.sh --check\n")
out = s[:i] + pre + s[j + 1:]
if out == s:
    sys.exit("MUTATION produced an IDENTICAL file — it did not apply")
open(sys.argv[2], "w").write(out)
PY
mrc=$?
if [ "$mrc" -ne 0 ]; then
  no "the mutation could not be applied — case 4 proves nothing"
else
  ok "the mutation applied (pre-#16520-era step body restored, file differs)"
  MSTEP="$TMPROOT/step-prefix.sh"
  if ! extract_step "$MUT" "$MSTEP"; then
    no "could not extract the step from the mutated copy"
  else
    rc=0; run_step "$MSTEP" "$STALE" || rc=$?
    if [ "$rc" -eq 127 ]; then
      ok "pre-fix: the stale head dies with exit 127 (the measured defect, reproduced)"
    elif [ "$rc" -ne 0 ]; then
      ok "pre-fix: the stale head fails (exit $rc) and skips the path verdict"
    else
      no "the PRE-FIX body PASSED on a head with no ratchet — this harness cannot detect the bug"
    fi
    if grep -q '^::warning' "$OUT"; then
      no "the pre-fix body named the absence — the mutation did not remove the guard"
    else
      ok "pre-fix: nothing named the absence (a red reading only 'exit code 127')"
    fi
  fi
fi

echo
echo "case 5/6: NON-VACUITY — the extracted body produced real output in both directions"
rc=0; run_step "$STEP" "$STALE" || rc=$?
stale_bytes=$(wc -c <"$OUT" | tr -d ' ')
rc=0; run_step "$STEP" "$REPO_ROOT" || rc=$?
present_bytes=$(wc -c <"$OUT" | tr -d ' ')
if [ "$stale_bytes" -gt 0 ] && [ "$present_bytes" -gt 0 ]; then
  ok "both runs produced output (${stale_bytes}B absent-head, ${present_bytes}B present-head), so the cases above judged something"
else
  no "a run produced NO output at all — the harness is vacuous"
fi

# ── case 6: the `sets` step's DECLARATION pin (task-a1d681421c82e995) ────────
# A DIFFERENT skew from cases 1-5. Those are about the SCRIPT the ratchet step
# shells (head) going missing. This one is about the `sets` step, which has no
# script at all: its parser, its two sentinels and its `-lt 30` floor are TEXT
# IN THE WORKFLOW FILE — merge ref — while the `on.push.paths` list they judge
# was read off the HEAD checkout's copy of that same file. Two commits of one
# file. #17622 (45c98ae0e) fixed this class for cloud/console/elixir and left
# go-tests.yml out, on the ratchet comment's argument that "both inputs come
# from the head" — true of the ratchet step, false of this one.
#
# The fixture is the REAL historical window: a head whose declaration is the
# 15-glob list (#15007 .. task-bb930319aeac0266, which grew it to 46) judged by
# a merge-ref workflow whose floor is 30. Both sentinels survive the truncation
# on purpose, so the arm measures the FLOOR and not a sentinel.
#
# Both directions in one run: the shipped body (pinned) must answer, and a copy
# MUTATED back to the pre-pin `wf=` one-liner must exit 1 on the same fixture.
echo
echo "case 6/6: the 'sets' step pins its path-set declaration to the merge ref"

DISP_WF="${GO_DISPATCH_WF:-$WF}"

extract_sets() { # extract_sets <workflow.yml> <dest.sh>
  python3 - "$1" "$2" <<'PY2'
import sys, re, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = [s for s in wf["jobs"]["changes"]["steps"] if s.get("id") == "sets"]
if len(step) != 1:
    sys.exit("expected exactly 1 step with id 'sets', found %d" % len(step))
body = (step[0]["run"]
        .replace("${{ github.event_name }}", "${T_EVENT}")
        .replace("${{ github.event.pull_request.base.sha }}", "${T_BASE}")
        .replace("${{ github.event.pull_request.number }}", "${T_PRNUM}"))
left = sorted(set(re.findall(r"\$\{\{.*?\}\}", body)))
if left:
    sys.stderr.write(
        "EXTRACTION IS OUT OF DATE: the 'sets' step uses Actions expressions this "
        "harness does not substitute: %s. Add each to the replace() chain (and pass "
        "its value from run_sets()), or every arm below measures nothing.\n"
        % ", ".join(left))
    sys.exit(3)
open(sys.argv[2], "w").write(body)
PY2
}

SETS="$TMPROOT/sets.sh"
if extract_sets "$DISP_WF" "$SETS"; then
  ok "extracted the 'sets' step body from $DISP_WF with every Actions expression substituted"
else
  no "could not extract the 'sets' step body (see the line above) — every arm in case 6 measures nothing"
fi

# The fixture repo. base commit carries the CURRENT (46-glob) declaration and is
# what `pinned-merge` points at — the stand-in for refs/pull/N/merge. The head
# commit carries the TRUNCATED 15-glob declaration: a branch cut before the list
# grew.
DR="$TMPROOT/dispatchrepo"
mkdir -p "$DR/.github/workflows" "$DR/internal/cli"
cp "$WF" "$DR/.github/workflows/go-tests.yml"
: >"$DR/internal/cli/a.go"
git -C "$DR" init -q
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
DR_BASE="$(git -C "$DR" rev-parse HEAD)"
git -C "$DR" branch pinned-merge "$DR_BASE"

# Truncate on.push.paths to its first 15 entries, textually — the parser under
# test reads TEXT, so a yaml round-trip would change what it sees.
python3 - "$WF" "$DR/.github/workflows/go-tests.yml" <<'PY2'
import sys
lines = open(sys.argv[1]).read().split("\n")
out, inon, inpush, inp, kept = [], False, False, False, 0
for ln in lines:
    if ln.startswith("on:"): inon = True; out.append(ln); continue
    if inon and ln and not ln[0] in " \t#": inon = inpush = inp = False
    if inon and ln.startswith("  push:"): inpush = True; out.append(ln); continue
    if inon and ln.startswith("    paths:"): inp = True; out.append(ln); continue
    if inp and ln.startswith("    ") and not ln.startswith("      "): inp = False
    if inp and ln.lstrip().startswith("- "):
        kept += 1
        if kept > 15: continue
    out.append(ln)
open(sys.argv[2], "w").write("\n".join(out))
PY2
TRUNC_N="$(python3 -c "
import yaml,sys; print(len(yaml.safe_load(open(sys.argv[1]))[True]['push']['paths']))" "$DR/.github/workflows/go-tests.yml")"
FULL_N="$(python3 -c "
import yaml,sys; print(len(yaml.safe_load(open(sys.argv[1]))[True]['push']['paths']))" "$WF")"
if [ "$TRUNC_N" = "15" ] && [ "$FULL_N" -ge 30 ]; then
  ok "fixture built: stale head declares $TRUNC_N globs, the pinned ref declares $FULL_N (floor is 30)"
else
  no "fixture is WRONG (head=$TRUNC_N pinned=$FULL_N) — the floor arm below measures nothing"
fi
printf 'package cli\n' >"$DR/internal/cli/a.go"
git -C "$DR" checkout -q -b stale-head
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm stale >/dev/null 2>&1

SOUT="$TMPROOT/sets-out.txt"
SGH="$TMPROOT/sets-gh-output"
run_sets() { # run_sets <sets.sh> [pin_ref] -> rc in $SRC
  : >"$SGH"; : >"$SOUT"
  ( cd "$DR" && env T_EVENT=pull_request T_BASE="$DR_BASE" T_PRNUM=0 \
      DISPATCH_PIN_REMOTE=. DISPATCH_PIN_REF="${2:-refs/heads/pinned-merge}" \
      RUNNER_TEMP="$TMPROOT/runner-temp" GITHUB_OUTPUT="$SGH" \
      bash --noprofile --norc "$1" ) >"$SOUT" 2>&1 && SRC=0 || SRC=$?
}
mkdir -p "$TMPROOT/runner-temp"

echo "  arm A — the SHIPPED body, pin reachable"
run_sets "$SETS"
if [ "$SRC" -eq 0 ]; then
  ok "shipped body exits 0 on a head whose own declaration is below the floor"
else
  no "shipped body exited $SRC — the pin did not rescue the stale head"
  sed 's/^/        /' "$SOUT" >&2
fi
if grep -q '^path-set declaration: refs/heads/pinned-merge ' "$SOUT"; then
  ok "  …and says by name which ref the declaration came from"
else
  no "  …but never named the declaration's source (the pinned read did not happen)"
fi
if grep -q "path set parsed from .*on.push.paths:" "$SOUT" && \
   [ "$(grep -c '^go=' "$SGH")" -eq 1 ]; then
  ok "  …and emits exactly one go= verdict"
else
  no "  …emitted $(grep -c '^go=' "$SGH") go= line(s) — the gated job has no defined answer"
fi

echo "  arm B — MUTATED back to the pre-pin shape, same fixture"
MUTWF="$TMPROOT/go-tests-prepin.yml"
python3 - "$DISP_WF" "$MUTWF" <<'PY2'
import sys
s = open(sys.argv[1]).read()
i = s.index("          # ── THE DECLARATION MUST MATCH THE PARSER")
anchor = '          echo "path-set declaration: ${pin_src}"\n\n'
j = s.index(anchor, i) + len(anchor)
out = s[:i] + '          wf=".github/workflows/go-tests.yml"\n' + s[j:]
if out == s:
    sys.exit("MUTATION produced an IDENTICAL file — it did not apply")
open(sys.argv[2], "w").write(out)
PY2
if [ $? -ne 0 ]; then
  no "could not build the pre-pin mutant — arm B proves nothing"
else
  ok "mutation applied (the pin block replaced by the pre-pin wf= one-liner)"
  MSETS="$TMPROOT/sets-prepin.sh"
  if ! extract_sets "$MUTWF" "$MSETS"; then
    no "could not extract 'sets' from the mutant"
  else
    run_sets "$MSETS"
    if [ "$SRC" -eq 1 ]; then
      ok "pre-pin: the stale head exits 1 — the skew reproduced"
    else
      no "pre-pin body exited $SRC on the stale head — this harness cannot detect the skew"
      sed 's/^/        /' "$SOUT" >&2
    fi
    if grep -q "parsed only ${TRUNC_N} path glob(s)" "$SOUT"; then
      ok "pre-pin: the red is the FLOOR, quoting the head's own ${TRUNC_N}-glob count"
    else
      no "pre-pin: exited non-zero for some other reason — arm B is not measuring the floor"
      sed 's/^/        /' "$SOUT" >&2
    fi
  fi
fi

echo "  arm C — NEGATIVE CONTROL: an unreadable pin ref must warn by name, never die silently"
run_sets "$SETS" refs/heads/no-such-merge-ref
if grep -q '^::warning::dispatcher: could NOT read .github/workflows/go-tests.yml out of refs/heads/no-such-merge-ref' "$SOUT"; then
  ok "an unreadable pin is NAMED as a degraded read"
else
  no "an unreadable pin produced no named warning — a silent fallback"
  sed 's/^/        /' "$SOUT" >&2
fi
if grep -q '^path-set declaration: the PR HEAD checkout' "$SOUT"; then
  ok "  …and the fallback source is stated, not implied"
else
  no "  …and never said which declaration it fell back to"
fi
if [ "$SRC" -ne 0 ] || [ "$(grep -c '^go=' "$SGH")" -eq 1 ]; then
  ok "  …and the step still either answers or refuses out loud (exit $SRC)"
else
  no "  …and exited 0 with NO go= line — the gated job would read an empty output"
fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK — go-tests' Dispatch job gives a stale head a path verdict and names the missing ratchet."
