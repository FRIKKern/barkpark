#!/usr/bin/env bash
# workflow-errexit-capture-check.sh — a status you capture under `-e` is a
# status you never see.
#
# THE HAZARD, MEASURED (task-3b5edb3d1f5990e3). The shell GitHub Actions runs a
# `run:` block with is `/usr/bin/bash -e {0}`. ERREXIT IS ALREADY ON when the
# first line of your script runs, and `set -uo pipefail` — the incantation
# nearly every step in this repo opens with — adds nounset and pipefail while
# leaving `-e` exactly where it was. So this shape:
#
#     set -uo pipefail
#     bash scripts/thing.sh          # exits 1 as DATA, not as an error
#     rc=$?                          # <-- NEVER RUNS
#     if [ "$rc" -gt 1 ]; then ... fi # <-- NEVER RUNS
#
# does not adjudicate anything. `-e` kills the step ON THE COMMAND ABOVE, and
# the step fails with the status the author had written code to tolerate.
#
# .github/workflows/main-red-owner.yml shipped exactly that and was STABLY RED
# on main's tip for it (runs 35244509820 / 35241984147 / 35241862194 /
# 35240848459). The failing log is the signature of this fault and worth
# recognising: the CALLED script's own final line prints, then
# `##[error]Process completed with exit code 1`, and NONE of the step's own
# echoes appear. That workflow's entire job is to notice a red on main, so the
# fault was self-amplifying — the watcher became the red it watches for.
#
# THE SECOND SHAPE, which no `rc=$?` grep can find:
#
#     set -o pipefail
#     cmd | tee log            # pipefail makes the PIPELINE carry cmd's status
#     rc=${PIPESTATUS[0]}      # <-- NEVER RUNS when cmd fails
#     { ...; } >> "$GITHUB_STEP_SUMMARY"
#
# Here the step usually ends `exit "$rc"`, so the final conclusion is unchanged
# and the bug looks cosmetic. It is not: the SUMMARY — the whole diagnosis of
# the failure — is written only on the path where nothing went wrong.
#
# THE THIRD SHAPE, and it is this file's OWN former advice (2026-09-17,
# task-0a48c7b64d5ab0f1):
#
#     cmd | tee log || :       # `:` runs, and `:` IS A PIPELINE
#     rc=${PIPESTATUS[0]}      # <-- reads `:`'s status. ALWAYS 0.
#
# Reachable, and dead. Three steps in this repo took the advice and published
# false greens with it: a `NOT YET MEASURED` 24 h window reported as `exit 0 —
# 0 CLEAN`, and two `exit "$rc"` lines that concluded SUCCESS on their scripts'
# could-not-deliver codes. The remedy is `set +e` around the pipeline and the
# capture, or keeping the capture inside the guarded compound.
#
# THE DISCRIMINATOR IS NOT THE STRING `rc=$?`. About eighty sites in this repo
# match that grep and nearly all are already correct, because their step ran
# `set +e` first. What makes a site defective is whether ERREXIT IS STILL IN
# EFFECT at the capture. That is a predicate, and this file is that predicate.
#
# THE RULE. Inside a `run:` block whose shell is the default `bash -e`, a
# status capture — `VAR=$?` or `VAR=${PIPESTATUS[n]}` — is REFUSED when errexit
# is still on AND the command whose status it reads was not protected. Either
# of these clears it:
#
#     set +e                    …anywhere earlier in the same step, or
#     <cmd> || rc=$?            …the `||` form, which is preferred: it keeps
#     <cmd> || :                   errexit ON for every other line of the step
#
# WHY THE `||` FORM IS PREFERRED over a step-wide `set +e`: `set +e` disarms the
# WHOLE body, so the next command someone appends fails silently. `|| rc=$?`
# is local to the one command that is allowed to fail. Both clear this check —
# the repo uses both — but the second is the one to write new.
#
# EXIT CODES
#   0  no capture in any scanned file is reached with errexit still armed
#   1  at least one is — each named with file, job, step and the offending line
#   2  CANNOT MEASURE: zero files, no PyYAML, or a bad flag. An empty scan is a
#      failure, never a vacuous green.
#
# USAGE
#   bash scripts/workflow-errexit-capture-check.sh                 # .github/workflows
#   bash scripts/workflow-errexit-capture-check.sh --dir <path>
#   bash scripts/workflow-errexit-capture-check.sh a.yml b.yml
#   bash scripts/workflow-errexit-capture-check.sh --selftest
#
# WIRED IN: .github/workflows/required-checks-drift.yml, job `workflow-job-shape`
# (rendered check-run name "Every workflow job has runs-on+steps or uses"). That
# job is deliberately dispatcher-independent and path-unfiltered, so it renders
# on EVERY pull request — including the ones that edit a workflow this check's
# subject lives in. Added as a STEP on an existing job on purpose: a new job
# would render a new check-run name and drag the required-checks census in
# behind it, for a lint that wants neither.

set -uo pipefail

SELFTEST=0
TARGETS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) SELFTEST=1; shift ;;
    --dir)
      if [ $# -lt 2 ]; then
        echo "workflow-errexit-capture-check: --dir needs a path — CANNOT MEASURE (rc 2)" >&2
        exit 2
      fi
      TARGETS+=("$2"); shift 2 ;;
    -h|--help) sed -n '2,80p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)
      echo "workflow-errexit-capture-check: unknown flag '$1' — CANNOT MEASURE (rc 2)" >&2
      exit 2 ;;
    *) TARGETS+=("$1"); shift ;;
  esac
done

