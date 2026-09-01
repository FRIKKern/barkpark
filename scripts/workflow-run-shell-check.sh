#!/usr/bin/env bash
# workflow-run-shell-check.sh — every `run:` body in .github/workflows must be
# valid shell. A workflow step is a shell script that nothing ever parses until
# it runs in CI, on a PR, once.
#
# THE DEFECT THAT MOTIVATED IT (a real one, caught by CI and not by review)
# ------------------------------------------------------------------------
# architecture.yml's warm-graph assertion is one long `node -e '<js>'`. Someone
# wrote an apostrophe inside a COMMENT in that JavaScript:
#
#     // reuse build-index.mjs's wording verbatim, so a SINGLE run printed …
#                          ^ closes the shell string, 20 lines early
#
# node then received a truncated program and died:
#
#     [eval]:22
#         // reuse build-index.mjss
#     SyntaxError: Unexpected end of input
#     Process completed with exit code 1
#
# Exit 1 is ci-boundary.mjs's REGRESSION code. So a step that could not start
# was indistinguishable, in the check list, from a step that had found
# architectural debt — a fault wearing a finding's exit code, which is the one
# collision the surrounding workflow was written to prevent.
#
# `bash -n` over the step body catches it: `syntax error near unexpected token`,
# rc=2. That is the whole gate.
#
# WHY A TEXT SCAN FOR APOSTROPHES WOULD BE THE WRONG GATE. An apostrophe is one
# spelling of one instance. Unbalanced double quotes, an unterminated heredoc, a
# stray backtick and a `case` without `esac` are the same defect wearing
# different clothes, and a matcher tuned to the instance we happened to hit
# would report a FLOOR while sounding like a TOTAL. Parsing answers all of them
# at once.
#
# CLEAN-TREE, NOT NEVER-WORSE — DELIBERATELY, AND MEASURED FIRST. At the time of
# writing all 444 shell `run:` bodies across the workflow corpus parse (2 more
# declare a non-shell `shell:` and are skipped by name). There is no debt to
# grandfather, so there is no baseline to freeze — and no baseline is a baseline
# that cannot rot. If this ever reds, a step really cannot start.
#
# COVERAGE IS ASSERTED, NOT ASSUMED. A gate over zero inputs reports success.
# This one FAILS if it checked nothing, prints how many bodies it checked versus
# how many exist, and names every step it skipped and why. You can always tell
# what it did not look at.
#
# NO APOSTROPHES AND NO BACKTICKS IN THE PYTHON BLOCKS BELOW — the gate caught
# itself twice, an hour apart, on the two characters. Each probe is a quoted
# heredoc inside a command substitution, `EXTRACT="$(cat <<'PY' …)"`.
# bash 5 honours the quoting and leaves the body alone; **bash 3.2, which is
# what macOS ships**, does not — it scans for the closing paren THROUGH the
# heredoc, so a lone apostrophe in a Python comment (`# Actions' default`) is an
# unterminated quote and the whole file fails to parse:
#
#   workflow-run-shell-check.sh: line 311: syntax error near unexpected token `}'
#
# It would have been GREEN in CI (ubuntu, bash 5) and RED on every macOS
# developer machine — a gate that only works where nobody edits it. Keep the
# block apostrophe-free; `bash -n scripts/workflow-run-shell-check.sh` on macOS
# is the check that this stayed true.
#
# ── ARM B: process.exit() in a script a workflow PIPES ───────────────────────
#
# Node does not flush a pending stdout write before process.exit(). When stdout
# is a PIPE the write is asynchronous, so a script that prints a report and then
# calls process.exit() can be TRUNCATED mid-payload — and the truncation is
# invisible, because the exit status is whatever was passed.
#
# ci-boundary.mjs is the reference implementation: it routes every exit through
# process.exitCode at a single exit point and explains this race in its own
# header. It is also the near-miss that proves the risk is not theoretical --
# its piped output measured 63,459 bytes against a 65,536 pipe buffer, 96 percent
# of the floor, roughly three more regressions from crossing. It is safe because
# of the exitCode discipline, NOT because it is small. This arm exists so that
# nobody simplifies that discipline back into an exit() and truncates the gate
# findings.
#
# WHAT IT SCANS: only scripts a workflow actually pipes. Repo-wide the
# process.exit( population is 92 files; the piped set is four, and the other 88
# are none of this gate business -- several use process.exit to break a loop
# where the exit CODE is the payload, and rewriting those would be a regression.
#
# THE ESCAPE HATCH IS VISIBLE. A guard that must abort before anything is
# spawned, writing one short stderr line, is not the defect this arm is about.
# Put `pipe-exit-ok: <reason>` in a comment on the same line and it stands down.
# One grep audits every such decision, which a hidden allowlist would not.
#
# COMMENTS ARE NOT CODE. A line whose content starts with a comment marker is
# skipped, so prose that merely mentions process.exit() -- including this header
# -- is never a finding. A scanner that cannot tell prose from payload reports
# noise until it is ignored.
#
# EXIT CODES, kept distinct on purpose:
#   0  every checked body parses
#   1  FINDING — at least one body is not valid shell
#   2  HARNESS-UNAVAILABLE — no python3, no PyYAML, or no bash. NOT a pass and
#      NOT a verdict: a gate that cannot read its input must not certify it.
#
# Usage:
#   scripts/workflow-run-shell-check.sh            # check (CI + gate)
#   scripts/workflow-run-shell-check.sh --list     # every body checked/skipped
#   scripts/workflow-run-shell-check.sh --selftest # prove the gate can fail
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Overridable so --selftest drives a synthetic tree and plants nothing real.
WF_DIR="${WORKFLOW_RUN_SHELL_DIR:-$ROOT/.github/workflows}"
# Arm B resolves piped script paths against this. Overridable for the same
# reason WF_DIR is: the selftest drives synthetic trees, and the arming proof
# points it at an export of origin/main to show the arm reds on the real
# pre-fix tree rather than only on a fixture.
ROOT="${WORKFLOW_RUN_SHELL_ROOT:-$ROOT}"

