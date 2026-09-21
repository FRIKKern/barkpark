#!/usr/bin/env bash
# pds-threshold-move-guard.sh — a PR that MOVES a reference literal must SAY SO.
#
# THE LAW THIS ENFORCES (task pds-bl-w49-budget-literal-moved-by-its-own-pr):
#   A check whose reference value is editable by the change it checks is not a
#   measurement. PR #9601 (c3b0421cb) raised js/packages/react/.size-limit.json
#   from "22.5 KB" to "22.75 KB" in the SAME commit that a criterion cited the
#   22.5 KB cap against. The size gate went green having measured nothing, and
#   the criterion became unstampable: before the commit the fix is absent, from
#   the commit onward the cap it names is gone.
#
# THIS IS NOT A FREEZE, AND THAT IS THE DESIGN, NOT A CONCESSION.
#   Caps legitimately move. A guard that forbids the move gets deleted, and a
#   deleted guard enforces nothing. So the move is ALLOWED — what is refused is
#   a move that is INVISIBLE. State the old value, the new value and why, at
#   column 0 of the PR body, and this guard passes. #9601's own author did the
#   honest half already: the measurement went into the cap's `name` string. What
#   a `name` string cannot do is reach the criterion that cited the old number,
#   or any diff-aware reader. A column-0 trailer can.
#
# THE WATCHED POPULATION is not invented here. It is the 18 rows measured in
#   tooling/grip/ledger/pds-w49-budget-literal-population-2026-09-11.md (criterion
#   c0 of the same task), each one a tracked file WHOSE CONTENTS ARE the reference
#   value and which a named consumer reads as such. Thresholds hard-coded inside
#   source are a different, larger population and are deliberately out of scope —
#   they need a parse, not a path filter, and the ledger says so.
#
# ── CONTRACT ────────────────────────────────────────────────────────────────
#   usage: pds-threshold-move-guard.sh [--base <ref>] [--head <ref>]
#                                      [--pr-body <file>] [--list] [--selftest-help]
#
#   PR BODY, same convention as scripts/pr-task-gate.sh: the body arrives in the
#   PR_BODY environment variable, or from a file named by --pr-body (or
#   PR_BODY_FILE). --pr-body wins. If NEITHER is supplied the run is UNCHECKED
#   (exit 2) — a guard that reads no body and prints a green has measured
#   nothing, which is the exact fault it exists to refuse. PR_BODY set to the
#   EMPTY STRING is a body, not an absence: it states nothing, so any move under
#   it is a refusal.
#
#   Refs default to origin/main (base) and HEAD (head).
#
#   EXIT CODES
#     0  PASS      — either nothing watched moved, or every move that happened is
#                    stated in the body with both values and a justification.
#     1  REFUSED   — at least one watched literal moved and the body does not say
#                    so. The run names every such literal, its old and new value,
#                    and prints the exact line that would satisfy it.
#     2  UNCHECKED — the guard could not read its own inputs (not a git repo, a
#                    ref that does not resolve, no PR body source at all). NEVER
#                    a silent green: a guard that cannot look must not report.
#     3  USAGE     — bad invocation.
#
# ── THE DECLARATION GRAMMAR ─────────────────────────────────────────────────
#   One line per moved literal, at COLUMN 0 (column 0 for the same reason
#   pr-task-gate.sh requires it: an example quoted inside a fenced code block is
#   indented, and this fleet pastes real bodies into bodies constantly):
#
#     Threshold-move: <path>#<key> <old> -> <new> — <why, in a sentence>
#
#   Checked, in the author's own words rather than by exact shape, so a body that
#   says the right thing in a slightly different order still passes:
#     (a) the line begins, case-insensitively, with `threshold-move:` at column 0;
#     (b) it carries the literal's id, `<path>#<key>`, verbatim;
#     (c) it carries BOTH the old and the new value as substrings;
#     (d) what remains, after the label, the id and the two values are struck
#         out, holds at least MIN_JUSTIFICATION_CHARS alphanumeric characters —
#         a justification, not a shrug. "Threshold-move: x#y 1 -> 2" alone is a
#         restatement of the diff, and the diff is already visible.
#
#   A watched path DROPPED from this guard's own roster is the row-9 hole of the
#   population ledger (`scripts/.silencer-counts` is the ratchet's own roster and
#   nothing ratchets it). Removing a path here silences this guard for that path
#   in the same PR that removes it, so a drop is REFUSED unless the body carries,
#   also at column 0:
#
#     Threshold-watch-drop: <path> — <why it is no longer a reference literal>
#
#   That arm compares this script's roster at --base against its roster at --head.
#   When the base revision has no copy of this script (the commit that ADDS it),
#   the arm prints that it is standing down and why, rather than passing silently.
#
# ── WHAT THIS GUARD DOES NOT CLAIM ──────────────────────────────────────────
#   It is not a required context and does not make one. Wiring venue belongs to
#   whoever owns .github/workflows; this file is the predicate. And the honest
#   limit measured in the c0 ledger stands: 16 of the 18 watched rows ride no
#   required gate at all, so for those rows moving the literal was never even the
#   cheapest way to go green — ignoring the red was. This guard makes the move
#   VISIBLE. It does not make the underlying check blocking.
# INTERPRETER GUARD — shebang-independent, and it must stay ABOVE the first
# process substitution in this file. bash reads a script INCREMENTALLY: invoked
# as `sh` it is in POSIX mode, where `<(…)` cannot be parsed, so everything
# above the offending line has ALREADY RUN and the script dies with the status
# of the last completed command. MEASURED 2026-09-13: under `sh` this file exited 2 having produced NO output at all.
# Pinned by scripts/posix-vacuous-green-census.sh, which reds if this guard is
# removed or moved below the first process substitution.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "pds-threshold-move-guard.sh: needs bash (this script uses process substitution); run: bash scripts/pds-threshold-move-guard.sh" >&2
  exit 2
