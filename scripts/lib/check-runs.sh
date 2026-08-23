#!/usr/bin/env bash
#
# lib/check-runs.sh — the ONE way this repo reads a commit's check runs.
#
# WHY A LIB AND NOT A THIRD COPY
# ------------------------------
# `required-checks-generate.sh` (fetch_check_runs) and `required-checks-verify.sh`
# (rendered_names) are the same function with cosmetic drift — a different
# fixture variable, a different error verb, a third TSV column. A third
# hand-rolled copy is literally the defect class this epic exists to remove, so
# the sampler sources this instead. The two incumbents are DELIBERATELY not
# refactored to adopt it in the same change: a concurrent slice owns those files,
# and a shared primitive lands honestly only when its first caller proves it.
#
# THE ONE DELIBERATE DIVERGENCE: EMPTINESS IS THE CALLER'S RULING
# --------------------------------------------------------------
# Both incumbents `die` on an empty feed, and for a GENERATOR that is right — a
# spec generated from nothing is a cheerfully empty required set. For a SAMPLER
# it is the opposite: a head whose feed is empty (measured: 23313e9a5,
# total_count=0) is the CADENCE datum, the single most informative row in the
# table. A primitive that dies there cannot be shared. So:
#
#   * an UNREADABLE feed is still fail-closed — non-zero return, nothing on
#     stdout. Never a silent empty set.
#   * an EMPTY feed returns 0 rows and exit 0. The caller rules on what that
#     means.
#
# OUTPUT: one row per check-run NAME, `name<TAB>conclusion<TAB>status`, sorted.
# A re-run leaves two rows for one name; the LATEST by started_at wins, because
# the older one is not what the branch protection will read.
#
# USAGE
#   . "$REPO_ROOT/scripts/lib/check-runs.sh"
#   rows="$(check_runs_rows "$repo" "$full_sha" "$fixture_dir")" || handle
#   conclusion="$(check_runs_conclusion "$rows" 'Console gate')"   # "" if absent

# Guard against double-sourcing (the lib carries no state, but a caller that
# sources it in a loop should not pay for it).
if [ -n "${BARKPARK_CHECK_RUNS_LIB_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
BARKPARK_CHECK_RUNS_LIB_LOADED=1

# check_runs_rows <repo> <sha> [fixture_dir]
#
# Prints `name<TAB>conclusion<TAB>status`, one row per name, sorted.
# Returns 0 on a readable feed (INCLUDING an empty one) and 2 when the feed
# cannot be read at all — the caller must treat 2 as a failure, never as "no
# checks". `conclusion` is the literal string `null` while a run is in flight,
# matching the API rather than inventing a sentinel.
check_runs_rows() {
  local repo="$1" sha="$2" fixture_dir="${3:-}" json fixture

  if [ -n "$fixture_dir" ]; then
    fixture="$fixture_dir/checkruns-$sha.json"
    if [ ! -f "$fixture" ]; then
      echo "check-runs: no fixture $fixture" >&2
      return 2
    fi
    json="$(cat "$fixture")"
  else
    json="$(gh api "repos/$repo/commits/$sha/check-runs?per_page=100" 2>/dev/null)" || {
      echo "check-runs: cannot read check-runs for $sha (an unreadable feed is a failure, not an empty set)" >&2
      return 2
    }
  fi

  # A payload that is not even shaped like the feed is unreadable, not empty.
  jq -e 'has("check_runs") and (.check_runs | type == "array")' >/dev/null 2>&1 <<<"$json" || {
    echo "check-runs: malformed check-runs payload for $sha" >&2
    return 2
  }

  # No rows is a legal, informative answer — but the transform must OWN its
  # status. As a plain pipeline this function returned SORT's exit code, so a
  # payload whose elements broke jq mid-stream (measured: {"check_runs":[1,…]},
  # bare jq rc 5) returned 0 with EMPTY rows under the shell's default options
  # — the silent empty set the header forbids — and only a caller that happened
  # to set pipefail saw the failure. Capture the jq stage first so the
  # documented return 2 holds under ANY caller options, and reject non-object
  # elements and nameless runs as unreadable rather than emitting phantom rows.
  local tsv
  tsv="$(jq -r '
      .check_runs
      | map(
          if type != "object" then error("non-object element in check_runs")
          elif ((.name // "") | tostring) == "" then error("check run with an empty name")
          else . end)
      | sort_by(.started_at // "") | .[]
      | [ .name, (.conclusion // "null"), (.status // "null") ] | @tsv' <<<"$json" 2>&1)" || {
    echo "check-runs: unreadable check_runs elements for $sha — $(printf '%s' "$tsv" | head -1 | cut -c1-200) (refusing to emit rows)" >&2
    return 2
  }
  [ -n "$tsv" ] || return 0
  printf '%s\n' "$tsv" \
    | awk -F'\t' '{ seen[$1] = $0 } END { for (n in seen) print seen[n] }' \
    | LC_ALL=C sort
}

# check_runs_conclusion <rows> <name>
# Prints the conclusion for an exact check-run name, or nothing when the name is
# absent. Exact match on the full field — a substring match would let
# `Cloud gate (legacy)` answer for `Cloud gate`.
check_runs_conclusion() {
  local rows="$1" name="$2"
  awk -F'\t' -v want="$name" '$1 == want { print $2; exit }' <<<"$rows"
}

# check_runs_present <rows> <name> — 0 when the name rendered at all.
check_runs_present() {
  local rows="$1" name="$2"
  awk -F'\t' -v want="$name" '$1 == want { found = 1 } END { exit(found ? 0 : 1) }' <<<"$rows"
}