run_check() {
  python3 - "$@" <<'PY'
import os
import re
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("workflow-errexit-capture-check: PyYAML is not importable — CANNOT MEASURE (rc 2)\n")
    sys.exit(2)

files = []
for a in sys.argv[1:]:
    if os.path.isdir(a):
        for name in sorted(os.listdir(a)):
            if name.endswith((".yml", ".yaml")):
                files.append(os.path.join(a, name))
    else:
        files.append(a)

if not files:
    sys.stderr.write("workflow-errexit-capture-check: zero workflow files to scan — CANNOT MEASURE (rc 2)\n")
    sys.exit(2)

CAPTURE = re.compile(r'^\s*[A-Za-z_][A-Za-z0-9_]*=(\$\?|\$\{PIPESTATUS\[)')
SET_LINE = re.compile(r'^\s*set\s+([-+][^;#]*)')
# `shell:` values whose shell is NOT errexit-armed. GitHub's own defaults:
# `bash` (the bare word) runs `bash --noprofile --norc -eo pipefail {0}` — still
# `-e`. `sh` runs `sh -e {0}`. Only these opt OUT of errexit.
SHELL_NO_E = ("bash {0}", "python", "pwsh", "powershell", "cmd")

# ── THE SECOND SHAPE IN THIS FAMILY: THE UNREACHABLE REPORTER ───────────────
# (task-1c8165ef0ada4fcd). There is no capture here at all, which is why the
# rule above cannot see it:
#
#     bash scripts/check-doc-budgets.sh --selftest   # a TRIPWIRE. may exit 1.
#     bash scripts/check-doc-budgets.sh              # <-- THE REPORTER
#
# Both bare, under `/usr/bin/bash -e {0}`. The tripwire's exit 1 kills the step
# ON ITS OWN LINE, so the shipping gate below — the ONLY command that prints the
# per-finding lines — never runs. The step's whole captured red is then the
# tripwire's one constant sentence, which names nothing.
#
# That is not cosmetic: scripts/main-red-breaker.sh classifies a failing step by
# whether its red NAMES what it found, and a constant sentence has no payload
# slot. It routed `Doc budgets + anchors` to OPAQUE-RED / OWNERSHIP-UNDETERMINED
# on every PR that inherited main's red (PR #19081, run 35253987928 — where the
# breaker names this exact cause). An unattributable red is a red no lane can
# act on, and the job is advisory, so nobody is forced to.
#
# THE PREDICATE, and it is a predicate and not a list: within ONE errexit-armed
# run body, an UNPROTECTED `<interp> <script> --selftest` line followed LATER by
# an UNPROTECTED line that is the SAME `<interp> <script>` with no flags. The
# second is the reporter; the first can abort before it. No workflow, job, step
# or script name appears here — a step added tomorrow is classified the first
# time it is written.
#
# FIX: `st_rc=0; <cmd> --selftest || st_rc=$?` / `gate_rc=0; <cmd> || gate_rc=$?`
# then adjudicate. Both run, the log carries both, and the step still fails when
# either does. NOT `|| true` and NOT `continue-on-error` — those make a real
# failure green, which is the one outcome these steps must still red on.
PREFLIGHT = re.compile(
    r'^(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)*'
    r'(?P<cmd>(?:bash|sh|node|python3?)\s+"?[^\s"]+"?)'
    r'\s+--selftest\s*$')
BARE_CMD = re.compile(
    r'^(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)*'
    r'(?P<cmd>(?:bash|sh|node|python3?)\s+"?[^\s"]+"?)\s*$')


def errexit_off(flagstr):
    """Does this `set` word turn errexit OFF (True) / ON (False) / neither (None)?"""
    for word in flagstr.split():
        if not word or word[0] not in "-+":
            continue
        sign, body = word[0], word[1:]
        if body.startswith("o") or body == "o":
            continue  # `set -o pipefail` / `set +o pipefail` — never errexit
        if "e" in body:
            return sign == "+"
    return None


def protected(cmd):
    """Was the command whose status is being captured allowed to fail?

    True when the line carries a top-level `||` (outside quotes), which is the
    `cmd || rc=$?` / `cmd || :` form errexit does not fire on. Deliberately
    conservative: a `|` inside quotes is not a `||`, and a trailing `\\` means
    the real command continues and we say nothing.
    """
    out, q, i = [], None, 0
    while i < len(cmd):
        c = cmd[i]
        if q:
            if c == "\\" and q == '"':
                i += 2
                continue
            if c == q:
                q = None
            i += 1
            continue
        if c in "\"'":
            q = c
            i += 1
            continue
        out.append(c)
        i += 1
    return "||" in "".join(out)


bad = []
dead_ps = []
unreachable = []
captures_seen = 0
selftest_lines_seen = 0
steps_seen = 0

for path in files:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except Exception as exc:                      # noqa: BLE001 — any load fault
        # NOT this check's subject. workflow-job-shape-check.sh owns
        # unparseable files and reds on them; duplicating the verdict here would
        # make one defect render as two unrelated reds.
        sys.stderr.write("workflow-errexit-capture-check: skipping %s (%s)\n"
                         % (path, exc.__class__.__name__))
        continue
    if not isinstance(doc, dict):
        continue
    jobs = doc.get("jobs")
    if not isinstance(jobs, dict):
        continue
    job_defaults = doc.get("defaults") or {}
    wf_shell = ((job_defaults.get("run") or {}) if isinstance(job_defaults, dict) else {}).get("shell")

    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            continue
        jd = job.get("defaults") or {}
        job_shell = ((jd.get("run") or {}) if isinstance(jd, dict) else {}).get("shell") or wf_shell
        steps = job.get("steps")
        if not isinstance(steps, list):
            continue
        for idx, step in enumerate(steps):
            if not isinstance(step, dict):
                continue
            body = step.get("run")
            if not isinstance(body, str) or not body.strip():
                continue
            steps_seen += 1
            shell = step.get("shell") or job_shell
            if shell and any(str(shell).strip().startswith(s) for s in SHELL_NO_E):
                continue
            label = "%s job `%s` step[%d]" % (path, job_id, idx)
            if isinstance(step.get("name"), str):
                label += ' (name: "%s")' % step["name"]

            e_on = True       # the runner hands you `bash -e`. This is the premise.
            # UNREACHABLE-REPORTER pass. Walked first and separately because it
            # is about the RELATION between two lines, not about one line.
            exec_lines = []
            e2 = True
            for lineno, line in enumerate(body.splitlines(), 1):
                m2 = SET_LINE.match(line)
                if m2:
                    v2 = errexit_off(m2.group(1))
                    if v2 is not None:
                        e2 = not v2
                st2 = line.strip()
                if not st2 or st2.startswith("#"):
                    continue
                exec_lines.append((lineno, st2, e2))
            for i, (ln_pre, txt_pre, e_pre) in enumerate(exec_lines):
                mp = PREFLIGHT.match(txt_pre)
                if not mp:
                    continue
                # Counted BEFORE the protection test: this is the COVERAGE
                # denominator (did the scan reach any preflight at all?), not the
                # finding count. Counting only unprotected ones would make a tree
                # where every site is already FIXED look like a scan that never
                # ran — the vacuous green this file exists to refuse.
                selftest_lines_seen += 1
                if not e_pre or protected(txt_pre):
                    continue
                for ln_rep, txt_rep, _e_rep in exec_lines[i + 1:]:
                    mb = BARE_CMD.match(txt_rep)
                    if mb and mb.group("cmd") == mp.group("cmd") and not protected(txt_rep):
                        unreachable.append((label, ln_pre, txt_pre, ln_rep, txt_rep))
                        break
            prev = ""
            for lineno, line in enumerate(body.splitlines(), 1):
                m = SET_LINE.match(line)
                if m:
                    verdict = errexit_off(m.group(1))
                    if verdict is not None:
                        e_on = not verdict
                if CAPTURE.match(line):
                    captures_seen += 1
                    # ── THE THIRD SHAPE: A DEAD PIPESTATUS CAPTURE ──────────
                    # (task-0a48c7b64d5ab0f1, 2026-09-17.) This one is the
                    # OPPOSITE of the rule below and it is why it needs its own
                    # test: the capture is perfectly REACHABLE — `protected()`
                    # says so — and it still reads a number that has nothing to
                    # do with the pipeline.
                    #
                    # PIPESTATUS is rewritten by EVERY pipeline, and a bare
                    # command is a pipeline. So the right-hand side of a `||`
                    # clobbers it before the capture on the next line runs:
                    #
                    #     (exit 3) | cat || :        # `:` is a pipeline
                    #     rc=${PIPESTATUS[0]}        # reads `:`'s status — 0
                    #
                    # Measured, not reasoned: bash 3.2 and 5.x both print 0, and
                    # `|| rc=$?` does it too — an assignment with no command is
                    # still a simple command and still resets the array.
                    #
                    # WHAT IT COST. This file's own FIX line used to recommend
                    # `<cmd> | tee … || :` for a pipeline, and three steps in
                    # this repo took the advice. main-red-owner.yml run
                    # 35276736665 printed `NOT YET MEASURED …` and then `window
                    # verdict exit=0`, where its summary labels exit 0 `0 CLEAN`
                    # — a false clean day on the one instrument the main-red 24 h
                    # criterion is stamped from. In the same file the ownership
                    # step's `exit "$rc"` concluded SUCCESS on could-not-deliver
                    # codes 3/4/5, and scheduled-arm-health.yml's did the same on
                    # a red arm. Three false greens from one blessed idiom.
                    #
                    # THE ONLY CORRECT FORMS put NOTHING between the pipeline and
                    # the capture: `set +e` around the pair (grip-suite.yml,
                    # research-coverage-suite.yml), or keep the capture INSIDE the
                    # protected compound — `rc=0; { cmd | tee f; rc=${PIPESTATUS[0]}; } || :`.
                    #
                    # `$?` captures are NOT affected: `cmd || rc=$?` is the
                    # documented remedy and `$?` there is the left side's status.
                    # This rule fires only on the `${PIPESTATUS[` form.
                    if "${PIPESTATUS[" in line and protected(prev):
                        dead_ps.append((label, lineno, line.strip(), prev.strip()))
                    elif e_on and not protected(prev):
                        bad.append((label, lineno, line.strip(), prev.strip()))
                stripped = line.strip()
                if stripped and not stripped.startswith("#"):
                    prev = line

if unreachable:
    print("workflow-errexit-capture-check: %d UNREACHABLE REPORTER(s) — a tripwire that can "
          "abort the step before the gate that names the findings" % len(unreachable))
    print()
    for label, ln_pre, txt_pre, ln_rep, txt_rep in unreachable:
        print("  %s" % label)
        print("      run-body line %d: %s" % (ln_pre, txt_pre))
        print("      run-body line %d: %s   <-- THE REPORTER" % (ln_rep, txt_rep))
        print("      -e kills the step on the first line, so the second never runs and its")
        print("      per-finding lines never reach the log. main-red-breaker.sh then reads")
        print("      this step as OPAQUE-RED / OWNERSHIP-UNDETERMINED.")
        print("      FIX: `st_rc=0; <cmd> --selftest || st_rc=$?` then")
        print("           `gate_rc=0; <cmd> || gate_rc=$?` then adjudicate both.")
        print()

if dead_ps:
    print("workflow-errexit-capture-check: %d DEAD PIPESTATUS capture(s) — the `||` on the "
          "line above overwrote the array, so this reads 0 no matter what the pipeline did"
          % len(dead_ps))
    print()
    for label, lineno, cap, prev in dead_ps:
        print("  %s" % label)
        print("      run-body line %d: %s" % (lineno, cap))
        print("      the command above it: %s" % (prev or "(none)"))
        print("      The right-hand side of that `||` IS A PIPELINE, so it replaced")
        print("      PIPESTATUS before this line ran. The capture is reachable and DEAD.")
        print("      FIX: `set +e` around the pipeline and the capture (then `set -e`),")
        print("           or keep the capture inside the guarded compound:")
        print("           `rc=0; { <cmd> | tee f; rc=${PIPESTATUS[0]}; } || :`")
        print()
    print("scanned %d run-step(s), %d status capture(s)" % (steps_seen, captures_seen))
    print("TERMINAL: exit 1")
    sys.exit(1)

if bad:
    print("workflow-errexit-capture-check: %d status capture(s) reached with errexit ARMED" % len(bad))
    print()
    for label, lineno, cap, prev in bad:
        print("  %s" % label)
        print("      run-body line %d: %s" % (lineno, cap))
        print("      the command above it: %s" % (prev or "(none)"))
        print("      -e kills the step on that line, so this capture never runs.")
        # NOT `<cmd> | tee … || :`, which this file recommended until
        # 2026-09-17 and which silently zeroes PIPESTATUS — see the DEAD
        # PIPESTATUS rule above.
        print("      FIX: `rc=0; <cmd> || rc=$?`, or for a pipeline `set +e` around")
        print("           the pipeline AND its `${PIPESTATUS[n]}` capture, then `set -e`")
        print()
    print("scanned %d run-step(s), %d status capture(s)" % (steps_seen, captures_seen))
    print("TERMINAL: exit 1")
    sys.exit(1)

if unreachable:
    print("scanned %d run-step(s), %d --selftest preflight(s)"
          % (steps_seen, selftest_lines_seen))
    print("TERMINAL: exit 1")
    sys.exit(1)

if captures_seen == 0 and selftest_lines_seen == 0:
    # THE COVERAGE FLOOR. This repo has dozens of status captures; finding zero
    # means the scan did not reach the tree, and reporting that as a pass is the
    # vacuous green this whole file exists to make impossible.
    sys.stderr.write("workflow-errexit-capture-check: scanned %d run-step(s) and found ZERO "
                     "status captures AND ZERO `--selftest` preflights — CANNOT MEASURE (rc 2)\n"
                     % steps_seen)
    sys.exit(2)

print("workflow-errexit-capture-check: OK — %d status capture(s) across %d run-step(s), "
      "every one either under `set +e` or guarded by `||`; and no unreachable reporter "
      "(%d `--selftest` preflight(s) walked, none of them shadowing a bare re-run of "
      "the same command)" % (captures_seen, steps_seen, selftest_lines_seen))
print("TERMINAL: exit 0")
sys.exit(0)
PY
}

