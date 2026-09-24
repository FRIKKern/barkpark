#!/usr/bin/env bash
# required-checks-ack-derive.sh — the SIXTH PLACE, derived instead of remembered.
#
# WHAT IT ANSWERS. `.github/required-checks.json` carries an `.exclusions`
# ledger. Every row in it that the frozen fixture pair (e34031104 / f69cfb1f6,
# scripts/fixtures/registration-flip) cannot re-derive has to be acknowledged,
# one name at a time, in the `ACK_EX` array of scripts/required-checks.test.sh —
# otherwise scripts/required-checks-generate.sh refuses `EXCLUSION LOSS` on
# every §14/§14b emit in that suite and the whole spec gate goes red. That
# coupling is written in a comment ("the SIXTH place a new blocking job has to
# pay") and enforced by nothing that runs on the PR adding the row.
#
# WHAT IT COST, ONCE, AND WHY THIS FILE EXISTS. #17111 (c19d7c7ab, 2026-09-09)
# added four `.exclusions` rows by hand and paid five of the six places.
# `Required-check spec gate` went red on #17111's own head (run 34392441135) and
# on every main push after it; the context is not one of the four required, so
# nothing stopped the merge, and main stayed red for ~3 hours until #17148
# (006d93bcd) typed the four missing lines. The 2026-09-07 census
# (task-6c8a76a6f6196dfd) had already paid the same tax by hand for 21 rows.
# An enumeration is a snapshot; this is the predicate.
#
# HOW IT DERIVES, and it derives rather than restates: it asks the generator.
#   run 1  the generator over the frozen pair with NO acknowledgement at all.
#          It exits 1 at `S1 LOSS` and NAMES the committed REQUIRED contexts the
#          pair cannot render. Those names are read off the output, never
#          hardcoded — that is the only reason run 2 can get past stage 1.
#   run 2  the same command plus exactly those names as --expect-unrendered.
#          Stage 1 passes, stage 2 derives `.exclusions` from the sample, and the
#          EXCLUSION LOSS block then names every committed exclusion row this
#          run could not reproduce. THAT set is what ACK_EX must cover.
# Nothing about "cannot render" is reimplemented here. If the generator's stage
# list changes, this check changes with it, because the answer comes from the
# generator's own refusal.
#
# THE ADDED / BY HAND ARM IS SUBSUMED, DELIBERATELY. A hand-added row the frozen
# pair CAN reproduce needs no acknowledgement — the generator accepts it — and
# demanding one would red this check on rows that are fine today (measured on
# origin/main 2e3ee4f6c: `Dependency CVE audit (mix_audit over mix.lock,
# blocking) (27.0, 1.18.1)` carries a literal `BY HAND` in its reason and is not
# in ACK_EX, correctly). The renderability predicate is the whole rule.
#
# BOTH DIRECTIONS RED (cch-w57-fu). A derived row ACK_EX does not carry is
# `MISSING ACK_EX` (paste the printed line). An ACK_EX name no derived row needs
# is `EXTRA ACK_EX` (delete the printed line) — a row that STOPPED being
# unrenderable, or a name no longer in `.exclusions`. Until this change the
# second direction printed "note: ... (harmless ...)" and exited 0, so the
# harness's own stated design — "a row that STOPS being unrenderable reds this
# file instead of quietly widening a blanket waiver" — held only when someone
# read the note: #19991 (ef953d587) deleted two such names BY HAND after they
# had sat unread. An acknowledgement that no longer answers for anything is a
# waiver waiting for the next row to hide under it, so it reds.
#
# WHY THE ACKNOWLEDGEMENT STAYS DERIVED-AND-PASTED rather than auto-applied
# (the row's option (a), beyond S8). The generator already auto-classifies a
# pull_request-only job as S8 PULL-REQUEST-ONLY off the workflow tree, which is
# a static property and cannot be wrong about the sample. A paths-filtered (S4)
# row is different: whether it renders depends on which paths the SAMPLED HEADS
# touched, and the frozen fixture pair decides that. Auto-acknowledging it would
# make a change in the sample — the very thing D130 freezes — invisible. So the
# gate derives, prints the exact lines, and refuses both a missing and an extra
# one; the human pastes or deletes and the diff records it.
#
# EVERY FAILED READ IS A DISTINCT `CANNOT READ` LINE AND EXIT 2, never a green:
# a generator that died for some other reason must not read as "nothing lost".
#
# USAGE
#   scripts/required-checks-ack-derive.sh              derive + compare (exit 1 names MISSING and EXTRA)
#   scripts/required-checks-ack-derive.sh --selftest   the same, plus the mutation proof
#   --repo-root DIR      read the spec, the harness, the generator and the
#                        fixtures from DIR (default: this script's repo).
#                        Used to reproduce the check against a historical tree.
#   --dump-derived FILE  write the derived name set, one per line, for evidence.
#   --harness FILE       read ACK_EX from FILE instead of the repo's harness —
#                        how scripts/required-checks.test.sh feeds a mutated copy.
#   --derived FILE       skip both generator runs and compare against a set a
#                        previous --dump-derived wrote. Only the ACK side is
#                        then under test; the harness uses it so its mutation
#                        arms cost no extra generator passes.
set -euo pipefail

