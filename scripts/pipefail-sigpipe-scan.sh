#!/usr/bin/env bash
#
# pipefail-sigpipe-scan.sh — find pipelines that can return 141 instead of a verdict.
#
# THE DEFECT.  Under `set -o pipefail`, a pipeline `producer | early-exit-reader`
# returns the PRODUCER's status when the reader exits first: the reader closes the
# pipe, the producer takes SIGPIPE and dies 141, and pipefail propagates 141 as the
# pipeline's status.  `grep -q` exits on the FIRST match; `head -N` after N lines.
# So a TRUE assertion can report FAIL:
#
#     printf '%s\n' "$out" | grep -Eq "$pat"    # 141 when "$out" outruns the pipe buffer
#
# THE NUMBER IS PLATFORM-SPECIFIC; THE DEFECT IS NOT.  Measured 2026-09-09: macOS
# (bash 3.2 + BSD tools) really answers 141 — the producer dies on the signal.
# ubuntu-latest (bash 5 + GNU coreutils) answers 1 — the producer reports the
# write error and exits instead of dying.  Either way a TRUE assertion comes back
# FAILED under pipefail, which is the whole hazard.  Read "141" throughout this
# file as "a failure the assertion did not earn".  The --selftest asserts the
# failure and REPORTS the number; keying a control on 141 is what kept this
# script's own selftest from ever running on the only platform CI has.
#
# It is OUTPUT-LENGTH DEPENDENT.  A short producer fits the ~64KB pipe buffer, writes
# everything before the reader exits, and never sees SIGPIPE — which is exactly why the
# bug sits latent until an unrelated change makes the output longer, and then produces
# FALSE FAILURES on PRE-EXISTING cases while the innocent change looks like the cause.
#
# WHAT THIS REPORTS.  A site only when all four hold:
#   (a) pipefail is in effect at that line;
#   (b) the pipeline's EXIT STATUS is consumed as a boolean — `if`/`while`/`until`
#       condition, left of `&&`/`||`, `!`-negated, `rc=$?` on the next line, or a bare
#       command in a `set -e` script.  A pipeline whose STDOUT is captured with the
#       status ignored is not the hazard;
#   (c) the reader genuinely exits early — grep -q / grep -m N / head / sed q /
#       awk with exit / read.  `grep` WITHOUT -q or -m reads to EOF and is NOT it;
#   (d) the producer can plausibly outlive the reader.
#
# CONFIDENCE is (d): high  = find/git/curl/cat FILE/loop/ls/jq/a full grep — unbounded
#                            or file-sized output;
#                   medium = printf/echo of a VARIABLE — the variable usually holds
#                            captured command output, so its size is unknown.  This is
#                            the shape of the live bug this scanner was written for;
#                   low    = printf/echo of a LITERAL — almost always inside the buffer.
#
# FIXES, in preference order:
#   1  no pipe at all:  case "$s" in *pat*) ;; esac   /   [[ $s =~ re ]]
#   2  drop -q, redirect:  printf '%s\n' "$s" | grep -E "$pat" >/dev/null
#   3  here-string:  grep -Eq "$pat" <<<"$s"    (no producer process to kill)
#
# INPUTS.  *.sh, *.bash — and, since 2026-09-09, *.yml/*.yaml: a GitHub Actions
# `run:` body IS shell.  Every `run:` block is a SEPARATE process, so pipefail,
# errexit, heredocs and a pending `rc=$?` are RESET at each block boundary, and a
# step's starting state comes from its `shell:` key (no key = `bash -e {0}`,
# pipefail OFF; `shell: bash` = `bash -eo pipefail {0}`, pipefail ON).  See
# yaml_flatten() below.  Before this the collector took only *.sh/*.bash, so
# `.github` — its own second default target — contributed 0 of 138 findings while
# the class's most recent live instance sat in .github/workflows/deploy-harnesses.yml.
#
# USAGE:  pipefail-sigpipe-scan.sh [PATH ...]      (default: scripts .github deploy)
#         --min-confidence high|medium|low         (default: low = report everything)
#         --count-only
#         --fail-on-finding                        (exit 1 if anything is reported)
#         --baseline FILE                          (ratchet: FILE's integer may only fall)
#         --selftest
#
# EXIT: 0 clean scan, findings or not · 1 findings and --fail-on-finding, or the
#       --baseline ratchet BROKEN · 2 CANNOT READ.
#
# A FAILED READ IS NEVER BYTE-IDENTICAL TO ZERO FINDINGS: an unreadable input prints a
# `CANNOT READ:` line to stderr and exits 2.

set -uo pipefail

PROG="pipefail-sigpipe-scan"
min_conf="low"
count_only=0
fail_on_finding=0
selftest=0
baseline_file=""
targets=()

die() {
  printf '%s: REFUSING — %s\n' "$PROG" "$*" >&2
  exit 2
}
cannot_read() {
  printf 'CANNOT READ: %s\n' "$1" >&2
  cannot=$((cannot + 1))
}

while [ $# -gt 0 ]; do
  case "$1" in
  --min-confidence)
    [ $# -ge 2 ] || die "--min-confidence needs a value"
    min_conf="$2"
    shift 2
    ;;
  --count-only)
    count_only=1
    shift
    ;;
  --selftest)
    selftest=1
    shift
    ;;
  --fail-on-finding)
    fail_on_finding=1
    shift
    ;;
  --baseline)
    [ $# -ge 2 ] || die "--baseline needs a file"
    baseline_file="$2"
    shift 2
    ;;
  -h | --help)
    sed -n '2,71p' "$0"
    exit 0
    ;;
  -*) die "unknown option: $1" ;;
  *)
    targets+=("$1")
    shift
    ;;
  esac
done