MODE="${1:-check}"

command -v bash >/dev/null 2>&1 || {
  echo "HARNESS-UNAVAILABLE: bash is not on PATH — cannot parse any step body." >&2
  echo "This is NOT a pass: a gate that cannot read its input must not certify it." >&2
  exit 2
}
command -v python3 >/dev/null 2>&1 || {
  echo "HARNESS-UNAVAILABLE: python3 not on PATH — cannot read workflow YAML." >&2
  echo "This is NOT a pass. Install python3 + PyYAML (pip install pyyaml) and re-run." >&2
  exit 2
}

# Emits one record per `run:` body: "<file>\t<job>\t<step>\t<shell>\t<path-to-body>",
# plus a trailing "SKIP\t…" per non-shell step and "TOTAL\t<n>".
EXTRACT="$(cat <<'PY'
import glob, os, re, sys, tempfile

try:
    import yaml
except ImportError:
    print("PyYAML not importable", file=sys.stderr)
    sys.exit(2)

wf_dir, outdir = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(wf_dir, "*.yml")) + glob.glob(os.path.join(wf_dir, "*.yaml")))

# GitHub substitutes ${{ … }} BEFORE the shell ever sees the body, so the raw
# expression is not shell input and must not be parsed as such. Replace it with
# an inert word. Non-greedy + DOTALL: an expression may span lines and may
# contain a closing brace inside a function call.
EXPR = re.compile(r"\$\{\{.*?\}\}", re.S)

# Shells whose bodies bash can parse. Anything else (pwsh, python, cmd, a custom
# `shell: <cmd> {0}`) is skipped BY NAME so the skip is visible, never silent.
BASHLIKE = {"bash", "sh"}

