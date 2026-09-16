#!/usr/bin/env bash
#
# PDS CITATION PRECEDES MERGE — a slice PR may not cite a decision main has not
# defined yet.
#
# THE INCIDENT, from the charter's own record (PDS-D643). On 2026-08-03 three
# PDS slice PRs merged at 10:49-10:50Z; the charter PR that DEFINED the numbers
# they cite merged at 11:29Z, forty minutes later. For that window
# a git grep over origin/main's api and scripts for the ten numbers D633 through
# D642 returned THIRTEEN HITS IN SHIPPED CODE pointing at decisions main did not
# define. (Written without the prefixed literals on purpose: pds-record-parity's
# axis D reads this file, and a prefixed number here would be a citation.) The
# wave's own stated law was "the charter merges FIRST and ALONE". It was
# inverted in practice and no one noticed until a verifier looked. D643 names
# the remedy in one sentence: a slice PR that cites a D-number MUST NOT merge
# before the charter PR that defines it. This script is that sentence, mechanised.
#
# ── EXISTENCE IS NOT COVERAGE. THE JUDGEMENT HALF IS OUT OF SCOPE. ───────────
#
# Read this before quoting a PASS from here in any argument.
#
# This check answers exactly one question: DOES THE CITED NUMBER RESOLVE TO A
# DECISION DEFINED IN THE CHARTER ON THE BASE REF. It does not read the decision.
# It cannot tell you whether the decision says what the citing line claims it
# says. The charter records that exact failure as the "arm-D phantom" class: a
# REAL charter entry cited as authority for something it does not cover. That
# citation resolves here and always will, and it is still wrong.
#
# So: a PASS from this script means "the authority exists on the base ref". It
# does NOT mean "the authority grants this". Deciding whether a cited decision
# COVERS the claim made in its name is a human read of the cited text, it is
# deliberately out of scope for this mechanical check, and no green printed
# below should ever be offered as evidence of it.
#
# ── WHY THIS IS A SIBLING OF pds-record-parity.sh AND NOT A DUPLICATE ─────────
#
# `scripts/pds-record-parity.sh` already resolves PDS-D citations, on two axes,
# and this script REUSES its definition lens rather than re-deriving one (that
# lens has drifted once already — PDS-D679 — and one drifting lens is enough).
# What it does not do, and cannot:
#
#   AXIS A resolves citations in the COMMIT MESSAGES of commits ALREADY MERGED.
#          Post-hoc by construction: on 2026-08-03 it would have gone red at
#          10:49 and green again at 11:29 without a single line changing.
#   AXIS D resolves the PDS-D literals carried in `scripts/pds-*` and
#          `tooling/pds/**` AGAINST THE CHARTER IN THE WORKING TREE. That is
#          precisely the blind spot D643 names: on a branch that carries both
#          the slice and the charter edit, the tree's charter already defines
#          the number, so axis D is green on the very ordering it must catch.
#
# This arm differs on all three axes that matter to the hazard:
#   CORPUS   the lines a PR's diff INTRODUCES, not a whole-tree census.
#   ORACLE   the charter AT THE BASE REF (origin/main), never the branch's.
#   MOMENT   before the merge, not after it.
#
# ── THE SAME-PR EXEMPTION, STATED ─────────────────────────────────────────────
#
# A number this PR's OWN charter diff defines also resolves. The hazard D643
# describes is an ORDERING hazard ACROSS PRs; a PR that lands the decision and
# the citation in one commit cannot be half-merged, so there is no window. A PR
# that only CITES gets no such exemption — that is the whole check.
#
# ── THE CONTROLS, AND WHY A GREEN WITHOUT THEM IS WORTHLESS ───────────────────
#
# An absence is never caught by inspection. "This number is not in the charter"
# and "my reader read nothing" produce byte-identical output. So before any
# verdict, two controls run over the same lens and are PRINTED beside the result:
#
#   PROBE     the lens is pointed at a charter THIS SCRIPT WRITES, defining
#             exactly two numbers in the charter's two definition forms and
#             MENTIONING a third in prose. It must return exactly the two, in
#             order. This is a control on the READER, not on the membership
#             test, and it is the only one of the three that survives a lens
#             which resolves everything.
#   POSITIVE  the highest number the real charter defines MUST resolve.
#   NEGATIVE  the number one above it MUST NOT resolve.
#
# All three are DERIVED from the charter under test, never listed: a hardcoded
# control rots into a second thing to maintain. If any misbehaves the verdict is
# UNCHECKED (exit 2) and no pass or fail is printed at all.
#
# WHY THE PROBE EXISTS AT ALL — it was not designed in, it was EARNED. The first
# version of this arm shipped with the positive and negative legs only, and the
# paired test's mutation 7 (a lens that returns every number from 1 upward)
# walked straight through both: the highest real number resolved, the one above
# the highest resolved number did not, and a phantom citation printed a clean
# PASS. Two legs that fail together prove one thing. The probe asks a different
# question of a different corpus, which is the only kind of leg that adds
# anything.
#
# A PR introducing ZERO citations PASSES, and says so in those words. That is a
# real pass, not a vacuous one, precisely because the controls above fired over
# a charter that was genuinely read.
#
# ── THIS IS A PREDICATE, NOT A LIST ───────────────────────────────────────────
#
# Nothing here enumerates known-bad numbers. The rule is "cited ⊆ defined-on-base
# ∪ defined-by-this-PR", evaluated fresh every run. The only roster consulted is
# the synthetic-fixture roster already owned by pds-record-parity.sh, read
# through it rather than copied (numbers that are prose ABOUT a test fixture,
# not a claim on an authority).
#
# ── EXIT CODES ────────────────────────────────────────────────────────────────
#
#   0  every introduced citation resolves on the base ref (or none was introduced)
#   1  at least one does not — each named, with the file that introduces it
#   2  UNCHECKED — a control misfired, the charter is unreadable at a ref, the
#      lens is unavailable, or the diff could not be produced. A verdict over a
#      corpus that was never read is not a pass.
#
# ── USAGE ─────────────────────────────────────────────────────────────────────
#
#   bash scripts/pds-citation-precedes-merge.sh                    # HEAD vs origin/main
#   bash scripts/pds-citation-precedes-merge.sh --base origin/main --head <sha>
#   bash scripts/pds-citation-precedes-merge.sh --list             # every citation
#   bash scripts/pds-citation-precedes-merge.sh --diff-file <f>    # corpus verbatim
#
set -uo pipefail