fi
case ":${SHELLOPTS:-}:" in
  *:posix:*)
    echo "pds-threshold-move-guard.sh: bash is in POSIX mode (invoked as \`sh\`?), which cannot parse this script's process substitution; run: bash scripts/pds-threshold-move-guard.sh" >&2
    exit 2
    ;;
esac

set -uo pipefail

MIN_JUSTIFICATION_CHARS=20

usage() {
  cat >&2 <<'USAGE'
usage: pds-threshold-move-guard.sh [--base <ref>] [--head <ref>] [--pr-body <file>] [--list]
  --base <ref>      revision to compare FROM (default: origin/main)
  --head <ref>      revision to compare TO   (default: HEAD)
  --pr-body <file>  PR description file (else $PR_BODY_FILE, else $PR_BODY)
  --list            print the watched roster (path<TAB>kind) and exit 0
exit: 0 pass · 1 refused · 2 UNCHECKED (could not read inputs) · 3 usage
USAGE
}

unchecked() { printf 'pds-threshold-move-guard: UNCHECKED: %s\n' "$*" >&2; exit 2; }

# ── THE WATCHED ROSTER ──────────────────────────────────────────────────────
# <path><TAB><kind>. The 18 rows of the c0 population ledger, in its order.
# KINDS, and why each file gets the one it gets:
#   size-limit  a size-limit.json: EVERY `"limit": "..."` is its own literal,
#               keyed by ordinal. Per-cap granularity is the point — #9601 moved
#               ONE of six caps, and a whole-file digest would have said only
#               "the file changed", which the diff already said.
#   counts      `<name> <number>` roster (scripts/.silencer-counts): one literal
#               per name, because the ratchet reads them one per name.
#   number      a file whose one payload line IS the number.
#   json-count  a JSON entry list whose LENGTH is the floor: the literal is the
#               count of `"doc":` keys, which is what the never-worse floor reads.
#   roster      a grandfather SET. The reference value is the set itself, so the
#               literal is `<payload line count> sha=<digest>` — any edit to the
#               set moves it. Coarse ON PURPOSE: a guard over a waiver list that
#               only noticed the count would miss a swap, and a swap is exactly
#               how a set grows without growing.
# Comment lines (`#`) and blanks are payload for NO kind: every extractor drops
# them, so re-wording a baseline's header prose is not a threshold move.
WATCHED='js/packages/react/.size-limit.json	size-limit
js/packages/core/.size-limit.json	size-limit
js/packages/nextjs/.size-limit.json	size-limit
js/packages/codegen/.size-limit.json	size-limit
.github/hex-audit-baseline.txt	roster
api/.sobelow-skips	roster
scripts/tenant-scope-baseline.txt	roster
design/status-manifest.json	roster
scripts/.silencer-counts	counts
.go-format-drift-ceiling	roster
scripts/pipefail-sigpipe-baseline.txt	roster
scripts/stale-verdict-watch.baseline	roster
tooling/concept-map/boundary-baseline.json	roster
tooling/doc-truth/fixtures/lineref-baseline.json	json-count
cloud/priv/static/__preview__/cssom-heads.baseline	number
cloud/priv/static/__preview__/cssom-heads-styleguide.baseline	number
api/test/search_golden/baseline.json	roster
internal/apiclient/testdata/doc_decode_baseline.txt	roster'