def shell_of(step, job, doc):
    for src in (step,
                (job.get("defaults") or {}).get("run") or {},
                (doc.get("defaults") or {}).get("run") or {}):
        if isinstance(src, dict) and src.get("shell"):
            return str(src["shell"])
    return "bash"          # the Actions default for Linux/macOS runners

total = 0
for path in files:
    try:
        with open(path, "rb") as fh:
            doc = yaml.safe_load(fh)
    except Exception as exc:
        print("YAMLFAIL\t%s\t%s" % (os.path.basename(path), " ".join(str(exc).split())))
        continue
    if not isinstance(doc, dict):
        continue
    for jname, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        for i, step in enumerate(job.get("steps") or []):
            if not isinstance(step, dict) or "run" not in step:
                continue
            total += 1
            name = str(step.get("name") or ("step[%d]" % i))
            sh = shell_of(step, job, doc)
            base = sh.split()[0] if sh else "bash"
            if base not in BASHLIKE:
                print("SKIP\t%s\t%s\t%s\t%s" % (os.path.basename(path), jname, name, sh))
                continue
            body = EXPR.sub("EXPR", str(step["run"]))
            fd, tmp = tempfile.mkstemp(suffix=".sh", dir=outdir)
            with os.fdopen(fd, "w") as fh:
                fh.write(body)
            print("BODY\t%s\t%s\t%s\t%s\t%s" % (os.path.basename(path), jname, name, base, tmp))
print("TOTAL\t%d" % total)
PY
)"

# Emits one record per offending site:
#   PIPEHIT\t<script>\t<line>\t<text>
# plus PIPEFILE\t<script> per piped script found, and PIPESCANNED\t<n>.
PIPEPROBE="$(cat <<'PY'
import glob, os, re, sys

try:
    import yaml
except ImportError:
    print("PyYAML not importable", file=sys.stderr)
    sys.exit(2)

wf_dir, root = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(wf_dir, "*.yml")) + glob.glob(os.path.join(wf_dir, "*.yaml")))

EXPR = re.compile(r"\$\{\{.*?\}\}", re.S)
# A repo script handed to an interpreter, somewhere before a single pipe.
SCRIPT = re.compile(r"(?:node|bash|sh|python3)\s+(?:--\S+\s+)*([\w./-]+\.(?:mjs|cjs|js|sh|py))")
# A real call, not a mention. Comment lines are dropped before this is applied,
# and so is every single-line string span -- ci-boundary.mjs carries
# process.exit() inside note(`...`) guidance prose, and reading that as a call
# is the same prose-vs-payload error this gate exists to avoid.
CALL = re.compile(r"process\.exit\s*\(")
COMMENT = re.compile(r"^\s*(//|#|\*|/\*)")
# BT and SQ are built with chr() on purpose: a literal backtick or apostrophe
# in this heredoc terminates the enclosing construct under bash 3.2. Same
# class as the apostrophe bug in the header, one character over.
BT = chr(96)
SQ = chr(39)
STRINGS = re.compile(
    BT + "[^" + BT + "]*" + BT
    + "|" + chr(34) + "[^" + chr(34) + "]*" + chr(34)
    + "|" + SQ + "[^" + SQ + "]*" + SQ
)

piped = set()
for path in files:
    try:
        with open(path, "rb") as fh:
            doc = yaml.safe_load(fh)
    except Exception:
        continue
    if not isinstance(doc, dict):
        continue
    for job in (doc.get("jobs") or {}).values():
        if not isinstance(job, dict):
            continue
        for step in (job.get("steps") or []):
            if not isinstance(step, dict) or "run" not in step:
                continue
            body = EXPR.sub("EXPR", str(step["run"]))
            for line in body.split("\n"):
                if COMMENT.match(line):
                    continue
                # a single pipe, not a logical or
                bar = re.sub(r"\|\|", "", line)
                if "|" not in bar:
                    continue
                head = bar.split("|")[0]
                m = SCRIPT.search(head)
                if m:
                    piped.add(m.group(1))