BASE="origin/main"
HEAD_REF="HEAD"
CHARTER_PATH=".claude/workflows/bp-pds-charter.md"
DIFF_FILE=""
ROOT=""
LIST=0
LENS="scripts/pds-record-parity.sh"

die2() { printf 'pds-citation-precedes-merge: UNCHECKED: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --base)          BASE="${2:-}"; shift 2 || die2 "--base needs a ref" ;;
    --head)          HEAD_REF="${2:-}"; shift 2 || die2 "--head needs a ref" ;;
    --charter-path)  CHARTER_PATH="${2:-}"; shift 2 || die2 "--charter-path needs a path" ;;
    --diff-file)     DIFF_FILE="${2:-}"; shift 2 || die2 "--diff-file needs a path" ;;
    --root)          ROOT="${2:-}"; shift 2 || die2 "--root needs a path" ;;
    --lens)          LENS="${2:-}"; shift 2 || die2 "--lens needs a path" ;;
    --list)          LIST=1; shift ;;
    -h|--help)       sed -n '2,120p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die2 "unknown argument: $1 (try --help)" ;;
  esac
done

if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || ROOT=""
  [ -n "$ROOT" ] || ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
cd "$ROOT" || die2 "cannot enter root: $ROOT"

[ -f "$LENS" ] || die2 "the definition lens $LENS is not present — this arm does not carry its own"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pds-citation.XXXXXX")" || die2 "cannot make a scratch dir"
trap 'rm -rf -- "$WORK"' EXIT

# ── the definition lens, borrowed whole from pds-record-parity.sh ─────────────
# defs_at <ref> -> newline-separated bare numbers, or empty if the ref has no charter
defs_at() {
  local ref="$1" f="$WORK/charter.$$.$RANDOM"
  git show "${ref}:${CHARTER_PATH}" > "$f" 2>/dev/null || return 1
  [ -s "$f" ] || return 1
  bash "$LENS" --print-defs --charter "$f" 2>/dev/null
}

BASE_SHA="$(git rev-parse --verify "${BASE}^{commit}" 2>/dev/null)" || die2 "base ref '$BASE' does not resolve"
HEAD_SHA="$(git rev-parse --verify "${HEAD_REF}^{commit}" 2>/dev/null)" || die2 "head ref '$HEAD_REF' does not resolve"

defs_at "$BASE_SHA" > "$WORK/defs.base" || die2 "no charter at ${BASE}:${CHARTER_PATH} — nothing to resolve against"
DEFN="$(grep -c . < "$WORK/defs.base" | tr -d ' ')"
[ "${DEFN:-0}" -ge 2 ] || die2 "the lens read $DEFN decision(s) from ${BASE}:${CHARTER_PATH} — a resolver over an unread charter is not a check"

