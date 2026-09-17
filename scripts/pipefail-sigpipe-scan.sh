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
#                            or file-sized output; OR any `head` reader whose
#                            producer is not PROVABLY bounded (see below);
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
# THE TRUNCATING READER (added 2026-09-12, task-ab1d5320e09c9e72).  `head` never
# reads to EOF: bare `head` stops at 10 lines, `head -N`/`head -n N` at N lines,
# `head -c N` at N bytes — then it CLOSES the pipe.  So for a head reader the
# question is not "is the producer file-sized", it is "can the producer be shown
# to STOP at or before what head takes".  If it cannot, the producer dies the
# instant it writes past N: no 64KB buffer overrun required, no tree growth
# required.  A head reader is therefore HIGH unless the producer is provably
# bounded — `od -N<n>`, `dd count=`, a `head` of its own, or the printf/echo of a
# LITERAL the classifier already calls low.
#
# TWO THINGS SHIPPED THAT BLIND SPOT TOGETHER, both fixed here:
#   1  `LC_ALL=C tr -dc 'a-f0-9' </dev/urandom` is an INFINITE producer and
#      matched none of the high-confidence NAMES, so it fell to "producer not
#      classified" → medium, and --min-confidence high (the only tier CI
#      enforces) dropped it.  Unbounded stdin — `</dev/urandom`, `</dev/zero`,
#      `yes`, `cat /dev/…` — was the worst case in the class and the one case
#      the enforced tier could not see.
#   2  worse, the site was invisible at EVERY tier: the pipeline lived inside
#      `"$( … )"`, and strip_quoted blanked every double-quoted run wholesale.
#      See strip_quoted_keep_subst.
# Measured on the tree that shipped it: scripts/pds-scratch-target.sh:389 (lineref-ok, historical) read 0
# findings at --min-confidence low before this change and is reported at high
# after it.  #17920 fixed that one site; this change is the scanner's blind spot.
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
#         --verify-against-origin-main              (measure a SNAPSHOT, never the checkout)
#         --check-provenance FILE                   (the banked number carries cmd+date+sha)
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
verify_origin=0
provenance_file=""
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
  --verify-against-origin-main)
    verify_origin=1
    shift
    ;;
  --check-provenance)
    [ $# -ge 2 ] || die "--check-provenance needs a baseline file"
    provenance_file="$2"
    shift 2
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
    # 2,96p — the whole header block; re-measure it when the header grows
    sed -n '2,96p' "$0"
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


# ── --check-provenance: a banked number carries the command, the date and the sha
#
# task-bf9d623529d86a86 c2.  Every target proposed for this class must be a
# DELTA against the post-2026-09-12 detector, carrying what produced it.  The
# baseline file's own header has said so in prose since 2026-09-09 ("TO LOWER
# IT: fix a site, re-run the command above, put its printed count here, and
# update the date and composition in this header in the same commit") and the
# rule was still broken: a small inherited number — 8, 15 or 16, all from the
# PRE-widening detector — reached an acceptance criterion as "high <= 6" and
# stood for four days, because prose does not fire.  A written finding does not
# fire by itself; this is the same sentence, made callable.
#
# WHAT IT REQUIRES, of the text AFTER the file's LAST `RE-MEASURED` banner —
# the block that must describe the number now enforced:
#   1  the enforced integer, quoted as the scanner's own output line;
#   2  the literal command that produces it, so the reader can re-run it;
#   3  an ISO date;
#   4  a commit sha (>= 9 hex), so the tree measured is NAMEABLE.
# It does NOT try to check that the sha is real or that the number is right —
# that is --verify-against-origin-main's job.  This one only refuses a number
# that arrives with no way to check it at all, which is the shape every wrong
# number in this class has had.
check_provenance() {
  local file="$1" want body missing=""
  [ -r "$file" ] || {
    printf 'CANNOT READ: %s (provenance)\n' "$file" >&2
    return 2
  }
  want=""
  while IFS= read -r bl || [ -n "$bl" ]; do
    bl="${bl%%#*}"
    bl="${bl//[[:space:]]/}"
    [ -n "$bl" ] || continue
    want="$bl"
    break
  done <"$file"
  case "$want" in
  '' | *[!0-9]*)
    printf 'CANNOT READ: %s carries no integer baseline (read: %s)\n' "$file" "${want:-<nothing>}" >&2
    return 2
    ;;
  esac

  # the text after the LAST re-measurement banner.  `sed -n '/RE-MEASURED/,$p'`
  # would start at the FIRST one; this keeps only the final block, which is the
  # one that has to describe the number in force.
  local last
  last="$(grep -n 'RE-MEASURED' "$file" | tail -1)"
  last="${last%%:*}"
  if [ -z "$last" ]; then
    # no re-measurement yet: the whole header is the block.
    last=1
  fi
  body="$(sed -n "${last},\$p" "$file")"

  grep -qE "pipefail-sigpipe-scan: $want finding" <<<"$body" ||
    missing="$missing
  - the scanner's own output line quoting $want (\"pipefail-sigpipe-scan: $want finding(s) …\")"
  grep -qF 'bash scripts/pipefail-sigpipe-scan.sh --min-confidence high --count-only' <<<"$body" ||
    missing="$missing
  - the literal command: bash scripts/pipefail-sigpipe-scan.sh --min-confidence high --count-only"
  grep -qE '20[0-9][0-9]-[01][0-9]-[0-3][0-9]' <<<"$body" ||
    missing="$missing
  - an ISO date (20YY-MM-DD) for the measurement"
  grep -qE '(^|[^0-9a-f])[0-9a-f]{9,40}([^0-9a-z]|$)' <<<"$body" ||
    missing="$missing
  - a commit sha (>= 9 hex characters) naming the tree that was measured"

  if [ -n "$missing" ]; then
    printf '%s: PROVENANCE MISSING in %s — the banked number is %s, and its block does not carry:%s\n' \
      "$PROG" "$file" "$want" "$missing" >&2
    printf '%s: a bare number is not a measurement. Re-run\n' "$PROG" >&2
    printf '%s:   bash scripts/pipefail-sigpipe-scan.sh --verify-against-origin-main\n' "$PROG" >&2
    printf '%s: and paste its command, date and sha into %s in the SAME commit that moves the number.\n' "$PROG" "$file" >&2
    return 1
  fi
  printf '%s: provenance OK — %s banks %s with a command, a date and a sha in its last RE-MEASURED block\n' \
    "$PROG" "$file" "$want"
  return 0
}