scanned = 0
for rel in sorted(piped):
    full = os.path.join(root, rel)
    if not os.path.isfile(full):
        continue
    scanned += 1
    print("PIPEFILE\t%s" % rel)
    with open(full, encoding="utf-8", errors="replace") as fh:
        for n, line in enumerate(fh, 1):
            if COMMENT.match(line):
                continue
            if "pipe-exit-ok" in line:
                continue
            if not CALL.search(STRINGS.sub("", line)):
                continue
            print("PIPEHIT\t%s\t%d\t%s" % (rel, n, line.strip()[:120]))
print("PIPESCANNED\t%d" % scanned)
PY
)"

run_pipe_check() {
  # `kind a b c` MUST be local. They are the read-loop's fields below, and
  # without `local` they are GLOBAL — so this arm's loop overwrote `run_both`'s
  # `a` and `b`, which hold arm A's and arm B's exit codes. Arm B then erased
  # arm A's verdict on its way past. Measured: arm A exited 1, arm B exited 0,
  # and run_both returned 0.
  local tmp records rc=0 hits=0 files=0 kind a b c
  tmp="$(mktemp -d -t wrsc-pipe-XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  records="$(printf '%s\n' "$PIPEPROBE" | python3 - "$WF_DIR" "$ROOT" 2>"$tmp/err")"
  if [ $? -ne 0 ]; then
    echo "HARNESS-UNAVAILABLE: $(cat "$tmp/err")" >&2
    return 2
  fi

  while IFS=$'\t' read -r kind a b c; do
    case "$kind" in
      PIPESCANNED) files="$a" ;;
      PIPEFILE) [ "$MODE" = "--list" ] && echo "piped $a" ;;
      PIPEHIT)
        hits=$((hits + 1))
        echo "FAIL  $a:$b  process.exit() in a script a workflow PIPES"
        echo "        $c"
        rc=1
        ;;
    esac
  done <<< "$records"

  if [ "$files" -eq 0 ]; then
    echo "FAIL  arm B found NO piped scripts — it inspected nothing." >&2
    echo "      A gate over zero inputs reports success; that is not a pass." >&2
    return 1
  fi

  if [ "$rc" -eq 0 ]; then
    echo "workflow-run-shell-check(arm B): OK — $files piped script(s), no unmarked process.exit()"
  else
    echo ""
    echo "workflow-run-shell-check(arm B): FAILED — $hits unmarked process.exit() in $files piped script(s)."
    echo "  Node does not flush a pending stdout write before process.exit(). Into a"
    echo "  pipe that can TRUNCATE the payload, silently, with the exit code intact."
    echo "  FIX: set process.exitCode and let node exit on its own (return first if"
    echo "  you are inside a function). If aborting IS the behaviour — a guard that"
    echo "  must stop before anything is spawned, writing one short stderr line —"
    echo "  add \`pipe-exit-ok: <reason>\` in a comment on the same line."
  fi
  return "$rc"
}