SELF="${BASH_SOURCE[0]}"
REPO_ROOT=""
SELFTEST=0
DUMP=""
HARNESS_ARG=""
DERIVED_IN=""

cannot_read() { printf 'CANNOT READ: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --selftest) SELFTEST=1; shift ;;
    --dump-derived) DUMP="$2"; shift 2 ;;
    --harness) HARNESS_ARG="$2"; shift 2 ;;
    --derived) DERIVED_IN="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$SELF" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
    *) cannot_read "unknown argument: $1 (try --help)" ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
fi
[ -d "$REPO_ROOT" ] || cannot_read "repo root '$REPO_ROOT' is not a directory"

SPEC="$REPO_ROOT/.github/required-checks.json"
HARNESS="${HARNESS_ARG:-$REPO_ROOT/scripts/required-checks.test.sh}"
GEN="$REPO_ROOT/scripts/required-checks-generate.sh"
FIXP="$REPO_ROOT/scripts/fixtures/registration-flip"
WFD="$REPO_ROOT/.github/workflows"

for f in "$SPEC" "$HARNESS" "$GEN"; do
  [ -r "$f" ] || cannot_read "$f is missing or unreadable"
done
[ -d "$FIXP" ] || cannot_read "$FIXP (the frozen fixture pair) is missing"
[ -d "$WFD" ] || cannot_read "$WFD is missing"
command -v jq >/dev/null 2>&1 || cannot_read "jq is not on PATH"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── the committed ledger ─────────────────────────────────────────────────────
EXCOUNT="$(jq -r '.exclusions | length' "$SPEC" 2>/dev/null)" \
  || cannot_read "$SPEC is not readable JSON"
case "$EXCOUNT" in ''|*[!0-9]*) cannot_read "$SPEC has no .exclusions array" ;; esac
[ "$EXCOUNT" -gt 0 ] \
  || cannot_read "$SPEC carries ZERO .exclusions rows — there is nothing for ACK_EX to acknowledge, which has never been true of this repo; refusing to certify a green from an empty read"