if [ -n "$provenance_file" ]; then
  check_provenance "$provenance_file"
  exit $?
fi

# ── --verify-against-origin-main: measure a SNAPSHOT, never the checkout ──────
#
# task-bf9d623529d86a86 c0.  THE FAILURE THIS EXISTS FOR, measured and not
# imagined: on 2026-09-16 this repo's main checkout was 38 commits behind and
# read `high 107` against a banked 108.  That reads as harmless RATCHET LOOSE —
# "progress not yet banked" — and it was nothing of the kind: it was a
# measurement of the PRE-FIX tree, and banking 107 would have written a number
# no tree on main ever had.  A stale checkout is the cheap fake green for this
# whole class, and it is invisible in the output, because the output of a scan
# over the wrong tree looks exactly like the output of a scan over the right one.
#
# So this mode never reads the working tree for its verdict.  It extracts
# origin/main into a scratch directory with `git archive`, runs THAT snapshot's
# OWN scanner over THAT snapshot's files, and compares against THAT snapshot's
# baseline — three things from one tree, named by one sha.  It also prints what
# the working tree says, unlabelled by any verdict, purely so a drift between
# the two is visible rather than silently quotable.
if [ "$verify_origin" -eq 1 ]; then
  command -v git >/dev/null 2>&1 || die "--verify-against-origin-main needs git on PATH"
  vroot="${PIPEFAIL_SCAN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
  vsha="$(git -C "$vroot" rev-parse origin/main 2>/dev/null)" ||
    die "cannot resolve origin/main in $vroot — run: git fetch origin main"
  [ -n "$vsha" ] || die "origin/main resolved to nothing in $vroot"
  vscratch="$(mktemp -d "${TMPDIR:-/tmp}/pfscan-origin.XXXXXX")" || die "mktemp failed"
  trap 'rm -rf "$vscratch"' EXIT
  git -C "$vroot" archive "$vsha" | tar -x -C "$vscratch" ||
    die "git archive $vsha failed — nothing was measured"
  [ -r "$vscratch/scripts/pipefail-sigpipe-scan.sh" ] ||
    die "the origin/main snapshot has no scripts/pipefail-sigpipe-scan.sh — nothing was measured"
  [ -r "$vscratch/scripts/pipefail-sigpipe-baseline.txt" ] ||
    die "the origin/main snapshot has no scripts/pipefail-sigpipe-baseline.txt — nothing was measured"

  vout="$(cd "$vscratch" && bash scripts/pipefail-sigpipe-scan.sh --min-confidence high --count-only)" ||
    die "the snapshot scan did not complete — nothing was measured"
  vn="$(sed -nE 's/.*: ([0-9]+) finding.*/\1/p' <<<"$vout")"
  case "$vn" in '' | *[!0-9]*) die "could not read a count out of: $vout" ;; esac
  vbank="$(tail -1 "$vscratch/scripts/pipefail-sigpipe-baseline.txt")"
  vbank="${vbank//[[:space:]]/}"
  case "$vbank" in '' | *[!0-9]*) die "the snapshot baseline's last line is not an integer: ${vbank:-<empty>}" ;; esac

  wout="$(bash "${BASH_SOURCE[0]}" --min-confidence high --count-only)" || wout="(the working-tree scan failed)"
  wn="$(sed -nE 's/.*: ([0-9]+) finding.*/\1/p' <<<"$wout")"

  printf '%s: MEASURED ON A SNAPSHOT OF origin/main — never on this checkout.\n' "$PROG"
  printf '  sha        %s\n' "$vsha"
  printf '  command    (cd <snapshot> && bash scripts/pipefail-sigpipe-scan.sh --min-confidence high --count-only)\n'
  printf '  scan       %s\n' "$vout"
  printf '  baseline   %s   (tail -1 scripts/pipefail-sigpipe-baseline.txt OF THAT SNAPSHOT)\n' "$vbank"
  printf '  date       %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '\n'
  printf '  this checkout reads %s — NOT quotable, shown only so a drift is visible.\n' "${wn:-?}"
  if [ -n "$wn" ] && [ "$wn" != "$vn" ]; then
    printf '  THE TWO DISAGREE. The snapshot number is the measurement; this checkout is\n'
    printf '  either ahead of, behind, or dirty against %s. Quote the snapshot.\n' "$vsha"
  fi
  printf '\n'
  if [ "$vn" -gt "$vbank" ]; then
    printf '%s: RATCHET BROKEN ON origin/main — %s finding(s), baseline %s. A NEW site is on main.\n' \
      "$PROG" "$vn" "$vbank" >&2
    exit 1
  fi
  if [ "$vn" -lt "$vbank" ]; then
    printf '%s: RATCHET LOOSE ON origin/main — %s finding(s), baseline still says %s.\n' "$PROG" "$vn" "$vbank" >&2
    printf '%s: bank it: put %s in scripts/pipefail-sigpipe-baseline.txt with the command, the date\n' "$PROG" "$vn" >&2
    printf '%s: and %s in the SAME commit. Slack is where the next regression hides.\n' "$PROG" "$vsha" >&2
    exit 0
  fi
  printf '%s: origin/main %s measures %s and banks %s — they agree.\n' "$PROG" "$vsha" "$vn" "$vbank"
  exit 0
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

  # (0c) SED as the producer — the shape task-b9eb6d9337a43370 c1 named and no
  # fixture covered.  `sed` is the most common FILTER in this tree's gates, and a
  # filter is the producer as far as the next stage is concerned: it streams, so
  # `grep -q` can answer and exit while sed still has most of the file to write.
  # The 141/EPIPE platform split of (0)/(0a) applies here too, so this arm asks
  # for NON-ZERO and REPORTS the rc rather than demanding a number.
  #
  # ORDER MATTERS: this runs BEFORE the static fixture below, so the fixture is
  # never classified by the scanner until the shape has been shown to really
  # fail on THIS box.  A fixture the scanner reports while the shape no longer
  # misbehaves is a green with no subject.
  rcsed=0
  (
    set -o pipefail
    sed -n 's/^hit$/hit/p' "$std/long.txt" | grep -q '^hit$'
  ) 2>/dev/null || rcsed=$?
  if [ "$rcsed" -ne 0 ]; then
    sok "(0c) non-vacuity: a TRUE \`sed FILE | grep -q\` really comes back FAILED under pipefail (rc $rcsed on this box)"
  else
    sno "(0c) sed | grep -q returned 0 — the sed-producer form does not reproduce here, so the fixture below tests a ghost"
  fi
  rcsedfix=0
  (
    set -o pipefail
    grep -q '^hit$' <<<"$(sed -n 's/^hit$/hit/p' "$std/long.txt")"
  ) || rcsedfix=$?
  [ "$rcsedfix" -eq 0 ] && sok "(0d) the command-substitution fix returns 0 on the same sed output" ||
    sno "(0d) the command-substitution fix returned $rcsedfix"

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
  # The STATIC counterpart of (0c): the scanner must actually REPORT the shape
  # (0c) just proved is live.  Two halves of one claim — a live failure nobody
  # reports is a blind spot, a report of a shape that no longer fails is noise.
  say sed-into-grep-q 'sed -n "s/^RELAND_STATUS=//p" "$f" | grep -q "^ok$" || exit 1' HIT

  say hit-if 'if printf "%s\n" "$x" | grep -q foo; then :; fi' HIT
  say hit-or 'printf "%s" "$x" | grep -q foo || exit 1' HIT
  say miss-grep-full 'if printf "%s\n" "$x" | grep foo >/dev/null; then :; fi' MISS
  say miss-capture 'v="$(printf "%s" "$x" | grep -q foo)"' MISS
  say miss-or-true 'printf "%s" "$x" | grep -q foo || true' MISS
  say miss-comment '# if printf "%s" "$x" | grep -q foo; then :; fi' MISS

  # ── the TRUNCATING-READER arm (task-ab1d5320e09c9e72) ─────────────────────
  # Run at --min-confidence HIGH, because high is the only tier CI enforces and
  # the whole defect was that the planted shape sat BELOW it.  The two MISS arms
  # are the discrimination: if the arm were satisfied by the word `head` they
  # would both report, and a scanner that flags every `head` is a scanner that
  # gets switched off.  Body on stdin so the fixture can be quoted verbatim.
  sayhigh() { # sayhigh <name> <HIT|MISS>; BODY on stdin, under `set -euo pipefail`
    local n
    {
      printf '#!/usr/bin/env bash\nset -euo pipefail\n'
      cat
    } >"$std/$1.sh"
    n="$(PIPEFAIL_SCAN_ROOT="$std" bash "${BASH_SOURCE[0]}" --min-confidence high --count-only "$std/$1.sh" 2>/dev/null | sed -E 's/.*: ([0-9]+) finding.*/\1/')"
    case "$2:$n" in
    HIT:0) sno "$1: wanted a HIGH finding, got none" ;;
    MISS:0) sok "$1: correctly silent at --min-confidence high" ;;
    HIT:*) sok "$1: reported at HIGH ($n)" ;;
    MISS:*) sno "$1: wanted silence at --min-confidence high, reported $n" ;;
    esac
  }

  # POSITIVE — verbatim from scripts/pds-scratch-target.sh:389 as it shipped (lineref-ok, historical).
  # An INFINITE producer (/dev/urandom through tr) into a 40-byte truncating
  # reader, the pipeline captured into an assignment under set -e.  Before this
  # arm the scanner reported it at NO confidence at all: the pipeline lives
  # inside `"$( … )"`, which strip_quoted blanked wholesale.
  sayhigh trunc-unbounded-producer HIT <<'SH'