run_check() {
  local tmpdir records rc=0 checked=0 skipped=0 total=0 yamlfail=0
  tmpdir="$(mktemp -d -t wrsc-XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN

  records="$(printf '%s\n' "$EXTRACT" | python3 - "$WF_DIR" "$tmpdir" 2>"$tmpdir/err")"
  if [ $? -ne 0 ]; then
    echo "HARNESS-UNAVAILABLE: $(cat "$tmpdir/err")" >&2
    echo "This is NOT a pass: a gate that cannot read its input must not certify it." >&2
    return 2
  fi

  while IFS=$'\t' read -r kind a b c d e; do
    case "$kind" in
      TOTAL) total="$a" ;;
      YAMLFAIL)
        yamlfail=$((yamlfail + 1))
        echo "FAIL  $a — workflow does not parse as YAML: $b"
        rc=1
        ;;
      SKIP)
        skipped=$((skipped + 1))
        [ "$MODE" = "--list" ] && echo "skip  $a :: $b :: $c  (shell: $d)"
        ;;
      BODY)
        checked=$((checked + 1))
        if ! err="$(bash -n "$e" 2>&1)"; then
          echo "FAIL  $a :: $b :: $c"
          printf '%s\n' "$err" | sed 's/^/        /'
          echo "        The step body is not valid $d. It cannot start in CI."
          rc=1
        elif [ "$MODE" = "--list" ]; then
          echo "ok    $a :: $b :: $c  ($d)"
        fi
        ;;
    esac
  done <<< "$records"

  # A gate over zero inputs reports success. Refuse to be that gate.
  if [ "$checked" -eq 0 ]; then
    echo "FAIL  checked 0 run: bodies in $WF_DIR — the gate inspected nothing." >&2
    echo "      A gate over zero inputs reports success; that is not a pass." >&2
    return 1
  fi

  if [ "$rc" -eq 0 ]; then
    echo "workflow-run-shell-check: OK — $checked of $total run: body/bodies parse as shell ($skipped skipped: non-shell \`shell:\`)"
  else
    echo ""
    echo "workflow-run-shell-check: FAILED — see the labelled failure(s) above."
    echo "  Checked $checked of $total run: body/bodies; $skipped skipped; $yamlfail unparseable workflow(s)."
  fi
  return "$rc"
}

