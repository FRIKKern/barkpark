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
# silent truncation at 100 (measured 2026-09-07: head 33799f6d8, total_count 122,
# 100 rows returned, 22 NAMES invisible). The live read now walks pages and asserts the
# accumulated count against the feed's own `total_count`; it REFUSES rather than
# emitting a set it cannot vouch for. Cost is demand-driven — page one carries
# total_count, so a head under 100 runs still costs exactly one request.
#
# USAGE (unchanged)
#   . "$REPO_ROOT/scripts/lib/check-runs.sh"
#   rows="$(check_runs_rows "$repo" "$full_sha" "$fixture_dir")" || handle
#   wide="$(check_runs_rows_ext "$repo" "$full_sha" "$fixture_dir")" || handle
#   wide="$(check_runs_rows_file "$explicit_json_path" "$sha")" || handle
#   feed="$(check_runs_feed "$repo" "$full_sha")" || handle   # raw, complete, proven
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
# MEASURED 2026-09-07: `repos/FRIKKern/barkpark/commits/33799f6d8/check-runs?per_page=100`
# answers `total_count: 122` and hands back exactly 100 elements — hiding 22 distinct
# names (73 unpaged vs 95 paged), among them `Doc budgets + anchors`, seven
# `Dispatch (...)` jobs and three path-escape ratchets.
#
# PICK THE SPECIMEN BY NAMES, NOT BY RUN COUNT — a row-count over 100 does NOT imply a
# hidden name. This comment first cited head 5df2cea8c (total_count 104), which hides
# ZERO names: its 104 runs carry only 49 distinct names and page one already holds all
# 49. Re-measured both directions with a control (a 95-run head also yields 0), so the
# rule is that reruns inflate the COUNT without adding NAMES. The REST API
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

# ── THE BOUNDED RETRY, AND WHY IT IS OPT-IN ─────────────────────────────────
#
# THE OBSERVED FAULT (measured 2026-09-11, 3 of 5 merges). scripts/bp-merge.sh's
# pre-flight refused with `BLOCKED: cannot read check runs for <sha>` and the
# SAME command 15-20 s later, against the SAME head with no push in between,
# read the feed and merged. GitHub's check-runs pagination is not a snapshot: a
# run created between page 1 and page 2 moves the accumulated length off the
# `total_count` page 1 reported, and the completeness proof below — correctly —
# refuses the set it cannot vouch for. Its own refusal already ends in the word
# `retry`. Until this commit the thing that retried was a human.
#
# WHAT IS RETRIED, AND WHAT IS NEVER. Only refusals whose CAUSE is the read
# being taken twice at different instants, or the far end being briefly
# unavailable:
#
#   * the completeness proof failing (`read N … but the feed reports total_count M`)
#   * a mid-walk page that adds no rows while rows are still outstanding
#   * a `gh api` call that failed with a 5xx / 429 / rate limit / a dropped
#     connection — the classes that clear on their own
#
# NEVER retried, because a second identical read returns the identical answer
# and the delay would be pure theatre: a malformed payload, a feed over the page
# ceiling, a FULL page with no `total_count`, an accumulation failure, and every
# `gh` failure that is not in the transient set (401/403/404 above all — a bad
# credential is not a blip, and retrying one hides it behind a timeout).
#
# IT IS OPT-IN (`BARKPARK_CHECK_RUNS_RETRIES`, default 1 = one attempt, today's
# behaviour exactly) because two consumers call this IN A LOOP OVER MANY HEADS
# (registration-sample.sh, required-checks-generate.sh) and a per-head sleep
# there multiplies into minutes for no benefit — they already tolerate a hole.
# The merge verb, which reads ONE head and whose refusal costs a human a manual
# rerun, opts in: see scripts/bp-merge.sh.
#
# THE REFUSAL WORDING DOES NOT MOVE. Each attempt prints its own reason, in the
# incumbent wording, from the same lines below; the wrapper adds only a
# `check-runs: … retrying in Ns` note BETWEEN attempts. A read that never
# settles refuses with the last attempt's line — byte-identical to today's — and
# returns 2 with ZERO bytes on stdout. A retry that ran out is still a refusal.
: "${BARKPARK_CHECK_RUNS_RETRIES:=1}"
: "${BARKPARK_CHECK_RUNS_RETRY_SLEEP:=10}"

# _check_runs_transient_gh_err <stderr text>  (INTERNAL)
#
# TRUE only for the `gh api` failures that clear on their own. Keyed on gh's own
# stderr, which is the only place the status ever appears. Deliberately narrow:
# anything unrecognised is PERMANENT, so a new failure shape is refused at once
# rather than silently costing three sleeps before saying the same thing.
_check_runs_transient_gh_err() {
  case "$1" in
    *"HTTP 500"*|*"HTTP 502"*|*"HTTP 503"*|*"HTTP 504"*|*"HTTP 429"*) return 0 ;;
    *"rate limit"*|*"Rate limit"*|*"secondary rate"*)                 return 0 ;;
    *"was reset by peer"*|*"connection reset"*|*"Connection reset"*)  return 0 ;;
    *"EOF"*|*"i/o timeout"*|*"Client.Timeout"*|*"TLS handshake timeout"*) return 0 ;;
    *) return 1 ;;
  esac
}