raw="pds-scratch-$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 40)"
SH

  # NEGATIVE (1) — a BOUNDED producer. `od -N20` stops after 20 bytes on its
  # own, so it cannot outrun a reader that takes 40; this is the shipped #17920
  # form with a `head` bolted back on. It contains the word `head`, the reader
  # IS `head`, pipefail IS on, the status IS consumed — everything the arm keys
  # on except the one thing that matters. Silence here is the discrimination.
  sayhigh trunc-bounded-od-producer MISS <<'SH'
raw="pds-scratch-$(LC_ALL=C od -An -v -tx1 -N20 </dev/urandom | tr -d ' \n' | head -c 40)"
SH

  # NEGATIVE (2) — printf of a LITERAL: 4 bytes into a 4-byte reader, already
  # classified `low` by the producer block, and the arm must not promote it.
  sayhigh trunc-literal-printf MISS <<'SH'
printf 'abcd' | head -c 4
SH

  # NEGATIVE (3) — the same planted shape with pipefail OFF. Without pipefail
  # the substitution's status is the LAST stage's (head, which succeeds), so
  # there is no hazard and no finding. This is the arm that reds if the new code
  # ever stops honouring condition (a).
  sayhigh trunc-no-pipefail MISS <<'SH'
set +o pipefail
raw="pds-scratch-$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 40)"
SH

  # NEGATIVE (4) — `|| true` INSIDE the substitution swallows the 141. The
  # trailing `)` is why this needs its own arm: a swallow pattern anchored on
  # the word `true` alone does not match `… | head -1 || true)`.
  sayhigh trunc-swallowed-by-or-true MISS <<'SH'
