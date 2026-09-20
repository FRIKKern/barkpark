#!/usr/bin/env bash
# workflow-run-block-length-check.sh — the cap that takes the WHOLE workflow
# down, measured on every PR instead of discovered in CI after the merge.
#
# ── THE FAILURE THIS ANSWERS, quoted ─────────────────────────────────────────
# MEASURED 2026-09-18 (task-91e5ae77bb475fe1, seen by deploy-w2 building #19291).
# Adding eleven roster rows to the `changes` job's `run:` block in
# .github/workflows/shell-harnesses.yml made GitHub refuse the WHOLE file:
#
#   Invalid workflow file: .github/workflows/shell-harnesses.yml#L1
#   (Line: 1529, Col: 14): Exceeded max expression length 21000
#
# The dangerous part is not the size, it is the SHAPE of the failure: a STARTUP
# FAILURE with ZERO jobs. Every harness in the workflow goes dark at once, and
# it renders as a `push`-event run on a branch the push filter excludes, so
# nobody is looking. actionlint, PyYAML, `shell-harnesses-dispatch.test.sh` (22
# arms) and every other local gate PASSED the broken file. A YAML parser cannot
# see this: the file is valid YAML. The cap is in Actions' EXPRESSION parser,
# one layer above.
#
# ── WHAT GITHUB ACTUALLY COUNTS, derived by measurement, not from the docs ───
# The discriminator is INTERPOLATION, not size. Measured on origin/main
# c0e04a7ea (the merge base of this file's PR), over all 647 `run:` blocks in
# .github/workflows/*.yml:
#
#   30379 chars  deploy.yml            record-delivery step[2]   NO ${{ }}
#   19952 chars  shell-harnesses.yml   changes         step[1]   HAS ${{ }}   <- the subject
#   19528 chars  cp-ops.yml            run             step[1]   NO ${{ }}
#
# deploy.yml's block is 30379 characters — 9379 OVER the 21000 cap — and it has
# shipped green on main for weeks. That is the control, and it is decisive: the
# cap does NOT apply to a plain literal `run:` scalar. A `run:` string
# containing `${{ ... }}` is compiled by Actions into a single interpolated
# expression, and THAT token is what the 21000 cap measures; a string with no
# `${{` is never handed to the expression parser at all.
#
# So the guarded population is DERIVED by measurement — every `run:` block in
# the tree whose scalar contains `${{` — not from a list of filenames. The set
# moves on its own when a block gains an interpolation, which is exactly the
# transition that would otherwise arm the bomb silently.
#
# THE UNIT. The criterion says bytes, and bytes is also the CONSERVATIVE
# reading, so this file counts UTF-8 bytes of the scalar AFTER YAML folding
# (what PyYAML hands back for a `|` block — newlines preserved, the `${{ }}`
# markup included verbatim, because the cap is on the template text and not on
# any expansion of it).
#
# I could not determine GitHub's exact counting rule from the outside: the
# runner is .NET, where `string.Length` is UTF-16 CODE UNITS, not bytes and not
# codepoints. For the subject block those three readings are 19952 codepoints /
# 19952 UTF-16 units / 19968 bytes. Bytes is >= UTF-16 units for every possible
# input (UTF-8 never encodes a BMP char in fewer bytes than its UTF-16 units,
# and an astral char is 4 bytes to 2 units), so measuring bytes can only fire
# EARLY, never late. Stated margin: on the subject block the byte reading is 16
# units pessimistic, 0.08%.
#
# ── THE TWO FLOORS ───────────────────────────────────────────────────────────
# FAIL_FLOOR reds. WARN_FLOOR only speaks. The gap exists because the subject
# already sits INSIDE the warn band (19968 of 21000) and the roster it carries
# grows every wave: a gate that only ever speaks at the last 1000 bytes gives
# the author of the next roster row no room to notice. The warn line is the
# thing that is supposed to fire first, and on this tree it already has.
#
#   CAP        21000  GitHub's, quoted from its own error text.
#   FAIL_FLOOR 20000  1000 under the cap — one average roster row of margin,
#                     so the red lands on the PR BEFORE the one that breaks it.
#   WARN_FLOOR 19000  2000 under the cap.
#
# MEASURED AT THIS FILE'S MERGE BASE, origin/main c0e04a7ea, so the next reader
# knows the headroom without re-deriving it (criterion 3):
#
#   .github/workflows/shell-harnesses.yml  job `changes`  step[1]
#   "Compute the changed-path set per harness"
#       19968 bytes  (19952 chars) of the 21000 cap  —  1032 bytes of headroom
#                     to the cap, and only 32 bytes under FAIL_FLOOR. It sits in
#                     the WARN band today and the next roster row reds it: that
#                     is the design, not an accident. The red is the invitation
#                     to move the bulk into a script under scripts/ before the
#                     cap does it for you, with zero jobs and no message.
#
# The row that filed this read 19654 on an earlier main and 19865 after #19291.
# It was 19968 at that measurement. The block grew ~100-300 bytes a wave; at
# that rate it would have reached FAIL_FLOOR in four to ten waves.
#
# RESOLVED 2026-09-20 (task-ca50ed283930706a). It did not get there: that body
# moved to scripts/shell-harness-dispatch.sh and the two GitHub values are
# passed as step `env:`, so the scalar is 38 LITERAL bytes and the expression
# parser never sees it. The subject above is therefore HISTORY, not the current
# tree — the largest interpolated block today is deploy.yml's `changes` step at
# 16118. Nothing about this gate changes: the population is still DERIVED (every
# `run:` scalar containing `${{`), so whichever block grows next is measured
# without anyone updating a list. The fix the red asks for is the fix that was
# taken, which is the whole point of naming it in the FAIL text below.
#
# ── BOTH FAILURE DIRECTIONS, NAMED ───────────────────────────────────────────
# RED (exit 1): an INTERPOLATED block is over FAIL_FLOOR. That is the real bomb.
# WARN (exit 0): either a block is in the warn band, or a NON-interpolated block
#   is over FAIL_FLOOR. The second is not a defect today — deploy.yml's 30379
#   is the proof — but such a block is ONE `${{ }}` away from a startup failure,
#   and whoever adds that interpolation deserves to have been told.
# REFUSED (exit 2): zero files, zero `run:` blocks in the scan, unparseable
#   YAML, missing PyYAML, unknown flag. Never 0 — a scan that measured nothing
#   is not a pass, and this whole family of checks refuses a vacuous green.