# _check_runs_fetch <repo> <sha>  (INTERNAL)
#
# Prints a SINGLE `{total_count, check_runs}` payload carrying every check run on
# the head, or returns 2 having printed nothing on stdout. Never prints a partial
# feed: a truncated read must not be byte-identical to a genuinely small one.
#
# The RETRY LADDER lives here; the read itself is _check_runs_fetch_once, which
# returns 3 (never seen by a caller) for a refusal this wrapper may take again
# and 2 for one it must not. Whatever the ladder ends on, the caller sees 0 or 2.
_check_runs_fetch() {
  local repo="$1" sha="$2"
  local attempts="$BARKPARK_CHECK_RUNS_RETRIES" n=1 rc
  [ "$attempts" -ge 1 ] 2>/dev/null || attempts=1
  while : ; do
    rc=0
    _check_runs_fetch_once "$repo" "$sha" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    # 3 is the ONE-SHOT's private "you may take this again". It must never reach
    # a caller: every exit of this wrapper is the documented 0 or 2.
    if [ "$rc" -eq 3 ] && [ "$n" -lt "$attempts" ]; then
      echo "check-runs: that refusal is a TRANSIENT read (attempt $n of $attempts) — retrying in ${BARKPARK_CHECK_RUNS_RETRY_SLEEP}s" >&2
      sleep "$BARKPARK_CHECK_RUNS_RETRY_SLEEP"
      n=$((n + 1))
      continue
    fi
    if [ "$rc" -eq 3 ] && [ "$attempts" -gt 1 ]; then
      echo "check-runs: $attempts attempts all refused — this is no longer a blip, and a retry that ran out is still a refusal" >&2
    fi
    return 2
  done
}

