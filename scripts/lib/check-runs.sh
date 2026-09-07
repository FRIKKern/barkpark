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
# THE WIDE ROW. The two incumbents need columns the sampler does not: the
# generator's R4 rule keys on `app.id`, and the verifier's PENDING line prints
# `status` and `started_at`. A private copy per extra column is how the fork got
# here in the first place, so the transform emits FIVE columns
# (`name conclusion status started_at app_id`) as `check_runs_rows_ext`, and
# `check_runs_rows` is that same read projected to its first three. One read,
# one dedup, one sort — the callers pick their columns.
#
# THE READ IS PAGED AND PROVES ITS OWN COMPLETENESS. `?per_page=100` alone is a
# silent truncation at 100 (measured: head 5df2cea8c, total_count 104, 100 rows
# returned, 15 NAMES invisible). The live read now walks pages and asserts the
# accumulated count against the feed's own `total_count`; it REFUSES rather than
# emitting a set it cannot vouch for. Cost is demand-driven — page one carries
# total_count, so a head under 100 runs still costs exactly one request.
#
# USAGE (unchanged)
#   . "$REPO_ROOT/scripts/lib/check-runs.sh"
#   rows="$(check_runs_rows "$repo" "$full_sha" "$fixture_dir")" || handle
#   wide="$(check_runs_rows_ext "$repo" "$full_sha" "$fixture_dir")" || handle
#   wide="$(check_runs_rows_file "$explicit_json_path" "$sha")" || handle
#   conclusion="$(check_runs_conclusion "$rows" 'Console gate')"   # "" if absent