pid="$(lsof -nP -iTCP:4000 -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
SH

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

  # ── the QUOTED REMOTE COMMAND arm (task-bf9d623529d86a86 c1) ──────────────
  # A `run:` body says `set -euo pipefail`; a pipeline inside a quoted string
  # that body hands to `ssh` is executed by a DIFFERENT shell on a DIFFERENT
  # host, which sets nothing.  Attributing the outer `set` to that text is how
  # cp-ops.yml:96,97,149,406 were banked into the enforced ratchet and then left
  # alone as "wrong attribution, not a defect" — four findings that described
  # the scanner's parser, not the tree.
  #
  # THESE ARMS KEY ON THE SHAPE, NOT ON A FILE AND A LINE.  An enumeration is a
  # snapshot: a skip list of those four lines would pass this arm today and let
  # a FIFTH remote site ship unreported while the count silently dropped.  The
  # rule under test is the shell's own — a line that BEGINS inside an
  # unterminated quoted run is a string literal to the shell that reads it —
  # so (b) below plants the same hazard behind `docker exec … sh -c "…"`, a
  # shape no line list for cp-ops.yml could ever cover.
  #
  # (a) IS THE MISS; (c) IS WHAT KEEPS IT FROM BEING VACUOUS.  A scanner that
  # simply stopped reading `head` would pass (a) and (b) and fail (c).
  yml remote-ssh-quoted-body MISS <<'YML'
name: t
on: [push]
jobs:
  a:
    steps:
      - name: the OUTER body arms pipefail; the inner text is a remote shell's
        run: |
          set -euo pipefail
          $SSH "root@${CP_HOST}" "
            KEY=/root/.ssh/key
            ssh -i \"\$KEY\" root@${BOX_IP} '
              docker ps -a --format \"{{.Names}}\" | head -10
              systemctl list-units --all --no-pager --plain \"barkpark*\" | head -14
            '
          "
YML

  # (b) THE SAME DEFECT BEHIND A DIFFERENT DOOR — `sh -c "…"` under docker exec.
  # No `ssh` anywhere; a file+line skip list keyed on cp-ops.yml sees nothing
  # here, and the shape rule sees it for the same reason it saw (a).
  yml remote-quoted-body-not-ssh MISS <<'YML'
