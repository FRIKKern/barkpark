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
# USAGE:  pipefail-sigpipe-scan.sh [PATH ...]      (default: scripts .github deploy)
#         --min-confidence high|medium|low         (default: low = report everything)
#         --count-only
#
# EXIT: 0 clean scan, findings or not · 1 findings and --fail-on-finding · 2 CANNOT READ.
#
# A FAILED READ IS NEVER BYTE-IDENTICAL TO ZERO FINDINGS: an unreadable input prints a
# `CANNOT READ:` line to stderr and exits 2.

set -uo pipefail

PROG="pipefail-sigpipe-scan"
min_conf="low"
count_only=0
fail_on_finding=0
selftest=0
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
  -h | --help)
    sed -n '2,45p' "$0"
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
# Six fixtures, and the FIRST is the non-vacuity arm: it RUNS the defect and
# asserts the shell really answers 141, so a future libc or bash that stopped
# SIGPIPE-ing would red this rather than let the scanner hunt a ghost.  The rest
# pin one discrimination each — the detector must say NO to the near-misses, or
# a 100%-recall scanner that flags every pipe would pass.
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
  long="hit"
  while [ "${#long}" -lt 200000 ]; do long="$long"$'\n'"$long"; done
  rc141=0
  (
    set -o pipefail
    printf '%s\n' "$long" | grep -q '^hit$'
  ) || rc141=$?
  if [ "$rc141" -eq 141 ]; then
    sok "(0) non-vacuity: printf | grep -q really returns 141 under pipefail on this shell"
  else
    sno "(0) printf | grep -q returned $rc141, not 141 — every fixture below is testing a ghost"
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

  echo
  echo "# pass $sp / # fail $sf"
  [ "$sf" -eq 0 ] || exit 1
  exit 0
fi

cannot=0
files=()
for t in "${targets[@]}"; do
  if [ -d "$t" ]; then
    while IFS= read -r f; do files+=("$f"); done < <(find "$t" -type f \( -name '*.sh' -o -name '*.bash' \) -print | sort)
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

for f in "${files[@]}"; do
  [ -r "$f" ] || {
    cannot_read "$f"
    continue
  }
  # A file with no pipefail anywhere cannot host the defect — condition (a).
  # Cheap precondition, deliberately loose — `set -u -o pipefail`, `set -euo
  # pipefail` and `set -o pipefail` must all pass it.  The per-line state machine
  # below is the real gate; this only skips files that cannot possibly host it.
  grep -q 'pipefail' "$f" || continue

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
    if [ "$prev_pipe_line" -ne 0 ] && [ "$lineno" -eq $((prev_pipe_line + 1)) ]; then
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
  done <"$f" || cannot_read "$f (read failed mid-file)"
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
if [ "$fail_on_finding" -eq 1 ] && [ "$findings" -gt 0 ]; then
  exit 1
fi
exit 0