set -uo pipefail

CAP=21000
FAIL_FLOOR=20000
WARN_FLOOR=19000
TARGET_DIR=".github/workflows"
SELFTEST=0
FILES=()

usage() {
  echo "usage: $0 [--selftest] [--dir DIR] [--fail-floor N] [--warn-floor N] [--cap N] [FILE...]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --selftest) SELFTEST=1; shift ;;
    --dir)
      [ "$#" -ge 2 ] || { echo "workflow-run-block-length-check: --dir needs a path" >&2; exit 2; }
      TARGET_DIR="$2"; shift 2 ;;
    --dir=*) TARGET_DIR="${1#--dir=}"; shift ;;
    --fail-floor) FAIL_FLOOR="$2"; shift 2 ;;
    --warn-floor) WARN_FLOOR="$2"; shift 2 ;;
    --cap) CAP="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ "$#" -gt 0 ]; do FILES+=("$1"); shift; done ;;
    -*)
      # An unknown flag NEVER passes. A typo'd flag that exits 0 is a gate that
      # silently stopped checking.
      echo "workflow-run-block-length-check: unknown option '$1'" >&2
      echo "workflow-run-block-length-check: CANNOT MEASURE (rc 2)" >&2
      exit 2 ;;
    *) FILES+=("$1"); shift ;;
  esac
done