name: t
on: [push]
jobs:
  a:
    steps:
      - run: |
          set -euo pipefail
          docker exec "$c" sh -c "
            cat /var/log/app.log | head -300
          "
YML

  # (c) THE DISCRIMINATION.  Byte-identical pipeline, same body, same pipefail —
  # but OUTSIDE the quoted run, so THIS shell runs it and it is still a finding.
  # If (a) and (b) passed because the scanner stopped seeing `head`, this reds.
  yml remote-outer-command-still-reported HIT 8 <<'YML'
name: t
on: [push]
jobs:
  a:
    steps:
      - run: |
          set -euo pipefail
          docker ps -a --format '{{.Names}}' | head -10
          $SSH "root@${CP_HOST}" "echo one-line remote, quote closes here"
YML

  # (d) A COMMAND SUBSTITUTION RESTARTS QUOTING.  `x="$(producer | head -1)"` is
  # code inside a double-quoted run, and suppressing it would silently delete the
  # 98 findings the 2026-09-12 widening was written to catch.  This is the arm
  # that reds if the cross-line tracker is made cruder — e.g. "skip every line
  # after an odd quote count".
  sayhigh quoted-substitution-is-still-code HIT <<'SH'
c="$(docker ps -q --filter name=app | head -1)"
SH

  # (e) THE OVER-SUPPRESSION REGRESSION ARM.  A trailing comment carrying an
  # apostrophe — `# the R1 main's roster` — is not an open quote: `#` at a word
  # boundary ends the shell line.  Measured while building the tracker: without
  # the comment rule that ONE line suppressed 11 real findings further down
  # scripts/required-checks.test.sh and scripts/pdf-mvp0-journey-proof.sh, and
  # the count fell from 101 to 86 while looking exactly like the fix working.
  # The finding here sits AFTER the comment, so it only reports if the state
  # recovered.
  sayhigh apostrophe-in-trailing-comment-is-not-a-quote HIT <<'SH'
jroster() { : ; }   # the R1 main's roster (the journey truth for R2-R5)
c="$(git log --format=%H | head -1)"
SH

  # (f) …and the same shape for `${x#pat}` and `$#`, which contain a `#` that is
  # NOT a comment.  A boundary rule keyed on the character alone would truncate
  # both lines and lose the finding on the second.
  sayhigh hash-in-expansion-is-not-a-comment HIT <<'SH'
v="${PATH#/usr}"; n=$#
c="$(git log --format=%H | head -1)"
SH

  # ── THE LIVE TREE, not only a copy of it (the fixture proves the matcher; the
  # real file proves the fixture is the same shape as the tree).  cp-ops.yml
  # must report ZERO at high — and the PRECONDITION is asserted first, because a
  # zero over a file that no longer contains the shape measures nothing.
  cpops="$sroot/.github/workflows/cp-ops.yml"
  if [ ! -r "$cpops" ]; then
    sno "live cp-ops.yml: NOT FOUND under $sroot — this arm measured nothing"
  elif ! grep -q 'docker ps -a --format' "$cpops"; then
    sno "live cp-ops.yml: the remote box-probe body is gone — this arm's subject no longer exists"
  else
    cpn="$(bash "${BASH_SOURCE[0]}" --min-confidence high --count-only "$cpops" 2>/dev/null | sed -E 's/.*: ([0-9]+) finding.*/\1/')"
    if [ "$cpn" = "0" ]; then
      sok "live cp-ops.yml: 0 high finding(s) — the four remote-ssh sites are no longer attributed to the outer run:"
    else
      sno "live cp-ops.yml: reported $cpn high finding(s); the remote-command attribution is back"
    fi
  fi

  # ── --check-provenance, both directions (task-bf9d623529d86a86 c2) ────────
  # The shipped baseline must pass, and the LAUNDERING SHAPE must fail: a file
  # whose integer was edited while its block still describes the OLD number is
  # exactly how an inherited number gets a paper trail it never earned.
  if bash "${BASH_SOURCE[0]}" --check-provenance "$sroot/scripts/pipefail-sigpipe-baseline.txt" >/dev/null 2>&1; then
    sok "provenance: the shipped baseline carries a command, a date and a sha for the number it banks"
  else
    sno "provenance: the shipped baseline does NOT carry a command, a date and a sha for its number"
  fi
  prov="$std/prov.txt"
  {
    printf '# ── RE-MEASURED 2026-09-17 on 1234567890abcdef ──\n'
    printf '#     bash scripts/pipefail-sigpipe-scan.sh --min-confidence high --count-only\n'
    printf '#     -> pipefail-sigpipe-scan: 97 finding(s) - high 97\n'
    printf '11\n'
  } >"$prov"
  if bash "${BASH_SOURCE[0]}" --check-provenance "$prov" >/dev/null 2>&1; then
    sno "provenance: a baseline whose integer (11) does not match its own quoted measurement (97) PASSED"
  else
    sok "provenance: an integer edited away from the number its block quotes is REFUSED"
  fi
  printf '97\n' >>"$prov"
  # (the last line is what the ratchet reads; the FIRST integer is what
  # provenance reads — keep them the same file and the same number.)
  if bash "${BASH_SOURCE[0]}" --check-provenance "$std/prov-ok.txt" >/dev/null 2>&1; then
    sno "provenance: a nonexistent file PASSED — an unreadable input must never be a pass"
  else
    sok "provenance: an unreadable baseline is refused, never silently passed"
  fi

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