resolves_base() { grep -qxF "$1" "$WORK/defs.base"; }

# ── CONTROLS. Derived from the charter under test; printed; never a list. ─────
#
# LEG 1 — THE PROBE. A charter this script writes, in the two definition forms,
# plus a prose MENTION that is not a definition. The lens must return exactly
# the two defined numbers. A lens that reads nothing fails it; so does a lens
# that resolves everything; so does a lens that counts any PDS-D it sees.
CTL_MAX="$(tail -n 1 "$WORK/defs.base")"
case "$CTL_MAX" in ''|*[!0-9]*) die2 "the lens returned '${CTL_MAX}' as its highest number — that is not a decision id" ;; esac
P1=$((CTL_MAX + 1000)); P2=$((CTL_MAX + 1005)); P3=$((CTL_MAX + 1010))
{
  printf '# Probe charter written by %s\n\n' "$(basename "$0")"
  printf '### PDS-D%s — HEADING FORM.\nbody\n\n' "$P1"
  printf -- '- **PDS-D%s — BOLD-LEAD FORM.** body\n\n' "$P2"
  printf 'Prose that merely MENTIONS PDS-D%s is a reference, not a definition.\n' "$P3"
} > "$WORK/probe.md"
PROBE_GOT="$(bash "$LENS" --print-defs --charter "$WORK/probe.md" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
PROBE_WANT="${P1} ${P2}"
[ "$PROBE_GOT" = "$PROBE_WANT" ] || die2 "probe control failed: pointed at a charter defining exactly ${PROBE_WANT}, the lens ${LENS} returned '${PROBE_GOT}'. The reader is not reading; a clean result from a broken reader is indistinguishable from a clean corpus"

CTL_POS="$CTL_MAX"
CTL_NEG=$((CTL_POS + 1))
resolves_base "$CTL_POS" || die2 "positive control failed: D${CTL_POS} is the highest number the lens read and it does not resolve through the same lens — the reader is broken, and a clean result from a broken reader is indistinguishable from a clean corpus"
if resolves_base "$CTL_NEG"; then
  die2 "negative control failed: D${CTL_NEG} is above the highest number read and still resolves — the membership test says yes to everything"
fi

# ── the synthetic-fixture roster, read THROUGH pds-record-parity.sh ───────────
# `--print-synthetic` prints the roster AFTER the lens owner's own run banner, so
# take the last line that is nothing but numbers. A usage error there yields an
# empty roster — which skips nothing and can only make this arm LOUDER, never
# quieter, so it is not a silent-pass path.
SYNTH="$(bash "$LENS" --print-synthetic a 2>/dev/null | grep -E '^[0-9]+([[:space:]]+[0-9]+)*$' | tail -1)"

echo "PDS CITATION PRECEDES MERGE"
echo "  base       : ${BASE} (${BASE_SHA})"
echo "  head       : ${HEAD_REF} (${HEAD_SHA})"
echo "  charter    : ${BASE}:${CHARTER_PATH} — ${DEFN} decisions defined (lens: ${LENS})"
echo "  controls   : probe charter defining D${P1}/D${P2} (+ a prose mention of D${P3}) read back as exactly '${PROBE_GOT}'"
echo "               D${CTL_POS} resolves=YES (positive), D${CTL_NEG} resolves=NO (negative) — all three fired"
echo "  synthetic  : ${SYNTH:-(none)} — prose ABOUT a fixture is not a claim on an authority"

# ── the corpus: the lines this PR's diff INTRODUCES, charter excluded ─────────
if [ -n "$DIFF_FILE" ]; then
  [ -f "$DIFF_FILE" ] || die2 "--diff-file $DIFF_FILE not found"
  cp "$DIFF_FILE" "$WORK/diff" || die2 "cannot read $DIFF_FILE"
  echo "  corpus     : --diff-file ${DIFF_FILE} (verbatim)"
else
  MB="$(git merge-base "$BASE_SHA" "$HEAD_SHA" 2>/dev/null)" || MB=""
  [ -n "$MB" ] || die2 "no merge-base between ${BASE} and ${HEAD_REF} — the set of introduced lines is undefined"
  git diff --no-color -U0 "$MB" "$HEAD_SHA" -- . ":(exclude)${CHARTER_PATH}" > "$WORK/diff" 2>/dev/null \
    || die2 "git diff ${MB}..${HEAD_SHA} failed — the corpus was never read"
  echo "  corpus     : added lines in ${MB}..${HEAD_SHA}, excluding ${CHARTER_PATH}"
fi