# ── THE ARMS ────────────────────────────────────────────────────────────────
# Every arm is a PAIR — the same fixture with ONE property moved — because an
# arm that only ever sees one answer cannot tell a working rule from `return 0`.
#
# ARM GROUP A, THE REVERT ARM, is the important one and it is not synthetic: it
# plants the PRE-FIX TEXT OF main-red-owner.yml's record step, verbatim, and
# asserts this checker reds on it. If someone "simplifies" that step back, this
# arm is what notices.
#
# ARM GROUP B, THE QUIET ARM, runs a real `bash -e` against both shapes at
# every interesting status — 0 (poll TRUE), 1 (poll FALSE: DATA) and 4 (the
# ledger could not be appended: TERMINAL) — and asserts the old shape loses its
# adjudication at 1 while the new shape keeps it at all three and still exits
# non-zero at 4. That is the behaviour claim; the scan above is only its proxy.
_pass=0; _fail=0
_ok() { _pass=$((_pass+1)); printf '  ok   %s — %s\n' "$1" "$2"; }
_no() { _fail=$((_fail+1)); printf '  FAIL %s — %s\n' "$1" "$2"; }

_selftest() {
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/wf-errexit-selftest.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$d'" EXIT

  # ── A1. THE REVERT ARM: the shipped defect, verbatim ─────────────────────
  cat > "$d/revert.yml" <<'Y'
name: revert
on: [push]
jobs:
  own-the-red:
    runs-on: ubuntu-latest
    steps:
      - name: Record one poll into the 24 h window ledger
        run: |
          set -uo pipefail
          L="$RUNNER_TEMP/main-red-window.jsonl"
          bash scripts/main-red-window.sh --record "$L" "$GITHUB_REPOSITORY"
          rc=$?
          echo "record exit=$rc"
          if [ "$rc" -gt 1 ]; then exit "$rc"; fi
Y
  local out rc
  out="$(run_check "$d/revert.yml" 2>&1)"; rc=$?
  if [ "$rc" = 1 ] && case "$out" in *'rc=$?'*) true;; *) false;; esac; then
    _ok "A1 revert arm" "the pre-fix record step reds (rc 1) and the red quotes the capture"
  else
    _no "A1 revert arm" "expected rc 1 naming rc=\$?, got rc $rc"
  fi

  # ── A2. THE FIXED SHAPE IS QUIET (same fixture, one property moved) ──────
  sed 's|--record "$L" "$GITHUB_REPOSITORY"|--record "$L" "$GITHUB_REPOSITORY" \|\| rc=$?|' \
      "$d/revert.yml" > "$d/fixed.yml"
  out="$(run_check "$d/fixed.yml" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && _ok "A2 fixed shape" "\`|| rc=\$?\` clears the same fixture (rc 0)" \
                || _no "A2 fixed shape" "expected rc 0, got rc $rc: $out"

  # ── A3. `set +e` ALSO CLEARS IT — the other legal form ──────────────────
  sed 's|set -uo pipefail|set +e|' "$d/revert.yml" > "$d/setplus.yml"
  out="$(run_check "$d/setplus.yml" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && _ok "A3 set +e" "a step-wide \`set +e\` clears the same fixture (rc 0)" \
                || _no "A3 set +e" "expected rc 0, got rc $rc: $out"

  # ── A4. THE PIPELINE SHAPE, which no \`rc=\$?\` grep can see ────────────
  cat > "$d/pipe.yml" <<'Y'
name: pipe
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: summary
        run: |
          set -o pipefail
          bash scripts/thing.sh | tee out.txt
          rc=${PIPESTATUS[0]}
          echo "summary" >> "$GITHUB_STEP_SUMMARY"
          exit "$rc"
Y
  out="$(run_check "$d/pipe.yml" 2>&1)"; rc=$?
  [ "$rc" = 1 ] && _ok "A4 pipeline shape" "\`cmd | tee; rc=\${PIPESTATUS[0]}\` under pipefail reds (rc 1)" \
                || _no "A4 pipeline shape" "expected rc 1, got rc $rc"
  # ── A5. THE REVERT ARM FOR THE 2026-09-17 FIX ───────────────────────────
  # `| tee … || :` was THIS FILE'S OWN recommended remedy and it is a DEAD
  # capture: `:` is a pipeline, so it overwrites PIPESTATUS and the next line
  # reads 0 whatever the pipeline did. Three steps in this repo shipped false
  # greens on it. If someone re-blesses the idiom, this arm reds.
  sed 's@| tee out.txt@| tee out.txt || :@' "$d/pipe.yml" > "$d/pipe-deadps.yml"
  out="$(run_check "$d/pipe-deadps.yml" 2>&1)"; rc=$?
  if [ "$rc" = 1 ] && case "$out" in *'DEAD PIPESTATUS'*) true;; *) false;; esac; then
    _ok "A5 dead PIPESTATUS" "a trailing \`|| :\` before a \${PIPESTATUS[0]} capture REDS (rc 1)"
  else
    _no "A5 dead PIPESTATUS" "expected rc 1 naming DEAD PIPESTATUS, got rc $rc: $out"
  fi

  # ── A5b. THE QUIET ARM: the CORRECT pipeline remedy stays silent ────────
  # `set +e` around the pipeline AND the capture. Nothing runs between them, so
  # PIPESTATUS still carries the pipeline's own status.
  sed -e 's@          set -o pipefail@          set -o pipefail\n          set +e@' \
      -e 's@          rc=${PIPESTATUS\[0\]}@          rc=${PIPESTATUS[0]}\n          set -e@' \
      "$d/pipe.yml" > "$d/pipe-fixed.yml"
  out="$(run_check "$d/pipe-fixed.yml" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && _ok "A5b pipeline fixed" "\`set +e\` around pipeline+capture clears it (rc 0)" \
                || _no "A5b pipeline fixed" "expected rc 0, got rc $rc: $out"

  # ── A5c. `|| rc=$?` IS STILL THE BLESSED REMEDY FOR A \`$?\` CAPTURE ─────
  # The new rule must fire ONLY on the \`${PIPESTATUS[\` form. If it widened to
  # every capture after a \`||\`, arm A2 above would already be red — but A2
  # uses the record fixture, so this arm states the boundary on the PIPELINE
  # fixture, where a widened rule would be easiest to write by accident.
  sed -e 's@          rc=${PIPESTATUS\[0\]}@          rc=0@' \
      -e 's@ | tee out.txt@ | tee out.txt || rc=$?@' "$d/pipe.yml" > "$d/pipe-dollar.yml"
  out="$(run_check "$d/pipe-dollar.yml" 2>&1)"; rc=$?
  [ "$rc" = 2 ] || [ "$rc" = 0 ] && _ok "A5c \`$?\` unaffected" "\`|| rc=\$?\` is not read as a dead capture (rc $rc)" \
                || _no "A5c \`$?\` unaffected" "expected rc 0 or 2, got rc $rc: $out"

  # ── A6. `set -o pipefail` MUST NOT BE READ AS RE-ARMING ERREXIT ─────────
  # `set +e` then `set -o pipefail` is the commonest safe shape in this repo
  # (grip-suite.yml, research-coverage-suite.yml). A checker that treated the
  # `-o` word as `-e` would red four already-correct jobs.
  cat > "$d/plusthenpipe.yml" <<'Y'
name: plusthenpipe
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: suite
        run: |
          set +e
          set -o pipefail
          node --test x.mjs 2>&1 | tee log
          run_rc=${PIPESTATUS[0]}
          exit "$run_rc"
Y
  out="$(run_check "$d/plusthenpipe.yml" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && _ok "A6 set +e then -o pipefail" "pipefail is not read as re-arming errexit (rc 0)" \
                || _no "A6 set +e then -o pipefail" "expected rc 0, got rc $rc: $out"
  # ...and the pair: a real `set -e` AFTER `set +e` DOES re-arm it.
  sed 's|set -o pipefail|set -e|' "$d/plusthenpipe.yml" > "$d/rearm.yml"
  out="$(run_check "$d/rearm.yml" 2>&1)"; rc=$?
  [ "$rc" = 1 ] && _ok "A7 re-arm" "an explicit \`set -e\` after \`set +e\` re-arms and reds (rc 1)" \
                || _no "A7 re-arm" "expected rc 1, got rc $rc"

  # ── A8. A NON-ERREXIT `shell:` IS NOT THIS CHECK'S SUBJECT ──────────────
  cat > "$d/shellov.yml" <<'Y'
name: shellov
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: explicit shell
        shell: bash {0}
        run: |
          bash scripts/thing.sh
          rc=$?
          echo "$rc"
Y
  out="$(run_check "$d/shellov.yml" 2>&1)"; rc=$?
  [ "$rc" = 2 ] && _ok "A8 shell override" "\`shell: bash {0}\` is not errexit-armed — no finding (coverage floor rc 2)" \
                || _no "A8 shell override" "expected rc 2 (no captures scanned), got rc $rc: $out"

  # ── A9. THE COVERAGE FLOOR: an empty scan is never a pass ───────────────
  mkdir -p "$d/empty"
  out="$(run_check --dir "$d/empty" 2>&1)"; rc=$?
  [ "$rc" = 2 ] && _ok "A9 coverage floor" "zero files exits 2, never a vacuous 0" \
                || _no "A9 coverage floor" "expected rc 2, got rc $rc"

  # ── A10. AN UNKNOWN FLAG REFUSES rather than scanning nothing quietly ───
  out="$(bash "${BASH_SOURCE[0]}" --not-a-flag 2>&1)"; rc=$?
  [ "$rc" = 2 ] && _ok "A10 unknown flag" "refuses with rc 2" \
                || _no "A10 unknown flag" "expected rc 2, got rc $rc"

  # ── B. THE BEHAVIOUR ARMS: run both shapes under a real `bash -e` ───────
  # The scan above is a PROXY for a claim about what bash does. These arms make
  # the claim directly, at every status that matters.
  cat > "$d/data.sh" <<'S'
echo "TERMINAL: recorded one poll"
exit "${FAKE_RC:-1}"
S
  cat > "$d/old.sh" <<'S'
set -uo pipefail
bash "$SUT_DIR/data.sh"
rc=$?
echo "record exit=$rc"
if [ "$rc" -gt 1 ]; then echo "TERMINAL: could not append (exit $rc)"; exit "$rc"; fi
echo "TERMINAL: one poll recorded"
S
  cat > "$d/new.sh" <<'S'
set -uo pipefail
rc=0
bash "$SUT_DIR/data.sh" || rc=$?
echo "record exit=$rc"
if [ "$rc" -gt 1 ]; then echo "TERMINAL: could not append (exit $rc)"; exit "$rc"; fi
echo "TERMINAL: one poll recorded"
S
  export SUT_DIR="$d"
  local o_rc o_out n_rc n_out
  # B1 — the DATA case, which is the whole defect.
  o_out="$(FAKE_RC=1 bash -e "$d/old.sh" 2>&1)"; o_rc=$?
  n_out="$(FAKE_RC=1 bash -e "$d/new.sh" 2>&1)"; n_rc=$?
  if [ "$o_rc" = 1 ] && ! printf '%s' "$o_out" | grep -q 'record exit='; then
    _ok "B1 old shape at rc 1" "aborts with exit 1 and prints NONE of its own adjudication"
  else
    _no "B1 old shape at rc 1" "expected exit 1 with no 'record exit=' line; got rc $o_rc: $o_out"
  fi
  if [ "$n_rc" = 0 ] && printf '%s' "$n_out" | grep -q 'record exit=1'; then
    _ok "B2 new shape at rc 1" "stays GREEN and prints 'record exit=1' — the datum survives"
  else
    _no "B2 new shape at rc 1" "expected exit 0 with 'record exit=1'; got rc $n_rc: $n_out"
  fi
  # B3 — the TRUE poll: both shapes already worked here, which is exactly why
  # the defect was invisible to anyone who only tested the happy path.
  n_out="$(FAKE_RC=0 bash -e "$d/new.sh" 2>&1)"; n_rc=$?
  if [ "$n_rc" = 0 ] && printf '%s' "$n_out" | grep -q 'record exit=0'; then
    _ok "B3 new shape at rc 0" "a TRUE poll is still green and still adjudicated"
  else
    _no "B3 new shape at rc 0" "expected exit 0 with 'record exit=0'; got rc $n_rc: $n_out"
  fi
  # B4 — THE FIX MUST NOT SWALLOW A REAL FAILURE. This is the arm that fails if
  # someone "fixes" the step with `|| true` or `continue-on-error`.
  n_out="$(FAKE_RC=4 bash -e "$d/new.sh" 2>&1)"; n_rc=$?
  if [ "$n_rc" = 4 ] && printf '%s' "$n_out" | grep -q 'could not append (exit 4)'; then
    _ok "B4 new shape at rc 4" "a genuine append failure still exits 4, with its TERMINAL line"
  else
    _no "B4 new shape at rc 4" "expected exit 4 with the TERMINAL line; got rc $n_rc: $n_out"
  fi
  unset SUT_DIR

  # ── ARM GROUP C: THE UNREACHABLE REPORTER (task-1c8165ef0ada4fcd) ────────
  # C1/C2 are the scan pair. C3/C4 are the BEHAVIOUR pair and they are the ones
  # that matter: they run both step bodies under a REAL `bash -e` against a real
  # two-mode script and read what actually reached stdout. A scan arm proves the
  # regex matches; only C3/C4 prove the log gains the per-finding line.
  cat > "$d/unreach.yml" <<'Y'
name: unreach
on: [push]
jobs:
  doc-gates:
    runs-on: ubuntu-latest
    steps:
      - name: Doc byte budgets (fails this job)
        run: |
          bash scripts/check-doc-budgets.sh --selftest
          bash scripts/check-doc-budgets.sh
Y
  out="$(run_check "$d/unreach.yml" 2>&1)"; rc=$?
  if [ "$rc" = 1 ] && case "$out" in *"UNREACHABLE REPORTER"*"THE REPORTER"*) true;; *) false;; esac; then
    _ok "C1 revert arm" "the shipped doc-gates s1 body reds (rc 1) and names the reporter line"
  else
    _no "C1 revert arm" "expected rc 1 naming the reporter, got rc $rc: $out"
  fi

  cat > "$d/unreach-fixed.yml" <<'Y'
name: unreach-fixed
on: [push]
jobs:
  doc-gates:
    runs-on: ubuntu-latest
    steps:
      - name: Doc byte budgets (fails this job)
        run: |
          st_rc=0; bash scripts/check-doc-budgets.sh --selftest || st_rc=$?
          gate_rc=0; bash scripts/check-doc-budgets.sh || gate_rc=$?
          echo "selftest exit=$st_rc  gate exit=$gate_rc"
          if [ "$st_rc" -ne 0 ] || [ "$gate_rc" -ne 0 ]; then exit 1; fi
      # A second step carrying a BARE preflight, so this fixture clears the
      # scan-wide coverage floor. Without it the file holds zero captures and
      # zero bare preflights, the checker correctly says CANNOT MEASURE, and a
      # rc-0 assertion here would be reading a floor instead of a verdict.
      - name: solo tripwire
        run: |
          bash scripts/docs-anchors-check.sh --selftest
Y
  out="$(run_check "$d/unreach-fixed.yml" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && _ok "C2 quiet arm" "the same two commands, both guarded by \`||\`, are clean (rc 0)" \
                || _no "C2 quiet arm" "expected rc 0, got rc $rc: $out"

  # C2b — THE QUIET ARM MUST NOT BE QUIET FOR THE WRONG REASON. A single
  # `--selftest` step with no bare re-run below it (the many tripwire-only steps
  # in this repo) must also pass, or C2 would be indistinguishable from a rule
  # that fires on `--selftest` alone.
  cat > "$d/unreach-solo.yml" <<'Y'
name: unreach-solo
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: tripwire only
        run: |
          bash scripts/check-doc-budgets.sh --selftest
Y
  out="$(run_check "$d/unreach-solo.yml" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && _ok "C2b solo tripwire" "a --selftest with no bare re-run below it is NOT a finding (rc 0)" \
                || _no "C2b solo tripwire" "expected rc 0, got rc $rc: $out"

  # C3/C4 — BEHAVIOUR, under a real `bash -e`. The stand-in is a two-mode script
  # exactly like a doc gate: `--selftest` exits FAKE_ST, the bare run PRINTS THE
  # FINDING and exits FAKE_GATE.
  cat > "$d/gate.sh" <<'Y'
if [ "${1:-}" = "--selftest" ]; then
  echo "gate --selftest: FAILED — a constant sentence that names nothing"
  exit "${FAKE_ST:-0}"
fi
echo "FAIL: docs/cards/js-sdk.md is 2605B, cap is 2400B"
exit "${FAKE_GATE:-0}"
Y
  printf 'bash %s/gate.sh --selftest\nbash %s/gate.sh\n' "$d" "$d" > "$d/old-step.sh"
  printf 'st_rc=0; bash %s/gate.sh --selftest || st_rc=$?\ngate_rc=0; bash %s/gate.sh || gate_rc=$?\necho "selftest exit=$st_rc  gate exit=$gate_rc"\nif [ "$st_rc" -ne 0 ] || [ "$gate_rc" -ne 0 ]; then exit 1; fi\n' "$d" "$d" > "$d/new-step.sh"

  local o_out o_rc n_out n_rc
  o_out="$(FAKE_ST=1 FAKE_GATE=1 bash -e "$d/old-step.sh" 2>&1)"; o_rc=$?
  if [ "$o_rc" = 1 ] && ! printf '%s' "$o_out" | grep -q '^FAIL: docs/cards/js-sdk.md'; then
    _ok "C3 old shape, tripwire red" "exits 1 and the gate's per-file FAIL line NEVER reaches stdout"
  else
    _no "C3 old shape, tripwire red" "expected exit 1 with no per-file FAIL line; got rc $o_rc: $o_out"
  fi
  n_out="$(FAKE_ST=1 FAKE_GATE=1 bash -e "$d/new-step.sh" 2>&1)"; n_rc=$?
  if [ "$n_rc" = 1 ] && printf '%s' "$n_out" | grep -q '^FAIL: docs/cards/js-sdk.md'; then
    _ok "C4 new shape, tripwire red" "still exits 1, AND the per-file FAIL line now reaches stdout"
  else
    _no "C4 new shape, tripwire red" "expected exit 1 WITH the per-file FAIL line; got rc $n_rc: $n_out"
  fi
  # C5 — THE FIX MUST NOT SWALLOW A REAL FAILURE. Fails if someone "fixes" a
  # step with `|| true` or continue-on-error: a green gate + red tripwire, and a
  # red gate + green tripwire, must both still red.
  n_out="$(FAKE_ST=0 FAKE_GATE=1 bash -e "$d/new-step.sh" 2>&1)"; n_rc=$?
  [ "$n_rc" = 1 ] && _ok "C5 gate-only red" "a clean tripwire + failing gate still exits 1" \
                  || _no "C5 gate-only red" "expected exit 1, got rc $n_rc: $n_out"
  n_out="$(FAKE_ST=1 FAKE_GATE=0 bash -e "$d/new-step.sh" 2>&1)"; n_rc=$?
  [ "$n_rc" = 1 ] && _ok "C6 tripwire-only red" "a failing tripwire + clean gate still exits 1" \
                  || _no "C6 tripwire-only red" "expected exit 1, got rc $n_rc: $n_out"
  n_out="$(FAKE_ST=0 FAKE_GATE=0 bash -e "$d/new-step.sh" 2>&1)"; n_rc=$?
  [ "$n_rc" = 0 ] && _ok "C7 all green" "both clean still exits 0 — the fix does not manufacture a red" \
                  || _no "C7 all green" "expected exit 0, got rc $n_rc: $n_out"

  # ── D. THE BEHAVIOUR ARMS FOR THE DEAD CAPTURE ─────────────────────────
  # The scan above is a PROXY. These make the claim directly, in a real shell:
  # the blessed-until-2026-09-17 idiom loses the status, the `set +e` form keeps
  # it, and the `{ … } || :` form keeps it too. Run under `bash -e` because that
  # is the shell a `run:` block gets.
  # SUT_DIR was `unset` after the B arms (and these fixtures run under `set -u`,
  # where an unbound variable exits 1 — which read as a PASSING D1 and a failing
  # D2/D3 the first time this was written). Re-export it explicitly.
  export SUT_DIR="$d"
  cat > "$d/exit3.sh" <<'S'
echo "TERMINAL: the script spoke"
exit 3
S
  cat > "$d/ps-old.sh" <<'S'
set -uo pipefail
bash "$SUT_DIR/exit3.sh" | tee /dev/null || :
rc=${PIPESTATUS[0]}
echo "rc=$rc"
S
  cat > "$d/ps-setplus.sh" <<'S'
set -uo pipefail
set +e
bash "$SUT_DIR/exit3.sh" | tee /dev/null
rc=${PIPESTATUS[0]}
set -e
echo "rc=$rc"
S
  cat > "$d/ps-group.sh" <<'S'
set -uo pipefail
rc=0
{ bash "$SUT_DIR/exit3.sh" | tee /dev/null; rc=${PIPESTATUS[0]}; } || :
echo "rc=$rc"
S
  local d_out
  # D0 — THE FIXTURE CONTROL. D1's expected value is 0, which is also what a
  # fixture that never ran would produce for several reasons (an unbound
  # variable, a missing file). Assert the subject SPOKE before reading D1.
  d_out="$(bash -e "$d/ps-old.sh" 2>&1)"
  case "$d_out" in
    *'TERMINAL: the script spoke'*) _ok "D0 fixture control" "the exit-3 subject actually ran" ;;
    *) _no "D0 fixture control" "the subject never ran, so D1's 0 would mean nothing: $d_out" ;;
  esac
  d_out="$(printf '%s' "$d_out" | tail -1)"
  [ "$d_out" = "rc=0" ] && _ok "D1 old idiom loses the status" "\`| tee … || :\` then \${PIPESTATUS[0]} reads 0, not 3" \
                        || _no "D1 old idiom loses the status" "expected 'rc=0' (the defect), got '$d_out'"
  d_out="$(bash -e "$d/ps-setplus.sh" 2>&1 | tail -1)"
  [ "$d_out" = "rc=3" ] && _ok "D2 set +e keeps it" "the shipped remedy reads the pipeline's own 3" \
                        || _no "D2 set +e keeps it" "expected 'rc=3', got '$d_out'"
  d_out="$(bash -e "$d/ps-group.sh" 2>&1 | tail -1)"
  [ "$d_out" = "rc=3" ] && _ok "D3 guarded compound keeps it" "\`{ …; rc=\${PIPESTATUS[0]}; } || :\` reads 3" \
                        || _no "D3 guarded compound keeps it" "expected 'rc=3', got '$d_out'"
  # D4 — the step SURVIVES. A remedy that keeps the status but lets `-e` kill
  # the step has fixed nothing; both forms must reach their last line.
  bash -e "$d/ps-setplus.sh" >/dev/null 2>&1
  [ $? = 0 ] && _ok "D4 set +e step survives" "\`-e\` does not abort on the pipeline's exit 3" \
             || _no "D4 set +e step survives" "the step aborted — the diagnosis is still stolen"

  # ── D5. THE REPO IS CLEAN OF THE IDIOM ─────────────────────────────────
  # Not a fixture: the real tree. A new dead capture added anywhere under
  # .github/workflows/ reds here as well as in the scan.
  if [ -d .github/workflows ]; then
    out="$(run_check .github/workflows 2>&1)"; rc=$?
    case "$out" in
      *'DEAD PIPESTATUS'*) _no "D5 live tree" "a DEAD PIPESTATUS capture is live in .github/workflows: $out" ;;
      *) _ok "D5 live tree" "no DEAD PIPESTATUS capture under .github/workflows (rc $rc)" ;;
    esac
  fi

  local total=$((_pass + _fail))
  if [ "$total" -lt 8 ]; then
    echo "SELFTEST: CANNOT READ — only $total arm(s) ran"
    return 2
  fi
  if [ "$_fail" = 0 ]; then
    echo "SELFTEST: $_pass/$total arms pass"
    echo "TERMINAL: exit 0"
    return 0
  fi
  echo "SELFTEST: $_fail of $total arm(s) FAILED"
  echo "TERMINAL: exit 1"
  return 1
}

if [ "$SELFTEST" -eq 1 ]; then
  _selftest
  exit $?
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  TARGETS=(".github/workflows")
fi
run_check "${TARGETS[@]}"
exit $?