# strip_quoted_keep_subst — strip_quoted, except that `$( … )` RESTARTS quoting,
# which is what real shell does.  strip_quoted blanks every double-quoted run, so
# a pipeline that lives inside a command substitution inside double quotes —
# `x="$(producer | head -c 40)"` — arrives at the matcher as `x=""`: no pipe, no
# reader, nothing to report.  That is the exact shape that let
# scripts/pds-scratch-target.sh:389 (lineref-ok, historical) ship `LC_ALL=C tr -dc 'a-f0-9' </dev/urandom
# | head -c 40` unflagged at EVERY confidence tier until a CI runner printed
# "tr: write error: Broken pipe" (main run 34685061716; fixed by #17920).
# Answers in STRIPPED_SUBST.  Used ONLY when the plain strip found no pipe at
# all, so it is strictly additive — it cannot change any site already reported.
# The stack is a string of D (was inside a double quote) / N (was unquoted)
# markers rather than an array index, because macOS ships bash 3.2 and
# ${a[-1]} is a bash 4.3 feature.
STRIPPED_SUBST=""
strip_quoted_keep_subst() {
  local s="$1" out="" ch nx q="" stack="" i n just_opened_dq=0
  n=${#s}
  for ((i = 0; i < n; i++)); do
    ch="${s:i:1}"
    nx="${s:i+1:1}"
    # A `$(` inside '…' is literal — single quotes do not expand — so the
    # restart is honoured only outside a single-quoted run.
    if [ "$q" != "'" ] && [ "$ch" = '$' ] && [ "$nx" = '(' ]; then
      # `x="$(…)"` must come out as `x=$(…)`, not `x=""$(…)`: the boolean-use
      # test below keys on the `=$(` adjacency, and the placeholder pair emitted
      # for the opening quote would break it — the site would then be reported
      # as a bare command under set -e instead of an assignment capture.
      [ "$just_opened_dq" -eq 1 ] && out="${out%??}"
      case "$q" in '"') stack="D$stack" ;; *) stack="N$stack" ;; esac
      q=""
      out="$out\$("
      i=$((i + 1))
      continue
    fi
    if [ -z "$q" ] && [ "$ch" = ')' ] && [ -n "$stack" ]; then
      case "${stack:0:1}" in 'D') q='"' ;; *) q="" ;; esac
      stack="${stack:1}"
      out="$out)"
      continue
    fi
    if [ -n "$q" ]; then
      [ "$ch" = "$q" ] && q=""
      continue
    fi
    case "$ch" in
    "'" | '"')
      q="$ch"
      out="$out$ch$ch"
      [ "$ch" = '"' ] && just_opened_dq=1 || just_opened_dq=0
      continue
      ;;
    esac
    out="$out$ch"
    just_opened_dq=0
  done
  STRIPPED_SUBST="$out"
}

