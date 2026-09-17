#!/usr/bin/env bash
# pds-citation-expand.sh — the slash-compressed PDS-D citation instrument.
#
# THE DEFECT. A citation that writes `PDS-D69` and then appends bare `/D70` and
# `/D71` carries the `PDS-D` prefix on the FIRST number only. `git grep PDS-D70`
# therefore MISSES a site that
# genuinely cites D70. Every coverage grep over the charter silently
# under-reports, and the under-report is invisible: a clean result and a blind
# instrument look identical.
#
# THREE DENOMINATORS, NEVER ONE. `grep -c` counts LINES. `grep -o | wc -l`
# counts MATCHES. Neither counts CITATIONS, because one match can carry seven.
# --count prints all three side by side so a caller cannot quote the flattering
# one by accident.
#
# A PREDICATE, NOT AN ENUMERATION. Nothing here holds a list of the compressed
# forms that exist today. The forms are matched by shape, so a form invented
# next week is counted, expanded and guarded without editing this file.
#
# THE SEGMENT ALPHABET. A D-number may carry a letter suffix (PDS-D220a,
# PDS-D391b, PDS-D480a — all live on main). A predicate written [0-9]+ silently
# TRUNCATES a trailing `/D480a` segment to `/D480`, and MISSES a token whose
# PREFIX carries the suffix (`PDS-D391b` + `/D336`) entirely: the same blindness
# this script exists to remove, wearing the instrument's own clothes. Every
# segment below is [0-9]+[a-z]?.
#
# A CAPTURE IS A RECORD, NOT A CITATION. A dated snapshot of the live board
# (tooling/pds/fixtures/live-corpus-<date>.json and its kin) records what a row
# ACTUALLY SAID on that date. Re-prefixing a citation inside one does not fix a
# blind grep — it FALSIFIES the record, making the snapshot disagree with the
# server it captured. Such files are skipped by path, and the skip is PRINTED
# with a count so it cannot grow into a silent exception list. This is a rule
# about provenance (captured vs authored), not a list of known offenders.
#
# THIS FILE GETS NO EXCEPTION. It is inside the guard's own fence, so it holds
# no compressed literal anywhere — the forms above are described rather than
# written, and the selftest fixtures are built from parts. An instrument that
# had to exempt itself would be the first thing to rot.

set -euo pipefail

# This script uses process substitution and bash arrays. A POSIX-mode shell
# would run everything above the refusal before failing on the first `<(`, so
# the guard sits here, ahead of any code that could act. Enforced by
# scripts/posix-vacuous-green-census.sh.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "pds-citation-expand.sh: needs bash (this script uses process substitution); run: bash scripts/pds-citation-expand.sh" >&2
  exit 2
fi
case ":${SHELLOPTS:-}:" in
  *:posix:*) echo "pds-citation-expand.sh: refuses to run in POSIX mode" >&2; exit 2;;
esac

# ── the predicate ───────────────────────────────────────────────────────────
# A compressed citation: a prefixed D-number followed by one or more segments
# that are NOT re-prefixed. `PDS-D276/PDS-D277` (the expanded form) does not
# match, which is what makes --expand idempotent and --check stable.
readonly SEG='[0-9]+[a-z]?'
readonly COMPRESSED="PDS-D${SEG}(/D?${SEG})+"

# The guard's default scope: the PDS corpus this lane owns. Citations in other
# lanes' trees are routed to those lanes as rows, never reached across into.
# The residue outside this scope is PRINTED by --check as a number, so a
# shrinking fence cannot quietly hide a growing debt.
# Captured data, never authored citations. A path predicate, not a name list.
readonly -a CAPTURED=(
  ':(exclude)*/fixtures/*'
)

readonly -a FENCE=(
  'deploy/'
  'scripts/pds-*'
  'tooling/pds/'
  '.claude/workflows/bp-pds-charter.md'
)

usage() {
  cat <<'USAGE'
usage: pds-citation-expand.sh <mode> [paths...]

  --count [paths...]   report every denominator over the scope (default: whole tree)
  --expand [paths...]  rewrite compressed citations into fully-prefixed form
  --check  [paths...]  GUARD: exit 1 if any compressed citation survives in scope
                       (default scope: the PDS fence; residue outside it is printed)
  --selftest           both arms, on a fixture built from parts

Denominators printed by --count:
  files      tracked files carrying at least one compressed citation
  lines      grep -c  — LINES, the number a naive coverage grep reports
  matches    grep -o  — MATCHES, still one per compressed token
  citations  matches + hidden segments — what a reader actually cited
  hidden     distinct D-numbers no `git grep PDS-D<n>` can currently reach
USAGE
}

