#!/usr/bin/env bash
# stale-verdict-watch.sh — a CONFLICTED pull request re-dispatches zero runs and
# keeps asserting the green required verdict it earned on a head main has since
# passed. This is the LEVEL check that says so, every 30 minutes, out loud.
#
# WHAT IT ACTUALLY WATCHES
#
# A PR whose merge is CONFLICTING cannot be merged and cannot be re-run: GitHub
# dispatches nothing until someone pushes to its head. Measured on #10944 —
# every workflow run on its head was created at the push instant with
# run_attempt=1, and 49 commits have landed on main since. The checks API keeps
# answering SUCCESS for all four required contexts. That verdict is not a lie
# about the run that produced it; it is a lie about the tree the merge button
# would produce. This script reds for as long as one exists.
#
# BEING MERELY BEHIND IS NOT A DEFECT. main is `strict: false` — a MERGEABLE PR
# behind main is exactly what this repository's merge policy allows, and every
# such PR would otherwise flood this verdict into noise. Only CONFLICTING rows
# are candidates.
#
# IT COUNTS ALL-OF-PRESENT, NEVER OCCURRENCES-OF-SUCCESS
#
# The obvious jq — count rollup entries whose name is required and whose
# conclusion is SUCCESS, then compare to 4 — OVER-REPORTS, and it does so in the
# comforting direction. #10722 and #10720 render FIVE required-named entries,
# because `PR references an active task` appears twice on the same head: once
# FAILURE, once SUCCESS. The SUCCESS occurrences still reach 4, so those PRs are
# counted as fully green and the failing required context is laundered out of
# the report entirely. Measured live: occurrence-counting says TEN, all-of-
# present says EIGHT — a 25% over-report. A context counts as green here only
# when it RENDERED and EVERY entry carrying its name concluded SUCCESS.
#
# `mergeable` IS LAZILY COMPUTED, AND UNKNOWN IS A WARNING ROW
#
# GitHub computes mergeability on demand. The first read after a quiet period
# answers UNKNOWN for rows it has not yet recomputed — reproduced live on
# 2026-08-09, when the FIRST poll returned 39 UNKNOWN of 40 open and the second,
# 12 seconds later, returned 22 CONFLICTING / 18 MERGEABLE. A naive
# `select(.mergeable=="CONFLICTING")` silently DROPS those rows and prints a
# comforting number. This re-polls, and any row still UNKNOWN afterwards is
# printed as a WARNING ROW — never omitted, never counted as clean.
#
# THE PAYLOAD TRAVELS BY FILE, NEVER BY ARGV (honest-gates D44)
#
# This watch shipped passing the whole `gh pr list` payload as a SINGLE argv
# word (`jq -c -n --argjson prs "$prs"`). Linux caps ONE argv string at
# MAX_ARG_STRLEN = 32 * PAGE_SIZE = 131072 bytes, independently of the much
# larger ARG_MAX (2097152 on the same box) — so the number an author would
# check says there is room, and execve fails E2BIG anyway. The live payload is
# ~380 KB, 2.9x the cap: every Linux run died at the jq call, while the same
# payload on macOS computed a full correct verdict. The watch therefore never
# once evaluated its population, and reported the death as a CREDENTIAL fault —
# which was false, the credential had just read 40 PRs. Both payloads (the PR
# list and main's commit dates) now travel by `--slurpfile` from a temp file,
# the idiom scripts/release-scan.sh already carries for the same class.
# `--slurpfile` wraps the file in an OUTER array, hence the `$x[0] as` bindings.
#
# A RED THAT CANNOT CLEAR ITSELF HAS STOPPED WARNING (the ratchet)
#
# This watch was RED on every one of its scheduled runs from 2026-08-08 to
# 2026-09-01 — 8 of the 8 most recent, and hundreds before them. For most of
# that window the population was ONE pull request, #11766, whose four required
# contexts passed at 2026-08-17T10:0*Z and which re-dispatched nothing after.
# Its own error line said so: "this cannot clear itself... it will keep failing
# every 30 minutes." An instrument that says the same word every 30 minutes for
# three weeks carries no information: a NEW conflicted PR arriving with a stale
# green changed the log by one line and changed the conclusion by nothing, and
# nobody was going to read the line. PR #13310 added a TREND sentence to that
# red — useful, and not a ratchet: a trend of `+0` is still a failing run.
#
# So the standing population is PINNED, in a committed file, and the verdict is
# a DELTA against the pin:
#
#   NOVEL     a reported row that no baseline entry covers      → rc 1, RED
#   KNOWN     a reported row a baseline entry covers exactly    → WARN, still
#             printed in full, counted, trended — never failing
#   HEALED    a baseline entry that is no longer reported       → rc 8, RED
#             (the PR was closed, or rebased, or its verdict refreshed)
#   UNREAD    a baseline entry whose row answered UNKNOWN       → neither; a
#             row this run could not classify is never called healed
#
# THE HEALED ARM IS WHAT MAKES THIS A RATCHET AND NOT AN ALLOWLIST. A pin is a
# debt, and the file may only SHRINK on its own: the moment a pinned row stops
# being reported, this run FAILS and names the exact line to delete. Growing it
# takes a human editing a committed file, and every entry carries a written
# reason the parser REFUSES to accept as blank. A tripwire that grows stops
# discriminating; this one costs a commit and a sentence to grow and reds until
# you shrink it.
#
# The pin is keyed on (number, head-oid prefix), never on the number alone. A
# pinned PR that gets a PUSH has a new head and a freshly-dispatched verdict —
# a different fact about a different tree — and it reds as NOVEL rather than
# inheriting the old line's cover.
#
# The baseline ships EMPTY (2026-09-01: #11766 was closed at 21:26Z and the live
# population is 0 CONFLICTING rows asserting a stale green — measured, see the
# file's header). An empty baseline means every stale verdict is NOVEL, which is
# exactly the pre-ratchet behaviour: this change cannot launder anything today.
# It is the lever for the next #11766, and the healed arm is what will stop that
# lever from being left down.
#
# EXIT CODES  0 = no conflicted PR asserts a stale green that the pinned
#                 baseline does not already cover. A non-empty KNOWN set still
#                 exits 0 — and prints every row, so the debt is visible.
#             1 = a NOVEL conflicted PR asserts a stale green — RED, and it
#                 will red again in 30 minutes until it is rebased, closed, or
#                 pinned with a reason
#             2 = no red, but SOME rows stayed UNKNOWN after re-polling while
#                 OTHERS were classified (warning). PARTIAL coverage, and only
#                 that: the loose wording this line used to carry ("rows stayed
#                 UNKNOWN") is what made it feel legal to return 2 from a run
#                 that read nothing at all. Those runs are 6 and 7 now.
#             3 = CONFIGURATION fault: the credential cannot list PRs, or the
#                 spec / arguments this run was given are unreadable
#             4 = COMPUTE fault: the payload WAS read, and the verdict could
#                 not be computed from it (malformed payload, or a jq that
#                 could not run). Never blamed on the credential — 3 and 4 are
#                 separate codes because for one full release they were not,
#                 and the size fault wore the credential fault's name.
#             5 = BLIND: the population is non-empty and NOT ONE row could be
#                 classified (every row answered UNKNOWN after re-polling).
#                 2 says "some rows went unread"; 5 says "this run classified
#                 NOTHING", which is a different claim and used to be
#                 indistinguishable from perfect coverage — run 31311358759
#                 classified 0 of 39 rows, printed the clean sentence and
#                 concluded SUCCESS 68 seconds before a 23-row RED run on the
#                 same tree. Zero coverage and full coverage shared one branch.
#                 The predicate is `open > 0 AND classified == 0`: an EMPTY
#                 population is still a legitimate 0, never a 5.
#             6 = UNREACHABLE: the pull-request list was NEVER READ. Every one
#                 of $ATTEMPTS polls failed with a non-configuration error
#                 (`is_config_fault` deliberately routes rate-limit and abuse
#                 detection here rather than to 3). This run does not even know
#                 how many pull requests exist — zero coverage, no population,
#                 no verdict. Remedy: the token, the network, the rate-limit
#                 budget, the poll budget. NOT the pull requests.
#             7 = DISTANCE UNREADABLE: the pull-request list WAS read and would
#                 have classified fine; main's commit history was not, so no
#                 staleness distance exists this run. Remedy: the commits API.
#                 6 and 7 are separate codes because their remedies are, and
#                 because a 7 could later be downgraded into a PARTIAL verdict
#                 (name the CONFLICTING rows, decline to state the distance)
#                 while a 6 never can. Neither reuses 2 or 3, for the reason
#                 the 3/4 split above already gives: for one full release 3 and
#                 4 were one code and the size fault wore the credential
#                 fault's name. rc=2 wore both of these.
#             8 = BASELINE DRIFT: no novel row, and at least one PINNED entry
#                 is no longer reported. The debt shrank and the committed file
#                 did not. Its own code, not 1, because the remedy is the
#                 opposite of 1's: 1 says "go fix a pull request", 8 says
#                 "delete a line from scripts/stale-verdict-watch.baseline".
#                 A shared code would have made the ratchet's own maintenance
#                 indistinguishable from the thing it watches. See the yml note
#                 at the bottom of this header: until the workflow grows an
#                 arm for 8 it lands in the `*)` catch-all, which still FAILS
#                 the run — safe, and less specific than it should be.
#
# USAGE
#   scripts/stale-verdict-watch.sh
#   scripts/stale-verdict-watch.sh --repo FRIKKern/barkpark --min-commits 1
#   scripts/stale-verdict-watch.sh --fixture prs.json --commits main-commits.txt
#   scripts/stale-verdict-watch.sh --baseline scripts/stale-verdict-watch.baseline
#   scripts/stale-verdict-watch.sh --selftest
#   scripts/stale-verdict-watch.sh --page-size 10 --page-attempts 6
#
# THE READ IS PAGED. The pull-request population is walked with a GraphQL
# cursor, PAGE_SIZE rows at a time, and a page that fails is retried AS A PAGE.
# `gh pr list --limit 100 --json …statusCheckRollup` — the read this replaced —
# asks for a hundred rows and a hundred check rollups in ONE request, and at
# this repository's open-PR population that request answers HTTP 504 every
# time. Every scheduled run of the workflow was rc=6 UNREACHABLE on it. The
# refusal is unchanged: a read that still cannot complete returns non-zero and
# the run still FAILS. See the block above fetch_prs for the measurement.
#
# The two fixture flags make every classification hermetically provable; see
# scripts/stale-verdict-watch.test.sh. `--selftest` is a self-contained,
# network-free prover of the ratchet that runs this very file as a subprocess
# against built fixtures, and it CAN LOSE: SVW_MUTATE=<pin-any|never-healed|
# head-blind> (honoured only inside a selftest child) breaks one arm of the
# partition, and `--selftest` must then exit non-zero. test.sh proves that.
#
# THE ONE THING THIS FILE CANNOT DO ALONE
#   .github/workflows/stale-verdict-watch.yml is owned elsewhere. Two hunks
#   there would make this better and neither is required for correctness:
#   (1) a `8)` arm in the rc case, so BASELINE DRIFT gets its own sentence
#       instead of the "not a verdict it defines" catch-all;
#   (2) `scripts/stale-verdict-watch.baseline` added to the `pull_request:`
#       paths filter, so a PR that edits ONLY the baseline still runs the
#       harness that governs it.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Where the payloads live on their way to jq. See the argv note in the header:
# nothing large may travel as an argument.
WATCH_TMP="$(mktemp -d)"
trap 'rm -rf "$WATCH_TMP"' EXIT

