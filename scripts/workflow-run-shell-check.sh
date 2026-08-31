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
# NO APOSTROPHES IN THE PYTHON BLOCK BELOW — the gate caught itself. The probe
# is a quoted heredoc inside a command substitution, `EXTRACT="$(cat <<'PY' …)"`.
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
    out="$(WORKFLOW_RUN_SHELL_DIR="$dir" "$0" 2>&1)"; got=$?
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

  echo ""
  if [ "$fail" -eq 0 ]; then
    echo "SELFTEST PASSED: $pass of $((pass + fail)) arms"
    return 0
  fi
  echo "SELFTEST FAILED: $fail of $((pass + fail)) arm(s) did not behave"
  return 1
}

case "$MODE" in
  --selftest) selftest ;;
  --list|check) run_check ;;
  *) echo "usage: $0 [--list|--selftest]" >&2; exit 64 ;;
esac