case "$min_conf" in
high | medium | low) ;;
*) die "--min-confidence must be high, medium or low (got: $min_conf)" ;;
esac

if [ "${#targets[@]}" -eq 0 ]; then
  ROOT="${PIPEFAIL_SCAN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
  targets=("$ROOT/scripts" "$ROOT/.github" "$ROOT/deploy")
fi

# ── --selftest ──────────────────────────────────────────────────────────────
# The FIRST two are the non-vacuity arms: they RUN the defect and require the
# shell to really hand a FAILURE back for a TRUE assertion, so a future libc or
# bash that stopped SIGPIPE-ing would red here rather than let the scanner hunt a
# ghost.  The rest pin one discrimination each — the detector must say NO to the
# near-misses, or a 100%-recall scanner that flags every pipe would pass.
if [ "$selftest" -eq 1 ]; then
  sp=0
  sf=0
  sok() {
    sp=$((sp + 1))
    echo "  ok   $*"
  }
  sno() {
    sf=$((sf + 1))
    echo "  FAIL $*"
  }
  std="$(mktemp -d "${TMPDIR:-/tmp}/pfscan-selftest.XXXXXX")" || die "mktemp failed"
  trap 'rm -rf "$std"' EXIT

  # (0) the defect is REAL on this box, right now.
  # MANY lines, matching on the FIRST: grep -q must be able to answer and exit
  # while the producer still has ~200KB to write.  One 200KB line would not do
  # it — grep would have to read to EOF just to see the line, and never SIGPIPE.
  #
  # THE PLATFORM SPLIT, and why these arms ask for NON-ZERO and not for 141.
  # MEASURED 2026-09-09 on both, and it is the reason the whole selftest could
  # never run in CI before that date — it demanded 141, and Actions answers 1:
  #
  #                          builtin `printf | grep -q`   external `cat | grep -q`
  #   macOS 15 / bash 3.2                        141                          141
  #   ubuntu-latest / bash 5 + GNU coreutils       1                            1
  #
  # On GNU the producer reports the write error and exits 1 instead of dying on
  # the signal; on BSD it dies and pipefail propagates 128+13.  DIFFERENT NUMBER,
  # IDENTICAL DEFECT: the true answer is 0 (grep matched) and pipefail hands back
  # a FAILURE either way, which is the entire hazard this scanner hunts.  So the
  # assertion is "a TRUE assertion comes back FALSE" and the rc is REPORTED, not
  # required — a control keyed on one platform's number is a control that reds on
  # the other platform's correct behaviour.  Non-vacuity still holds: if SIGPIPE
  # and EPIPE both stopped mattering, both arms return 0 and BOTH red.
  #
  # (0) uses a bash BUILTIN producer, (0a) an EXTERNAL one, because those are two
  # different mechanisms (bash's own write-error handling vs. the process's) and
  # the tree contains both shapes.
  long="hit"
  while [ "${#long}" -lt 200000 ]; do long="$long"$'\n'"$long"; done
  rcbi=0
  (
    set -o pipefail
    printf '%s\n' "$long" | grep -q '^hit$'
  ) 2>/dev/null || rcbi=$?
  if [ "$rcbi" -ne 0 ]; then
    sok "(0) non-vacuity: a TRUE \`printf | grep -q\` really comes back FAILED under pipefail (rc $rcbi on this box)"
  else
    sno "(0) printf | grep -q returned 0 — the defect does not reproduce here, so every fixture below is testing a ghost"
  fi
  printf '%s\n' "$long" >"$std/long.txt"
  rcext=0
  (
    set -o pipefail
    cat "$std/long.txt" | grep -q '^hit$'
  ) 2>/dev/null || rcext=$?
  if [ "$rcext" -ne 0 ]; then
    sok "(0a) non-vacuity: an EXTERNAL producer (cat) into grep -q comes back FAILED too (rc $rcext on this box)"
  else
    sno "(0a) cat | grep -q returned 0 — the external-producer form does not reproduce here"
  fi
  rcfix=0
  (
    set -o pipefail
    grep -q '^hit$' <<<"$long"
  ) || rcfix=$?
  [ "$rcfix" -eq 0 ] && sok "(0b) the here-string fix returns 0 on the same input" ||
    sno "(0b) the here-string fix returned $rcfix"

  say() { # say <name> <body> <want: HIT|MISS>
    printf '#!/usr/bin/env bash
set -uo pipefail
%s
' "$2" >"$std/$1.sh"
    n="$(PIPEFAIL_SCAN_ROOT="$std" bash "${BASH_SOURCE[0]}" --count-only "$std/$1.sh" 2>/dev/null | sed -E 's/.*: ([0-9]+) finding.*/\1/')"
    case "$3:$n" in
    HIT:0) sno "$1: wanted a finding, got none" ;;
    MISS:0) sok "$1: correctly silent" ;;
    HIT:*) sok "$1: reported ($n)" ;;
    MISS:*) sno "$1: wanted silence, reported $n" ;;
    esac
  }
  say hit-if 'if printf "%s\n" "$x" | grep -q foo; then :; fi' HIT
  say hit-or 'printf "%s" "$x" | grep -q foo || exit 1' HIT
  say miss-grep-full 'if printf "%s\n" "$x" | grep foo >/dev/null; then :; fi' MISS
  say miss-capture 'v="$(printf "%s" "$x" | grep -q foo)"' MISS
  say miss-or-true 'printf "%s" "$x" | grep -q foo || true' MISS
  say miss-comment '# if printf "%s" "$x" | grep -q foo; then :; fi' MISS

  # ── the WORKFLOW arm (task-b090e1c603d686ba) ──────────────────────────────
  # `.github` was a default target that could never produce a finding, so these
  # fixtures are the whole proof that it now can — AND that it does not
  # over-report, which is the failure mode a naive `-o -name '*.yml'` produces.
  # Every fixture is a whole workflow, and the HIT arms pin the LINE, because a
  # finding at the wrong line is a scanner that parsed something else.
  yml() { # yml <name> <HIT|MISS> [<line the single finding must be on>] ; YAML on stdin
    cat >"$std/$1.yml"
    local out n
    out="$(bash "${BASH_SOURCE[0]}" "$std/$1.yml" 2>/dev/null)"
    n="$(sed -nE 's/.*: ([0-9]+) finding.*/\1/p' <<<"$out")"
    case "$2:$n" in
    HIT:0) sno "$1: wanted a finding, got none" ;;
    MISS:0) sok "$1: correctly silent" ;;
    MISS:*) sno "$1: wanted silence, reported $n — $(tr '\n' ' ' <<<"$out")" ;;
    HIT:*)
      if [ -z "${3:-}" ]; then
        sok "$1: reported ($n)"
      elif [ "$n" != 1 ]; then
        sno "$1: wanted exactly 1 finding on line $3, got $n — $(tr '\n' ' ' <<<"$out")"
      elif grep -q ":$3: " <<<"$out"; then
        sok "$1: reported at line $3, and only there"
      else
        sno "$1: reported 1 finding but NOT on line $3 — $(tr '\n' ' ' <<<"$out")"
      fi
      ;;
    esac
  }

  # (1) THE BLOCK BOUNDARY.  Step 1 arms pipefail; step 5 carries the byte-identical
  # hazard and does NOT.  They are separate processes, so only step 1 is a finding.
  # If pipefail leaked across the boundary this reports 2 and the line check reds.
  yml block-reset HIT 9 <<'YML'