# ── ACK_EX, lifted from the harness rather than restated ─────────────────────
# The array is read out of the file and evaluated so the quoting is bash's, not
# a regex's: one committed name carries a literal `${{ matrix.elixir }}` and is
# single-quoted in the source for exactly that reason.
# COMMENT LINES ARE DROPPED, and that is not cosmetic: the block's own prose
# carries backticks and apostrophes, and the safety refusal below would fire on
# a comment while the array itself is perfectly inert. A comment-only line is
# one whose first non-blank byte is `#`; no committed check-run name starts
# with one.
# `extract_acked <harness-file> <out-file> <label>` — one function, used for the
# real harness AND for the mutated scratch copy the selftest writes, so the
# mutation proof exercises this parser instead of bypassing it.
extract_acked() {
  local src="$1" out="$2" label="$3" block="$TMP/ackblock.$$.sh"
  awk '/^ACK_EX=\(/{f=1}
       f && /^[[:space:]]*#/{next}
       f{print}
       f && /\)[[:space:]]*$/{exit}' \
    "$src" > "$block"
  [ -s "$block" ] || cannot_read "no \`ACK_EX=(\` array found in $label — it was renamed or moved, and every comparison below would be vacuous"
  grep -q '^ACK_EX=(' "$block" || cannot_read "the extracted ACK_EX block from $label does not start with \`ACK_EX=(\` — the awk window is wrong"
  grep -qE '\)[[:space:]]*$' "$block" || cannot_read "the extracted ACK_EX block from $label never closes its paren — the array is longer than the awk window saw"
  # The block is evaluated, so refuse anything that could execute.
  if grep -qE '\$\(|`|;|&&|\|\|' "$block"; then
    cannot_read "the ACK_EX block in $label contains a command substitution or a shell operator — refusing to evaluate it"
  fi
  # shellcheck disable=SC1090
  if ! ( set +u; . "$block"
         n_flag=0; n_name=0
         for a in "${ACK_EX[@]}"; do
           if [ "$a" = "--expect-unrendered" ]; then n_flag=$((n_flag + 1))
           else n_name=$((n_name + 1)); printf '%s\n' "$a"; fi
         done
         [ "$n_flag" -eq "$n_name" ] || exit 3
       ) > "$out"; then
    cannot_read "the ACK_EX array in $label does not alternate --expect-unrendered/<name> — one flag has no name or one name has no flag"
  fi
  rm -f "$block"
  sort -u -o "$out" "$out"
}

ACKED="$TMP/acked.txt"
extract_acked "$HARNESS" "$ACKED" "$HARNESS"
ACKN="$(wc -l < "$ACKED" | tr -d ' ')"
[ "$ACKN" -gt 0 ] || cannot_read "ACK_EX parsed to ZERO names"

GENARGS=(--workflows "$WFD" --fixture-dir "$FIXP" --merge-base "$SPEC"
         --sha e34031104 --sha f69cfb1f6)

# `  LOST  <name>  [<hint>]` -> `<name>`. The hint is appended by
# unrenderable_hint() on the same line and is always bracketed at the end.
strip_lost() { sed -n 's/^  LOST  //p' | sed 's/  \[[^][]*\]$//'; }

DERIVED="$TMP/derived.txt"
R1RC="-"; R2RC="-"; STALE="-"
S1NAMES="$TMP/s1.txt"
: > "$S1NAMES"
if [ -n "$DERIVED_IN" ]; then
  [ -r "$DERIVED_IN" ] || cannot_read "--derived $DERIVED_IN is missing or unreadable"
  grep -v '^$' "$DERIVED_IN" | sort -u > "$DERIVED" || true
else
# ── run 1: which committed REQUIRED contexts can this pair not render? ───────
R1="$TMP/run1.txt"
set +e
bash "$GEN" "${GENARGS[@]}" >/dev/null 2>"$R1"
R1RC=$?
set -e
if [ "$R1RC" -eq 0 ]; then
  : > "$S1NAMES"
elif [ "$R1RC" -eq 1 ] && grep -q '^S1 LOSS' "$R1"; then
  strip_lost < "$R1" > "$S1NAMES"
  [ -s "$S1NAMES" ] || cannot_read "the generator printed S1 LOSS with no LOST line — its refusal format moved"
else
  cannot_read "the unacknowledged generator run failed for a reason that is not S1 LOSS (exit $R1RC). First lines: $(head -3 "$R1" | tr '\n' '|')"
fi

S1ARGS=()
while IFS= read -r n; do [ -n "$n" ] && S1ARGS+=(--expect-unrendered "$n"); done < "$S1NAMES"

# ── run 2: with stage 1 satisfied, the exclusion arm names the real set ──────
R2="$TMP/run2.txt"
set +e
bash "$GEN" "${GENARGS[@]}" ${S1ARGS[@]+"${S1ARGS[@]}"} >/dev/null 2>"$R2"
R2RC=$?
set -e
if grep -q '^S1 LOSS' "$R2"; then
  cannot_read "run 2 still refused at S1 LOSS after acknowledging every name run 1 reported — the two runs disagree, so nothing below was measured"