# roster_paths — the paths this roster watches, one per line. Used both for the
# sweep and, against the base revision's copy of this file, for the drop arm.
roster_paths() { printf '%s\n' "$WATCHED" | awk -F'\t' 'NF {print $1}'; }

# roster_paths_of_text — the same extraction over a STRING holding another
# revision of this script. It re-reads the assignment rather than sourcing it:
# sourcing an arbitrary older revision of a script to ask it a question is how a
# guard ends up executing the change it is judging.
roster_paths_of_text() {
  printf '%s\n' "$1" \
    | sed -n "/^WATCHED='/,/'\$/p" \
    | sed "s/^WATCHED='//; s/'\$//" \
    | awk -F'\t' 'NF && $1 != "" { print $1 }'
}

digest() { # 12 hex of stdin, whichever digester the host has
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -c1-12
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-12
  else cksum | tr -d ' ' | cut -c1-12
  fi
}

payload() { grep -vE '^[[:space:]]*(#|$)' || true; }

# extract <kind> — reads the file on stdin, prints `<key>\t<value>` lines.
extract() {
  case "$1" in
    size-limit)
      grep -oE '"limit"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed -E 's/.*"limit"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' \
        | awk '{ printf "limit#%d\t%s\n", NR, $0 }'
      ;;
    counts)
      payload | awk 'NF >= 2 { printf "%s\t%s\n", $1, $2 }'
      ;;
    number)
      payload | grep -E '^[[:space:]]*[0-9]+([.][0-9]+)?[[:space:]]*$' \
        | tr -d '[:space:]' | awk 'NR == 1 { printf "value\t%s\n", $0 }'
      ;;
    json-count)
      awk '{ n += gsub(/"doc"[[:space:]]*:/, "") } END { printf "entries\t%d\n", n }'
      ;;
    *) return 1 ;;
  esac
}

# roster needs the payload TWICE (count and digest), so it is its own function
# rather than a branch of `extract` that would have to buffer stdin twice.
extract_roster() {
  local body n sha
  body="$(payload)"
  n="$(printf '%s' "$body" | grep -c . || true)"
  sha="$(printf '%s' "$body" | digest)"
  printf 'entries\t%s lines sha=%s\n' "$n" "$sha"
}