measure() {
  CAP="$CAP" FAIL_FLOOR="$FAIL_FLOOR" WARN_FLOOR="$WARN_FLOOR" python3 - "$@" <<'PY'
import os
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("workflow-run-block-length-check: PyYAML is not importable — CANNOT MEASURE (rc 2)\n")
    sys.exit(2)

CAP = int(os.environ["CAP"])
FAIL_FLOOR = int(os.environ["FAIL_FLOOR"])
WARN_FLOOR = int(os.environ["WARN_FLOOR"])

args = sys.argv[1:]
files = []
for a in args:
    if os.path.isdir(a):
        for name in sorted(os.listdir(a)):
            if name.endswith((".yml", ".yaml")):
                files.append(os.path.join(a, name))
    else:
        files.append(a)

if not files:
    sys.stderr.write("workflow-run-block-length-check: zero workflow files to scan — CANNOT MEASURE (rc 2)\n")
    sys.exit(2)


def walk(doc, path):
    """Yield (file, job_id, step_index, step_name, run_scalar) for every run: block."""
    if not isinstance(doc, dict):
        return
    jobs = doc.get("jobs")
    if not isinstance(jobs, dict):
        return
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            continue
        steps = job.get("steps")
        if not isinstance(steps, list):
            continue
        for idx, step in enumerate(steps):
            if not isinstance(step, dict):
                continue
            run = step.get("run")
            if isinstance(run, str) and run != "":
                name = step.get("name") if isinstance(step.get("name"), str) else ""
                yield (path, job_id, idx, name, run)


blocks = []
for path in files:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except FileNotFoundError:
        sys.stderr.write("workflow-run-block-length-check: %s does not exist — CANNOT MEASURE (rc 2)\n" % path)
        sys.exit(2)
    except yaml.YAMLError as exc:
        first = str(exc).splitlines()[0] if str(exc).strip() else exc.__class__.__name__
        sys.stderr.write(
            "workflow-run-block-length-check: %s is not parseable as YAML (%s) — CANNOT MEASURE (rc 2)\n"
            % (path, first)
        )
        sys.exit(2)
    blocks.extend(walk(doc, path))

# COVERAGE FLOOR. Scanning files that contain no `run:` block at all measured
# NOTHING, and reporting that as a pass is the vacuous green this family exists
# to refuse. It is exit 2, never 0 — including for a single hand-named fixture.
if not blocks:
    sys.stderr.write(
        "workflow-run-block-length-check: scanned %d file(s) and found ZERO `run:` blocks — "
        "nothing was measured, so this is REFUSED, not a pass (rc 2)\n" % len(files)
    )
    sys.exit(2)


def label(path, job_id, idx, name):
    s = "%s  job `%s`  step[%d]" % (path, job_id, idx)
    if name:
        s += ' "%s"' % name
    return s


rows = []
for (path, job_id, idx, name, run) in blocks:
    nbytes = len(run.encode("utf-8"))
    interpolated = "${{" in run
    rows.append((nbytes, interpolated, path, job_id, idx, name, len(run)))
rows.sort(key=lambda r: -r[0])

reds = [r for r in rows if r[1] and r[0] > FAIL_FLOOR]
# A warn is one of two different statements and they must not be conflated:
#   - an INTERPOLATED block in the warn band: the cap applies and it is close.
#   - a LITERAL block over the FAIL floor: the cap does not apply today, but one
#     `${{ }}` would make it apply at a size that is already over.
warns = [r for r in rows if not (r[1] and r[0] > FAIL_FLOOR)
         and ((r[1] and r[0] > WARN_FLOOR) or ((not r[1]) and r[0] > FAIL_FLOOR))]

print("── longest `run:` blocks in %d workflow file(s) (%d blocks measured) ──" % (len(files), len(rows)))
for r in rows[:5]:
    print("   %7d bytes  %s  %s" % (r[0], "INTERPOLATED" if r[1] else "literal     ", label(r[2], r[3], r[4], r[5])))
print("   cap=%d fail_floor=%d warn_floor=%d  (unit: UTF-8 bytes of the folded run: scalar)" % (CAP, FAIL_FLOOR, WARN_FLOOR))

for r in warns:
    if r[1]:
        sys.stderr.write(
            "WARN: %s is %d bytes of the %d cap — %d bytes under the %d fail floor.\n"
            % (label(r[2], r[3], r[4], r[5]), r[0], CAP, FAIL_FLOOR - r[0], FAIL_FLOOR)
        )
    else:
        sys.stderr.write(
            "WARN: %s is %d bytes, over the %d fail floor, but carries NO `${{ }}` so GitHub never hands it "
            "to the expression parser and the cap does not apply. It is ONE interpolation away from a startup failure.\n"
            % (label(r[2], r[3], r[4], r[5]), r[0], FAIL_FLOOR)
        )

if reds:
    for r in reds:
        # Past the cap the headroom is NEGATIVE, and "-728 bytes from the cap"
        # is the kind of line a reader skims past. Say which side of it you are.
        if r[0] > CAP:
            tail = "ALREADY %d bytes OVER GitHub's %d max expression length — this file is a STARTUP FAILURE, zero jobs." % (r[0] - CAP, CAP)
        else:
            tail = "%d bytes of headroom left to GitHub's %d max expression length." % (CAP - r[0], CAP)
        sys.stderr.write(
            "FAIL: %s is %d bytes and contains `${{ }}` — over the %d fail floor. %s\n"
            % (label(r[2], r[3], r[4], r[5]), r[0], FAIL_FLOOR, tail)
        )
    sys.stderr.write(
        "      Actions compiles an interpolated `run:` scalar into ONE expression. Over the cap the WHOLE workflow is "
        "refused at parse time: a startup failure with ZERO jobs, every job in the file dark at once, and no local "
        "YAML gate can see it (the file is valid YAML).\n"
    )
    sys.stderr.write(
        "      FIX: move the bulk out of the `run:` scalar — a script under scripts/ invoked from the step, or a "
        "here-doc written to a file in an earlier step — or split the step in two.\n"
    )
    sys.exit(1)

print("  ok     %d `run:` block(s) measured, none interpolated over %d bytes (largest interpolated: %d)"
      % (len(rows), FAIL_FLOOR, max([r[0] for r in rows if r[1]] or [0])))
sys.exit(0)
PY
}