fi

if grep -q '^EXCLUSION LOSS' "$R2"; then
  awk '/^EXCLUSION LOSS/{f=1} f' "$R2" | strip_lost | sort -u > "$DERIVED"
else
  : > "$DERIVED"
fi
STALE="$(grep -c '^  STALE ' "$R2" || true)"
fi
DERN="$(wc -l < "$DERIVED" | tr -d ' ')"

# THE PRECONDITION, asserted rather than assumed. This frozen pair is two main
# heads from 2026-07-31; it has never been able to reproduce every committed
# exclusion row, and a run that says it can has read something else (an empty
# EXCLUSION LOSS block, a moved refusal format, a fixture dir that did not load).
# A zero here must not be byte-identical to a green.
[ "$DERN" -gt 0 ] \
  || cannot_read "the frozen pair reproduced ALL $EXCOUNT committed exclusion rows — no EXCLUSION LOSS block at all (run 2 exit $R2RC${DERIVED_IN:+, --derived $DERIVED_IN}). That has never been true; refusing to certify a green from a read that produced nothing"

[ -z "$DUMP" ] || cp "$DERIVED" "$DUMP"

printf 'required-checks-ack-derive — every committed .exclusions row ACK_EX must acknowledge, DERIVED\n'
printf '  spec       %s  (%s exclusion rows)\n' "$SPEC" "$EXCOUNT"
printf '  harness    %s  (%s ACK_EX names)\n' "$HARNESS" "$ACKN"
printf '  generator  %s\n' "$GEN"
printf '  fixtures   %s  (e34031104 f69cfb1f6)\n' "$FIXP"
if [ -n "$DERIVED_IN" ]; then
  printf '  derived set READ from %s (%s names) — no generator run; only the ACK side is under test\n' \
    "$DERIVED_IN" "$DERN"
else
  printf '  run 1  exit %s, S1-unrenderable required contexts: %s\n' \
    "$R1RC" "$(tr '\n' '|' < "$S1NAMES")"
  printf '  run 2  exit %s, exclusion rows this sample could not reproduce: %s (STALE rows: %s)\n' \
    "$R2RC" "$DERN" "$STALE"
fi

# ── the comparison, factored so --selftest can re-run it on a mutated copy ───
# `ack_line <name>` — the line as it is typed in ACK_EX. A name carrying a
# literal `${` is single-quoted so bash does not expand it.
ack_line() {
  case "$1" in
    *'${'*) printf "        --expect-unrendered '%s'\n" "$1" ;;
    *)      printf '        --expect-unrendered "%s"\n' "$1" ;;
  esac
}
# `delete_line <harness-file> <name>` — the harness line that carries <name>
# inside ACK_EX, printed as FILE:LINE:TEXT so the operator deletes exactly it.
# The match is on the QUOTED name, so a name that is a prefix of another does
# not claim the longer one's line. When the name shares a line with `ACK_EX=(`
# or the closing paren, only the flag and the name come off that line.
delete_line() {
  local src="$1" name="$2" hit
  hit="$(NAME="$name" awk '
    /^ACK_EX=\(/{f=1}
    f && !/^[[:space:]]*#/ && /--expect-unrendered/ \
      && (index($0, "\"" ENVIRON["NAME"] "\"") || index($0, "\047" ENVIRON["NAME"] "\047")) {
      printf "%d:%s\n", NR, $0; exit }
    f && /\)[[:space:]]*$/{exit}' "$src")"
  if [ -n "$hit" ]; then
    printf '  %s:%s\n' "$src" "$hit"
    case "$hit" in
      *:ACK_EX=\(*|*\)) printf '    (that line opens or closes the array: remove only the flag and the name, keep the paren)\n' ;;
    esac
  else
    printf '  (no single ACK_EX line in %s carries it verbatim — remove this pair:)\n' "$src"
    ack_line "$name"
  fi
}