SPEC="$REPO_ROOT/.github/required-checks.json"
REPO_OVERRIDE=""
BRANCH="main"
FIXTURE=""
COMMITS_FILE=""
# The pinned known-red set. DEFAULT_BASELINE is remembered separately from
# BASELINE so the two absences can be told apart: the committed default going
# missing is survivable (the ratchet falls back to "everything is novel", which
# is the STRICT direction), while a `--baseline` a human TYPED and misspelled
# must never quietly disarm the pin.
DEFAULT_BASELINE="$REPO_ROOT/scripts/stale-verdict-watch.baseline"
BASELINE="$DEFAULT_BASELINE"
BASELINE_EXPLICIT=0
# Honoured ONLY inside a --selftest child (SVW_SELFTEST_CHILD=1). A mutation
# switch that a production run could read is a production defect, so the guard
# is on the reader, not on the caller.
SELFTEST_CHILD="${SVW_SELFTEST_CHILD:-0}"
# ATTEMPTS / SLEEPS below are measured against real traffic, not tuned blind
# (dr-w29-bl-watch-poll-budget-inadequate-under-a-merge-burst). 368 scheduled
# runs from 2026-08-09T15:34Z to 2026-08-23T17:23Z (14 days, spanning the
# whole window since the rc=5 and rc=6/rc=7 splits above both landed)
# classified ZERO as rc=5 BLIND: 244 were rc=1 RED (a real CONFLICTING PR),
# 34 rc=6 UNREACHABLE (token/rate-limit — never a poll-budget symptom), 2
# rc=3 CONFIG, 88 clean. The single BLIND run that motivated suspicion of
# this budget — 31311358759, 2026-08-09, 39/39 UNKNOWN after ~28s of waiting
# behind five merges — predates rc=5 by hours; it is the incident rc=5 was
# built to catch, not a second occurrence surviving past it. Raising ATTEMPTS
# or SLEEPS now would add wall-clock to every one of ~370 runs/2wk to guard
# against a failure mode this exact budget has not reproduced once since
# going live. Left unchanged on that evidence; re-measure if a BLIND run
# recurs rather than re-guessing the number.
ATTEMPTS=3
# THE TRANSPORT BUDGET, which is a different budget from ATTEMPTS above and was
# the actual cause of the permanent rc=6 red. See the block above fetch_prs for
# the measurement. PAGE_SIZE=25 is chosen with margin: 50 still answered at 72
# open pull requests, 25 answered in ~4s, and the page count is cheap.
PAGE_SIZE="${SVW_PAGE_SIZE:-25}"
PAGE_ATTEMPTS="${SVW_PAGE_ATTEMPTS:-4}"
# Backoff BETWEEN page retries. The old budget spent all three of its attempts
# inside ~60 seconds against a deterministic 504 — three shots at the same wall.
PAGE_SLEEPS="${SVW_PAGE_SLEEP:-3 8 20 0}"
# A ceiling so a cursor that never terminates cannot spin forever. At the
# default page size this is 1000 pull requests — ten times what the read it
# replaces could see at all — and exhausting it is SAID, never silent.
MAX_PAGES="${SVW_MAX_PAGES:-40}"
MIN_COMMITS=1
# The TREND state (dr-w29): a line-oriented file the workflow persists between
# runs. Two verbs only. `START <iso>` is appended the moment a run knows its
# arguments — BEFORE any network call — so a run that is cancelled mid-read, or
# that exits BLIND/UNREACHABLE, leaves a START with no READ behind it. `READ
# <iso> reported=<n> classified=<c> open=<o>` is appended ONLY by a run that
# actually read its population (classified > 0, or a legitimately empty 0).
# The trend baseline is the LAST READ LINE, never the last run: a cancelled or
# blind run can therefore never be a baseline, and the intervening dangling
# STARTs are counted and SAID as UNREAD — never as "unchanged". No state file
# (unset, or evicted by the store) is its own honest arm: no baseline, nothing
# compared, and no run is ever called unchanged without one.
STATE_SVW="${SVW_STATE_FILE:-}"
# 0 in the harness; a live run waits long enough for GitHub to finish computing
# mergeability for the rows it answered UNKNOWN on.
SLEEPS="${SVW_RETRY_SLEEP:-8 20 0}"
# How many main commits to page in. The count is reported as `N+` when the
# window is exhausted, never rounded down silently.
COMMIT_PAGES=3

say() { echo "$*"; }
red() { echo "$*" >&2; }

command -v jq >/dev/null 2>&1 || { red "jq is required"; exit 3; }

spec_repo() { [ -f "$SPEC" ] && jq -r '.repo' "$SPEC" 2>/dev/null || echo ""; }

# The required set is DERIVED from the committed spec, never typed here. A
# context this repository renames changes this verdict on the next run.
required_contexts() {
  [ -f "$SPEC" ] || return 1
  jq -c '[.protection.required_status_checks.checks[].context]' "$SPEC" 2>/dev/null
}

# Same classification as breakglass-watch.sh: a credential that cannot read is a
# permanent fault, a rate limit is not.
is_config_fault() { # body
  grep -qiE 'rate limit|abuse detection' <<<"$1" && return 1
  grep -qE 'HTTP 401|HTTP 403|Bad credentials|Resource not accessible by integration|Requires authentication|requires authentication' <<<"$1"
}

# ── THE READ, AND WHY IT IS PAGED ────────────────────────────────────────────
#
# THE DEFECT THIS OWNS. Every scheduled run of this workflow was RED for weeks
# with rc=6 UNREACHABLE, and the cause was not the token and not permissions:
# the read itself had outgrown GitHub's own timeout. `gh pr list --limit 100
# --json …statusCheckRollup` asks GitHub, in ONE GraphQL request, for a hundred
# pull requests AND each one's full check rollup. Measured against this
# repository on 2026-09-02 with 72 open pull requests, three consecutive
# attempts at limit=100:
#
#     limit=100 + rollup  → HTTP 504 after ~11s   (3 of 3 attempts)
#     limit=50  + rollup  → 50 rows in ~10s
#     limit=25  + rollup  → 25 rows in ~4s
#     limit=100, NO rollup→ 72 rows in ~4s
#
# So the fault is the PRODUCT of page size and the rollup, and it is
# DETERMINISTIC at this population — every attempt failed, which is why raising
# the attempt budget alone would have bought nothing. The rollup cannot be
# dropped: VERDICT_JQ below reads $pr.statusCheckRollup for every required
# context, and without it there is no verdict at all.
#
# THE FIX IS THE PAGE, NOT THE BUDGET. This asks for PAGE_SIZE rows at a time
# and walks the population with a cursor. A page that 504s is retried AS A
# PAGE, so the pages already read are never thrown away, and the population is
# no longer capped at the 100 `gh pr list` would have silently truncated to.
#
# WHAT IS DELIBERATELY UNCHANGED. The refusal. A read that cannot complete
# still returns non-zero here, still exits 6 UNREACHABLE upstream, and still
# fails the run. Nothing below falls back to an empty population, and no arm
# added here can turn a failed read into a green: the ONLY success return is
# the one that printed a payload GitHub actually answered with.
PR_QUERY='
query($owner:String!,$name:String!,$first:Int!,$after:String){
  repository(owner:$owner,name:$name){
    pullRequests(states:OPEN, first:$first, after:$after,
                 orderBy:{field:CREATED_AT,direction:DESC}){
      pageInfo{ hasNextPage endCursor }
      nodes{
        number mergeable mergeStateStatus updatedAt headRefOid
        commits(last:1){ nodes{ commit{ statusCheckRollup{ contexts(first:100){ nodes{
          __typename
          ... on CheckRun { name conclusion completedAt status }
          ... on StatusContext { context state createdAt }
        }}}}}}
      }
    }
  }
}'