# path<TAB>number, one per introduced occurrence
awk '
  /^\+\+\+ /     { p = $2; sub(/^b\//, "", p); next }
  /^\+\+\+$/     { next }
  /^\+/ {
    line = substr($0, 2)
    while (match(line, /PDS-D[0-9]+/)) {
      tok = substr(line, RSTART, RLENGTH)
      sub(/^PDS-D/, "", tok)
      printf "%s\t%s\n", (p == "" ? "(unknown)" : p), tok
      line = substr(line, RSTART + RLENGTH)
    }
  }
' "$WORK/diff" | sort -u > "$WORK/cites.raw"

# drop /dev/null targets and the synthetic roster
: > "$WORK/cites"
while IFS=$'\t' read -r path num; do
  [ "$path" = "/dev/null" ] && continue
  skip=0
  for s in $SYNTH; do [ "$s" = "$num" ] && skip=1 && break; done
  [ "$skip" -eq 1 ] && continue
  printf '%s\t%s\n' "$path" "$num" >> "$WORK/cites"
done < "$WORK/cites.raw"

CITES="$(grep -c . < "$WORK/cites" | tr -d ' ')"
DISTINCT="$(cut -f2 "$WORK/cites" | sort -n -u | tr '\n' ' ')"
echo "  citations  : ${CITES:-0} introduced occurrence(s) over: ${DISTINCT:-(none)}"

# ── the same-PR exemption: numbers this PR's own charter diff DEFINES ─────────
: > "$WORK/defs.head"
if [ -z "$DIFF_FILE" ] && ! git diff --quiet "$BASE_SHA" "$HEAD_SHA" -- "$CHARTER_PATH" 2>/dev/null; then
  if defs_at "$HEAD_SHA" > "$WORK/defs.head.all" 2>/dev/null; then
    comm -13 "$WORK/defs.base" <(sort "$WORK/defs.head.all") 2>/dev/null \
      | sort -n > "$WORK/defs.head" || : > "$WORK/defs.head"
    echo "  same-PR    : this PR's charter diff defines $(grep -c . < "$WORK/defs.head" | tr -d ' ') new number(s) — exempt, see the header"
  fi
fi

if [ "${CITES:-0}" -eq 0 ]; then
  echo
  echo "PASS — this diff introduces no PDS-D citation. The controls above fired over"
  echo "       ${DEFN} genuinely-read decisions — including a probe charter this run wrote —"
  echo "       so this is an empty corpus, not an unread one."
  echo "       EXISTENCE IS NOT COVERAGE: this arm never reads what a decision SAYS."
  exit 0
fi

if [ "$LIST" -eq 1 ]; then
  echo
  echo "  --- every introduced citation ---"
  while IFS=$'\t' read -r path num; do
    if resolves_base "$num"; then st="ok  "
    elif grep -qxF "$num" "$WORK/defs.head" 2>/dev/null; then st="self"
    else st="MISS"; fi
    printf '  %s  PDS-D%-6s %s\n' "$st" "$num" "$path"
  done < "$WORK/cites"
fi

: > "$WORK/miss"
while IFS=$'\t' read -r path num; do
  resolves_base "$num" && continue
  grep -qxF "$num" "$WORK/defs.head" 2>/dev/null && continue
  printf '%s\t%s\n' "$path" "$num" >> "$WORK/miss"
done < "$WORK/cites"

if [ ! -s "$WORK/miss" ]; then
  echo
  echo "PASS — every one of the ${CITES} introduced citation(s) resolves to a decision"
  echo "       ${CHARTER_PATH} ALREADY defines on ${BASE}. Merging this PR cannot strand a"
  echo "       citation the way PDS-D643 records."
  echo "       EXISTENCE IS NOT COVERAGE: a real entry can be cited as authority it does"
  echo "       not grant. Whether each cited decision COVERS the claim made in its name is"
  echo "       a human read of the cited text and is OUT OF SCOPE for this check."
  exit 0
fi

MISSN="$(cut -f2 "$WORK/miss" | sort -n -u | sed 's/^/PDS-D/' | tr '\n' ' ')"
echo
echo "FAIL — $(grep -c . < "$WORK/miss" | tr -d ' ') introduced citation(s) name a decision ${BASE} does NOT define:"
echo
echo "  MISSING: ${MISSN}"
echo
while IFS=$'\t' read -r path num; do
  printf '  PDS-D%-6s introduced by %s\n' "$num" "$path"
done < "$WORK/miss"
echo
echo "  This is the PDS-D643 shape: shipped code pointing at a decision main has not"
echo "  defined. Land the charter PR that defines ${MISSN}FIRST, or fix the citation."
exit 1