compare() { # compare <acked-file> <label> [<harness-file-it-was-parsed-from>]
  local acked="$1" label="$2" src="${3:-$HARNESS}" missing extra rc=0
  missing="$(comm -23 "$DERIVED" "$acked")"
  extra="$(comm -13 "$DERIVED" "$acked")"
  if [ -n "$missing" ]; then
    rc=1
    {
      printf 'ACK_EX GAP (%s) — %s committed .exclusions row(s) this tree cannot re-derive are NOT acknowledged.\n' \
        "$label" "$(printf '%s\n' "$missing" | wc -l | tr -d ' ')"
      printf 'scripts/required-checks-generate.sh will refuse EXCLUSION LOSS on every emit in\n'
      printf 'scripts/required-checks.test.sh, so `Required-check spec gate` is red until each\n'
      printf 'name below is added to ACK_EX, ONE NAME AT A TIME:\n'
      while IFS= read -r m; do
        [ -n "$m" ] || continue
        printf '  MISSING ACK_EX  %s\n' "$m"
      done <<EOF
$missing
EOF
      printf '\nPaste into the ACK_EX array in scripts/required-checks.test.sh:\n'
      while IFS= read -r m; do
        [ -n "$m" ] || continue
        ack_line "$m"
      done <<EOF
$missing
EOF
    } >&2
  fi
  if [ -n "$extra" ]; then
    rc=1
    {
      printf 'ACK_EX EXTRA (%s) — %s ACK_EX name(s) acknowledge NO row this tree fails to re-derive.\n' \
        "$label" "$(printf '%s\n' "$extra" | wc -l | tr -d ' ')"
      printf 'Either the row became renderable on the frozen pair, or the name left .exclusions.\n'
      printf 'An acknowledgement that answers for nothing is a waiver the next row can hide\n'
      printf 'under, so it reds. Delete each line below from scripts/required-checks.test.sh:\n'
      while IFS= read -r e; do
        [ -n "$e" ] || continue
        printf '  EXTRA ACK_EX  %s\n' "$e"
      done <<EOF
$extra
EOF
      printf '\nDelete:\n'
      while IFS= read -r e; do
        [ -n "$e" ] || continue
        delete_line "$src" "$e"
      done <<EOF
$extra
EOF
    } >&2
  fi
  return "$rc"
}

RC=0
if compare "$ACKED" "this tree"; then
  printf '  OK  ACK_EX == the derived set: all %s derived rows acknowledged, 0 extra\n' "$DERN"
else
  RC=1
fi