name: t
on: [push]
jobs:
  a:
    steps:
      - name: step 1 — arms pipefail, and IS the hazard
        run: |
          set -euo pipefail
          if printf '%s' "$x" | grep -q foo; then :; fi
      - name: step 2
        run: echo two
      - name: step 3
        run: |
          echo three
      - name: step 4 — not a run: step at all
        uses: actions/checkout@v4
      - name: step 5 — byte-identical hazard, NO pipefail, SEPARATE shell
        run: |
          if printf '%s' "$x" | grep -q foo; then :; fi
YML

  # (2) THE KNOWN INSTANCE, both arms in one run.  Verbatim from
  # .github/workflows/deploy-harnesses.yml before and after #16872.
  yml known-instance-prefix HIT 9 <<'YML'
name: deploy-harnesses (pre-#16872 excerpt)
on: [push]
jobs:
  a:
    steps:
      - run: |
          set -euo pipefail
          ctl_out="$(shellcheck -S warning "$ctl/planted.sh" 2>&1)" && ctl_rc=0 || ctl_rc=$?
          if ! printf '%s' "$ctl_out" | grep -q "SC2034"; then
            exit 1
          fi
YML
  yml known-instance-postfix MISS <<'YML'
name: deploy-harnesses (post-#16872 excerpt, the shipped form)
on: [push]
jobs:
  a:
    steps:
      - run: |
          set -euo pipefail
          ctl_out="$(shellcheck -S warning "$ctl/planted.sh" 2>&1)" && ctl_rc=0 || ctl_rc=$?
          if ! grep -q "SC2034" <<<"$ctl_out"; then
            exit 1
          fi
YML
  # …and against the REAL file, not only a copy of it: a fixture proves the
  # matcher, the live tree proves the fixture is the same shape as the tree.
  sroot="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
  if [ -r "$sroot/.github/workflows/deploy-harnesses.yml" ]; then
    live="$(bash "${BASH_SOURCE[0]}" "$sroot/.github/workflows/deploy-harnesses.yml" 2>/dev/null)"
    if grep -q 'SC2034' <<<"$live"; then
      sno "live deploy-harnesses.yml: the SHIPPED here-string control is being reported — over-reporting on the real tree"
    else
      sok "live deploy-harnesses.yml: the shipped here-string control is NOT reported (and it reads $(sed -nE 's/.*: ([0-9]+) finding.*/\1/p' <<<"$live") other site(s))"
    fi
  else
    sno "live deploy-harnesses.yml: NOT FOUND under $sroot — this arm measured nothing"
  fi

  # (3) MUST NOT REPORT: a full `grep` reads to EOF, so there is no early exit and
  # no SIGPIPE.  This is the arm that reds if the YAML path over-reports.
  yml yaml-miss-grep-full MISS <<'YML'
name: t
on: [push]
jobs:
  a:
    steps:
      - run: |
          set -euo pipefail
          if printf '%s\n' "$x" | grep foo >/dev/null; then :; fi
          printf '%s\n' "$x" | grep -E "$pat" >/dev/null || exit 1
YML

  # (4) `shell: bash` IS `bash -eo pipefail {0}` — pipefail is on with no `set`
  # line anywhere in the body.  A scanner that only looks for `set -o pipefail`
  # text misses every step written this way.
  yml yaml-shell-bash-arms HIT 9 <<'YML'
name: t
on: [push]
jobs:
  a:
    steps:
      - name: shell bash means -eo pipefail
        shell: bash
        run: |
          if printf '%s' "$x" | grep -q foo; then :; fi
YML

  # (5) …and the inverse: NO `shell:` key is `bash -e {0}`, pipefail OFF. Same body.
  yml yaml-default-shell-does-not-arm MISS <<'YML'
name: t
on: [push]
jobs:
  a:
    steps:
      - name: no shell key — Actions default is bash -e, NOT -eo pipefail
        run: |
          if printf '%s' "$x" | grep -q foo; then :; fi
YML

  # (6) a non-shell `shell:` is not shell at all; the body is not scanned.
  yml yaml-non-shell-body MISS <<'YML'
name: t
on: [push]
jobs:
  a:
    steps:
      - shell: python3 {0}
        run: |
          set -euo pipefail
          if printf '%s' "$x" | grep -q foo; then :; fi
YML

  # (7) a single-line `run:` is a whole block on one line — it must not be lost.
  yml yaml-inline-run HIT 8 <<'YML'
name: t
on: [push]
jobs:
  a:
    steps:
      - name: inline
        shell: bash
        run: printf '%s' "$x" | grep -q foo
YML

  # (8) THE RATCHET, both directions, on a fixture whose count is known.
  bl="$std/bl.txt"
  printf '# reason lives here\n1\n' >"$bl"
  bash "${BASH_SOURCE[0]}" --baseline "$bl" "$std/block-reset.yml" >/dev/null 2>&1 &&
    sok "ratchet: 1 finding vs baseline 1 exits 0" ||
    sno "ratchet: 1 finding vs baseline 1 did not exit 0"
  printf '0\n' >"$bl"
  bash "${BASH_SOURCE[0]}" --baseline "$bl" "$std/block-reset.yml" >/dev/null 2>&1 &&
    sno "ratchet: 1 finding vs baseline 0 exited 0 — the ratchet does not hold" ||
    sok "ratchet: 1 finding vs baseline 0 reds"
  printf '9\n' >"$bl"
  loose_rc=0
  loose="$(bash "${BASH_SOURCE[0]}" --baseline "$bl" "$std/block-reset.yml" 2>&1 >/dev/null)" || loose_rc=$?
  if [ "$loose_rc" -eq 0 ] && grep -q 'RATCHET LOOSE' <<<"$loose"; then
    sok "ratchet: a FALL says RATCHET LOOSE and does NOT red (rc 0)"
  else
    sno "ratchet: a fall printed rc=$loose_rc / $(tr '\n' ' ' <<<"$loose")"
  fi
  printf 'not-a-number\n' >"$bl"
  bash "${BASH_SOURCE[0]}" --baseline "$bl" "$std/block-reset.yml" >/dev/null 2>&1
  [ "$?" -eq 2 ] && sok "ratchet: an unreadable baseline is CANNOT READ (exit 2), never a pass" ||
    sno "ratchet: a non-numeric baseline did not exit 2"

  echo
  echo "# pass $sp / # fail $sf"
  [ "$sf" -eq 0 ] || exit 1
  exit 0
fi

cannot=0
files=()
for t in "${targets[@]}"; do
  if [ -d "$t" ]; then
    # *.yml/*.yaml are collected too — a GitHub Actions `run:` body IS shell, and
    # the class's most recent live instance lived in one (deploy-harnesses.yml:171,
    # fixed by #16872).  Before 2026-09-09 this find(1) took only *.sh/*.bash, so
    # `.github` — the scanner's own second default target, and almost entirely
    # YAML — contributed 0 of its 138 findings.  A YAML file that declares no
    # `run:` body flattens to nothing and can report nothing, so widening the net
    # to every .yml costs a stat and cannot over-report.
    while IFS= read -r f; do files+=("$f"); done < <(find "$t" -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.yml' -o -name '*.yaml' \) -print | sort)
  elif [ -f "$t" ]; then
    files+=("$t")
  else
    cannot_read "$t (not a file or directory)"
  fi
done

if [ "${#files[@]}" -eq 0 ] && [ "$cannot" -gt 0 ]; then
  printf '%s: no readable input — refusing to report zero findings\n' "$PROG" >&2
  exit 2
fi

rank() {
  case "$1" in
  high) echo 3 ;;
  medium) echo 2 ;;
  *) echo 1 ;;
  esac
}
min_rank="$(rank "$min_conf")"

