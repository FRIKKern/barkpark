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
# EVERY FAILED READ IS A DISTINCT `CANNOT READ` LINE AND EXIT 2, never a green:
# a generator that died for some other reason must not read as "nothing lost".
#
# USAGE
#   scripts/required-checks-ack-derive.sh              derive + compare (exit 1 names the gaps)
#   scripts/required-checks-ack-derive.sh --selftest   the same, plus the mutation proof
#   --repo-root DIR      read the spec, the harness, the generator and the
#                        fixtures from DIR (default: this script's repo).
#                        Used to reproduce the check against a historical tree.
#   --dump-derived FILE  write the derived name set, one per line, for evidence.
set -euo pipefail

SELF="${BASH_SOURCE[0]}"
REPO_ROOT=""
SELFTEST=0
DUMP=""

cannot_read() { printf 'CANNOT READ: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --selftest) SELFTEST=1; shift ;;
    --dump-derived) DUMP="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$SELF" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
    *) cannot_read "unknown argument: $1 (try --help)" ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
fi
[ -d "$REPO_ROOT" ] || cannot_read "repo root '$REPO_ROOT' is not a directory"

SPEC="$REPO_ROOT/.github/required-checks.json"
HARNESS="$REPO_ROOT/scripts/required-checks.test.sh"
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

# ── run 1: which committed REQUIRED contexts can this pair not render? ───────
R1="$TMP/run1.txt"
set +e
bash "$GEN" "${GENARGS[@]}" >/dev/null 2>"$R1"
R1RC=$?
set -e
S1NAMES="$TMP/s1.txt"
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

DERIVED="$TMP/derived.txt"
if grep -q '^EXCLUSION LOSS' "$R2"; then
  awk '/^EXCLUSION LOSS/{f=1} f' "$R2" | strip_lost | sort -u > "$DERIVED"
else
  : > "$DERIVED"
fi
DERN="$(wc -l < "$DERIVED" | tr -d ' ')"

# THE PRECONDITION, asserted rather than assumed. This frozen pair is two main
# heads from 2026-07-31; it has never been able to reproduce every committed
# exclusion row, and a run that says it can has read something else (an empty
# EXCLUSION LOSS block, a moved refusal format, a fixture dir that did not load).
# A zero here must not be byte-identical to a green.
[ "$DERN" -gt 0 ] \
  || cannot_read "the frozen pair reproduced ALL $EXCOUNT committed exclusion rows — no EXCLUSION LOSS block at all (run 2 exit $R2RC). That has never been true; refusing to certify a green from a read that produced nothing"

[ -z "$DUMP" ] || cp "$DERIVED" "$DUMP"

STALE="$(grep -c '^  STALE ' "$R2" || true)"

printf 'required-checks-ack-derive — every committed .exclusions row ACK_EX must acknowledge, DERIVED\n'
printf '  spec       %s  (%s exclusion rows)\n' "$SPEC" "$EXCOUNT"
printf '  harness    %s  (%s ACK_EX names)\n' "$HARNESS" "$ACKN"
printf '  generator  %s\n' "$GEN"
printf '  fixtures   %s  (e34031104 f69cfb1f6)\n' "$FIXP"
printf '  run 1  exit %s, S1-unrenderable required contexts: %s\n' \
  "$R1RC" "$(tr '\n' '|' < "$S1NAMES")"
printf '  run 2  exit %s, exclusion rows this sample could not reproduce: %s (STALE rows: %s)\n' \
  "$R2RC" "$DERN" "$STALE"

# ── the comparison, factored so --selftest can re-run it on a mutated copy ───
compare() { # compare <acked-file> <label>
  local acked="$1" label="$2" missing
  missing="$(comm -23 "$DERIVED" "$acked")"
  if [ -n "$missing" ]; then
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
        case "$m" in
          *'${'*) printf "        --expect-unrendered '%s'\n" "$m" ;;
          *)      printf '        --expect-unrendered "%s"\n' "$m" ;;
        esac
      done <<EOF
$missing
EOF
    } >&2
    return 1
  fi
  return 0
}

RC=0
if compare "$ACKED" "this tree"; then
  printf '  OK  all %s derived rows are acknowledged in ACK_EX\n' "$DERN"
else
  RC=1
fi

EXTRA="$(comm -13 "$DERIVED" "$ACKED" || true)"
if [ -n "$EXTRA" ]; then
  printf '  note: %s ACK_EX name(s) this run did not need (harmless; a row that stopped being unrenderable, or a name no longer in .exclusions):\n' \
    "$(printf '%s\n' "$EXTRA" | wc -l | tr -d ' ')"
  while IFS= read -r e; do
    [ -n "$e" ] && printf '        %s\n' "$e"
  done <<EOF
$EXTRA
EOF
fi

# ── the mutation proof ───────────────────────────────────────────────────────
# The derivation above is expensive (two generator passes), so the selftest
# REUSES it and mutates only the cheap half: delete one real ACK_EX line from a
# scratch copy of the harness and the same comparison must red BY NAME; restore
# and it must green. Both directions, one derive.
if [ "$SELFTEST" -eq 1 ]; then
  printf '\n-- selftest: the ACK_EX side, mutated --\n'
  # The victim is drawn from DERIVED ∩ ACKED so the mutation always has a real
  # line to delete, even on a tree this check is currently RED on.
  VICTIM="$(comm -12 "$DERIVED" "$ACKED" | head -1)"
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
  compare "$MUT" "SELFTEST mutated copy" 2>"$MUTOUT"
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
  printf '  RED with it deleted, and it NAMES the context: %s\n' \
    "$(grep -F 'MISSING ACK_EX' "$MUTOUT")"
  # RESTORED: the untouched harness is re-parsed through the same extractor,
  # so the green arm travels the whole path the red arm did, minus the deletion.
  RESTORED="$TMP/acked-restored.txt"
  extract_acked "$HARNESS" "$RESTORED" "the SELFTEST restored harness"
  if [ "$(wc -l < "$RESTORED" | tr -d ' ')" -ne "$ACKN" ]; then
    printf 'SELFTEST FAILED: the restored parse produced %s names, not the original %s\n' \
      "$(wc -l < "$RESTORED" | tr -d ' ')" "$ACKN" >&2
    exit 1
  fi
  if compare "$RESTORED" "SELFTEST restored" 2>/dev/null; then
    printf '  GREEN again with it restored — single-variable, both directions\n'
  else
    printf 'SELFTEST FAILED: the restored ACK_EX set did not green — the mutation was not the only variable\n' >&2
    exit 1
  fi
  printf '  selftest OK\n'
fi

exit "$RC"