# ── the mutation proof ───────────────────────────────────────────────────────
# The derivation above is expensive (two generator passes), so the selftest
# REUSES it and mutates only the cheap half: delete one real ACK_EX line from a
# scratch copy of the harness and the same comparison must red BY NAME (MISSING);
# plant one name no row needs and it must red BY NAME (EXTRA); restore and it
# must reproduce the BASELINE. Both mutation directions, one derive.
#
# THE BASELINE IS THE REFERENCE, NOT "GREEN". The restored arm used to demand a
# green, which is only right on a tree whose real comparison above is green. On
# a tree that is already red (MEASURED: Elixir run 35889983944, PR 19973 head
# 8b63ac40e, real gap `console-harness.sh reads CI's pin (it must be able to
# LOSE)`) the untouched harness IS the red baseline, so re-parsing it reds again
# and the selftest printed "the mutation was not the only variable" — a false
# diagnosis stacked on a correct red. So each arm is compared, as a SET, to the
# baseline's own MISSING and EXTRA sets (EXTRA joined the verdict with
# cch-w57-fu; a baseline that omitted it would let a red-by-extra tree read as
# a clean baseline and every arm below would compare against the wrong thing):
#   deleted   MISSING == baseline MISSING + exactly the victim, EXTRA == baseline EXTRA
#   planted   EXTRA   == baseline EXTRA + exactly the plant,   MISSING == baseline MISSING
#   restored  MISSING == baseline MISSING and EXTRA == baseline EXTRA
# On a red baseline "RED with it deleted" is trivially true; the set equality is
# what still discriminates. The real verdict ($RC) is untouched and is the exit.
if [ "$SELFTEST" -eq 1 ]; then
  printf '\n-- selftest: the ACK_EX side, mutated --\n'
  # missing_set / extra_set <acked-file> <out-file> — the comparison's two sets, as files.
  missing_set() { comm -23 "$DERIVED" "$1" > "$2"; }
  extra_set()   { comm -13 "$DERIVED" "$1" > "$2"; }
  # same_set <want> <got> <what> — refuse unless the two files are identical.
  same_set() {
    if ! cmp -s "$1" "$2"; then
      printf 'SELFTEST FAILED: %s. diff (want vs got):\n' "$3" >&2
      diff "$1" "$2" >&2 || true
      exit 1
    fi
  }
  BASEMISS="$TMP/missing-baseline.txt"
  BASEXTRA="$TMP/extra-baseline.txt"
  missing_set "$ACKED" "$BASEMISS"
  extra_set "$ACKED" "$BASEXTRA"
  BASEN="$(wc -l < "$BASEMISS" | tr -d ' ')"
  BASEX="$(wc -l < "$BASEXTRA" | tr -d ' ')"
  if [ "$BASEN" -eq 0 ] && [ "$BASEX" -eq 0 ]; then
    printf '  baseline: GREEN (0 MISSING, 0 EXTRA) — the arms below are measured against two empty sets\n'
  else
    printf '  baseline: RED (%s MISSING, %s EXTRA) — the arms below are measured against those sets, not against green\n' "$BASEN" "$BASEX"
  fi
  # The victim is drawn from DERIVED ∩ ACKED so the mutation always has a real
  # line to delete, even on a tree this check is currently RED on.
  # NO PIPE ON THIS LINE, and the reason is the bug it used to carry. The shape
  # that shipped here was `VICTIM="$(comm -12 "$DERIVED" "$ACKED" | head -1)"`
  # under `set -euo pipefail` (line 52). `head -1` prints the first line and
  # CLOSES the pipe; when the intersection is more than one line — it is 166 on
  # this tree — `comm` then writes into a closed pipe, takes SIGPIPE, and exits
  # 141. Under pipefail 141 becomes the PIPELINE's status, an assignment's status
  # IS its substitution's status, and errexit kills the selftest right there. It
  # is a scheduling race: `head` usually exits after `comm` has already finished
  # writing 166 short lines into the 64KB buffer, so it passes — until a loaded
  # runner loses the race. MEASURED on console #19336, where this ratchet went
  # red on a PR whose diff never touched this file.
  # scripts/pipefail-sigpipe-scan.sh reports the old form at [high]:
  #   "truncating reader (head closes the pipe at N) on a producer not provably
  #    bounded — 141 needs no buffer overrun".
  # comm writes the whole intersection to a FILE, and one `read` takes the first
  # line off it. Nothing can close a pipe that does not exist; an empty
  # intersection leaves VICTIM empty and the refusal below still fires.
  BOTH="$TMP/derived-and-acked.txt"
  comm -12 "$DERIVED" "$ACKED" > "$BOTH"
  VICTIM=""
  IFS= read -r VICTIM < "$BOTH" || VICTIM=""
  [ -n "$VICTIM" ] || cannot_read "selftest has no derived-and-acknowledged name to delete — DERIVED and ACK_EX share nothing, so the mutation would be vacuous"
  # The mutation is applied to a SCRATCH COPY OF THE HARNESS FILE and then
  # re-parsed by the same extract_acked() above — not to the parsed name list —
  # so the awk window, the safety refusal and the alternation check are all in
  # the proven path. Exactly one `--expect-unrendered <VICTIM>` line is deleted.
  MUTSRC="$TMP/harness-mutated.sh"
  VICTIM="$VICTIM" awk '
    !done && /--expect-unrendered/ && index($0, ENVIRON["VICTIM"]) { done = 1; next }
    { print }
    END { if (!done) exit 1 }
  ' "$HARNESS" > "$MUTSRC" \
    || cannot_read "selftest found no \`--expect-unrendered\` line carrying '$VICTIM' in $HARNESS — the mutation could not be applied"
  if [ "$(wc -l < "$MUTSRC" | tr -d ' ')" -ne "$(( $(wc -l < "$HARNESS" | tr -d ' ') - 1 ))" ]; then
    printf 'SELFTEST FAILED: the mutated harness copy is not exactly one line shorter than %s\n' "$HARNESS" >&2
    exit 1
  fi
  MUT="$TMP/acked-mutated.txt"
  extract_acked "$MUTSRC" "$MUT" "the SELFTEST mutated harness copy"
  if [ "$(wc -l < "$MUT" | tr -d ' ')" -ne $((ACKN - 1)) ]; then
    printf 'SELFTEST FAILED: deleting the ACK_EX line for %s from a scratch copy of %s left %s names, not %s — the mutation did not apply, so the proof below would be vacuous\n' \
      "$VICTIM" "$HARNESS" "$(wc -l < "$MUT" | tr -d ' ')" "$((ACKN - 1))" >&2
    exit 1
  fi
  if grep -qxF "$VICTIM" "$MUT"; then
    printf 'SELFTEST FAILED: %s is STILL in the ACK_EX set parsed from the mutated copy — the wrong line was deleted\n' "$VICTIM" >&2
    exit 1
  fi
  printf '  fixture reached the mutated state: 1 ACK_EX line deleted from a scratch copy of the harness, re-parsed to %s of %s names, %s gone\n' \
    "$((ACKN - 1))" "$ACKN" "$VICTIM"
  MUTOUT="$TMP/mutout.txt"
  set +e
  compare "$MUT" "SELFTEST mutated copy" "$MUTSRC" 2>"$MUTOUT"
  MRC=$?
  set -e
  if [ "$MRC" -ne 1 ]; then
    printf 'SELFTEST FAILED: the ACK_EX comparison stayed GREEN with %s deleted — this check cannot fail\n' "$VICTIM" >&2
    exit 1
  fi
  if ! grep -qF "MISSING ACK_EX  $VICTIM" "$MUTOUT"; then
    printf 'SELFTEST FAILED: the comparison reddened but did not NAME %s. Output was:\n' "$VICTIM" >&2
    cat "$MUTOUT" >&2
    exit 1
  fi
  MUTMISS="$TMP/missing-mutated.txt"
  missing_set "$MUT" "$MUTMISS"
  WANTMUT="$TMP/missing-mutated-want.txt"
  { cat "$BASEMISS"; printf '%s\n' "$VICTIM"; } | sort -u > "$WANTMUT"
  same_set "$WANTMUT" "$MUTMISS" "the mutated MISSING set is not the baseline MISSING set plus exactly $VICTIM"
  MUTEXTRA="$TMP/extra-mutated.txt"
  extra_set "$MUT" "$MUTEXTRA"
  same_set "$BASEXTRA" "$MUTEXTRA" "deleting $VICTIM moved the EXTRA set — the deletion was not the only variable"
  printf '  RED with it deleted, and it NAMES the context: MISSING ACK_EX  %s\n' "$VICTIM"
  printf '  mutated MISSING set = baseline (%s) + exactly the victim (%s names); EXTRA unchanged (%s)\n' \
    "$BASEN" "$(wc -l < "$MUTMISS" | tr -d ' ')" "$BASEX"

  # PLANTED: the other direction. One name no .exclusions row carries is added
  # to a scratch copy, right after the `ACK_EX=(` line, and re-parsed through the
  # same extractor. It must red as EXTRA, NAME the plant, and print the planted
  # line (FILE:LINE:TEXT) as the one to delete.
  PLANT="ack-derive selftest plant — no .exclusions row carries this name"
  grep -qxF "$PLANT" "$DERIVED" && cannot_read "the selftest plant '$PLANT' is in the derived set — pick another"
  PLANTSRC="$TMP/harness-planted.sh"
  PLANT="$PLANT" awk '
    { print }
    !done && /^ACK_EX=\(/ { printf "        --expect-unrendered \"%s\"\n", ENVIRON["PLANT"]; done = 1 }
    END { if (!done) exit 1 }
  ' "$HARNESS" > "$PLANTSRC" \
    || cannot_read "selftest found no ACK_EX=( line in $HARNESS to plant after"
  PLANTED="$TMP/acked-planted.txt"
  extract_acked "$PLANTSRC" "$PLANTED" "the SELFTEST planted harness copy"
  if [ "$(wc -l < "$PLANTED" | tr -d ' ')" -ne $((ACKN + 1)) ] || ! grep -qxF "$PLANT" "$PLANTED"; then
    printf 'SELFTEST FAILED: planting one ACK_EX line did not re-parse to %s names including the plant — the proof below would be vacuous\n' "$((ACKN + 1))" >&2
    exit 1
  fi
  printf '  fixture reached the planted state: 1 ACK_EX line added to a scratch copy, re-parsed to %s names\n' "$((ACKN + 1))"
  PLANTOUT="$TMP/plantout.txt"
  set +e
  compare "$PLANTED" "SELFTEST planted copy" "$PLANTSRC" 2>"$PLANTOUT"
  PRC=$?
  set -e
  if [ "$PRC" -ne 1 ]; then
    printf 'SELFTEST FAILED: the ACK_EX comparison stayed GREEN with an EXTRA name planted — the extra direction cannot fail\n' >&2
    exit 1
  fi
  if ! grep -qF "EXTRA ACK_EX  $PLANT" "$PLANTOUT" || ! grep -qF "$PLANTSRC:" "$PLANTOUT"; then
    printf 'SELFTEST FAILED: the comparison reddened but did not NAME the plant and print its line to delete. Output was:\n' >&2
    cat "$PLANTOUT" >&2
    exit 1
  fi
  PLANTEXTRA="$TMP/extra-planted.txt"
  extra_set "$PLANTED" "$PLANTEXTRA"
  WANTPLANT="$TMP/extra-planted-want.txt"
  { cat "$BASEXTRA"; printf '%s\n' "$PLANT"; } | sort -u > "$WANTPLANT"
  same_set "$WANTPLANT" "$PLANTEXTRA" "the planted EXTRA set is not the baseline EXTRA set plus exactly the plant"
  PLANTMISS="$TMP/missing-planted.txt"
  missing_set "$PLANTED" "$PLANTMISS"
  same_set "$BASEMISS" "$PLANTMISS" "planting an EXTRA moved the MISSING set — the plant was not the only variable"
  printf '  RED with it planted, and it NAMES it: EXTRA ACK_EX  %s\n' "$PLANT"
  printf '  …and prints the line to delete: %s\n' "$(grep -F "$PLANTSRC:" "$PLANTOUT" | sed "s|$PLANTSRC|<planted copy>|")"
  # RESTORED: the untouched harness is re-parsed through the same extractor,
  # so the green arm travels the whole path the red arm did, minus the deletion.
  RESTORED="$TMP/acked-restored.txt"
  extract_acked "$HARNESS" "$RESTORED" "the SELFTEST restored harness"
  if [ "$(wc -l < "$RESTORED" | tr -d ' ')" -ne "$ACKN" ]; then
    printf 'SELFTEST FAILED: the restored parse produced %s names, not the original %s\n' \
      "$(wc -l < "$RESTORED" | tr -d ' ')" "$ACKN" >&2
    exit 1
  fi
  RESTMISS="$TMP/missing-restored.txt"
  missing_set "$RESTORED" "$RESTMISS"
  same_set "$BASEMISS" "$RESTMISS" "the restored MISSING set differs from the baseline MISSING set — the mutation was not the only variable"
  RESTEXTRA="$TMP/extra-restored.txt"
  extra_set "$RESTORED" "$RESTEXTRA"
  same_set "$BASEXTRA" "$RESTEXTRA" "the restored EXTRA set differs from the baseline EXTRA set — the mutation was not the only variable"
  if [ "$BASEN" -eq 0 ] && [ "$BASEX" -eq 0 ]; then
    printf '  GREEN again with it restored — single-variable, both directions\n'
  else
    printf '  RED again with it restored, reproducing the baseline red exactly (same %s MISSING, %s EXTRA) — single-variable, both directions\n' "$BASEN" "$BASEX"
  fi
  if [ "$RC" -eq 0 ]; then
    printf '  selftest OK\n'
  else
    printf '  selftest OK — the instrument is sound; the exit is the tree'"'"'s own verdict (%s), RED above\n' "$RC"
  fi
fi

exit "$RC"