selftest() {
  local dir pass=0 fail=0
  dir="$(mktemp -d -t wrsc-st-XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf '$dir'" RETURN

  st() { # st <label> <expected-rc> ; workflow already written
    local label="$1" want="$2" got out
    # Re-invokes THIS script as a child, pointed at the synthetic tree. The
    # child re-reads MODE from $1, so pass no args: it runs the default check.
    out="$(WORKFLOW_RUN_SHELL_DIR="$dir" "$0" --arm-a 2>&1)"; got=$?
    if [ "$got" = "$want" ]; then
      echo "  ok    $label — exit $got"
      pass=$((pass + 1))
    else
      echo "  FAIL  $label — got $got want $want"
      printf '%s\n' "$out" | sed 's/^/          /'
      fail=$((fail + 1))
    fi
  }

  echo "workflow-run-shell-check --selftest"
  echo ""

  # (0) a clean workflow passes
  cat > "$dir/w.yml" <<'YML'
name: t
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - name: fine
        run: |
          set -euo pipefail
          echo "hello"
YML
  st "0) a clean run: body passes" 0

  # (a) THE REAL DEFECT: an apostrophe inside a single-quoted node -e body
  cat > "$dir/w.yml" <<'YML'
name: t
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - name: apostrophe closes the string early
        run: |
          node -e '
            // build-index.mjs's wording — this apostrophe truncates the program
            console.log("never reached");
          '
YML
  st "a) an apostrophe in a single-quoted node -e body REDS" 1

  # (b) unterminated double quote — same class, different spelling
  cat > "$dir/w.yml" <<'YML'
name: t
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - name: unbalanced double quote
        run: |
          echo "open and never closed
YML
  st "b) an unterminated double quote REDS" 1

  # (c) ${{ }} expressions must NOT be parsed as shell — no false positive
  cat > "$dir/w.yml" <<'YML'
name: t
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - name: expression is substituted before the shell sees it
        run: |
          echo "ref is ${{ github.ref }} and ${{ toJSON(github.event.inputs) }}"
YML
  st "c) a \${{ }} expression does not false-positive" 0

  # (d) a non-shell `shell:` is skipped BY NAME, not silently parsed as bash
  cat > "$dir/w.yml" <<'YML'
name: t
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - name: python step that is not shell at all
        shell: python
        run: |
          x = {"not": "shell"}
          print(f"{x}")
      - name: one real shell step so coverage is non-zero
        run: echo ok
YML
  st "d) a non-shell shell: is skipped, not mis-parsed" 0

  # (e) a workflow that is not valid YAML REFUSES — never a silent skip
  printf 'name: t\non: [push]\njobs:\n  a:\n   steps:\n  - run: |\n     oops\n\tbad-tab\n' > "$dir/w.yml"
  st "e) an unparseable workflow REFUSES by name" 1

  # (f) zero inputs must FAIL, not pass vacuously
  rm -f "$dir"/*.yml
  st "f) zero run: bodies FAILS — a gate over nothing is not a pass" 1

  # ── arm B ────────────────────────────────────────────────────────────────
  local bdir
  bdir="$(mktemp -d -t wrsc-b-XXXXXX)"
  mkdir -p "$bdir/.github/workflows" "$bdir/tooling"

  stb() { # stb <label> <expected-rc>
    local label="$1" want="$2" got out
    out="$(WORKFLOW_RUN_SHELL_DIR="$bdir/.github/workflows" WORKFLOW_RUN_SHELL_ROOT="$bdir" "$0" --arm-b 2>&1)"; got=$?
    if [ "$got" = "$want" ]; then
      echo "  ok    $label — exit $got"
      pass=$((pass + 1))
    else
      echo "  FAIL  $label — got $got want $want"
      printf %s\\n "$out" | sed "s/^/          /"
      fail=$((fail + 1))
    fi
  }

  cat > "$bdir/.github/workflows/w.yml" <<'YML'
name: t
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - name: piped
        run: node tooling/r.mjs --json | tee /tmp/out.txt
YML

  printf %s\\n "console.log(1); process.exitCode = 0;" > "$bdir/tooling/r.mjs"
  stb "B0) a piped script using process.exitCode passes" 0

  printf %s\\n "console.log(1); process.exit(0);" > "$bdir/tooling/r.mjs"
  stb "Ba) a piped script calling process.exit() REDS" 1

  printf %s\\n "console.log(1); process.exit(0); // pipe-exit-ok: adjudicated" > "$bdir/tooling/r.mjs"
  stb "Bb) the pipe-exit-ok hatch stands down" 0

  printf %s\\n "// prose about process.exit() in a comment" > "$bdir/tooling/r.mjs"
  stb "Bc) a MENTION in a comment is not a call" 0

  printf %s\\n "note(\`do not call process.exit() here\`);" > "$bdir/tooling/r.mjs"
  stb "Bd) a MENTION inside a string literal is not a call" 0

  cat > "$bdir/.github/workflows/w.yml" <<'YML'
name: t
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - name: not piped
        run: node tooling/r.mjs --json
YML
  printf %s\\n "console.log(1); process.exit(0);" > "$bdir/tooling/r.mjs"
  stb "Be) an UNPIPED script is out of scope — and zero inputs still FAILS" 1

  rm -rf "$bdir"

  # ── the COMBINER (arm C) ─────────────────────────────────────────────────
  # Every case above runs ONE arm in isolation via --arm-a or --arm-b. That is
  # exactly how the masking survived: arm A's detection was well covered, and
  # how the two verdicts COMBINE was covered by nothing. Measured on
  # origin/main before this fix — arm A exited 1, arm B exited 0, and the
  # default mode exited 0 while printing "FAILED", because run_pipe_check's
  # read loop (`read -r kind a b c`, un-localised) overwrote run_both's `a`,
  # and `[ -z "$a" ] && a=0` then turned the lost verdict into a pass.
  # Consequence: deprecate.yml's "Resolve the range" step was unparseable bash,
  # unable to start in CI, and every run was green over it.
  local cdir
  cdir="$(mktemp -d -t wrsc-c-XXXXXX)"
  mkdir -p "$cdir/.github/workflows" "$cdir/tooling"

  stc() { # stc <label> <expected-rc> — DEFAULT mode, both arms, the combiner
    local label="$1" want="$2" got out
    out="$(WORKFLOW_RUN_SHELL_DIR="$cdir/.github/workflows" WORKFLOW_RUN_SHELL_ROOT="$cdir" "$0" 2>&1)"; got=$?
    if [ "$got" = "$want" ]; then
      echo "  ok    $label — exit $got"
      pass=$((pass + 1))
    else
      echo "  FAIL  $label — got $got want $want"
      printf %s\\n "$out" | sed "s/^/          /"
      fail=$((fail + 1))
    fi
  }

  # Arm A FAILS (unterminated quote — the real deprecate.yml defect), while
  # arm B is clean and passes. The combined verdict must be the FAILURE.
  # This is the case that reproduces the bug: it returned 0 before the fix.
  cat > "$cdir/.github/workflows/w.yml" <<'YML'
name: t
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - name: arm A fails — a command substitution whose quote is never closed
        run: |
          set -euo pipefail
          MATCHED="$(printf '%s' "x" | node -e 'process.stdout.write("y")')
          echo "done"
      - name: arm B input — piped and clean
        run: node tooling/r.mjs --json | tee /tmp/out.txt
YML
  printf %s\\n "console.log(1); process.exitCode = 0;" > "$cdir/tooling/r.mjs"
  stc "C0) arm A fails + arm B passes => the FAILURE wins, never masked" 1

  # The mirror: arm B fails while arm A is clean. Neither arm may mask the other.
  cat > "$cdir/.github/workflows/w.yml" <<'YML'
name: t
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - name: arm A input — parses fine
        run: |
          set -euo pipefail
          echo "hello"
      - name: arm B input — piped
        run: node tooling/r.mjs --json | tee /tmp/out.txt
YML
  printf %s\\n "console.log(1); process.exit(0);" > "$cdir/tooling/r.mjs"
  stc "C1) arm B fails + arm A passes => the FAILURE wins, never masked" 1

  # NON-VACUITY. Without this the two cases above would also pass against a
  # combiner hard-wired to return 1.
  cat > "$cdir/.github/workflows/w.yml" <<'YML'
name: t
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - name: arm A input — parses fine
        run: |
          set -euo pipefail
          echo "hello"
      - name: arm B input — piped and clean
        run: node tooling/r.mjs --json | tee /tmp/out.txt
YML
  printf %s\\n "console.log(1); process.exitCode = 0;" > "$cdir/tooling/r.mjs"
  stc "C2) both arms pass => the combiner still says 0" 0

  rm -rf "$cdir"

  echo ""
  if [ "$fail" -eq 0 ]; then
    echo "SELFTEST PASSED: $pass of $((pass + fail)) arms"
    return 0
  fi
  echo "SELFTEST FAILED: $fail of $((pass + fail)) arm(s) did not behave"
  return 1
}

# Both arms always run; the worse exit code wins so neither can mask the other.
run_both() {
  local a b
  run_check; a=$?
  echo ""
  run_pipe_check; b=$?
  # A RETURN trap can clobber $? under bash 3.2, and an empty operand makes
  # `[ -gt ]` abort with "integer expression expected" — a harness crash rather
  # than either arm verdict. That much was right.
  #
  # But coercing the empty value to ZERO was the bug, not the cure: it turned a
  # LOST verdict into a PASS. Combined with run_pipe_check's un-localised read
  # loop (fixed above), arm A's failure was erased and this function returned 0
  # while printing "workflow-run-shell-check: FAILED". Measured on origin/main:
  # arm A exited 1, arm B exited 0, run_both exited 0 — and deprecate.yml's
  # "Resolve the range" step had been unparseable bash, unable to start in CI,
  # with every run green over it.
  #
  # An absent verdict is now a CONFIGURATION FAULT (3), never a pass. A checker
  # that cannot say what it measured must not say "OK".
  if [ -z "$a" ] || [ -z "$b" ]; then
    echo "::error::workflow-run-shell-check: an arm returned no verdict (arm A='${a}', arm B='${b}'). Refusing to report a result — an absent verdict is not a pass." >&2
    return 3
  fi
  [ "$a" -gt "$b" ] && return "$a"
  return "$b"
}

case "$MODE" in
  --selftest) selftest ;;
  --arm-a) run_check ;;
  --arm-b) run_pipe_check ;;
  --list|check) run_both ;;
  *) echo "usage: $0 [--list|--selftest|--arm-a|--arm-b]" >&2; exit 64 ;;
esac