# Resolve the pathspecs a mode operates on. No argument means the whole tree
# for --count/--expand, and the fence for --check.
files_in_scope() {
  git ls-files -z -- "$@" | tr '\0' '\n'
}

# ── the expanding counter ───────────────────────────────────────────────────
mode_count() {
  local -a spec=("$@")
  [ ${#spec[@]} -eq 0 ] && spec=('.')

  local tmp; tmp="$(mktemp -d)"

  # One pass, recorded to disk, so every denominator below is derived from the
  # SAME read. Deriving them from separate greps would let them disagree for
  # reasons that have nothing to do with the corpus.
  git grep -nhoE "$COMPRESSED" -- "${spec[@]}" > "$tmp/matches.txt" 2>/dev/null || true
  git grep -lE  "$COMPRESSED" -- "${spec[@]}" > "$tmp/files.txt"   2>/dev/null || true
  git grep -cE  "$COMPRESSED" -- "${spec[@]}" > "$tmp/lines.txt"   2>/dev/null || true

  local n_files n_lines n_matches n_hidden n_citations
  n_files=$(wc -l < "$tmp/files.txt" | tr -d ' ')
  n_lines=$(awk -F: '{s+=$NF} END{print s+0}' "$tmp/lines.txt")
  n_matches=$(wc -l < "$tmp/matches.txt" | tr -d ' ')
  # Each `/D<n>` segment is one citation the prefix does not reach.
  n_hidden=$(grep -oE "/D?${SEG}" "$tmp/matches.txt" 2>/dev/null | wc -l | tr -d ' ')
  n_citations=$(( n_matches + n_hidden ))

  echo "PDS-D compressed-citation census"
  echo "  scope      ${spec[*]}"
  echo "  files      $n_files"
  echo "  lines      $n_lines      (grep -c — what a naive coverage grep reports)"
  echo "  matches    $n_matches      (grep -o — one per compressed token)"
  echo "  citations  $n_citations      (matches + hidden segments — the honest count)"

  # The unreachable set, by number. This is the damage in the form a reader can
  # act on: every one of these is a D a `git grep PDS-D<n>` cannot currently find.
  local unreachable
  unreachable=$(grep -oE "/D?${SEG}" "$tmp/matches.txt" 2>/dev/null \
                | sed 's|^/||; s|^D||' | sort -u -V | tr '\n' ' ' || true)
  local n_distinct
  n_distinct=$(grep -oE "/D?${SEG}" "$tmp/matches.txt" 2>/dev/null \
               | sed 's|^/||; s|^D||' | sort -u | wc -l | tr -d ' ')
  echo "  hidden     $n_distinct distinct D-numbers unreachable by \`git grep PDS-D<n>\`"
  [ "$n_distinct" -gt 0 ] && echo "             $unreachable"
  rm -rf "$tmp"
  return 0
}

# ── the expander ────────────────────────────────────────────────────────────
# A token that appends a bare `/D277` to `PDS-D276` becomes `PDS-D276/PDS-D277`.
# The slash is kept, so the
# "these rulings belong together" reading survives and the diff stays minimal;
# only the prefix is restored. Applied repeatedly until no compressed form
# remains, because one token can carry many segments.
mode_expand() {
  local -a spec=("$@")
  [ ${#spec[@]} -eq 0 ] && spec=('.')

  local changed=0 f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    local before_sum after_sum
    before_sum=$(cksum < "$f")
    # Rewrite the file's BYTES in place. An earlier draft round-tripped through
    # $(cat) and printf '%s\n', which strips every trailing newline and adds
    # exactly one back: it silently added a newline to a JSON fixture and
    # removed one from a record. A rewriter must change the citations and
    # NOTHING else, so the substitution never leaves perl's buffer.
    # `1 while s///g` re-runs until no compressed segment is left, because one
    # token can carry many; the expanded form cannot re-match, so it terminates.
    # The segment class comes from $SEG, never a second literal. An earlier
    # draft hardcoded it here, so narrowing $SEG blinded --check while --expand
    # kept working — the guard would have gone quiet with the corpus unfixed,
    # and the selftest arm that exists to catch exactly that could not see it.
    # One definition, two readers.
    SEG_RE="$SEG" perl -0777 -i -pe \
      'BEGIN{$re=qr/(PDS-D$ENV{SEG_RE})\/D?($ENV{SEG_RE})/} 1 while s{$re}{$1/PDS-D$2}g;' "$f"
    after_sum=$(cksum < "$f")
    if [ "$before_sum" != "$after_sum" ]; then
      changed=$((changed + 1))
      echo "expanded: $f"
    fi
  done < <(git grep -lE "$COMPRESSED" -- "${spec[@]}" "${CAPTURED[@]}" 2>/dev/null || true)

  echo "expanded $changed file(s)"
  return 0
}

# ── the guard ───────────────────────────────────────────────────────────────
mode_check() {
  local -a spec=("$@")
  local scoped_to_fence=0
  if [ ${#spec[@]} -eq 0 ]; then
    spec=("${FENCE[@]}")
    scoped_to_fence=1
  fi

  local hits
  hits=$(git grep -nE "$COMPRESSED" -- "${spec[@]}" "${CAPTURED[@]}" 2>/dev/null || true)

  # The captured-data skip, ALWAYS PRINTED with its count. An exclusion nobody
  # can see is how a principled rule turns into a silent exception list.
  local cap_files
  cap_files=$(git grep -lE "$COMPRESSED" -- "${spec[@]}" 2>/dev/null \
              | { grep -c '/fixtures/' || true; })
  if [ "${cap_files:-0}" -gt 0 ]; then
    echo "captured-data files skipped (a dated snapshot records what a row SAID; re-prefixing it falsifies the record): $cap_files"
  fi

  # THE RESIDUE, ALWAYS PRINTED. A guard that reports only its own scope lets a
  # narrowing fence read as progress. This number is the debt still owed by
  # other lanes, and it is visible on every green.
  if [ "$scoped_to_fence" -eq 1 ]; then
    local out_files out_matches
    out_files=$(git grep -lE "$COMPRESSED" -- . ':(exclude)deploy/' ':(exclude)scripts/pds-*' \
                 ':(exclude)tooling/pds/' ':(exclude).claude/workflows/bp-pds-charter.md' \
                 2>/dev/null | wc -l | tr -d ' ')
    out_matches=$(git grep -hoE "$COMPRESSED" -- . ':(exclude)deploy/' ':(exclude)scripts/pds-*' \
                   ':(exclude)tooling/pds/' ':(exclude).claude/workflows/bp-pds-charter.md' \
                   2>/dev/null | wc -l | tr -d ' ')
    echo "residue outside this guard's fence: $out_files file(s), $out_matches compressed token(s) — routed, not reached into"
  fi

  if [ -n "$hits" ]; then
    echo "FAIL: slash-compressed PDS-D citation(s) in scope — \`git grep PDS-D<n>\` cannot reach every number cited here"
    printf '%s\n' "$hits"
    echo
    echo "repair: scripts/pds-citation-expand.sh --expand <file>"
    return 1
  fi
  echo "OK: no slash-compressed PDS-D citation in scope (${spec[*]})"
  return 0
}

# ── selftest ────────────────────────────────────────────────────────────────
# The fixture is BUILT FROM PARTS, so this file carries no compressed literal of
# its own and the guard needs no exception for its own test data.
#
# Every arm runs `git grep` with the pattern passed POSITIONALLY. An earlier
# draft exported $COMPRESSED into a subshell that had already marked it
# readonly; the subshell died, returned 1, and two arms expecting rc=1 printed
# `ok` having measured nothing. A vacuous green is the failure this file is
# supposed to catch, so the mechanism that produced one is gone.
mode_selftest() {
  local P='PDS-D' S='/' D='D'
  local tmp; tmp="$(mktemp -d)"
  local pass=0 fail=0

  # grep_rc <dir> <pattern> <pathspec> -> echoes the rc, never inherits set -e
  grep_rc() {
    local d="$1" pat="$2" pathspec="$3" rc=0
    ( cd "$d" && git grep -nE "$pat" -- "$pathspec" >/dev/null 2>&1 ) || rc=$?
    echo "$rc"
  }
  # Exercises the REAL --check path. ARM 7b first used a hand-rolled git grep
  # and so measured the predicate while claiming to measure the guard — the
  # captured-data skip lives in --check, and a raw grep cannot see it.
  check_rc() {
    local d="$1" pathspec="$2" rc=0
    ( cd "$d" && "$SELF" --check "$pathspec" >/dev/null 2>&1 ) || rc=$?
    echo "$rc"
  }
  lit_rc() {
    local d="$1" lit="$2" pathspec="$3" rc=0
    ( cd "$d" && git grep -qF "$lit" -- "$pathspec" ) || rc=$?
    echo "$rc"
  }
  # Tolerates a no-op commit. Without the guard, a mutation that happens to
  # leave a fixture unchanged aborts the whole harness under set -e, and the
  # run prints nothing at all — a crash that reads exactly like a silent pass.
  commit() {
    git -C "$tmp" add -A
    git -C "$tmp" -c user.email=t@t -c user.name=t commit -qm x >/dev/null 2>&1 || true
  }
  chk() { # chk <expect-rc> <actual-rc> <label>
    if [ "$1" -eq "$2" ]; then pass=$((pass+1)); echo "  ok   $3"
    else fail=$((fail+1)); echo "  FAIL $3 (expected rc=$1, got rc=$2)"; fi
  }

  git -C "$tmp" init -q .
  mkdir -p "$tmp/scripts"

  # ARM 1 (NEGATIVE CONTROL) — a compressed citation MUST be found.
  # Built from parts: P+276+S+D+277 never appears as a literal in this file.
  printf '# per %s276%s%s277 the door stays shut\n' "$P" "$S" "$D" > "$tmp/scripts/pds-fixture.sh"
  commit
  chk 0 "$(grep_rc "$tmp" "$COMPRESSED" 'scripts/pds-*')" \
       "ARM 1  the predicate FINDS a compressed citation (guard would red)"

  # ARM 1b — the damage is MEASURED, not merely detected.
  chk 1 "$(lit_rc "$tmp" 'PDS-D277' '.')" \
       "ARM 1b the hidden number is UNREACHABLE by \`git grep PDS-D277\`"

  # ARM 2 — expansion makes it reachable, and the guard goes quiet.
  ( cd "$tmp" && "$SELF" --expand 'scripts/pds-*' >/dev/null ); commit
  chk 0 "$(lit_rc "$tmp" 'PDS-D277' '.')" \
       "ARM 2  after --expand the hidden number IS reachable"
  chk 1 "$(grep_rc "$tmp" "$COMPRESSED" 'scripts/pds-*')" \
       "ARM 2b after --expand the predicate finds NOTHING (guard green)"

  # ARM 3 (POSITIVE CONTROL) — an already-expanded citation must stay QUIET.
  # Without this, ARM 2b is compatible with a predicate that matches nothing.
  printf '# per %s280%s%s281 both apply\n' "$P" "$S$P" "$D" > "$tmp/scripts/pds-quiet.sh"
  commit
  chk 1 "$(grep_rc "$tmp" "$COMPRESSED" 'scripts/pds-quiet.sh')" \
       "ARM 3  an EXPANDED citation does not red the guard (no false positive)"

  # ARM 3b (POSITIVE CONTROL) — a LONE D-number must stay quiet too.
  printf '# per %s404 alone\n' "$P" > "$tmp/scripts/pds-lone.sh"
  commit
  chk 1 "$(grep_rc "$tmp" "$COMPRESSED" 'scripts/pds-lone.sh')" \
       "ARM 3b a LONE PDS-D404 does not red the guard"

  # ARM 4 — the letter-suffix segment. A [0-9]+ predicate truncates or misses
  # these; this arm fails loudly if the alphabet is ever narrowed back.
  printf '# per %s391b%s%s336 and %s480%s%s480a\n' "$P" "$S" "$D" "$P" "$S" "$D" > "$tmp/scripts/pds-suffix.sh"
  commit
  ( cd "$tmp" && "$SELF" --expand 'scripts/pds-suffix.sh' >/dev/null ); commit
  chk 0 "$(lit_rc "$tmp" 'PDS-D480a' 'scripts/pds-suffix.sh')" \
       "ARM 4  a letter-suffixed segment (D480a) survives expansion intact"
  chk 0 "$(lit_rc "$tmp" 'PDS-D336' 'scripts/pds-suffix.sh')" \
       "ARM 4b a letter-suffixed PREFIX (D391b/D336) is expanded, not skipped"

  # Assertions below read with a herestring, never `printf | grep -q`: under
  # `set -o pipefail` grep -q exits on the first match, printf takes SIGPIPE,
  # and the pipeline returns 141 — an arm that fails only under load.
  # ARM 5 — the counter separates its denominators. One line carrying two
  # tokens is exactly this row's defect wearing a different hat.
  printf '# %s10%s%s11 and %s12%s%s13 on ONE line\n' "$P" "$S" "$D" "$P" "$S" "$D" > "$tmp/scripts/pds-twoline.sh"
  commit
  local out rc
  out=$( cd "$tmp" && "$SELF" --count 'scripts/pds-twoline.sh' )
  rc=0; grep -qE '^  lines      1 ' <<<"$out" || rc=1
  chk 0 "$rc" "ARM 5  --count reports 1 LINE for two tokens on one line"
  rc=0; grep -qE '^  matches    2 ' <<<"$out" || rc=1
  chk 0 "$rc" "ARM 5b --count reports 2 MATCHES for the same line"
  rc=0; grep -qE '^  citations  4 ' <<<"$out" || rc=1
  chk 0 "$rc" "ARM 5c --count reports 4 CITATIONS — the number lines and matches both hide"

  # ARM 6 — --expand is IDEMPOTENT. The FIRST pass here absorbs the fixtures
  # added since ARM 2 (the ARM 5 two-token line was only counted, never
  # expanded); the SECOND must then change nothing. Asserting on the second
  # pass alone would have measured whichever fixtures happened to be left.
  local first second
  first=$( cd "$tmp" && "$SELF" --expand 'scripts/pds-*' ); commit
  rc=0; grep -qE '^expanded [1-9][0-9]* file\(s\)$' <<<"$first" || rc=1
  chk 0 "$rc" "ARM 6  the pre-pass expands the remaining fixtures (setup asserted, not assumed)"
  second=$( cd "$tmp" && "$SELF" --expand 'scripts/pds-*' )
  rc=0; grep -qE '^expanded 0 file\(s\)$' <<<"$second" || rc=1
  chk 0 "$rc" "ARM 6b --expand is idempotent (second pass expands 0 files)"

  # ARM 7 — CAPTURED DATA. A compressed citation inside a dated snapshot is a
  # RECORD of what a row said, not a citation this repo authored: --expand must
  # leave it byte-identical and --check must not red on it. Both halves asserted,
  # because a rule that only skips is indistinguishable from a rule that is broken.
  mkdir -p "$tmp/tooling/pds/fixtures"
  printf '{"title": "expand (%s69%s%s70) please"}\n' "$P" "$S" "$D" > "$tmp/tooling/pds/fixtures/live-corpus-2026-07-31.json"
  commit
  local cap_before cap_after
  cap_before=$(cksum < "$tmp/tooling/pds/fixtures/live-corpus-2026-07-31.json")
  ( cd "$tmp" && "$SELF" --expand 'tooling/pds/fixtures/*' >/dev/null )
  cap_after=$(cksum < "$tmp/tooling/pds/fixtures/live-corpus-2026-07-31.json")
  rc=0; [ "$cap_before" = "$cap_after" ] || rc=1
  chk 0 "$rc" "ARM 7  --expand leaves a dated snapshot BYTE-IDENTICAL"
  chk 0 "$(check_rc "$tmp" 'tooling/pds/fixtures/*')" \
       "ARM 7b --check stays GREEN on captured data"

  # ARM 7c (NEGATIVE CONTROL) — the same bytes in an AUTHORED path must still
  # red. Without this, ARM 7b is satisfied by a predicate that skips everything.
  mkdir -p "$tmp/scripts"
  printf '# expand (%s69%s%s70) please\n' "$P" "$S" "$D" > "$tmp/scripts/pds-authored.sh"
  commit
  chk 1 "$(check_rc "$tmp" 'scripts/pds-authored.sh')" \
       "ARM 7c --check REDS on the same citation in an authored path (skip is path-scoped, not blanket)"

  rm -rf "$tmp"
  echo
  echo "selftest: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
readonly SELF
export SELF

main() {
  [ $# -ge 1 ] || { usage; exit 2; }
  local mode="$1"; shift
  case "$mode" in
    --count)    mode_count "$@" ;;
    --expand)   mode_expand "$@" ;;
    --check)    mode_check "$@" ;;
    --selftest) mode_selftest ;;
    -h|--help)  usage ;;
    *)          echo "unknown mode: $mode" >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