# ── track_quote — carry an OPEN quoted string ACROSS lines ──────────────────
#
# THE ATTRIBUTION BUG THIS CLOSES (task-bf9d623529d86a86).  strip_quoted and
# strip_quoted_keep_subst are per-LINE: they start every line unquoted.  A quote
# opened on one line and closed on another is therefore invisible, and every
# line in between is read as code THIS shell runs.  The loudest instance is a
# remote command:
#
#     $SSH "root@${CP_HOST}" "                 # ← opens a double quote
#       ssh -i \"\$KEY\" root@${BOX_IP} '
#         docker ps -a --format \"…\" | head -10   # ← a DIFFERENT shell, on a
#       '                                           #   DIFFERENT host, runs this
#     "                                        # ← closes it
#
# The `run:` body above it says `set -euo pipefail`, so the scanner reported the
# inner `| head -10` as "bare command under set -e".  It is not: the outer shell
# sees one `ssh` word plus a string literal, and the remote shell that actually
# executes the text sets nothing at all.  Four such sites in cp-ops.yml
# (96, 97, 149, 406 as of b569033e2e) were banked into the enforced ratchet on
# that reading and then left alone as "wrong attribution, not a defect".
#
# THIS KEYS ON THE SHAPE, NOT ON A FILE+LINE LIST.  An enumeration is a snapshot:
# a fifth remote-ssh site would ship unreported under a skip list while the count
# silently dropped.  The rule here is the shell's own — a line that BEGINS inside
# an unterminated quoted run is a string literal to this shell, whoever ends up
# executing it — so it covers `ssh`, `docker exec`, `su -c`, `bash -c`, a heredoc
# assembled by hand, and every remote runner not yet written.
#
# IT CAN ONLY MAKE US REPORT LESS, NEVER MORE — the same direction strip_quoted
# errs in.  A site suppressed here is one this shell does not run; if the remote
# shell arms pipefail, that is a finding about a REMOTE script, which this
# scanner has never claimed to read.
#
# Answers in the globals QQ (the open quote char, "" when none) and QSTACK (the
# `$( … )` nesting, D = the substitution opened inside a double quote, N = it did
# not), because a command substitution RESTARTS quoting — `x="$(a | head -1)"` is
# code, not a literal, and must keep being reported.  Both reset at every file and
# at every `run:` block boundary: a workflow step is a fresh process, so an
# unbalanced quote in step 1 says nothing about step 5.
#
# Unlike the strip functions this one honours BACKSLASH ESCAPES, because `\"` is
# how a nested remote command quotes its own arguments and a tracker that let
# `\"` close the string would fall out of the literal three characters in.
QQ=""
QSTACK=""
# The characters that can change the state. Everything between two of them is
# skipped in ONE parameter expansion instead of a loop turn per character: this
# function runs over a large fraction of the lines in 442 files, and a per-char
# `${s:i:1}` walk made the whole scan 4x slower on the tree it guards.
PFS_INTERESTING='["'"'"'\\$)#]'
track_quote() {
  local s="$1" head ch prev=""
  while [ -n "$s" ]; do
    # Inside a single-quoted run NOTHING is special but the closing quote —
    # no escapes, no substitutions, no comments.
    if [ "$QQ" = "'" ]; then
      case "$s" in
      *"'"*)
        s="${s#*\'}"
        QQ=""
        prev="'"
        ;;
      *) s="" ;;
      esac
      continue
    fi
    head="${s%%$PFS_INTERESTING*}"
    [ "${#head}" -eq "${#s}" ] && break # nothing interesting left on this line
    [ -n "$head" ] && prev="${head:${#head}-1:1}"
    s="${s:${#head}}"
    ch="${s:0:1}"
    s="${s:1}"
    case "$ch" in
    '\')
      # Outside single quotes a backslash escapes the next character — including
      # at end of line, where it is a line continuation and escapes nothing.
      # `\"` is how a nested remote command quotes its own arguments, and a
      # tracker that let it close the string would fall out of the literal three
      # characters in.
      prev="${s:0:1}"
      s="${s:1}"
      ;;
    '$')
      if [ "${s:0:1}" = '(' ]; then
        # a command substitution RESTARTS quoting, which is what real shell
        # does: `x="$(a | head -1)"` is CODE and must keep being reported. D
        # remembers that the substitution opened inside a double-quoted run.
        case "$QQ" in '"') QSTACK="D$QSTACK" ;; *) QSTACK="N$QSTACK" ;; esac
        QQ=""
        s="${s:1}"
        prev='('
      else
        prev='$'
      fi
      ;;
    '"')
      if [ "$QQ" = '"' ]; then QQ=""; else QQ='"'; fi
      prev='"'
      ;;
    "'")
      # ignored inside a double-quoted run, where it is an ordinary character.
      [ -z "$QQ" ] && QQ="'"
      prev="'"
      ;;
    ')')
      if [ -z "$QQ" ] && [ -n "$QSTACK" ]; then
        case "${QSTACK:0:1}" in 'D') QQ='"' ;; *) QQ="" ;; esac
        QSTACK="${QSTACK:1}"
      fi
      prev=')'
      ;;
    '#')
      # A `#` at a WORD BOUNDARY starts a comment and the rest of the line is
      # not shell at all. Without this the apostrophe in a trailing
      # `# the R1 main's roster` opens a single-quoted run that never closes and
      # every later line in the file is suppressed as "inside a string".
      # MEASURED while building this: that one comment silently dropped 11 real
      # findings across required-checks.test.sh and pdf-mvp0-journey-proof.sh —
      # an over-suppression that looks exactly like the fix working, which is
      # why the arms below diff the WHOLE finding list and not just the count.
      # `${x#pat}` and `$#` must NOT match, hence the test on the PRECEDING
      # character rather than on `#` alone.
      if [ -z "$QQ" ]; then
        case "$prev" in '' | ' ' | '	' | ';' | '&' | '|' | '(') break ;; esac
      fi
      prev='#'
      ;;
    esac
  done
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
  QQ=""
  QSTACK=""
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
        QQ=""
        QSTACK=""
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
    # ── a line CONTINUING an open quoted string is NOT this shell's code ──
    # See track_quote above. It runs BEFORE the comment test on purpose: inside
    # a quoted run a leading `#` is a literal `#`, not a comment, so skipping
    # such a line without advancing the state would strand the tracker inside a
    # string it has already left. It runs before the heredoc-OPEN test for the
    # same reason — a `<<` inside a remote command string opens a heredoc for
    # the REMOTE shell, never for this one.
    if [ -n "$QQ" ]; then
      # Only a matching quote char or a `$(` can change the state, so most lines
      # of a multi-line awk/python/remote body skip the char loop entirely.
      case "$line" in *"$QQ"* | *'$('*) track_quote "$line" ;; esac
      prev_pipe_line=0
      prev_pipe_text=""
      prev_pipe_conf=""
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

    # Advance the cross-line quote state for this CODE line. A line with no
    # quote character at all cannot open one, and can only matter when a `$( … )`
    # is already open — so it costs one pattern test and nothing else.
    # MEASURED on scripts/required-checks.test.sh (6k lines, the tree's worst
    # case): 1.55s before this change, 2.12s after. An earlier cut tried to skip
    # more by pre-counting quote characters with `${line//[^\"]/}`; that cost
    # MORE than the tracker it was avoiding (3.03s) and was removed.
    case "$line" in
    *'"'* | *"'"*) track_quote "$line" ;;
    *) [ -n "$QSTACK" ] && track_quote "$line" ;;
    esac

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

    # ── the substitution-aware re-strip (task-ab1d5320e09c9e72) ───────────
    # Only when the plain strip left no pipe at all: then the only place a
    # pipeline can be hiding is inside a `$( … )` within a double-quoted run,
    # where real shell restarts quoting and this script did not.  Narrowed to
    # a `head` reader on purpose — that is the class this row was filed for,
    # and keeping the swap narrow keeps the change strictly additive instead
    # of re-classifying every already-reported site.
    case "$bare" in
    *'|'*) ;;
    *)
      strip_quoted_keep_subst "$line"
      case "$STRIPPED_SUBST" in
      *'|'*head*) bare="$STRIPPED_SUBST" ;;
      esac
      ;;
    esac
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
    # Inside a command substitution the swallow is the LAST thing before the
    # closing paren — `x="$(producer | head -1 || true)"` — and once the quoted
    # run is blanked the tail reads `… || true)""`. A pattern anchored on the
    # word alone matches neither, so a genuinely harmless site gets reported.
    # Peel the closers off a COPY before testing; `bare` itself is untouched
    # because the reported text comes from it.  Measured 2026-09-12: without
    # this, scripts/pds-crown-launch.sh:1886 (lineref-ok, historical; a `| head -1 || true)"` line
    # continuation) is a false positive banked into the enforced ratchet.
    swallow="$bare"
    while :; do
      case "$swallow" in
      *[\)\"\'\ ]) swallow="${swallow%?}" ;;
      *) break ;;
      esac
    done
    case "$swallow" in
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

    # ── a TRUNCATING READER forces HIGH (task-ab1d5320e09c9e72) ───────────
    # `head` does not read to EOF under any flag: bare `head` stops at 10 lines,
    # `head -N`/`head -n N` at N lines, `head -c N` at N bytes — and then CLOSES
    # the pipe.  So the question is never "is the producer file-sized"; it is
    # "can the producer be shown to STOP at or before what head takes".  If it
    # cannot, the producer is killed the instant it writes past N, and pipefail
    # hands back 141 — no 64KB buffer required, no tree growth required.
    #
    # WHAT THE OLD CLASSIFIER DID.  `LC_ALL=C tr -dc 'a-f0-9' </dev/urandom` is
    # an INFINITE producer and matched none of the high-confidence names, so it
    # fell to `producer not classified` → medium, and `--min-confidence high` —
    # the only tier CI enforces — dropped it.  An unbounded stdin (`</dev/urandom`,
    # `</dev/zero`, `yes`, `cat /dev/…`) is the worst case in the class and was
    # the one case the tier could not see.
    #
    # THE EXCEPTION IS BOUNDEDNESS, NOT THE WORD `head`: a producer that is
    # byte/line-capped by its own flags (`od -N<n>`, `dd count=`, a `head` of its
    # own) cannot outrun the reader, and printf/echo of a LITERAL is already
    # classified low by the block above and stays there.  The selftest pins both
    # directions (trunc-unbounded-producer / trunc-bounded-producer).
    if [ "$reader" = "head" ] && [ "$conf" != "low" ]; then
      case "$ptrim" in
      *od\ *-N[0-9]* | *od\ *-N\ [0-9]* | *dd\ *count=* | *head\ -c* | *head\ -n* | *head\ -[0-9]*)
        why="$why; truncating reader, but the producer is byte/line-BOUNDED"
        ;;
      *)
        conf="high"
        why="truncating reader (head closes the pipe at N) on a producer not provably bounded — 141 needs no buffer overrun"
        ;;
      esac
    fi

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
    printf '%s: BEFORE YOU BANK IT: a LOOSE ratchet is also what a STALE CHECKOUT looks like (this repo\n' "$PROG" >&2
    printf '%s: read 107 against a banked 108 on 2026-09-16 while 38 commits behind). Measure a snapshot:\n' "$PROG" >&2
    printf '%s:   bash scripts/pipefail-sigpipe-scan.sh --verify-against-origin-main\n' "$PROG" >&2
  fi
fi

if [ "$fail_on_finding" -eq 1 ] && [ "$findings" -gt 0 ]; then
  exit 1
fi
exit 0
