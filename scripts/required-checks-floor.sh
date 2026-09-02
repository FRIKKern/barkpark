#!/usr/bin/env bash
# required-checks-floor.sh — the SUPERSET floor for a regenerated spec.
#
# WHY A FLOOR AT ALL (honest-gates D64, D74)
#
# `scripts/required-checks-generate.sh` derives the required set from check runs
# it observed on the sampled heads. That is the right way to build the list —
# and it is also a silent downgrade waiting to happen. Sample two heads where
# one required job happened to be cancelled, and the generator honestly emits a
# SMALLER set. Nothing in the toolchain notices: `--payload` builds, the PUT
# returns 200, `required-checks-verify.sh` compares the spec against live
# protection and both agree, because the spec IS the thing that shrank. A
# one-name spec passes its own verify end to end. That is the shape this script
# refuses.
#
# WHY A COUNT FLOOR IS NOT ENOUGH, and this is the whole reason the script is
# not three lines of `jq length`:
#
#   committed: ["Elixir gate", "PR references an active task"]
#   candidate: ["PR references an active task", "Boundary gate (advisory)"]
#
# Two in, two out. A `>= 2` floor is GREEN on that specimen, and it has swapped
# the repo's only blocking Elixir gate for a check that carries
# continue-on-error and therefore cannot fail. So the comparison is a SET
# comparison, on the pair (context, app_id) — an app_id that drifted to `null`
# means "any app with checks:write may satisfy this name" (D21) and is exactly
# as much of a loss as the name disappearing.
#
# WHY THE REFERENCE COMES FROM `git show origin/main:…` AND NEVER THE WORKTREE
#
# The PR that regenerates the spec REWRITES `.github/required-checks.json`. A
# floor that reads the worktree copy compares the candidate to itself and passes
# unconditionally — a guard that structurally cannot fail, in an epic about
# guards that cannot fail. The reference is therefore read out of git, from the
# branch protection is actually installed on.
#
# GROWTH IS NOT SILENTLY FINE EITHER (D69)
#
# A name the generator newly promotes is a real decision — it becomes a context
# every PR in the repo must render forever, and a job that is green today and
# paths-filtered tomorrow deadlocks the branch. So growth exits NON-ZERO with
# the added names printed, and the caller must pass `--acknowledge-growth` to
# say a human looked. Loss is never acknowledgeable; it is exit 1, always.
#
# THE SET OF NAMES IS NOT THE WHOLE SPEC — `_readme` AND `enforced` ARE FLOORED
# TOO, and until this was written the floor was measurably blind to both.
#
# `grep -c '_readme\|enforced' scripts/required-checks-floor.sh` returned 0. A
# candidate byte-identical to the committed spec except with `_readme` replaced
# by `["gone"]` and `enforced` flipped to `false` printed
# `FLOOR OK … identical on context AND app_id` and exited 0.
#
# AND THE REACHABLE VERSION OF THAT SPECIMEN IS THE GENERATOR'S OWN DEFAULT.
# Re-derived against required-checks-generate.sh as it stands, because the
# original filing described an older generator and half of it has since been
# fixed — say what is true today, not what was true when the row was written:
#
#   `_readme` is now MERGED onto the committed base, not overwritten (the
#   `($b._readme // []) | reduce $owned[] …` emit), so a plain regeneration no
#   longer drops the floor/exclusions/merge-protocol paragraphs wholesale. Two
#   shapes still lose entries: `--no-merge`, the deliberate greenfield emit,
#   writes only the six paragraphs the generator owns against the committed
#   nine; and the `enforced=` paragraph's TEXT is conditioned on the same
#   variable as the flag, so the flip below rewrites that entry — a set loss in
#   its own right.
#
#   `ENFORCED` defaults to `false` and nothing in the generator refuses to
#   downgrade a base that says `true`. So `required-checks-generate.sh --sha …
#   --out .github/required-checks.json`, typed exactly as an agent would type
#   it, emits `enforced: false` over a committed `enforced: true`.
#
# So the flip is not a hypothetical: it is what you get by not passing a flag.
# Neither loss is cosmetic:
#
#   `_readme` is the ONLY place the repo records WHY a name is required, why a
#   count floor is insufficient, and what the exclusions census is for. It is
#   the prose an agent reads before regenerating. Losing it does not red a
#   single gate — it deletes the reason the gates exist, which is how the next
#   wave repeats the clobber verbatim.
#
#   `enforced: false` is worse than cosmetic, because it makes a DOWNSTREAM
#   guard vacuous: `required-checks-verify.sh` skips the live-protection diff on
#   an `enforced: false` spec, so the only three-way drift guard goes green
#   without looking. `required-checks-apply.sh` does refuse `enforced: false`
#   loudly, but that is the WRITE path only — a PR that commits the flipped spec
#   never runs apply, and nothing else was watching.
#
# Both are therefore LOSSES, not growth: exit 1, never acknowledgeable. Growth
# in `_readme` (a candidate that ADDS paragraphs) is silently fine — more
# explanation is never a downgrade. `enforced` going false → true is likewise
# an improvement and passes.
#
# The floor holds `_readme` by SET, exactly as it holds the contexts: every
# entry present in the reference must be present in the candidate. Reordering
# and rewrapping therefore red, and that is deliberate — an edited paragraph is
# a paragraph whose edit should be visible in a diff a human approves, and the
# escape hatch is to change the reference on main in a PR that says why, which
# is the same escape hatch a removed context has.
#
# EXIT CODES
#   0  candidate ⊇ committed, and no unacknowledged growth
#   1  LOSS — a committed (context, app_id) is missing or weakened, OR a
#      committed `_readme` entry is gone, OR `enforced` regressed true → false.
#      Hard, and never clearable with --acknowledge-growth.
#   2  GROWTH — the candidate is a strict superset and nobody acknowledged it
#
# USAGE
#   scripts/required-checks-floor.sh <candidate.json>
#   scripts/required-checks-floor.sh --reference <ref.json> <candidate.json>
#   scripts/required-checks-floor.sh --acknowledge-growth <candidate.json>
#   scripts/required-checks-floor.sh --ref-rev origin/main <candidate.json>

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC_PATH=".github/required-checks.json"