# The page payload, rendered into exactly the shape `gh pr list --json` used to
# hand the verdict — same keys, same values, including the Go zero time gh
# substitutes for a check run that has not completed. Nothing downstream had to
# change, which is the point: this slice replaces the TRANSPORT, not the
# verdict.
PR_NORMALISE_JQ='
[ .data.repository.pullRequests.nodes[]
  | { number, mergeable, mergeStateStatus, headRefOid, updatedAt,
      statusCheckRollup:
        [ (.commits.nodes[0].commit.statusCheckRollup.contexts.nodes // [])[]
          | { __typename,
              name:        (.name // .context),
              status:      (.status // ""),
              conclusion:  (.conclusion // .state // ""),
              completedAt: (.completedAt // "0001-01-01T00:00:00Z") } ] } ]'

# ONE full pass over the population: pages until GitHub says there is no next
# page. Retries a PAGE that fails, up to PAGE_ATTEMPTS, so a transient 504 on
# page 3 does not discard pages 1 and 2.
#   0 = the whole population was read   (prints the JSON array)
#   2 = a page could not be read        (prints the last error body)
#   3 = credential fault                (prints the error body)
fetch_pr_pages() { # <repo> -> JSON array | error body
  local repo="$1" owner name after="" rows="[]" page=0 attempt out body
  local sleep_for got next
  owner="${repo%%/*}"; name="${repo##*/}"
  [ -n "$owner" ] && [ -n "$name" ] && [ "$owner" != "$repo" ] || {
    printf '%s' "not an owner/name repository: '$repo'"
    return 3
  }
  while :; do
    page=$((page + 1))
    if [ "$page" -gt "$MAX_PAGES" ]; then
      # NEVER silent. The old read truncated at 100 rows and said nothing; a
      # truncation this one cannot avoid is stated in the log.
      red "  the population did not end within $MAX_PAGES page(s) of $PAGE_SIZE — this read is TRUNCATED at $(jq 'length' <<<"$rows") row(s) and any pull request past that point was NOT examined."
      break
    fi
    attempt=0
    while :; do
      attempt=$((attempt + 1))
      if [ -n "$after" ]; then
        out="$(gh api graphql -f query="$PR_QUERY" -F owner="$owner" -F name="$name" \
                 -F first="$PAGE_SIZE" -F after="$after" 2>&1)" && break
      else
        out="$(gh api graphql -f query="$PR_QUERY" -F owner="$owner" -F name="$name" \
                 -F first="$PAGE_SIZE" 2>&1)" && break
      fi
      if is_config_fault "$out"; then
        printf '%s' "$out"
        return 3
      fi
      body="$(printf '%s' "$out" | head -1)"
      if [ "$attempt" -ge "$PAGE_ATTEMPTS" ]; then
        red "  page $page failed $attempt/$PAGE_ATTEMPTS times, giving up on this pass: $body"
        printf '%s' "$out"
        return 2
      fi
      sleep_for="$(printf '%s\n' $PAGE_SLEEPS | sed -n "${attempt}p")"
      [ -n "${sleep_for:-}" ] || sleep_for=0
      red "  page $page attempt $attempt/$PAGE_ATTEMPTS failed, retrying the PAGE in ${sleep_for}s: $body"
      [ "$sleep_for" = "0" ] || sleep "$sleep_for"
    done
    got="$(jq -c "$PR_NORMALISE_JQ" <<<"$out" 2>/dev/null)" || {
      # A page GitHub answered 200 to and jq could not read is NOT a transport
      # silence — but it is also not a population, so it must not be reported
      # as one. It leaves as an unreadable page, which upstream calls
      # UNREACHABLE rather than green.
      red "  page $page came back 200 and could not be parsed as a pull-request page"
      printf '%s' "$out"
      return 2
    }
    [ -n "$got" ] || { red "  page $page normalised to nothing"; printf '%s' "$out"; return 2; }
    # Both arrays go through STDIN, never argv: `--argjson a "$rows"` put the whole
    # accumulated population on the command line and, past a few hundred PRs of
    # check-rollup rows, execve refused it — "jq: Argument list too long" on
    # every run from 2026-09-03 06:08Z, read as UNREACHABLE (task-0a48c7b64d5ab0f1).
    rows="$(printf '%s\n%s\n' "$rows" "$got" | jq -c -s '.[0] + .[1]')" || {
      red "  page $page could not be appended to the population"
      return 2
    }
    next="$(jq -r '.data.repository.pullRequests.pageInfo.hasNextPage' <<<"$out" 2>/dev/null)"
    [ "$next" = "true" ] || break
    after="$(jq -r '.data.repository.pullRequests.pageInfo.endCursor' <<<"$out" 2>/dev/null)"
    [ -n "$after" ] && [ "$after" != "null" ] || {
      red "  page $page says there is a next page and names no cursor for it"
      return 2
    }
  done
  printf '%s' "$rows"
  return 0
}

# The population, re-polled while any row is still mergeable=UNKNOWN (GitHub
# computes that lazily). The outer budget is about UNKNOWN; the inner
# PAGE_ATTEMPTS budget above is about transport. They are separate on purpose:
# the 2026-08-23 measurement of 368 scheduled runs found ZERO rc=5 BLIND runs,
# so the UNKNOWN budget was never the problem — the transport was.
fetch_prs() { # -> prints JSON array, or the error body on failure
  local repo="$1" out i=0 rc sleep_for unknown
  while [ "$i" -lt "$ATTEMPTS" ]; do
    i=$((i + 1))
    out="$(fetch_pr_pages "$repo")"; rc=$?
    if [ "$rc" = "0" ]; then
      unknown="$(jq '[.[] | select(.mergeable == "UNKNOWN")] | length' <<<"$out" 2>/dev/null || echo 0)"
      if [ "${unknown:-0}" = "0" ] || [ "$i" -ge "$ATTEMPTS" ]; then
        printf '%s' "$out"
        return 0
      fi
      red "  poll $i/$ATTEMPTS: $unknown row(s) answered mergeable=UNKNOWN (lazily computed) — re-polling"
    elif [ "$rc" = "3" ]; then
      printf '%s' "$out"
      return 3
    else
      red "  poll $i/$ATTEMPTS could not list pull requests: $(printf '%s' "$out" | head -1)"
    fi
    sleep_for="$(printf '%s\n' $SLEEPS | sed -n "${i}p")"
    [ -n "${sleep_for:-}" ] || sleep_for=0
    [ "$sleep_for" = "0" ] || sleep "$sleep_for"
  done
  printf '%s' "${out:-}"
  return 2
}

# main's commit timestamps, newest first. The verdict needs only "how many
# landed after instant T", so nothing but the dates is fetched.
fetch_commits() { # <repo> -> ISO lines
  local repo="$1" page out
  for page in $(seq 1 "$COMMIT_PAGES"); do
    if out="$(gh api "repos/$repo/commits?sha=$BRANCH&per_page=100&page=$page" --jq '.[].commit.committer.date' 2>&1)"; then
      printf '%s\n' "$out"
      [ "$(printf '%s\n' "$out" | grep -c .)" -lt 100 ] && return 0
    else
      red "  could not read main's commit dates (page $page): $(printf '%s' "$out" | head -1)"
      return 1
    fi
  done
  return 0
}

VERDICT_JQ='
def commits_since($t):
  if ($t // "") == "" then null
  else [$commits[] | select(. > $t)] | length
  end;

[ .[] |
  . as $pr
  | {
      number, mergeable, mergeStateStatus, headRefOid, updatedAt,
      ctx: [ $req[] as $n
             | { name: $n,
                 hits: [ $pr.statusCheckRollup[]?
                         | { name: (.name // .context),
                             conclusion: (.conclusion // .state // ""),
                             completedAt: (.completedAt // "") }
                         | select(.name == $n) ] } ]
    }
  | .rendered      = [ .ctx[] | select(.hits | length > 0) ]
  # ALL-OF-PRESENT: rendered, and every entry carrying the name is SUCCESS.
  | .green_all     = [ .rendered[] | select([.hits[] | .conclusion] | all(. == "SUCCESS")) ]
  # The wrong counting, kept so the report can show both side by side.
  | .green_occurrences = ([ .ctx[].hits[] | select(.conclusion == "SUCCESS") ] | length)
  | .full_green    = ((.green_all | length) == ($req | length))
  | .occurrence_full_green = (.green_occurrences >= ($req | length))
  # The commit window is finite, so a distance that fills it is reported as
  # `N+`, never rounded down into a comforting exact number.
  | .stale_greens  = [ .green_all[]
                       | (.hits | map(.completedAt) | max) as $at
                       | { name, conclusion: "SUCCESS", completedAt: $at, since: commits_since($at) }
                       | select(.since != null and .since >= $min)
                       | .capped = (.since >= $window) ]
  | .missing       = [ $req[] as $n | select([ .ctx[] | select(.name == $n and (.hits | length) > 0) ] | length == 0) | $n ]
]
| . as $rows
| { required: $req,
    window: $window,
    open: ($rows | length),
    # Every number this run SAW, classified or not. The ratchet needs it to
    # tell a pinned PR that was CLOSED (gone from the population entirely)
    # apart from one that is still open and merely no longer stale.
    all_numbers: [ $rows[].number ],
    conflicting: [ $rows[] | select(.mergeable == "CONFLICTING") ],
    mergeable_n: [ $rows[] | select(.mergeable == "MERGEABLE") ] | length,
    unknown: [ $rows[] | select(.mergeable != "CONFLICTING" and .mergeable != "MERGEABLE") ] }
# COVERAGE, carried in the verdict so no sentence has to infer it. A row is
# classified when its mergeability was actually read; everything else went
# unread. `blind` is the run that read a population and classified none of it —
# and it is deliberately `open > 0 AND classified == 0`, never a bare
# `classified == 0`, which would also fire on an empty population and turn this
# verdict into an unconditional red.
| .classified          = ((.conflicting | length) + .mergeable_n)
| .blind               = (.open > 0 and .classified == 0)
| .full_green_all      = [ .conflicting[] | select(.full_green) | .number ]
| .full_green_occurr   = [ .conflicting[] | select(.occurrence_full_green) | .number ]
| .laundered           = (.full_green_occurr - .full_green_all)
| .partial             = [ .conflicting[]
                           | select((.missing | length) > 0 and (.rendered | length) > 0
                                    and (.green_all | length) == (.rendered | length))
                           | { number, green: (.green_all | length), rendered: (.rendered | length) } ]
| .reported            = [ .conflicting[] | select((.stale_greens | length) > 0) ]
'

# ── THE PIN ──────────────────────────────────────────────────────────────────
#
# One entry per line:  <pr-number> <head-oid-prefix> <YYYY-MM-DD> <reason…>
#
# Every field is MANDATORY and every field is checked. A blank reason is a
# CONFIGURATION FAULT (rc 3), not a warning — the whole cost of growing this
# file is the sentence, and a parser that shrugged at an empty one would have
# made the pin free. A malformed line names its own line number: a baseline
# this run could not read must never be treated as an empty baseline, because
# an empty baseline is the PERMISSIVE reading of "healed" (nothing pinned,
# nothing to shrink) even though it is the strict reading of "novel".
BASELINE_JSON='[]'
BASELINE_NOTE=''
parse_baseline() { # <file> -> sets BASELINE_JSON; returns 1 on a malformed file
  # `set -f` for the whole parse: the fields are split with an unquoted $raw
  # (the only portable way to take "everything after field 3" in bash 3.2), and
  # a reason containing a `*` would otherwise be expanded against the working
  # directory — a pin whose text silently becomes a file listing. The wrapper
  # exists so that the dozen `return 1` arms below cannot each forget `set +f`.
  local rc=0
  set -f
  parse_baseline_body "$@" || rc=$?
  set +f
  return "$rc"
}

parse_baseline_body() { # <file>
  local f="$1" ln=0 n head date reason stripped acc="$WATCH_TMP/baseline.ndjson"
  : > "$acc"
  while IFS= read -r raw || [ -n "$raw" ]; do
    ln=$((ln + 1))
    stripped="${raw#"${raw%%[![:space:]]*}"}"
    case "$stripped" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2086
    set -- $stripped
    n="${1:-}"; head="${2:-}"; date="${3:-}"
    if [ "$#" -gt 3 ]; then shift 3; reason="$*"; else reason=""; fi
    case "$n" in ''|*[!0-9]*) red "baseline $f line $ln: '$n' is not a pull-request number"; return 1 ;; esac
    case "$head" in
      ''|*[!0-9a-f]*) red "baseline $f line $ln: '$head' is not a lowercase hex head-oid prefix"; return 1 ;;
    esac
    [ "${#head}" -ge 7 ] || { red "baseline $f line $ln: head prefix '$head' is ${#head} chars; 7 is the minimum, because a shorter prefix pins more than one tree"; return 1; }
    [ "${#head}" -le 40 ] || { red "baseline $f line $ln: head prefix '$head' is longer than a git oid"; return 1; }
    case "$date" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) red "baseline $f line $ln: '$date' is not a YYYY-MM-DD pin date"; return 1 ;;
    esac
    [ "${#reason}" -ge 12 ] || { red "baseline $f line $ln: #$n is pinned with a ${#reason}-character reason ('$reason'). A pin is standing debt; it does not get in without a sentence saying why."; return 1; }
    jq -c -n --argjson number "$n" --arg head "$head" --arg date "$date" --arg reason "$reason" \
      '{number: $number, head: $head, pinned_on: $date, reason: $reason}' >> "$acc" || return 1
  done < "$f"
  BASELINE_JSON="$(jq -s -c '.' "$acc")" || return 1
  # A number pinned twice is two claims about one PR, and the second silently
  # wins every comparison. Refuse rather than pick.
  local dupes
  dupes="$(jq -r 'group_by(.number) | map(select(length > 1) | .[0].number) | map("#\(.)") | join(", ")' <<<"$BASELINE_JSON")"
  [ -z "$dupes" ] || { red "baseline $f: pinned twice — $dupes. One line per pull request."; return 1; }
  return 0
}

# The DELTA. Everything above computes what is true right now; this computes
# what CHANGED against the pin, which is the only thing a 30-minute level check
# can usefully fail on.
RATCHET_JQ='
  . as $v
  | ($v.reported | map({number, head: .headRefOid})) as $R
  | ($v.unknown  | map(.number))                     as $UNK
  | ($v.all_numbers)                                 as $SEEN
  | [ $R[] | . as $r | select([ $base[] | . as $b | select($b.number == $r.number and ($r.head | startswith($b.head))) ] | length > 0) ] as $known
  | [ $R[] | . as $r | select([ $base[] | . as $b | select($b.number == $r.number and ($r.head | startswith($b.head))) ] | length == 0) ] as $novel
  # A pinned number that IS reported at a different head: covered by no entry,
  # so it is novel — and it deserves its own sentence, because "#N is new" is
  # a confusing thing to read about a number that appears in the file.
  | [ $novel[] | . as $r
      | select([ $base[] | select(.number == $r.number) ] | length > 0)
      | { number: $r.number, head: $r.head,
          pinned_head: ([ $base[] | select(.number == $r.number) | .head ] | first) } ] as $head_moved
  | [ $base[] | . as $b | select([ $R[] | select(.number == $b.number) ] | length == 0) ] as $unreported
  | [ $unreported[] | . as $b | select(($UNK | index($b.number)) != null) ] as $pinned_unread
  | [ $unreported[] | . as $b | select(($UNK | index($b.number)) == null)
      | . + { gone: (($SEEN | index($b.number)) == null) } ] as $healed
  | . + { ratchet: {
      pinned:        ($base | length),
      note:          $note,
      entries:       $base,
      known:         $known,
      novel:         $novel,
      head_moved:    $head_moved,
      healed:        $healed,
      pinned_unread: $pinned_unread } }
'

render() { # reads the verdict JSON on stdin
  jq -r '
    . as $v |
    "stale-verdict-watch — conflicted pull requests still asserting a green they can no longer earn",
    "required contexts (\(.required | length), derived from .github/required-checks.json): \(.required | join(" · "))",
    "",
    "POPULATION, re-derived at run time (never baked):",
    "  \(.open) open · \(.conflicting | length) CONFLICTING · \(.mergeable_n) MERGEABLE · \(.unknown | length) UNKNOWN after re-polling",
    "COUNTING, both ways, side by side:",
    "  all-of-present (this verdict): \(.full_green_all | length) conflicted PR(s) assert a full \(.required | length)-of-\(.required | length) green" +
      (if (.full_green_all | length) > 0 then " — \(.full_green_all | sort | map("#\(.)") | join(", "))" else "" end),
    "  occurrences-of-SUCCESS (WRONG): \(.full_green_occurr | length)" +
      (if (.laundered | length) > 0
       then " — over-reports by \(.laundered | length) (\(.laundered | sort | map("#\(.)") | join(", "))), which render more required-named entries than there are required contexts and launder a FAILURE out of the count"
       else " — no duplicate-entry rows in this sample" end),
    (if (.partial | length) > 0
     then "PARTIAL CLASS (the \(.required|length)-of-\(.required|length) framing hides these): " +
          (.partial | sort_by(.number) | map("#\(.number) \(.green)-of-\(.rendered) rendered") | join(", ")) +
          " — the rest of the required set never rendered at all"
     else "PARTIAL CLASS: none" end),
    "",
    # THREE WAYS TO SAY "NOT RED", AND THEY ARE NOT THE SAME CLAIM. The clean
    # sentence used to be printed on the sole condition that .reported was
    # empty — which it also is when NOTHING WAS CLASSIFIED. Every arm below now
    # carries `classified N of M`, so the coverage behind the conclusion is in
    # the sentence a human actually reads.
    "RATCHET, against the pinned baseline (\(.ratchet.pinned) entr\(if .ratchet.pinned == 1 then "y" else "ies" end)):",
    "  PIN    \(.ratchet.note)",
    "  NOVEL  \(.ratchet.novel | length)" +
      (if (.ratchet.novel | length) > 0 then " — \(.ratchet.novel | map(.number) | sort | map("#\(.)") | join(", "))  ← this run FAILS on these" else " — nothing arrived that the pin does not cover" end),
    "  KNOWN  \(.ratchet.known | length)" +
      (if (.ratchet.known | length) > 0 then " — \(.ratchet.known | map(.number) | sort | map("#\(.)") | join(", "))  (standing debt, printed in full below, NOT failed on)" else " — no pinned row is still reporting" end),
    "  HEALED \(.ratchet.healed | length)" +
      (if (.ratchet.healed | length) > 0 then " — \(.ratchet.healed | map(.number) | sort | map("#\(.)") | join(", "))  ← this run FAILS: the baseline must shrink" else " — every pinned entry is still earning its line" end),
    (if (.ratchet.pinned_unread | length) > 0
     then "  UNREAD \(.ratchet.pinned_unread | length) — \(.ratchet.pinned_unread | map(.number) | sort | map("#\(.)") | join(", ")): pinned, and this run could not classify the row. NOT called healed on a read that did not happen."
     else empty end),
    (.ratchet.head_moved | sort_by(.number)[] |
      "  ^ #\(.number) is PINNED at head \(.pinned_head) and is reported at head \(.head[0:9]) — a push landed, the verdict is about a different tree, and the old line does not cover it. Re-pin it (with a reason) or fix the PR."),
    (.ratchet.healed | sort_by(.number)[] |
      "  ^ #\(.number) pinned \(.pinned_on) is no longer reported (\(if .gone then "the pull request is closed or merged — it is not in the open population at all" else "still open, and no longer asserting a stale green" end)). DELETE its line from the baseline: \(.number) \(.head) \(.pinned_on) …"),
    "",
    # THREE WAYS TO SAY "NOT RED", AND THEY ARE NOT THE SAME CLAIM — plus the
    # ratchet adds two more, which come FIRST because they are the only arms that fail.
    # The order here MIRRORS the exit-code order in main(); if the two ever
    # disagree the log and the conclusion describe different runs.
    (if (.ratchet.novel | length) > 0
     then "RED — \(.ratchet.novel | length) NOVEL CONFLICTING pull request(s) assert a green required verdict main has moved past, and no baseline entry covers them. A conflicted PR re-dispatches NOTHING: this cannot clear itself. Rebase it, close it, or pin it with a written reason."
     elif .blind
     then "BLIND — classified 0 of \(.open) open pull request(s): the mergeability of every row was still UNKNOWN after re-polling, so this run classified NOTHING. This is NOT a green — a run that could not look cannot report the population clean."
     elif (.ratchet.healed | length) > 0
     then "BASELINE DRIFT — no novel row, and \(.ratchet.healed | length) pinned entr\(if (.ratchet.healed|length) == 1 then "y is" else "ies are" end) no longer reported. The debt shrank and the committed file did not. This run fails until the line(s) named above are deleted — a pin may only get smaller on its own."
     elif (.reported | length) > 0
     then "WARN — \(.reported | length) CONFLICTING pull request(s) assert a green required verdict main has moved past, and every one of them is PINNED in scripts/stale-verdict-watch.baseline with a reason. This is standing debt, stated in full below and trended; it is not a new fact, so this run does not fail on it. It fails the moment a NEW one arrives or a pinned one heals."
     elif (.unknown | length) > 0
     then "INCONCLUSIVE — classified \(.classified) of \(.open) open pull request(s); \(.unknown | length) row(s) went unread. No CONFLICTING row in the part this run COULD read is asserting a stale green — that says nothing about the rows below."
     else "ok — no CONFLICTING pull request is asserting a green required verdict that main has moved past (classified \(.classified) of \(.open) open)." end),
    (.reported | sort_by(.number)[] | . as $row |
      "",
      "  #\(.number)  \(.mergeStateStatus)  head \(.headRefOid[0:9])  verdict as of \(.updatedAt)  [\(if ([$v.ratchet.known[] | select(.number == $row.number)] | length) > 0 then "KNOWN — pinned: " + ([$v.ratchet.entries[]? | select(.number == $row.number) | .reason] | first // "—") else "NOVEL" end)]",
      (.ctx[] |
        "      \(.name)\(" " * (if (34 - (.name | length)) > 0 then 34 - (.name | length) else 1 end))" +
        (if (.hits | length) == 0 then "NEVER RENDERED"
         else ([.hits[] | .conclusion] | join("+")) + "  " + ((.hits | map(.completedAt) | max) // "—")
         end)),
      (.stale_greens[] | "      ^ STALE: \(.name) passed at \(.completedAt), \(.since)\(if .capped then "+" else "" end) commit(s) have landed on main since — and this PR can dispatch nothing to refresh it")),
    (if (.unknown | length) > 0
     then "", "WARNING ROWS — mergeable was still UNKNOWN after re-polling. These are NOT classified and NOT dropped:",
          (.unknown | sort_by(.number)[] | "  ? #\(.number)  mergeable=\(.mergeable)  \(.mergeStateStatus // "—")  — re-read on the next run")
     else empty end)
  '
}

state_start() { # append the START marker; prune so the store never grows unbounded
  [ -n "$STATE_SVW" ] || return 0
  { echo "START $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$STATE_SVW" && tail -n 200 "$STATE_SVW" > "$STATE_SVW.prune" && mv "$STATE_SVW.prune" "$STATE_SVW"; } 2>/dev/null || true
}

state_read() { # <reported> <classified> <open> <novel> — only a run that READ may call this
  [ -n "$STATE_SVW" ] || return 0
  # `novel=` is APPENDED, never inserted before `reported=`: the baseline
  # parser below reads `reported=` with a greedy `.*` prefix, and a second
  # field carrying that substring earlier in the line would silently
  # re-baseline the trend on the wrong number.
  echo "READ $(date -u +%Y-%m-%dT%H:%M:%SZ) reported=$1 classified=$2 open=$3 novel=${4:-0}" >> "$STATE_SVW" 2>/dev/null || true
}

trend_report() { # <reported> [novel] — how the count moved since the last READ run
  if [ -z "$STATE_SVW" ]; then
    say "TREND: no state file configured — movement since the last READ run is unknown, and no run is called unchanged without a baseline."
    return 0
  fi
  if [ ! -f "$STATE_SVW" ]; then
    say "TREND: no baseline — the state file is absent (first run, or the store evicted it). Nothing is compared, and nothing is called unchanged."
    return 0
  fi
  local base base_line_no base_rest base_ts base_count unread delta sign
  base="$(grep -n '^READ ' "$STATE_SVW" 2>/dev/null | tail -1)"
  if [ -z "$base" ]; then
    unread="$(grep -c '^START ' "$STATE_SVW" 2>/dev/null)"; unread="${unread:-0}"
    unread=$((unread - 1)); [ "$unread" -lt 0 ] && unread=0
    say "TREND: no READ baseline yet — ${unread} earlier run(s) left a START with no READ (cancelled, blind, or unreachable). They are counted UNREAD, never as unchanged."
    return 0
  fi
  base_line_no="${base%%:*}"
  base_rest="${base#*:}"
  base_ts="$(printf '%s\n' "$base_rest" | awk '{print $2}')"
  base_count="$(printf '%s\n' "$base_rest" | sed -n 's/.*reported=\([0-9][0-9]*\).*/\1/p')"
  # Dangling STARTs strictly after the baseline READ, minus this run's own.
  unread="$(tail -n +$((base_line_no + 1)) "$STATE_SVW" 2>/dev/null | grep -c '^START ')"; unread="${unread:-0}"
  unread=$((unread - 1)); [ "$unread" -lt 0 ] && unread=0
  delta=$(( $1 - ${base_count:-0} )); sign=""; [ "$delta" -ge 0 ] && sign="+"
  say "TREND: reported $1 — was ${base_count:-?} at ${base_ts:-?} (moved ${sign}${delta} since the last READ run); ${unread} intervening run(s) went UNREAD (cancelled, blind, or unreachable) and are counted UNREAD, never as unchanged."
  # The novel trend is the one a human should read: `reported` moving +0 for
  # three weeks is what this ratchet was built because of.
  local base_novel novel_delta novel_sign
  base_novel="$(printf '%s\n' "$base_rest" | sed -n 's/.*novel=\([0-9][0-9]*\).*/\1/p')"
  if [ -n "$base_novel" ] && [ -n "${2:-}" ]; then
    novel_delta=$(( ${2} - base_novel )); novel_sign=""; [ "$novel_delta" -ge 0 ] && novel_sign="+"
    say "TREND (novel): $2 — was $base_novel at ${base_ts:-?} (moved ${novel_sign}${novel_delta}). This is the number the run's conclusion is computed from; the reported count above includes the pinned standing debt."
  else
    say "TREND (novel): ${2:-?} — the baseline READ line predates the ratchet and carries no novel= field, so nothing is compared and nothing is called unchanged."
  fi
}

# The DELTA, restated where a human looks first. $GITHUB_STEP_SUMMARY is set by
# the runner for every step, so this needs no change to the workflow file.
step_summary() { # <verdict-json> <reported> <novel> <known> <healed>
  local dest="${GITHUB_STEP_SUMMARY:-}"
  [ -n "$dest" ] || return 0
  {
    echo "### stale-verdict-watch — delta against the pinned baseline"
    echo
    echo "| | count | pull requests |"
    echo "|---|---|---|"
    printf '| **NOVEL** (fails this run) | %s | %s |\n' "$3" "$(jq -r '.ratchet.novel | if length == 0 then "—" else map("#\(.number)") | join(", ") end' <<<"$1")"
    printf '| KNOWN (pinned standing debt) | %s | %s |\n' "$4" "$(jq -r '.ratchet.known | if length == 0 then "—" else map("#\(.number)") | join(", ") end' <<<"$1")"
    printf '| **HEALED** (fails this run — shrink the baseline) | %s | %s |\n' "$5" "$(jq -r '.ratchet.healed | if length == 0 then "—" else map("#\(.number)") | join(", ") end' <<<"$1")"
    printf '| UNREAD pinned rows (not classified) | %s | %s |\n' "$(jq '.ratchet.pinned_unread | length' <<<"$1")" "$(jq -r '.ratchet.pinned_unread | if length == 0 then "—" else map("#\(.number)") | join(", ") end' <<<"$1")"
    echo
    printf '%s pinned entr%s · %s reported · classified %s of %s open\n' \
      "$(jq '.ratchet.pinned' <<<"$1")" "$( [ "$(jq '.ratchet.pinned' <<<"$1")" = "1" ] && echo y || echo ies )" \
      "$2" "$(jq '.classified' <<<"$1")" "$(jq '.open' <<<"$1")"
  } >> "$dest" 2>/dev/null || true
}

# ── --selftest ───────────────────────────────────────────────────────────────
#
# Network-free, self-contained, and it CAN LOSE. Every probe runs THIS FILE as
# a subprocess against a built fixture, so what is proved is the shipped path
# and not a re-implementation of it. SVW_MUTATE breaks one arm of the partition
# in the child; a mutated run must make this exit non-zero, which is what
# scripts/stale-verdict-watch.test.sh asserts.
SELFTEST_PASS=0
SELFTEST_FAIL=0
st_ok()  { SELFTEST_PASS=$((SELFTEST_PASS + 1)); echo "  ok   $*"; }
st_bad() { SELFTEST_FAIL=$((SELFTEST_FAIL + 1)); echo "  FAIL $*" >&2; }

selftest() {
  local d="$WATCH_TMP/selftest" out rc
  mkdir -p "$d"
  export SVW_SELFTEST_CHILD=1

  local req_json ctx1 ctx_n
  req_json="$(required_contexts)" || { red "--selftest needs the required-check spec at $SPEC"; return 3; }
  ctx_n="$(jq 'length' <<<"$req_json")"

  # A pinned commit history: ten commits, all after the fixture verdicts.
  : > "$d/commits.txt"
  for i in 1 2 3 4 5 6 7 8 9; do echo "2026-08-0${i}T00:00:00Z" >> "$d/commits.txt"; done
  echo "2026-08-10T00:00:00Z" >> "$d/commits.txt"
  local OLDT="2026-07-01T00:00:00Z" HEAD_A="aaaaaaaa11112222333344445555666677778888"

  # Every required context SUCCESS at $OLDT → a full stale green.
  local rollup
  rollup="$(jq -c --arg t "$OLDT" '[ .[] | {__typename:"CheckRun", name: ., status:"COMPLETED", conclusion:"SUCCESS", completedAt: $t} ]' <<<"$req_json")"
  ctx1="$(jq -r '.[0]' <<<"$req_json")"
  [ -n "$ctx1" ] && [ "$ctx_n" -ge 1 ] || { red "--selftest: the spec lists no required contexts"; return 3; }

  row() { # <number> <mergeable> <head>
    jq -c -n --argjson n "$1" --arg m "$2" --arg h "$3" --argjson r "$rollup" \
      '{number:$n, mergeable:$m, mergeStateStatus:(if $m=="CONFLICTING" then "DIRTY" else "CLEAN" end),
        headRefOid:$h, updatedAt:"2026-08-01T00:00:00Z", statusCheckRollup:$r}'
  }
  # The child's output goes to a FILE and its rc is this function's own rc.
  # `out="$(run_child …)"; rc=$SOME_GLOBAL` cannot work: command substitution
  # is a subshell, and every variable the child run set dies with it.
  run_child() { # <fixture> <baseline> -> rc; output in $d/out.txt
    bash "$0" --fixture "$1" --commits "$d/commits.txt" --spec "$SPEC" \
      --repo FRIKKern/barkpark --baseline "$2" > "$d/out.txt" 2>&1
  }

  echo "── stale-verdict-watch --selftest ──"

  # (1) EMPTY PIN + a stale conflicted row → NOVEL, rc 1. This is the arm the
  #     whole ratchet is judged on: an unpinned arrival still fails.
  row 9001 CONFLICTING "$HEAD_A" | jq -s -c '.' > "$d/one.json"
  : > "$d/empty.baseline"
  run_child "$d/one.json" "$d/empty.baseline"; rc=$?; out="$(cat "$d/out.txt")"
  [ "$rc" = "1" ] && st_ok "(1) an unpinned stale verdict is NOVEL and exits 1" \
    || st_bad "(1) expected rc 1 for an unpinned stale verdict, got $rc"
  grep -q "NOVEL  1 — #9001" <<<"$out" && st_ok "(1) …and #9001 is named as NOVEL" \
    || st_bad "(1) #9001 was not named NOVEL: $out"

  # (2) THE SAME ROW, PINNED → KNOWN, rc 0, and still printed in full.
  printf '9001 %s 2026-08-01 pinned by the selftest to prove the known arm does not fail\n' "${HEAD_A:0:9}" > "$d/pin.baseline"
  run_child "$d/one.json" "$d/pin.baseline"; rc=$?; out="$(cat "$d/out.txt")"
  [ "$rc" = "0" ] && st_ok "(2) a pinned stale verdict is KNOWN and exits 0" \
    || st_bad "(2) expected rc 0 for a pinned stale verdict, got $rc"
  grep -q "KNOWN  1 — #9001" <<<"$out" && st_ok "(2) …counted KNOWN" || st_bad "(2) not counted KNOWN: $out"
  grep -q "^  #9001 " <<<"$out" && st_ok "(2) …and the row is still printed in full, so the debt stays visible" \
    || st_bad "(2) the pinned row was hidden from the report: $out"
  grep -q "STALE: $ctx1 passed at $OLDT" <<<"$out" \
    && st_ok "(2) …with its staleness distance, unchanged by the pin" \
    || st_bad "(2) the pinned row lost its staleness detail: $out"

  # (3) A SECOND, UNPINNED ARRIVAL alongside the pinned one → rc 1. The pin
  #     must not launder the population it does not name.
  { row 9001 CONFLICTING "$HEAD_A"; row 9002 CONFLICTING "bbbbbbbb1111222233334444555566667777aaaa"; } | jq -s -c '.' > "$d/two.json"
  run_child "$d/two.json" "$d/pin.baseline"; rc=$?; out="$(cat "$d/out.txt")"
  [ "$rc" = "1" ] && st_ok "(3) a NEW arrival beside a pinned row still exits 1" \
    || st_bad "(3) expected rc 1 with one pinned and one novel row, got $rc"
  grep -q "NOVEL  1 — #9002" <<<"$out" && st_ok "(3) …and only #9002 is novel" \
    || st_bad "(3) the novel row was not isolated: $out"

  # (4) HEALED — the pinned PR is gone from the population entirely.
  echo "[]" > "$d/none.json"
  run_child "$d/none.json" "$d/pin.baseline"; rc=$?; out="$(cat "$d/out.txt")"
  [ "$rc" = "8" ] && st_ok "(4) a pinned entry that stopped reporting exits 8 (baseline drift)" \
    || st_bad "(4) expected rc 8 when a pin healed, got $rc"
  grep -q "HEALED 1 — #9001" <<<"$out" && st_ok "(4) …and #9001 is named as HEALED" \
    || st_bad "(4) #9001 was not named HEALED: $out"
  grep -q "DELETE its line from the baseline" <<<"$out" \
    && st_ok "(4) …with the exact remedy: delete the line" \
    || st_bad "(4) no shrink instruction was printed: $out"

  # (5) HEALED, the other way: the PR is still open and no longer stale.
  local FRESH="2026-08-11T00:00:00Z" fresh_rollup
  fresh_rollup="$(jq -c --arg t "$FRESH" '[ .[] | {__typename:"CheckRun", name: ., status:"COMPLETED", conclusion:"SUCCESS", completedAt: $t} ]' <<<"$req_json")"
  jq -c -n --arg h "$HEAD_A" --argjson r "$fresh_rollup" \
    '[{number:9001, mergeable:"CONFLICTING", mergeStateStatus:"DIRTY", headRefOid:$h,
       updatedAt:"2026-08-11T00:00:00Z", statusCheckRollup:$r}]' > "$d/fresh.json"
  run_child "$d/fresh.json" "$d/pin.baseline"; rc=$?; out="$(cat "$d/out.txt")"
  [ "$rc" = "8" ] && st_ok "(5) a pinned PR that is still open and no longer stale also exits 8" \
    || st_bad "(5) expected rc 8 for a refreshed pin, got $rc"
  grep -q "still open, and no longer asserting a stale green" <<<"$out" \
    && st_ok "(5) …and the message says WHY it healed (open, not closed)" \
    || st_bad "(5) the healed reason was wrong or missing: $out"

  # (6) A PINNED ROW THIS RUN COULD NOT CLASSIFY IS NOT HEALED. This is the
  #     arm that keeps a flaky mergeability read from emptying the baseline.
  jq -c -n --arg h "$HEAD_A" --argjson r "$rollup" \
    '[{number:9001, mergeable:"UNKNOWN", mergeStateStatus:null, headRefOid:$h,
       updatedAt:"2026-08-01T00:00:00Z", statusCheckRollup:$r}]' > "$d/unk.json"
  run_child "$d/unk.json" "$d/pin.baseline"; rc=$?; out="$(cat "$d/out.txt")"
  [ "$rc" = "5" ] && st_ok "(6) an all-UNKNOWN population is BLIND (rc 5), never a baseline-drift verdict" \
    || st_bad "(6) expected rc 5 when the only row went UNKNOWN, got $rc"
  grep -q "UNREAD 1 — #9001" <<<"$out" && st_ok "(6) …and the pinned row is counted UNREAD, not HEALED" \
    || st_bad "(6) an unclassified pinned row was not held out of the healed set: $out"
  grep -q "HEALED 0" <<<"$out" && st_ok "(6) …healed stays empty on a read that did not happen" \
    || st_bad "(6) healed was non-empty on an unread row: $out"

  # (7) THE HEAD MOVED. Same number, new head, still stale → NOVEL, not KNOWN.
  row 9001 CONFLICTING "cccccccc1111222233334444555566667777bbbb" | jq -s -c '.' > "$d/moved.json"
  run_child "$d/moved.json" "$d/pin.baseline"; rc=$?; out="$(cat "$d/out.txt")"
  [ "$rc" = "1" ] && st_ok "(7) a pinned number at a NEW head is novel, not covered, and exits 1" \
    || st_bad "(7) expected rc 1 when the pinned head moved, got $rc"
  grep -q "is PINNED at head ${HEAD_A:0:9} and is reported at head" <<<"$out" \
    && st_ok "(7) …and the message says the pin is for a different tree" \
    || st_bad "(7) no head-moved explanation: $out"

  # (8) THE PARSER REFUSES A PIN WITHOUT A REASON, and says so.
  printf '9001 %s 2026-08-01\n' "${HEAD_A:0:9}" > "$d/noreason.baseline"
  run_child "$d/one.json" "$d/noreason.baseline"; rc=$?; out="$(cat "$d/out.txt")"
  [ "$rc" = "3" ] && st_ok "(8) a reasonless pin is a configuration fault (rc 3), not a silent allow" \
    || st_bad "(8) expected rc 3 for a reasonless pin, got $rc"
  grep -q "does not get in without a sentence" <<<"$out" \
    && st_ok "(8) …and the refusal explains the cost of a pin" \
    || st_bad "(8) the reasonless-pin refusal was unexplained: $out"

  # (9) A MISSPELLED --baseline NEVER DISARMS THE RATCHET.
  run_child "$d/one.json" "$d/no-such-file.baseline"; rc=$?; out="$(cat "$d/out.txt")"
  [ "$rc" = "3" ] && st_ok "(9) a --baseline that cannot be opened is rc 3, never an empty pin" \
    || st_bad "(9) expected rc 3 for a missing --baseline, got $rc"

  # (10) A NUMBER PINNED TWICE is refused rather than silently resolved.
  { printf '9001 %s 2026-08-01 first claim about this pull request\n' "${HEAD_A:0:9}"
    printf '9001 %s 2026-08-02 second claim about the same pull request\n' "${HEAD_A:0:9}"; } > "$d/dupe.baseline"
  run_child "$d/one.json" "$d/dupe.baseline"; rc=$?; out="$(cat "$d/out.txt")"
  [ "$rc" = "3" ] && st_ok "(10) a number pinned twice is refused (rc 3)" \
    || st_bad "(10) expected rc 3 for a duplicate pin, got $rc"

  # (11) DISARM. An empty population with an empty pin must be a clean 0 — if
  #      any of the reds above were unconditional, this is where it shows.
  run_child "$d/none.json" "$d/empty.baseline"; rc=$?; out="$(cat "$d/out.txt")"
  [ "$rc" = "0" ] && st_ok "(11) empty population + empty pin = 0; the reds above are conditional" \
    || st_bad "(11) an empty population with an empty pin exited $rc — something here reds unconditionally"
  grep -q "this string appears in no verdict" <<<"$out" \
    && st_bad "(11) a nonsense assertion passed — these greps match anything" \
    || st_ok "(11) a nonsense assertion fails, so the greps above are load-bearing"

  echo
  echo "── stale-verdict-watch --selftest: $SELFTEST_PASS passed, $SELFTEST_FAIL failed ──"
  [ "$SELFTEST_FAIL" -eq 0 ] || return 1
  return 0
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) REPO_OVERRIDE="${2:-}"; shift 2 ;;
      --branch) BRANCH="${2:-}"; shift 2 ;;
      --spec) SPEC="${2:-}"; shift 2 ;;
      --fixture) FIXTURE="${2:-}"; shift 2 ;;
      --commits) COMMITS_FILE="${2:-}"; shift 2 ;;
      # An ARGUMENT fault must not wear transport silence's name. `--attempts 0`
      # (or a non-numeric value) makes the poll loop never execute and `out`
      # stay unset, and the run then left through the transport arm printing
      # "could not list pull requests after 0 attempts" — a run that never
      # ASKED, described as a run that asked and was not answered. A
      # non-numeric value did worse: `[ "$i" -lt three ]` printed a bash
      # "integer expression expected" error and took the same exit.
      --page-size)
        PAGE_SIZE="${2:-}"; shift 2 || true
        case "$PAGE_SIZE" in
          ''|*[!0-9]*) red "--page-size must be a positive integer, got: '${PAGE_SIZE}'"; exit 3 ;;
        esac
        [ "$PAGE_SIZE" -ge 1 ] && [ "$PAGE_SIZE" -le 100 ] || { red "--page-size must be between 1 and 100: GitHub's connection cap is 100, and 0 rows per page is not a read."; exit 3; }
        ;;
      --page-attempts)
        PAGE_ATTEMPTS="${2:-}"; shift 2 || true
        case "$PAGE_ATTEMPTS" in
          ''|*[!0-9]*) red "--page-attempts must be a positive integer, got: '${PAGE_ATTEMPTS}'"; exit 3 ;;
        esac
        [ "$PAGE_ATTEMPTS" -ge 1 ] || { red "--page-attempts must be at least 1: a page nobody asks for is not a read."; exit 3; }
        ;;
      --attempts)
        ATTEMPTS="${2:-}"
        case "$ATTEMPTS" in
          ''|*[!0-9]*) red "--attempts must be a positive integer, got: '${ATTEMPTS}'"; exit 3 ;;
        esac
        [ "$ATTEMPTS" -ge 1 ] || { red "--attempts must be at least 1: 0 polls is not a read, and a run that never polls cannot report anything about the pull requests."; exit 3; }
        shift 2 ;;
      --min-commits) MIN_COMMITS="${2:-}"; shift 2 ;;
      --state-file) STATE_SVW="${2:-}"; shift 2 ;;
      --baseline) BASELINE="${2:-}"; BASELINE_EXPLICIT=1; shift 2 ;;
      --selftest) shift; selftest; return $? ;;
      -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
      *) red "unknown argument: $1"; exit 3 ;;
    esac
  done

  local repo req prs commits rc window verdict
  repo="${REPO_OVERRIDE:-$(spec_repo)}"
  req="$(required_contexts)" || { red "cannot read the required-check spec at $SPEC — this verdict has no set to check against"; exit 3; }
  [ -n "$req" ] && [ "$req" != "null" ] || { red "the spec at $SPEC lists no required contexts"; exit 3; }

  # THE PIN, loaded before anything is read. A `--baseline` a human typed and
  # got wrong is a hard 3: silently disarming a ratchet on a typo is exactly
  # the shape of failure this whole file exists to refuse. The COMMITTED
  # default going missing is different — it degrades to "everything is novel",
  # the strict direction — and it is SAID rather than swallowed.
  if [ -z "$BASELINE" ]; then
    BASELINE_JSON='[]'
    BASELINE_NOTE="baseline: explicitly disabled (--baseline '') — every stale verdict this run reports is NOVEL."
  elif [ -f "$BASELINE" ]; then
    parse_baseline "$BASELINE" || { red "the pinned baseline at $BASELINE is unreadable — this run refuses to treat an unparseable pin as an empty one."; exit 3; }
    BASELINE_NOTE="baseline: $(jq 'length' <<<"$BASELINE_JSON") pinned entr$( [ "$(jq 'length' <<<"$BASELINE_JSON")" = "1" ] && echo y || echo ies ) from ${BASELINE#"$REPO_ROOT/"}"
  elif [ "$BASELINE_EXPLICIT" = "1" ]; then
    red "no such baseline: $BASELINE — a --baseline this run cannot open is a typo, not an empty pin."
    exit 3
  else
    BASELINE_JSON='[]'
    BASELINE_NOTE="baseline: ${BASELINE#"$REPO_ROOT/"} is ABSENT. The ratchet falls back to 'every stale verdict is NOVEL' — the strict direction — and no pinned entry can be reported healed this run."
  fi

  # The START marker lands BEFORE any read is attempted, so a run cancelled
  # mid-poll — or one that leaves through 5/6/7 — is visible to the next run
  # as a dangling START and is counted UNREAD.
  state_start

  if [ -n "$FIXTURE" ]; then
    [ -f "$FIXTURE" ] || { red "no such fixture: $FIXTURE"; exit 3; }
    prs="$(cat "$FIXTURE")"
  else
    [ -n "$repo" ] || { red "no repo: pass --repo or commit one in $SPEC"; exit 3; }
    prs="$(fetch_prs "$repo")"; rc=$?
    case "$rc" in
      0) ;;
      3) red "CONFIGURATION FAULT — this run's credential cannot list pull requests (401/403). A watch that cannot read what it watches must not report success."
         red "$(printf '%s' "$prs" | head -3)"
         return 3 ;;
      *) red "UNREACHABLE — the pull-request list could not be read after $ATTEMPTS attempt(s), so this run classified nothing and does not know how many pull requests exist. This is a transport silence, not a green."
         return 6 ;;
    esac
  fi

  if [ -n "$COMMITS_FILE" ]; then
    [ -f "$COMMITS_FILE" ] || { red "no such commits fixture: $COMMITS_FILE"; exit 3; }
    commits="$(grep -v '^[[:space:]]*$' "$COMMITS_FILE")"
  else
    # The early return is CORRECTNESS, not defence. Falling through with an
    # empty commits array makes `commits_since` answer 0 for every green and
    # `select(.since >= $min)` drop all of them at MIN_COMMITS=1 — a
    # MANUFACTURED CLEAN VERDICT. Never "continue with what we have".
    commits="$(fetch_commits "$repo")" || {
      red "DISTANCE UNREADABLE — the pull requests were read and main's commit history was not, so the staleness distance is unknowable this run. That is a silence, not a green."
      return 7
    }
  fi

  window="$(printf '%s\n' "$commits" | grep -c . || true)"
  [ -n "$window" ] || window=0

  # BY FILE, NEVER BY ARGV. $prs is ~380 KB live and jq would never have
  # started; $commits is 6.9 KB at COMMIT_PAGES=3 and breaches the same ceiling
  # at roughly COMMIT_PAGES >= 54. Only small scalars remain on the command
  # line. --slurpfile wraps each file in an outer array, so the program binds
  # $prs_in[0] / $commits_in[0] before the verdict body reads $prs / $commits.
  local prs_file="$WATCH_TMP/prs.json" commits_file="$WATCH_TMP/commits.json"
  printf '%s' "$prs" > "$prs_file"
  { printf '%s\n' "$commits" | grep . | jq -R . | jq -s -c . > "$commits_file"; } || true
  [ -s "$commits_file" ] || printf '[]' > "$commits_file"

  verdict="$(jq -c -n \
      --slurpfile prs_in "$prs_file" \
      --slurpfile commits_in "$commits_file" \
      --argjson req "$req" \
      --argjson min "$MIN_COMMITS" \
      --argjson window "$window" \
      "\$prs_in[0] as \$prs | \$commits_in[0] as \$commits | \$prs | $VERDICT_JQ")" || {
    red "COMPUTE FAULT — the pull-request payload was READ ($(wc -c < "$prs_file" | tr -d ' ') bytes) and the verdict could not be computed from it. This is not a credential fault: nothing here says the token cannot read."
    return 4
  }

  # THE DELTA against the pin. Folded into the same document the renderer
  # reads, so the verdict line and the exit code below cannot be computed from
  # two different partitions.
  local base_file="$WATCH_TMP/baseline.json" ratchet_jq="$RATCHET_JQ"
  printf '%s' "$BASELINE_JSON" > "$base_file"
  # MUTATION SWITCHES. Read ONLY inside a --selftest child; a production run
  # has SELFTEST_CHILD=0 and never looks at the variable, so an ambient
  # SVW_MUTATE in a real environment cannot reach the partition.
  if [ "$SELFTEST_CHILD" = "1" ]; then
    case "${SVW_MUTATE:-}" in
      pin-any)     ratchet_jq="$(printf '%s' "$ratchet_jq" | sed 's/] | length == 0) ] as \$novel/] | length >= 0 and false) ] as $novel/')" ;;
      never-healed) ratchet_jq="$(printf '%s' "$ratchet_jq" | sed 's/| . + { gone: ((\$SEEN | index(\$b.number)) == null) } ] as \$healed/| select(false) ] as $healed/')" ;;
      head-blind)  ratchet_jq="$(printf '%s' "$ratchet_jq" | sed 's/select(\$b.number == \$r.number and (\$r.head | startswith(\$b.head)))/select($b.number == $r.number)/g')" ;;
      '') ;;
      *) red "SVW_MUTATE='${SVW_MUTATE:-}' is not a mutation this file defines"; return 3 ;;
    esac
    # A MUTATION THAT DID NOT APPLY IS NOT A MUTATION. If the sed above ever
    # stops matching (someone reflows the jq), the "mutant" is the pristine
    # program and every probe passes — a disarm test that proved nothing.
    if [ -n "${SVW_MUTATE:-}" ] && [ "$ratchet_jq" = "$RATCHET_JQ" ]; then
      red "SVW_MUTATE='$SVW_MUTATE' matched nothing in RATCHET_JQ — the mutant is identical to the original, so any probe against it is vacuous."
      return 3
    fi
  fi
  verdict="$(jq -c --slurpfile base_in "$base_file" --arg note "$BASELINE_NOTE" \
      "\$base_in[0] as \$base | $ratchet_jq" <<<"$verdict")" || {
    red "COMPUTE FAULT — the verdict was computed and the ratchet partition against the pinned baseline was not."
    return 4
  }

  printf '%s' "$verdict" | render

  local reported unknown open classified novel_n healed_n known_n
  reported="$(jq '.reported | length' <<<"$verdict")"
  unknown="$(jq '.unknown | length' <<<"$verdict")"
  open="$(jq '.open' <<<"$verdict")"
  classified="$(jq '.classified' <<<"$verdict")"
  novel_n="$(jq '.ratchet.novel | length' <<<"$verdict")"
  known_n="$(jq '.ratchet.known | length' <<<"$verdict")"
  healed_n="$(jq '.ratchet.healed | length' <<<"$verdict")"
  # The trend is computed BEFORE this run writes its own READ line, so the
  # baseline is always a PREVIOUS read — and only a run that actually read
  # (classified > 0, or a legitimately empty population) becomes one. A BLIND
  # run writes no READ: its dangling START is the next run's UNREAD count.
  say ""
  trend_report "$reported" "$novel_n"
  if [ "${open:-0}" -eq 0 ] || [ "${classified:-0}" -gt 0 ]; then # MUT:G-READLINE
    state_read "$reported" "$classified" "$open" "$novel_n"
  fi
  step_summary "$verdict" "$reported" "$novel_n" "$known_n" "$healed_n"

  # THE ORDER MIRRORS render()'s VERDICT ARMS, and it is not arbitrary:
  #   novel first — the only arm that says a NEW pull request needs a human;
  #   blind next  — a run that classified nothing must not issue a ratchet
  #                 verdict about a population it could not read;
  #   healed next — a firm, actionable fact about a committed file;
  #   unknown     — partial coverage;
  #   0           — including a non-empty KNOWN set, which is the whole point.
  if [ "${novel_n:-0}" -gt 0 ]; then return 1; fi
  # BEFORE the unknown check: a run that classified nothing is a stronger
  # statement than "some rows went unread", and 2 is mapped to success by the
  # workflow. An empty population is not blind — it is a read that found no
  # pull requests, which is a legitimate 0.
  if [ "${open:-0}" -gt 0 ] && [ "${classified:-0}" -eq 0 ]; then return 5; fi
  if [ "${healed_n:-0}" -gt 0 ]; then return 8; fi
  if [ "$unknown" -gt 0 ]; then return 2; fi
  return 0
}

main "$@"