findings=0
n_high=0
n_med=0
n_low=0
report=""

# strip_quoted — blank out single/double quoted runs so a pipe or && inside a
# string literal is not read as shell structure.  Crude but conservative: it can
# only make us report LESS, never more.  Pure bash on purpose: this runs per
# candidate line over hundreds of files, and a fork per line is minutes of wall
# clock.  Answers in the global STRIPPED — a command substitution would fork too.
STRIPPED=""
strip_quoted() {
  local s="$1" out="" ch q="" i n
  n=${#s}
  for ((i = 0; i < n; i++)); do
    ch="${s:i:1}"
    if [ -n "$q" ]; then
      [ "$ch" = "$q" ] && q=""
      continue
    fi
    case "$ch" in
    "'" | '"')
      q="$ch"
      out="$out$ch$ch"
      continue
      ;;
    esac
    out="$out$ch"
  done
  STRIPPED="$out"
}

# ── yaml_flatten — render a GitHub Actions workflow as the shell it really is ──
#
# WHY THIS IS NOT `find … -o -name '*.yml'` PLUS THE EXISTING LOOP.  The loop
# below keeps a per-line pipefail state machine down the whole file.  A workflow
# is not one shell: EVERY `run:` body is a SEPARATE process.  `set -euo pipefail`
# in step 1 says NOTHING about step 5, and letting it leak would flag every
# later step in the 149 workflow files that arm pipefail once — a scanner that
# reports its own parser instead of the defect.
#
# So the file is FLATTENED first, ONE OUTPUT LINE PER INPUT LINE so every
# reported `file:line` still points at the real workflow line:
#   · a line outside a shell `run:` body  → a blank line (invisible to the loop);
#   · the `run:` KEY line                 → a `###PFSCAN-RESET` sentinel that the
#                                           loop below turns into a hard state
#                                           reset — that IS the block boundary;
#   · a line inside the body              → itself, verbatim.
#
# THE SENTINEL CARRIES THE BLOCK'S STARTING STATE, because a workflow step does
# not start from bash's defaults (this is the part a naive extension gets wrong
# in BOTH directions):
#   · no `shell:` key      → Actions runs `bash -e {0}`      → errexit ON, pipefail OFF
#   · `shell: bash`        → `bash --noprofile --norc -eo pipefail {0}` → BOTH ON
#   · `shell: sh`          → `sh -e {0}`                     → errexit ON, pipefail OFF
#   · anything else (python3/pwsh/node/a custom `<cmd> {0}`) → NOT shell; the
#     body is emitted as blanks and reports nothing, by name rather than silently.
# errexit therefore comes from HERE and not from the loop's column-0 `set -e`
# rule — a `run:` body is indented, so that rule can never fire inside one.
#
# `${{ … }}` is substituted by Actions BEFORE any shell sees the body, so it is
# not shell input; it is replaced with the inert word EXPR so a `|` inside an
# expression is not read as a pipeline.  Same treatment as
# scripts/workflow-run-shell-check.sh, deliberately.
#
# LIMIT, stated rather than discovered later: `defaults.run.shell` is honoured at
# workflow and job level by the scan below only when it appears as the
# `defaults:` → `run:` → `shell:` triple; a step-level `shell:` always wins.
# Anything this parser cannot resolve is treated as the Actions DEFAULT (pipefail
# OFF), which under-reports.  That is the same direction strip_quoted() errs in:
# it can make us report LESS, never more.
yaml_flatten() {
  local file="$1"
  local -a L=()
  local raw
  while IFS= read -r raw || [ -n "$raw" ]; do L+=("$raw"); done <"$file"
  local n=${#L[@]}

  # workflow/job-level `defaults: → run: → shell:` (see LIMIT above).
  local def_shell="" d_state=0 d_indent=0 s t ind
  local i
  for ((i = 0; i < n; i++)); do
    s="${L[i]}"
    t="${s#"${s%%[![:space:]]*}"}"
    [ -n "$t" ] || continue
    case "$t" in '#'*) continue ;; esac
    ind=$((${#s} - ${#t}))
    case "$d_state:$t" in
    0:defaults:*) d_state=1 d_indent=$ind ;;
    1:run:*) [ "$ind" -gt "$d_indent" ] && d_state=2 || d_state=0 ;;
    2:shell:*)
      def_shell="${t#shell:}"
      def_shell="${def_shell#"${def_shell%%[![:space:]]*}"}"
      d_state=0
      ;;
    *) [ "$ind" -le "$d_indent" ] && d_state=0 ;;
    esac
  done

  local in_body=0 run_indent=-1 body_ok=0
  local j k kl dash_ind step_end sh rest pf ee
  for ((i = 0; i < n; i++)); do
    s="${L[i]}"
    t="${s#"${s%%[![:space:]]*}"}"

    if [ "$in_body" -eq 1 ]; then
      if [ -z "$t" ]; then
        printf '\n'
        continue
      fi
      ind=$((${#s} - ${#t}))
      if [ "$ind" -gt "$run_indent" ]; then
        if [ "$body_ok" -eq 1 ]; then
          scrub_expr "$s"
          printf '%s\n' "$SCRUBBED"
        else
          printf '\n'
        fi
        continue
      fi
      in_body=0
    fi

    # a `run:` key: `run: …`, `- run: …`, `        run: |`
    case "$t" in
    'run:' | 'run:'[[:space:]]*) ;;
    '- run:' | '- run:'[[:space:]]*)
      t="${t#- }"
      ;;
    *)
      printf '\n'
      continue
      ;;
    esac
    run_indent=$((${#s} - ${#t}))

    # the enclosing step's own `shell:` — same indent as this `run:` key, inside
    # the same `- ` list item.  Nearest preceding dash at run_indent-2 opens it;
    # the next line at indent <= that dash closes it.
    sh="$def_shell"
    if [ "$run_indent" -ge 2 ]; then
      dash_ind=$((run_indent - 2))
      step_end=$n
      for ((j = i; j >= 0; j--)); do
        [ "${L[j]:dash_ind:2}" = "- " ] || continue
        case "${L[j]:0:dash_ind}" in *[![:space:]]*) continue ;; esac
        for ((k = j + 1; k < n; k++)); do
          local s2="${L[k]}" t2
          t2="${s2#"${s2%%[![:space:]]*}"}"
          [ -n "$t2" ] || continue
          if [ $((${#s2} - ${#t2})) -le "$dash_ind" ]; then
            step_end=$k
            break
          fi
        done
        for ((k = j; k < step_end; k++)); do
          # `- shell: bash` is the SAME key as `  shell: bash` two lines down —
          # the `- ` opens the mapping and its first key sits at run_indent.
          # Blanking the dash is what lets one prefix test serve both.
          kl="${L[k]}"
          [ "${kl:dash_ind:2}" = "- " ] && kl="${kl:0:dash_ind}  ${kl:dash_ind+2}"
          case "${kl:0:run_indent}" in *[![:space:]]*) continue ;; esac
          case "${kl:run_indent}" in
          'shell:'*)
            sh="${kl:run_indent+6}"
            sh="${sh#"${sh%%[![:space:]]*}"}"
            ;;
          esac
        done
        break
      done
    fi
    sh="${sh%%[[:space:]]*}"
    sh="${sh//\"/}"
    sh="${sh//\'/}"

    case "$sh" in
    "" | bash) pf=1 ee=1 ;; # `shell: bash` == bash -eo pipefail; "" only when a
      # `defaults` triple named it, so it is the same thing
    sh) pf=0 ee=1 ;;
    *) pf=-1 ee=0 ;; # not a shell Actions runs as bash/sh — skip the body
    esac
    # NO `shell:` key at all is the Actions DEFAULT `bash -e {0}`: errexit on,
    # pipefail OFF.  Distinguish it from an explicit `shell: bash`.
    if [ -z "$sh" ] && [ -z "$def_shell" ]; then pf=0 ee=1; fi

    if [ "$pf" -lt 0 ]; then
      body_ok=0
      pf=0
      ee=0
    else
      body_ok=1
    fi

    rest="${t#run:}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    case "$rest" in
    '' | '|' | '|-' | '|+' | '>' | '>-' | '>+' | '|'[0-9]* | '>'[0-9]*)
      in_body=1
      printf '###PFSCAN-RESET\t%d\t%d\n' "$pf" "$ee"
      ;;
    *)
      # single-line `run: cmd` — one whole block on one line.  Emit the reset AND
      # the command, or a `run: printf … | grep -q …` under `shell: bash` would
      # be silently invisible.
      in_body=0
      if [ "$body_ok" -eq 1 ]; then
        scrub_expr "$rest"
        printf '###PFSCAN-RESET\t%d\t%d\t%s\n' "$pf" "$ee" "$SCRUBBED"
      else
        printf '###PFSCAN-RESET\t%d\t%d\n' "$pf" "$ee"
      fi
      ;;
    esac
  done
}