# ── selftest ────────────────────────────────────────────────────────────────
# Present-in-file is not fires-when-it-should. Every arm runs THIS script over a
# real fixture tree and asserts the exit code AND a substring of the output, so
# an arm cannot pass on a red that fired for the wrong reason.
selftest() {
  local tmp rc=0 out code
  tmp="$(mktemp -d)" || return 2

  # $1=path $2=job id $3=step name $4=payload-size $5=interpolate(0|1)
  mk_wf() {
    local p="$1" job="$2" name="$3" size="$4" interp="$5" pad
    pad="$(head -c "$size" < /dev/zero | tr '\0' 'x')"
    mkdir -p "$(dirname "$p")"
    {
      echo "name: fixture"
      echo "on: [push]"
      echo "jobs:"
      echo "  $job:"
      echo "    runs-on: ubuntu-latest"
      echo "    steps:"
      echo "      - name: $name"
      echo "        run: |"
      [ "$interp" -eq 1 ] && echo "          echo \"\${{ github.sha }}\""
      echo "          echo $pad"
    } > "$p"
  }

  probe() { # $1=label $2=want_code $3=want_substr $4..=args
    local lbl="$1" want="$2" want_s="$3"; shift 3
    out="$("$0" "$@" 2>&1)"; code=$?
    if [ "$code" -ne "$want" ]; then
      echo "  FAIL  $lbl: exit $code, wanted $want"; printf '%s\n' "$out" | sed 's/^/        /'; rc=1; return
    fi
    if [ -n "$want_s" ] && ! printf '%s' "$out" | grep -qF -- "$want_s"; then
      echo "  FAIL  $lbl: exit $code as wanted, but output never said '$want_s'"; printf '%s\n' "$out" | sed 's/^/        /'; rc=1; return
    fi
    echo "  ok    $lbl"
  }

  # 1. POSITIVE CONTROL — a planted INTERPOLATED block over the floor reds, and
  #    the red NAMES the file, the job id and the step.
  mk_wf "$tmp/over/boom.yml" "dispatch" "the planted oversize block" 20500 1
  probe "planted over-floor interpolated block reds BY NAME" 1 "boom.yml  job \`dispatch\`  step[0] \"the planted oversize block\"" \
    --dir "$tmp/over"
  probe "...and the red quotes the byte length and the cap" 1 "headroom left to GitHub's 21000 max expression length" --dir "$tmp/over"

  # 1b. OVER THE CAP ITSELF — the headroom goes negative and the line must say
  #     which side of the cap it is on, not print "-728 bytes from the cap".
  mk_wf "$tmp/past/past.yml" "dispatch" "a block past the cap" 21500 1
  probe "past the cap, the red says STARTUP FAILURE" 1 "STARTUP FAILURE, zero jobs" --dir "$tmp/past"

  # 2. NEGATIVE CONTROL — the same block under the floor passes. Same fixture
  #    shape, one number different, so arm 1 cannot be passing for a shape reason.
  mk_wf "$tmp/under/fine.yml" "dispatch" "a block with room to spare" 5000 1
  probe "under-floor interpolated block passes" 0 "ok  " --dir "$tmp/under"

  # 3. THE DISCRIMINATOR IS THE INTERPOLATION, proved in both directions. The
  #    SAME oversize payload with no `${{ }}` does NOT red — that is deploy.yml's
  #    30379-byte literal block, which ships green on main — but it warns.
  mk_wf "$tmp/literal/big.yml" "dispatch" "a literal block over the floor" 20500 0
  probe "oversize LITERAL block does not red" 0 "ONE interpolation away" --dir "$tmp/literal"

  # 4. COVERAGE FLOOR — a fixture with NO run: block measured nothing and is
  #    REFUSED (exit 2), never a pass.
  mkdir -p "$tmp/norun"
  { echo "name: fixture"; echo "on: [push]"; echo "jobs:"; echo "  j:"; echo "    runs-on: ubuntu-latest";
    echo "    steps:"; echo "      - uses: actions/checkout@v4"; } > "$tmp/norun/norun.yml"
  probe "a fixture with no run: block is REFUSED" 2 "ZERO \`run:\` blocks" --dir "$tmp/norun"

  # 5. CONTROL — zero workflow files is REFUSED, not a vacuous green.
  mkdir -p "$tmp/empty"
  probe "zero workflow files is REFUSED" 2 "zero workflow files" --dir "$tmp/empty"

  # 6. CONTROL — unparseable YAML is REFUSED. The subject failure is invisible
  #    to YAML, but a file this cannot READ is a verdict it cannot give.
  mkdir -p "$tmp/bad"; printf 'jobs:\n  j:\n   - [unclosed\n' > "$tmp/bad/bad.yml"
  probe "unparseable YAML is REFUSED" 2 "CANNOT MEASURE" --dir "$tmp/bad"

  # 7. CONTROL — an unknown flag exits 2, never 0.
  probe "unknown flag is REFUSED" 2 "unknown option" --dir "$tmp/under" --nope

  # 8. The floor is a knob, and moving it moves the verdict: the under-floor
  #    fixture reds against a floor below its size. If it did not, arm 2's pass
  #    would not be evidence that the comparison runs at all.
  probe "lowering the floor reds the passing fixture" 1 "over the 1000 fail floor" \
    --dir "$tmp/under" --warn-floor 500 --fail-floor 1000

  rm -rf "$tmp"
  if [ "$rc" -eq 0 ]; then echo "selftest: 10/10 arms passed"; else echo "selftest: FAILED"; fi
  return "$rc"
}

if [ "$SELFTEST" -eq 1 ]; then selftest; exit $?; fi

if [ "${#FILES[@]}" -gt 0 ]; then
  measure "${FILES[@]}"
else
  measure "$TARGET_DIR"
fi