# _check_runs_fetch_once <repo> <sha>  (INTERNAL)
#
# ONE read. Returns 0 having printed the payload, 3 on a refusal whose cause is
# transient (see the ladder above), or 2 on one that is not. Prints NOTHING on
# stdout on any non-zero return.
_check_runs_fetch_once() {
  local repo="$1" sha="$2"
  local page=1 body acc total got prev err page_runs

  # gh's OWN stderr is carried into the refusal rather than swallowed. It is the
  # only place `Bad credentials` / `HTTP 401` ever appears, and a caller that
  # grades a credential fault differently from a network blip (the census exits
  # 3 on one and 2 on the other) cannot make that call off a message this
  # function paraphrased. `2>/dev/null` here was a silent downgrade of every
  # such caller to "could not read".
  err="$(mktemp)"
  body="$(gh api "repos/$repo/commits/$sha/check-runs?per_page=100&page=1" 2>"$err")" || {
    echo "check-runs: cannot read check-runs for $sha (an unreadable feed is a failure, not an empty set) — $(head -3 "$err" | tr '\n' ' ' | cut -c1-400)" >&2
    _check_runs_transient_gh_err "$(cat "$err")" && { rm -f "$err"; return 3; }
    rm -f "$err"
    return 2
  }

  # A payload that is not shaped like the feed is the TRANSFORM's ruling, not
  # this function's — hand page one through unchanged so _check_runs_tsv issues
  # its documented "malformed check-runs payload" refusal with its own wording.
  jq -e 'has("check_runs") and (.check_runs | type == "array")' >/dev/null 2>&1 <<<"$body" || {
    printf '%s\n' "$body"
    rm -f "$err"
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
      rm -f "$err"
      return 2
    fi
    printf '%s\n' "$body"
    rm -f "$err"
    return 0
  fi

  if [ "$total" -gt $((BARKPARK_CHECK_RUNS_MAX_PAGES * 100)) ]; then
    echo "check-runs: $sha carries $total check runs, over the $BARKPARK_CHECK_RUNS_MAX_PAGES-page ceiling ($((BARKPARK_CHECK_RUNS_MAX_PAGES * 100))) — refusing rather than returning a bounded read that reads like a complete one (raise BARKPARK_CHECK_RUNS_MAX_PAGES deliberately)" >&2
    rm -f "$err"
    return 2
  fi

  while [ "$got" -lt "$total" ]; do
    page=$((page + 1))
    if [ "$page" -gt "$BARKPARK_CHECK_RUNS_MAX_PAGES" ]; then
      echo "check-runs: hit the $BARKPARK_CHECK_RUNS_MAX_PAGES-page ceiling for $sha with $got of $total runs read — refusing (a partial read must never look like a small feed)" >&2
      rm -f "$err"
      return 2
    fi
    body="$(gh api "repos/$repo/commits/$sha/check-runs?per_page=100&page=$page" 2>"$err")" || {
      echo "check-runs: cannot read check-runs page $page for $sha ($got of $total runs read) — refusing the partial set — $(head -3 "$err" | tr '\n' ' ' | cut -c1-400)" >&2
      _check_runs_transient_gh_err "$(cat "$err")" && { rm -f "$err"; return 3; }
      rm -f "$err"
      return 2
    }
    jq -e 'has("check_runs") and (.check_runs | type == "array")' >/dev/null 2>&1 <<<"$body" || {
      echo "check-runs: malformed check-runs payload on page $page for $sha ($got of $total runs read) — refusing the partial set" >&2
      rm -f "$err"
      return 2
    }
    # A page that adds nothing cannot terminate the walk quietly — that is the
    # infinite loop's exit AND the truncation's disguise, so it is a refusal.
    # Same rule as the assembly below: nothing that scales with the feed goes on
    # argv. This one put ONE PAGE there (the accumulator was already on stdin), so
    # it is bounded at 100 runs - but at the ~3,076 bytes/run measured on this
    # repo a full page is ~307KB, still 2.3x the 131072-byte per-argument cap. It
    # is dormant only because a >100-run sha is needed to reach the loop at all.
    # Two JSON values on stdin, slurped: no argument grows with the data.
    page_runs="$(jq -c '.check_runs' <<<"$body")"
    acc="$(jq -c -s '.[0] + .[1]' <<<"$acc"$'\n'"$page_runs")" || {
      echo "check-runs: cannot accumulate page $page for $sha — refusing the partial set" >&2
      rm -f "$err"
      return 2
    }
    prev="$got"
    got="$(jq -r 'length' <<<"$acc")"
    if [ "$got" -le "$prev" ]; then
      echo "check-runs: page $page for $sha added no runs while $prev of $total were read — refusing the partial set" >&2
      rm -f "$err"
      return 3
    fi
  done

  # THE PROOF. Not a comment, a comparison: what we hold must equal what the API
  # said exists. A re-run landing mid-walk can move this; that is still a refusal,
  # because a set we cannot vouch for is exactly what this function exists to
  # stop being returned silently.
  if [ "$got" -ne "$total" ]; then
    echo "check-runs: read $got check runs for $sha but the feed reports total_count $total — refusing (the set cannot be vouched for; a re-run may have landed mid-read, retry)" >&2
    rm -f "$err"
    return 3
  fi

  rm -f "$err"
  # THE FEED GOES ON STDIN, NEVER ARGV. This line used to pass the whole
  # accumulated payload as ONE argument, and Linux caps a SINGLE argument at
  # MAX_ARG_STRLEN = 32 * PAGE_SIZE = 131072 bytes regardless of ARG_MAX. Real
  # feeds passed that long ago: the sha this was measured on (d580983459) carries
  # 83 runs / 255,330 bytes compact - 1.9x the cap, ~3,076 bytes per run, so only
  # ~42 runs fit. Past that, exec fails with "Argument list too long", the
  # function cannot return, and the guard goes BLIND EXACTLY WHEN THE FEED IS
  # BIGGEST. It failed closed, which is the only reason it was survivable and the
  # reason nobody saw it. "$total" stays on argv: it is a bounded integer.
  printf '%s' "$acc" | jq -c --argjson total "$total" '{total_count: $total, check_runs: .}'
}

# check_runs_feed <repo> <sha>
#
# THE COMPLETE FEED, RAW — `{total_count, check_runs}` as one JSON object, or a
# refusal (return 2, ZERO bytes on stdout, a `check-runs: …` line on stderr).
# Same paged read and same completeness proof as check_runs_rows_ext; only the
# shape differs.
#
# WHY A SECOND PUBLIC SHAPE AND NOT "JUST USE THE TSV". Two callers outside this
# lib read columns the TSV does not carry AND must not inherit its dedup:
#
#   * release-scan.sh needs `.check_suite.id` per run, and its advisory
#     derivation counts REDS PER SUITE — `$reds_per_suite[...] == 1` is the
#     whole "sole red in a red suite" proof. `check_runs_rows*` keeps the LATEST
#     row per NAME, which is right for a required-context census and would
#     silently collapse two reds of the same name into one here, turning
#     "cannot_tell" into a confident "blocking".
#   * absent-context-census.sh emits `{name, status, conclusion}` NDJSON and
#     grades a credential fault (exit 3) apart from an unreadable feed (exit 2).
#
# Handing them the raw feed is the alternative to a third hand-rolled paging
# loop — the defect class this lib exists to remove. The PROOF is shared; the
# projection stays the caller's.
check_runs_feed() {
  _check_runs_fetch "$1" "$2"
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