# scrub_expr — blank out `${{ … }}`; answers in SCRUBBED (no fork, same reason
# as strip_quoted).
SCRUBBED=""
scrub_expr() {
  local s="$1" pre post
  while :; do
    case "$s" in
    *'${{'*'}}'*) ;;
    *) break ;;
    esac
    pre="${s%%'${{'*}"
    post="${s#*'${{'}"
    case "$post" in
    *'}}'*) post="${post#*'}}'}" ;;
    *) post="" ;;
    esac
    s="${pre}EXPR${post}"
  done
  SCRUBBED="$s"
}

flat_tmp=""
cleanup_flat() { [ -n "$flat_tmp" ] && rm -f "$flat_tmp"; }
trap cleanup_flat EXIT

for f in "${files[@]}"; do
  [ -r "$f" ] || {
    cannot_read "$f"
    continue
  }
  src="$f"
  yaml_mode=0
  case "$f" in
  *.yml | *.yaml)
    # `shell: bash` IS `bash -eo pipefail {0}`, so a workflow can be armed with
    # the word `pipefail` appearing NOWHERE in the file.  Keying the cheap
    # precondition on that word alone skipped exactly those files — caught by the
    # yaml-inline-run selftest arm, which is the only fixture here whose prose
    # does not happen to contain the word.
    grep -qE 'pipefail|shell:' "$f" || continue
    yaml_mode=1
    [ -n "$flat_tmp" ] || flat_tmp="$(mktemp "${TMPDIR:-/tmp}/pfscan-flat.XXXXXX")" || die "mktemp failed"
    if ! yaml_flatten "$f" >"$flat_tmp"; then
      cannot_read "$f (workflow flatten failed)"
      continue
    fi
    src="$flat_tmp"
    ;;
  *)
    # A file with no pipefail anywhere cannot host the defect — condition (a).
    # Cheap precondition, deliberately loose — `set -u -o pipefail`, `set -euo
    # pipefail` and `set -o pipefail` must all pass it.  The per-line state
    # machine below is the real gate; this only skips files that cannot host it.
    grep -q 'pipefail' "$f" || continue
    ;;
  esac

  pipefail_on=0
  errexit=0
  lineno=0
  heredoc=""
  prev_pipe_line=0
  prev_pipe_text=""
  prev_pipe_conf=""

  while IFS= read -r raw || [ -n "$raw" ]; do
    lineno=$((lineno + 1))
    line="${raw%%$'\r'}"

    # ── a `run:` BLOCK BOUNDARY (flattened workflows only) ─────────────────
    # THE reset.  Every `run:` body is its own process, so pipefail, errexit,
    # any open heredoc and any pending `rc=$?` from the previous block all end
    # here.  Without this, one `set -euo pipefail` in step 1 would arm the
    # scanner for every later step in the file.
    if [ "$yaml_mode" -eq 1 ]; then
      case "$line" in
      '###PFSCAN-RESET'*)
        IFS=$'\t' read -r _sent pipefail_on errexit line <<<"$line"
        heredoc=""
        prev_pipe_line=0
        prev_pipe_text=""
        prev_pipe_conf=""
        [ -n "$line" ] || continue
        raw="$line"
        ;;
      esac
    fi

    # ── heredoc bodies are DATA, not code ──────────────────────────────────
    # scripts/deploy-convergence-check.sh writes whole fixture workflows into
    # heredocs; every `| grep -q` in one of those is a string this script never
    # runs.  Reporting them is a pure false positive.
    if [ -n "$heredoc" ]; then
      case "${line#"${line%%[![:space:]]*}"}" in "$heredoc") heredoc="" ;; esac
      continue
    fi
    case "$line" in
    *'<<'*)
      hd="${line##*<<}"
      hd="${hd#-}"
      hd="${hd#"${hd%%[![:space:]]*}"}"
      hd="${hd%%[[:space:];)&|]*}"
      hd="${hd//\'/}"
      hd="${hd//\"/}"
      hd="${hd//\\/}"
      case "$line" in *'<<<'*) hd="" ;; esac
      [ -n "$hd" ] && heredoc="$hd"
      ;;
    esac

    # comments FIRST: a commented-out or merely DESCRIBED `set -o pipefail`
    # must not arm the scanner, and a `| grep -q` inside prose is not code.
    # Several scripts here carry paragraphs explaining this very defect.
    case "${line#"${line%%[![:space:]]*}"}" in '#'* | '') continue ;; esac

    # ── (a) is pipefail in effect here? ────────────────────────────────────
    case "$line" in
    *set\ -*o*pipefail*)
      pipefail_on=1
      case "$line" in *set\ -*e*o*pipefail*) errexit=1 ;; esac
      ;;
    *set\ +o\ pipefail*) pipefail_on=0 ;;
    esac
    # errexit ONLY at column 0.  An indented `set -e` is inside a function or a
    # subshell, where it does not govern the top-level lines this loop reads
    # afterwards — honouring it made every later bare pipeline a false positive.
    case "$line" in
    set\ -e | set\ -e[a-zA-Z]* | set\ -e\ *) errexit=1 ;;
    esac

    # a `rc=$?` / `status=$?` immediately after a pipeline CONSUMES its status.
    if [ "$prev_pipe_line" -ne 0 ] && [ "$lineno" -eq $((prev_pipe_line + 1)) ] &&
      [ "$(rank "$prev_pipe_conf")" -ge "$min_rank" ]; then
      # The rank test is on this branch too (added 2026-09-09).  Without it
      # `--min-confidence high` printed `17 finding(s) — high 16 · low 1`: this
      # branch is the ONLY producer of a finding that skips the filter every
      # other site passes through, so the headline count and the breakdown
      # disagreed — and a ratchet keyed on the headline would have frozen a
      # number the flag's own name says it excludes.
      case "$line" in
      *=\$\?*)
        findings=$((findings + 1))
        case "$prev_pipe_conf" in
        high) n_high=$((n_high + 1)) ;;
        medium) n_med=$((n_med + 1)) ;;
        *) n_low=$((n_low + 1)) ;;
        esac
        report="$report$f:$prev_pipe_line: [$prev_pipe_conf] status captured into \$? on the next line
    $prev_pipe_text