# literals_at <ref> <path> <kind> — the literal map of one watched file at one
# revision. A file ABSENT at that revision yields the single literal
# `<file>` = ABSENT: deleting a baseline outright silences its gate, and that is
# a threshold move in the only direction that matters.
literals_at() {
  local ref="$1" path="$2" kind="$3" blob
  if ! blob="$(git show "$ref:$path" 2>/dev/null)"; then
    printf '%s\tABSENT\n' '(file)'
    return 0
  fi
  if [ "$kind" = roster ]; then
    printf '%s' "$blob" | extract_roster
  else
    printf '%s' "$blob" | extract "$kind"
  fi
}

# ── body reading ────────────────────────────────────────────────────────────
BODY=''
have_body=0

# statement_for <id> <old> <new> — does the body declare THIS move?
statement_for() {
  local id="$1" old="$2" new="$3" line rest alnum
  while IFS= read -r line; do
    case "$line" in
      [Tt][Hh][Rr][Ee][Ss][Hh][Oo][Ll][Dd]-[Mm][Oo][Vv][Ee]:*) : ;;
      *) continue ;;
    esac
    case "$line" in *"$id"*) : ;; *) continue ;; esac
    case "$line" in *"$old"*) : ;; *) continue ;; esac
    case "$line" in *"$new"*) : ;; *) continue ;; esac
    # (d) a justification, not a restatement of the diff: strike the label, the
    # id and both values, then count what alphanumeric text is left.
    rest="${line#*:}"
    rest="${rest//$id/}"
    rest="${rest//$old/}"
    rest="${rest//$new/}"
    alnum="$(printf '%s' "$rest" | tr -cd '[:alnum:]')"
    [ "${#alnum}" -ge "$MIN_JUSTIFICATION_CHARS" ] && return 0
  done <<< "$BODY"
  return 1
}

drop_statement_for() {
  local path="$1" line rest alnum
  while IFS= read -r line; do
    case "$line" in
      [Tt][Hh][Rr][Ee][Ss][Hh][Oo][Ll][Dd]-[Ww][Aa][Tt][Cc][Hh]-[Dd][Rr][Oo][Pp]:*) : ;;
      *) continue ;;
    esac
    case "$line" in *"$path"*) : ;; *) continue ;; esac
    rest="${line#*:}"
    rest="${rest//$path/}"
    alnum="$(printf '%s' "$rest" | tr -cd '[:alnum:]')"
    [ "${#alnum}" -ge "$MIN_JUSTIFICATION_CHARS" ] && return 0
  done <<< "$BODY"
  return 1
}