REF_FILE=""
REF_REV="origin/main"
ACK_GROWTH=0
CANDIDATE=""
QUIET=0

fail() { echo "FAIL: $*" >&2; exit 1; }

# Reading the reference is itself a thing that can fail, and an unreadable
# reference must never degrade into "nothing to compare against, so pass".
read_reference() {
  if [ -n "$REF_FILE" ]; then
    [ -f "$REF_FILE" ] || fail "cannot read reference file $REF_FILE"
    jq -e . "$REF_FILE" >/dev/null 2>&1 || fail "$REF_FILE is not valid JSON"
    cat "$REF_FILE"
    return
  fi
  local out
  out="$(git -C "$REPO_ROOT" show "$REF_REV:$SPEC_PATH" 2>&1)" \
    || fail "cannot read $REF_REV:$SPEC_PATH — the floor has no reference to compare against (failure, never a skip): $out"
  jq -e . <<<"$out" >/dev/null 2>&1 || fail "$REF_REV:$SPEC_PATH is not valid JSON"
  printf '%s' "$out"
}

# The pair, normalized: a missing app_id and an explicit null are the same
# weakening and must compare equal so neither can hide behind the other.
checks_of() {
  jq -S -c '
    .protection.required_status_checks.checks
    // error("no .protection.required_status_checks.checks")
    | map({context: .context, app_id: (.app_id // null)})
    | sort_by(.context, (.app_id | tostring))
  ' 2>/dev/null || fail "input does not carry .protection.required_status_checks.checks"
}

# The `_readme` block, normalized to a list of strings. A spec that carries no
# `_readme` at all yields the empty list, which floors nothing — the reference
# decides how much prose there is to lose, never the candidate. A `_readme` that
# is not an array (the clobber shape is a bare string) is wrapped rather than
# rejected, so the comparison below reports it as the loss it is instead of
# dying on a type error and looking like a broken script.
readme_of() {
  jq -c 'if has("_readme") | not then []
         elif (._readme | type) == "array" then (._readme | map(tostring))
         else [(._readme | tostring)] end' 2>/dev/null \
    || fail "input carries an _readme that could not be read"
}

# `enforced` as one of three words, because ABSENT and `false` are different
# stories and only one of them is a regression from a reference that says true.
enforced_of() {
  jq -r 'if has("enforced") then (.enforced | tostring) else "absent" end' 2>/dev/null \
    || fail "input carries an enforced flag that could not be read"
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --reference) REF_FILE="$2"; shift 2 ;;
      --ref-rev) REF_REV="$2"; shift 2 ;;
      --spec-path) SPEC_PATH="$2"; shift 2 ;;
      --acknowledge-growth) ACK_GROWTH=1; shift ;;
      --quiet) QUIET=1; shift ;;
      -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
      -*) fail "unknown argument: $1" ;;
      *) [ -z "$CANDIDATE" ] || fail "exactly one candidate spec, got a second: $1"
         CANDIDATE="$1"; shift ;;
    esac
  done

  [ -n "$CANDIDATE" ] || fail "no candidate spec given (usage: $0 [--reference REF] <candidate.json>)"
  [ -f "$CANDIDATE" ] || fail "cannot read candidate spec $CANDIDATE"
  jq -e . "$CANDIDATE" >/dev/null 2>&1 || fail "$CANDIDATE is not valid JSON"

  local ref want got
  ref="$(read_reference)"
  want="$(printf '%s' "$ref" | checks_of)"
  got="$(checks_of < "$CANDIDATE")"

  # A reference that requires nothing cannot floor anything. Say so rather than
  # returning the vacuous pass.
  [ "$(jq 'length' <<<"$want")" -gt 0 ] \
    || fail "the reference lists ZERO required contexts — there is no floor to hold"
  [ "$(jq 'length' <<<"$got")" -gt 0 ] \
    || fail "the candidate lists ZERO required contexts — a spec that requires nothing cannot fail"

  local lost gained
  lost="$(jq -r --argjson g "$got" '[.[] | select(. as $w | $g | index($w) | not)] | .[] | "\(.context)\t\(.app_id // "null")"' <<<"$want")"
  gained="$(jq -r --argjson w "$want" '[.[] | select(. as $g | $w | index($g) | not)] | .[] | "\(.context)\t\(.app_id // "null")"' <<<"$got")"

  # The other two floored fields. Read here rather than inside the `if`s so a
  # candidate that breaches on several axes at once reports ALL of them in one
  # run — a guard that names one loss and hides the next teaches the reader to
  # fix and re-run instead of to look.
  local want_readme got_readme readme_lost want_enforced got_enforced enforced_regressed
  want_readme="$(printf '%s' "$ref" | readme_of)"
  got_readme="$(readme_of < "$CANDIDATE")"
  readme_lost="$(jq -r --argjson g "$got_readme" '[.[] | select(IN($g[]) | not)] | .[] | (if length > 96 then .[0:96] + " …" else . end)' <<<"$want_readme")"  # README-LOSS CLAUSE
  want_enforced="$(printf '%s' "$ref" | enforced_of)"
  got_enforced="$(enforced_of < "$CANDIDATE")"
  enforced_regressed=0
  [ "$want_enforced" != "true" ] || [ "$got_enforced" = "true" ] || enforced_regressed=1  # ENFORCED-REGRESSION CLAUSE

  local breached=0
  local ref_label
  ref_label="$( [ -n "$REF_FILE" ] && printf '%s' "$REF_FILE" || printf '%s:%s' "$REF_REV" "$SPEC_PATH" )"

  # The words the PASS line uses. A reference that carries no `_readme` and no
  # `enforced` floors neither, and the summary must SAY that rather than imply a
  # check it did not make.
  local readme_note enforced_note
  if [ "$(jq 'length' <<<"$want_readme")" -eq 0 ]; then
    readme_note="the reference carries no _readme, so none is floored"
  else
    readme_note="all $(jq 'length' <<<"$want_readme") committed _readme entr(y/ies) still present"
  fi
  if [ "$want_enforced" = "true" ]; then
    enforced_note="enforced still true"
  else
    enforced_note="the reference does not say enforced=true (it says $want_enforced), so no enforcement floor applies"
  fi

  if [ -n "$lost" ]; then
    {
      echo "FLOOR BREACH — the candidate spec is NOT a superset of $ref_label."
      echo "Every line below is a gate that is live on the protected branch today and would stop being one:"
      printf '%s\n' "$lost" | sed 's/^/  LOST  /'
      echo
      echo "A count floor (>= N) would have PASSED a swap that keeps the count and drops the only blocking gate."
      echo "Regenerate from heads where every required job actually ran, or, if the removal is intended,"
      echo "change the reference on main in a PR that says why — never by letting a sample shrink the set."
    } >&2
    breached=1
  fi

  if [ "$enforced_regressed" -eq 1 ]; then
    {
      echo "FLOOR BREACH — ENFORCED REGRESSED: $ref_label says enforced=true, the candidate says $got_enforced."
      echo "This is not a flag about intent. required-checks-verify.sh SKIPS the live-protection diff on an"
      echo "enforced=false spec, so committing this turns the repo's only three-way drift guard into a green"
      echo "that never looked. required-checks-apply.sh refuses it on the WRITE path; nothing was watching the"
      echo "COMMIT path, which is how a regenerated spec carries the flip in."
      echo "The generator emits enforced=false by design — set it back to true before committing."
    } >&2
    breached=1
  fi

  if [ -n "$readme_lost" ]; then
    {
      echo "FLOOR BREACH — README LOST: $(jq 'length' <<<"$want_readme") entr(y/ies) in $ref_label, $(jq 'length' <<<"$got_readme") in the candidate,"
      echo "and the paragraph(s) below are present in the reference and ABSENT from the candidate:"
      printf '%s\n' "$readme_lost" | sed 's/^/  LOST README  /'
      echo
      echo "_readme is the only place this repo records WHY each name is required and why a count floor is not"
      echo "enough, and losing it reds no gate at all — it deletes the reason the gates exist. The two shapes"
      echo "that reach here: \`required-checks-generate.sh --no-merge\` (greenfield, keeps only the paragraphs the"
      echo "generator owns), and a regeneration that flipped \`enforced\`, which rewrites the enforced= paragraph."
      echo "Carry the committed paragraphs forward, or, if a rewrite is intended, land it on main in a PR that"
      echo "says why — the same escape hatch a removed context has."
    } >&2
    breached=1
  fi

  [ "$breached" -eq 0 ] || exit 1

  if [ -n "$gained" ]; then
    {
      echo "FLOOR: the candidate ADDS required context(s). This is a decision, not a detail —"
      echo "every PR in this repo must render these forever, and a job that is green today and"
      echo "paths-filtered tomorrow deadlocks main (D69)."
      printf '%s\n' "$gained" | sed 's/^/  ADDED  /'
    } >&2
    if [ "$ACK_GROWTH" -eq 1 ]; then
      echo "FLOOR OK: superset held; growth ACKNOWLEDGED (--acknowledge-growth), $(jq 'length' <<<"$got") context(s); $readme_note; $enforced_note."
      exit 0
    fi
    echo "Re-run with --acknowledge-growth once a human has decided each added name belongs." >&2
    exit 2
  fi

  # Name every axis that was actually checked. A summary that says "identical on
  # context AND app_id" while silently not looking at `_readme` is how this
  # script spent its whole life so far reading as more thorough than it was.
  [ "$QUIET" -eq 1 ] || echo "FLOOR OK: the candidate holds the floor exactly — $(jq 'length' <<<"$got") context(s), identical on context AND app_id; $readme_note; $enforced_note."
  exit 0
}

main "$@"