"
        ;;
      esac
    fi
    prev_pipe_line=0
    prev_pipe_text=""
    prev_pipe_conf=""

    [ "$pipefail_on" -eq 1 ] || continue

    # cheap pre-filter BEFORE the per-character strip: no pipe, no hazard.
    case "$line" in *'|'*) ;; *) continue ;; esac
    strip_quoted "$line"
    bare="$STRIPPED"
    # `||` and `&&` are NOT pipes.  Fold them out of the way BEFORE anything
    # splits on `|`, or `${bare##*|}` lands inside the `||` of
    # `printf … | grep -q … || fail` and the boolean use goes unseen — which is
    # how the first cut of this scanner missed the loudest sites in the tree.
    norm="${bare//||/$'\002'}"
    norm="${norm//&&/$'\003'}"
    case "$norm" in *'|'*) ;; *) continue ;; esac
    bare="$norm"

    # ── (c) is the reader an EARLY-EXIT reader? ────────────────────────────
    reader=""
    case "$bare" in
    *'|'*grep*-*q*) reader="grep -q" ;;
    esac
    case "$bare" in
    *'|'*grep*-m\ [0-9]* | *'|'*grep*-m[0-9]*) reader="grep -m N" ;;
    esac
    case "$bare" in
    *'| head '* | *'|head '*) reader="head" ;;
    esac
    case "$bare" in
    *'|'*sed*' q'* | *'|'*sed*q\;*) reader="sed q" ;;
    esac
    case "$bare" in
    *'|'*awk*exit*) reader="awk exit" ;;
    esac
    case "$bare" in
    *'| read '* | *'|read '* | *'| IFS='*read*) reader="read" ;;
    esac
    [ -n "$reader" ] || continue

    # `… || true` / `… || :` swallows the 141.  The status is consumed, but the
    # consequence is nil — reporting it is a pure false positive.
    case "$bare" in
    *$'\002'*true | *$'\002'*true\ * | *$'\002'*: | *$'\002'*:\ *) continue ;;
    esac

    # `grep` with neither -q nor -m reads to EOF: NOT the hazard.  Re-check that
    # a bare `grep -e`/`grep -E` did not get matched by the loose -*q* pattern.
    if [ "$reader" = "grep -q" ]; then
      case "$bare" in
      *grep*-[a-zA-Z]*q* | *grep*\ -q*) ;;
      *)
        continue
        ;;
      esac
    fi

    # ── (b) is the STATUS consumed as a boolean? ───────────────────────────
    trimmed="${bare#"${bare%%[![:space:]]*}"}"
    consumed=""
    case "$trimmed" in
    if\ * | elif\ * | while\ * | until\ * | !\ *) consumed="condition of ${trimmed%% *}" ;;
    esac
    if [ -z "$consumed" ]; then
      # A one-line function whose body IS the pipeline: `f() { a | grep -q b; }`.
      # The pipeline's status becomes the FUNCTION's status, and the caller reads
      # it as a boolean — which is exactly the shape of the `says()` helper in
      # scripts/which-gates.test.sh that produced this lane's false FAILs.
      # But only when a caller really uses it as a boolean: a helper called only
      # as `x=$(f)` discards the status, and reporting those was pure noise.
      case "$raw" in
      *'()'*'{'*'}'* | *'() {'*)
        fname="${raw%%'('*}"
        fname="${fname#"${fname%%[![:space:]]*}"}"
        fname="${fname%"${fname##*[![:space:]]}"}"
        if [ -n "$fname" ] && grep -qE "(^|[^A-Za-z0-9_.$])((if|elif|while|until)[[:space:]]+!?[[:space:]]*${fname}([[:space:]]|;|\$)|!?[[:space:]]*${fname}([[:space:]][^|]*)?[[:space:]]*(&&|\|\|))" "$f"; then
          consumed="the one-line body of ${fname}(), whose status a caller reads as a boolean"
        fi
        ;;
      esac
    fi
    if [ -z "$consumed" ]; then
      # a folded `&&`/`||` AFTER the last real pipe — the pipeline's status
      # drives it.  `printf … | grep -q … || fail` lives here.
      after="${bare##*'|'}"
      case "$after" in
      *$'\002'* | *$'\003'*) consumed="left of &&/||" ;;
      esac
    fi
    if [ -z "$consumed" ]; then
      # Captured stdout: `x=$(a | grep -q b)`.  With errexit OFF the status is
      # genuinely discarded and this is NOT the hazard.  With errexit ON it is:
      # an assignment's status IS the substitution's status, so a 141 kills the
      # script.  (An `echo "$(…)"` does not — only the assignment form.)
      case "$trimmed" in
      *=\$\(* | *=\`*)
        if [ "$errexit" -eq 1 ]; then
          consumed="captured into an assignment under set -e"
        else
          continue
        fi
        ;;
      esac
    fi
    if [ -z "$consumed" ]; then
      if [ "$errexit" -eq 1 ]; then
        consumed="bare command under set -e"
      else
        # status may still be read on the NEXT line — remember and move on
        prev_pipe_line="$lineno"
        prev_pipe_text="$trimmed"
        prev_pipe_conf="low"
        continue
      fi
    fi

    # ── (d) can the producer outlive the reader? ───────────────────────────
    producer="${bare%%'|'*}"
    ptrim="${producer#"${producer%%[![:space:]]*}"}"
    case "$ptrim" in
    if\ * | elif\ * | while\ * | until\ * | !\ *) ptrim="${ptrim#* }" ;;
    esac
    conf="medium"
    why=""
    case "$ptrim" in
    *find\ * | *git\ * | *curl\ * | *ls\ * | *jq\ * | *cat\ * | *awk\ * | *sed\ * | *tail\ * | *docker\ * | *gh\ * | *ssh\ * | *systemctl\ * | *grep\ * | *for\ * | *while\ * | *done*)
      conf="high"
      why="unbounded or file-sized producer"
      ;;
    printf* | echo*)
      # a VARIABLE usually holds captured command output: size unknown.
      case "$producer$line" in
      *'$'*) conf="medium" why="printf/echo of a VARIABLE — size unknown; this is the shape of the live bug" ;;
      *) conf="low" why="printf/echo of a LITERAL — very likely inside the 64KB pipe buffer" ;;
      esac
      ;;
    *) conf="medium" why="producer not classified" ;;
    esac

    [ "$(rank "$conf")" -ge "$min_rank" ] || continue

    findings=$((findings + 1))
    case "$conf" in
    high) n_high=$((n_high + 1)) ;;
    medium) n_med=$((n_med + 1)) ;;
    *) n_low=$((n_low + 1)) ;;
    esac
    report="$report$f:$lineno: [$conf] reader=$reader; status $consumed; $why
    $trimmed
"
  done <"$src" || cannot_read "$f (read failed mid-file)"
done

if [ "$count_only" -eq 0 ] && [ -n "$report" ]; then
  printf '%s' "$report"
  printf '\n'
fi

printf '%s: %d finding(s) — high %d · medium %d · low %d — over %d file(s)\n' \
  "$PROG" "$findings" "$n_high" "$n_med" "$n_low" "${#files[@]}"

if [ "$cannot" -gt 0 ]; then
  printf '%s: %d input(s) could not be read — this scan is INCOMPLETE\n' "$PROG" "$cannot" >&2
  exit 2
fi

# ── --baseline: the ratchet ─────────────────────────────────────────────────
# The count may FALL freely and may never RISE.  A rise is a NEW site and reds.
# A fall does NOT red, deliberately: a ratchet that fails when the world gets
# BETTER trains its readers to regenerate the number, and the regeneration is
# where a real regression gets laundered in.  It prints RATCHET LOOSE instead,
# loudly, so the next PR through here lowers it on purpose.
if [ -n "$baseline_file" ]; then
  if [ ! -r "$baseline_file" ]; then
    printf 'CANNOT READ: %s (baseline)\n' "$baseline_file" >&2
    exit 2
  fi
  want=""
  while IFS= read -r bl || [ -n "$bl" ]; do
    bl="${bl%%#*}"
    bl="${bl//[[:space:]]/}"
    [ -n "$bl" ] || continue
    want="$bl"
    break
  done <"$baseline_file"
  case "$want" in
  '' | *[!0-9]*)
    printf 'CANNOT READ: %s carries no integer baseline (read: %s)\n' "$baseline_file" "${want:-<nothing>}" >&2
    exit 2
    ;;
  esac
  printf '%s: baseline %s (%s, --min-confidence %s) vs %d found\n' \
    "$PROG" "$want" "$baseline_file" "$min_conf" "$findings"
  if [ "$findings" -gt "$want" ]; then
    printf '%s: RATCHET BROKEN — %d finding(s) at confidence >= %s, baseline is %d.\n' \
      "$PROG" "$findings" "$min_conf" "$want" >&2
    printf '%s: a NEW pipefail/SIGPIPE site was added. Fix it (here-string, or drop -q and redirect —\n' "$PROG" >&2
    printf '%s: see the FIXES block at the top of this script). Do NOT raise the number in %s.\n' "$PROG" "$baseline_file" >&2
    exit 1
  fi
  if [ "$findings" -lt "$want" ]; then
    printf '%s: RATCHET LOOSE — %d finding(s) at confidence >= %s, baseline still says %d.\n' \
      "$PROG" "$findings" "$min_conf" "$want" >&2
    printf '%s: this is not a failure, it is progress that has not been banked. Lower the number in\n' "$PROG" >&2
    printf '%s: %s to %d (and date the change) so the next regression cannot hide in the slack.\n' "$PROG" "$baseline_file" "$findings" >&2
  fi
fi

if [ "$fail_on_finding" -eq 1 ] && [ "$findings" -gt 0 ]; then
  exit 1
fi
exit 0