main() {
  local base='origin/main' head='HEAD' body_file='' list_only=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="${2:-}"; [ -n "$base" ] || { usage; exit 3; }; shift 2 ;;
      --head) head="${2:-}"; [ -n "$head" ] || { usage; exit 3; }; shift 2 ;;
      --pr-body) body_file="${2:-}"; [ -n "$body_file" ] || { usage; exit 3; }; shift 2 ;;
      --list) list_only=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'pds-threshold-move-guard: unknown argument: %s\n' "$1" >&2; usage; exit 3 ;;
    esac
  done

  if [ "$list_only" = 1 ]; then printf '%s\n' "$WATCHED"; exit 0; fi

  git rev-parse --git-dir >/dev/null 2>&1 \
    || unchecked "this is not a git working tree, so no diff can be taken (cwd $(pwd))"

  local base_sha head_sha
  base_sha="$(git rev-parse --verify --quiet "$base^{commit}" 2>/dev/null)" \
    || unchecked "the base ref '$base' does not resolve to a commit in this repository — nothing to compare against"
  head_sha="$(git rev-parse --verify --quiet "$head^{commit}" 2>/dev/null)" \
    || unchecked "the head ref '$head' does not resolve to a commit in this repository — nothing to compare"

  [ -n "$body_file" ] || body_file="${PR_BODY_FILE:-}"
  if [ -n "$body_file" ]; then
    [ -r "$body_file" ] \
      || unchecked "the PR body file '$body_file' cannot be read — the guard was told where the body is and it is not there"
    BODY="$(cat "$body_file")"; have_body=1
  elif [ -n "${PR_BODY+x}" ]; then
    BODY="${PR_BODY}"; have_body=1
  fi
  [ "$have_body" = 1 ] \
    || unchecked "no PR body was supplied — pass --pr-body <file>, or set PR_BODY_FILE or PR_BODY. A guard that reads no body and prints a green has measured nothing"

  printf 'pds-threshold-move-guard: base %s (%s) -> head %s (%s), %s watched files\n' \
    "$base" "${base_sha:0:9}" "$head" "${head_sha:0:9}" "$(roster_paths | grep -c . || true)"

  local moved=0 unstated=0 path kind key oldv newv id
  # THE TWO WORK SIDES of the sweep count identities (task-fb55d468c7dea75b):
  # watched paths REACHED, and — accumulated across every outer iteration —
  # union keys REACHED against union keys ENUMERATED.
  local watched_seen=0 watched_enumerated keys_seen=0 keys_enumerated=0 union
  watched_enumerated="$(printf '%s' "$WATCHED" | grep -c . || true)"
  local before after

  # ── the roster-drop arm (the row-9 hole: nothing ratchets the ratchet's roster)
  local self_rel self_base
  self_rel="$(git ls-files --full-name -- "${BASH_SOURCE[0]}" 2>/dev/null | head -1)"
  [ -n "$self_rel" ] || self_rel='scripts/pds-threshold-move-guard.sh'
  if self_base="$(git show "$base_sha:$self_rel" 2>/dev/null)"; then
    local dropped
    dropped="$(comm -23 <(roster_paths_of_text "$self_base" | sort -u) <(roster_paths | sort -u))"
    if [ -n "$dropped" ]; then
      while IFS= read -r path; do
        [ -n "$path" ] || continue
        if drop_statement_for "$path"; then
          printf '  STATED-DROP  %s is no longer watched, and the body says why.\n' "$path"
        else
          printf '  REFUSED-DROP %s was dropped from this guard'"'"'s own roster in this diff,\n' "$path"
          printf '               which silences the guard for that path in the same PR that drops it.\n'
          printf '               Add at column 0:  Threshold-watch-drop: %s — <why it is no longer a reference literal>\n' "$path"
          unstated=$((unstated + 1))
        fi
      done <<< "$dropped"
    else
      printf '  roster-drop arm: no watched path was dropped between %s and %s.\n' "${base_sha:0:9}" "${head_sha:0:9}"
    fi
  else
    printf '  roster-drop arm: STANDING DOWN — %s does not exist at %s, so there is no earlier\n' "$self_rel" "${base_sha:0:9}"
    printf '                   roster to compare against. This is the commit that ADDS the guard.\n'
  fi

  # ── the literal sweep
  while IFS=$'\t' read -r path kind; do
    [ -n "$path" ] || continue
    # MUT-SPLICE: watched-count-identity
    # THE WORK SIDE — tallied above every `continue`, so it counts watched paths
    # REACHED, the only quantity a short read moves.
    watched_seen=$((watched_seen + 1))
    before="$(literals_at "$base_sha" "$path" "$kind")"
    after="$(literals_at "$head_sha" "$path" "$kind")"
    [ "$before" = "$after" ] && continue

    # every key present on EITHER side, so an added or removed cap is a move too.
    # MATERIALISED into `$union` rather than consumed straight out of the process
    # substitution: the key identity below needs an enumeration side that a short
    # read cannot move.
    union="$( { printf '%s\n' "$before"; printf '%s\n' "$after"; } | awk -F'\t' 'NF {print $1}' | awk '!seen[$0]++' )"
    keys_enumerated=$((keys_enumerated + $(printf '%s' "$union" | grep -c . || true)))
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      # MUT-SPLICE: key-count-identity
      keys_seen=$((keys_seen + 1))
      oldv="$(printf '%s\n' "$before" | awk -F'\t' -v k="$key" '$1 == k { print $2; exit }')"
      newv="$(printf '%s\n' "$after"  | awk -F'\t' -v k="$key" '$1 == k { print $2; exit }')"
      [ -n "$oldv" ] || oldv='(absent)'
      [ -n "$newv" ] || newv='(absent)'
      [ "$oldv" = "$newv" ] && continue
      moved=$((moved + 1))
      id="$path#$key"
      if statement_for "$id" "$oldv" "$newv"; then
        printf '  STATED   %s moved %s -> %s, and the body states both values with a reason.\n' \
          "$id" "$oldv" "$newv"
      else
        printf '  REFUSED  %s moved %s -> %s and the PR body does not say so.\n' "$id" "$oldv" "$newv"
        printf '           This check now measures the value this PR wrote. Add at column 0:\n'
        printf '           Threshold-move: %s %s -> %s — <why this move is right, in a sentence>\n' \
          "$id" "$oldv" "$newv"
        unstated=$((unstated + 1))
      fi
    done <<< "$union"
  done <<< "$WATCHED"

  # ── THE COUNT IDENTITIES (task-fb55d468c7dea75b) ───────────────────────────
  # BOTH loops above read on fd 0 — the outer from `<<< "$WATCHED"`, the inner
  # from `<<< "$union"`. Any body child that reads stdin (a future `git` with a
  # pager, a `read`, an `ssh`, a `gh` without `</dev/null`) swallows the
  # remaining rows and the loop ENDS EARLY with no error and no non-zero status.
  # Nothing below could see it: `$moved` and `$unstated` are BOTH read off those
  # loops, so they agree with each other on a short read, and the verdict
  #     PASS: nothing watched moved.
  # is what a guard that examined 1 of 12 watched paths prints — the same words
  # a complete sweep uses. A key never reached is a threshold move never
  # REFUSED, which is precisely the silence this guard exists to break.
  #
  # Two identities, not one: the outer count alone would not notice an inner
  # loop cut short inside a single watched path. The key identity accumulates
  # across outer iterations, so it holds for the whole sweep.
  # MUT-ANCHOR: watched-count-identity
  if [ "$watched_seen" -ne "$watched_enumerated" ]; then
    printf 'pds-threshold-move-guard: SHORT SWEEP — examined %s of %s watched path(s) in the roster.\n' "$watched_seen" "$watched_enumerated"
    printf '  The sweep loop ended before $WATCHED did (a loop-body child that reads stdin consumes\n'
    printf '  the remaining rows silently). A partial sweep must never print a PASS in the same words\n'
    printf '  as a complete one. This is a fault in THIS guard, not a finding about the PR.\n'
    exit 2
  fi
  if [ "$keys_seen" -ne "$keys_enumerated" ]; then
    printf 'pds-threshold-move-guard: SHORT KEY SWEEP — examined %s of %s union key(s) across the watched paths.\n' "$keys_seen" "$keys_enumerated"
    printf '  The per-path key loop ended before its union did; a threshold key never reached is a\n'
    printf '  move never refused. This is a fault in THIS guard, not a finding about the PR.\n'
    exit 2
  fi
  # MUT-END: watched-count-identity

  printf 'pds-threshold-move-guard: %s watched literal(s) moved, %s unstated.\n' "$moved" "$unstated"
  if [ "$unstated" -gt 0 ]; then
    printf 'REFUSED: a reference value this PR is judged by was edited by this PR without saying so.\n'
    printf '  The move is not the fault and this guard does not forbid it — caps move. The fault is\n'
    printf '  that the new number is invisible to anyone reading the old one. State it and pass.\n'
    exit 1
  fi
  if [ "$moved" -eq 0 ]; then
    printf 'PASS: nothing watched moved.\n'
  else
    printf 'PASS: every watched literal that moved is stated in the PR body with both values and a reason.\n'
  fi
  exit 0
}

main "$@"