# Guard against double-sourcing (the lib carries no state, but a caller that
# sources it in a loop should not pay for it).
if [ -n "${BARKPARK_CHECK_RUNS_LIB_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
BARKPARK_CHECK_RUNS_LIB_LOADED=1

# _check_runs_tsv <json> <label>  (INTERNAL)
#
# The one transform: validate the payload shape, reject unreadable elements,
# keep the LATEST row per name, sort. Prints five tab-separated columns —
# `name conclusion status started_at app_id`. Returns 2 when the payload cannot
# be read at all, and 0 (with no rows) when it is legitimately empty.
_check_runs_tsv() {
  local json="$1" label="$2" tsv

  # A payload that is not even shaped like the feed is unreadable, not empty.
  jq -e 'has("check_runs") and (.check_runs | type == "array")' >/dev/null 2>&1 <<<"$json" || {
    echo "check-runs: malformed check-runs payload for $label" >&2
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
  tsv="$(jq -r '
      .check_runs
      | map(
          if type != "object" then error("non-object element in check_runs")
          elif ((.name // "") | tostring) == "" then error("check run with an empty name")
          else . end)
      | sort_by(.started_at // "") | .[]
      | [ .name, (.conclusion // "null"), (.status // "null"),
          (.started_at // ""), ((.app.id // 0) | tostring) ] | @tsv' <<<"$json" 2>&1)" || {
    echo "check-runs: unreadable check_runs elements for $label — $(printf '%s' "$tsv" | head -1 | cut -c1-200) (refusing to emit rows)" >&2
    return 2
  }
  [ -n "$tsv" ] || return 0
  printf '%s\n' "$tsv" \
    | awk -F'\t' '{ seen[$1] = $0 } END { for (n in seen) print seen[n] }' \
    | LC_ALL=C sort
}

# check_runs_rows_file <path> [label]
#
# The wide row read from an EXPLICIT json file rather than a fixture directory
# — `required-checks-verify.sh --runs <file>` names one file, not a directory
# keyed by sha, and that difference is the whole reason it used to keep its own
# copy of the reader. Same return contract: 2 when the file cannot be read, 0
# (no rows) when the feed is legitimately empty.
check_runs_rows_file() {
  local file="$1"
  local label="${2:-$file}"
  if [ ! -f "$file" ]; then
    echo "check-runs: cannot read check-runs file $file" >&2
    return 2
  fi
  _check_runs_tsv "$(cat "$file")" "$label"
}

# ── THE PAGED READ, AND WHY A COMPLETENESS PROOF AND NOT JUST `--paginate` ────
#
# MEASURED 2026-09-07: `repos/FRIKKern/barkpark/commits/5df2cea8c/check-runs?per_page=100`
# answers `total_count: 104` and hands back exactly 100 elements. The REST API
# caps a page at 100 and says NOTHING about the remainder — no error, no flag on
# the payload, just a short array. A reader that stops there is not wrong-looking,
# it is silently blind, and it fails in the REASSURING direction: the required-
# check census asks "does every name rendered on this head carry a status in the
# spec?", so fewer names read means fewer unaccounted names found and the census
# reports CLEANER than the truth. An absence it reports is not an absence.
#
# WHY NOT `gh api --paginate`. --paginate walks Link headers and, for an OBJECT
# response like this one, emits one JSON object PER PAGE — it does not merge, and
# `--slurp` (which does) is a newer gh flag this repo cannot assume on every
# runner. More importantly --paginate has no notion of "did I get everything": if
# a page fails mid-walk it is indistinguishable from a short feed. So the loop is
# explicit and it ENDS IN A PROOF: the accumulated element count must equal the
# `total_count` the API itself reported. Anything else REFUSES.
#
# COST. `total_count` arrives on PAGE ONE, so a head with <= 100 runs costs
# exactly the one request it always cost — ZERO delta on the ordinary case. Only
# a head that actually carries more pays for more, and it pays ceil(total/100)-1
# extra requests. This matters: two consumers call this in a loop over many heads
# (registration-sample.sh, required-checks-generate.sh) and this repo has already
# spent its REST budget once in a day.
#
# THE CAP IS EXPLICIT, NOT AN ACCIDENT. The old bound was "whatever one page
# holds", which nobody chose. BARKPARK_CHECK_RUNS_MAX_PAGES is a real ceiling on
# what one head may cost, and hitting it REFUSES rather than returning the pages
# it managed — a bounded read that returns rows is the same lie in a smaller hat.
: "${BARKPARK_CHECK_RUNS_MAX_PAGES:=20}"

# _check_runs_fetch <repo> <sha>  (INTERNAL)
#
# Prints a SINGLE `{total_count, check_runs}` payload carrying every check run on
# the head, or returns 2 having printed nothing on stdout. Never prints a partial
# feed: a truncated read must not be byte-identical to a genuinely small one.
_check_runs_fetch() {
  local repo="$1" sha="$2"
  local page=1 body acc total got prev

  body="$(gh api "repos/$repo/commits/$sha/check-runs?per_page=100&page=1" 2>/dev/null)" || {
    echo "check-runs: cannot read check-runs for $sha (an unreadable feed is a failure, not an empty set)" >&2
    return 2
  }

  # A payload that is not shaped like the feed is the TRANSFORM's ruling, not
  # this function's — hand page one through unchanged so _check_runs_tsv issues
  # its documented "malformed check-runs payload" refusal with its own wording.
  jq -e 'has("check_runs") and (.check_runs | type == "array")' >/dev/null 2>&1 <<<"$body" || {
    printf '%s\n' "$body"
    return 0
  }

  acc="$(jq -c '.check_runs' <<<"$body")"
  got="$(jq -r 'length' <<<"$acc")"

  # `total_count` is the API's OWN statement of how many runs exist. Without it
  # completeness cannot be proven, so a full page with no total is a refusal, not
  # an answer. A SHORT page with no total is fine: a page the API did not fill is
  # the end of the feed.
  total="$(jq -r 'if (.total_count | type) == "number" then .total_count else "" end' <<<"$body")"
  if [ -z "$total" ]; then
    if [ "$got" -ge 100 ]; then
      echo "check-runs: check-runs feed for $sha returned a FULL page ($got) with no total_count — completeness cannot be proven, refusing to emit a possibly-truncated set" >&2
      return 2
    fi
    printf '%s\n' "$body"
    return 0
  fi

  if [ "$total" -gt $((BARKPARK_CHECK_RUNS_MAX_PAGES * 100)) ]; then
    echo "check-runs: $sha carries $total check runs, over the $BARKPARK_CHECK_RUNS_MAX_PAGES-page ceiling ($((BARKPARK_CHECK_RUNS_MAX_PAGES * 100))) — refusing rather than returning a bounded read that reads like a complete one (raise BARKPARK_CHECK_RUNS_MAX_PAGES deliberately)" >&2
    return 2
  fi

  while [ "$got" -lt "$total" ]; do
    page=$((page + 1))
    if [ "$page" -gt "$BARKPARK_CHECK_RUNS_MAX_PAGES" ]; then
      echo "check-runs: hit the $BARKPARK_CHECK_RUNS_MAX_PAGES-page ceiling for $sha with $got of $total runs read — refusing (a partial read must never look like a small feed)" >&2
      return 2
    fi
    body="$(gh api "repos/$repo/commits/$sha/check-runs?per_page=100&page=$page" 2>/dev/null)" || {
      echo "check-runs: cannot read check-runs page $page for $sha ($got of $total runs read) — refusing the partial set" >&2
      return 2
    }
    jq -e 'has("check_runs") and (.check_runs | type == "array")' >/dev/null 2>&1 <<<"$body" || {
      echo "check-runs: malformed check-runs payload on page $page for $sha ($got of $total runs read) — refusing the partial set" >&2
      return 2
    }
    # A page that adds nothing cannot terminate the walk quietly — that is the
    # infinite loop's exit AND the truncation's disguise, so it is a refusal.
    acc="$(jq -c --argjson p "$(jq -c '.check_runs' <<<"$body")" '. + $p' <<<"$acc")" || {
      echo "check-runs: cannot accumulate page $page for $sha — refusing the partial set" >&2
      return 2
    }
    prev="$got"
    got="$(jq -r 'length' <<<"$acc")"
    if [ "$got" -le "$prev" ]; then
      echo "check-runs: page $page for $sha added no runs while $prev of $total were read — refusing the partial set" >&2
      return 2
    fi
  done

  # THE PROOF. Not a comment, a comparison: what we hold must equal what the API
  # said exists. A re-run landing mid-walk can move this; that is still a refusal,
  # because a set we cannot vouch for is exactly what this function exists to
  # stop being returned silently.
  if [ "$got" -ne "$total" ]; then
    echo "check-runs: read $got check runs for $sha but the feed reports total_count $total — refusing (the set cannot be vouched for; a re-run may have landed mid-read, retry)" >&2
    return 2
  fi

  jq -c -n --argjson runs "$acc" --argjson total "$total" '{total_count: $total, check_runs: $runs}'
}

# check_runs_rows_ext <repo> <sha> [fixture_dir]
#
# Prints `name<TAB>conclusion<TAB>status<TAB>started_at<TAB>app_id`, one row per
# name, sorted. Returns 0 on a readable feed (INCLUDING an empty one) and 2 when
# the feed cannot be read at all — the caller must treat 2 as a failure, never
# as "no checks". `conclusion` is the literal string `null` while a run is in
# flight, matching the API rather than inventing a sentinel.
check_runs_rows_ext() {
  local repo="$1" sha="$2" fixture_dir="${3:-}" json fixture

  if [ -n "$fixture_dir" ]; then
    fixture="$fixture_dir/checkruns-$sha.json"
    if [ ! -f "$fixture" ]; then
      echo "check-runs: no fixture $fixture" >&2
      return 2
    fi
    json="$(cat "$fixture")"
  else
    # The read is PAGED and proves its own completeness — see _check_runs_fetch.
    json="$(_check_runs_fetch "$repo" "$sha")" || return 2
  fi

  _check_runs_tsv "$json" "$sha"
}

# check_runs_rows <repo> <sha> [fixture_dir]
#
# The narrow projection of check_runs_rows_ext: `name<TAB>conclusion<TAB>status`.
# Same return contract, and the projection is a SEPARATE statement rather than a
# pipe off the reader — in a pipeline the reader's `return 2` would be discarded
# for `cut`'s 0 under default shell options, which is exactly the silent empty
# set the header forbids.
check_runs_rows() {
  local ext rc=0
  ext="$(check_runs_rows_ext "$@")" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ -n "$ext" ] || return 0
  printf '%s\n' "$ext" | cut -f1-3
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
