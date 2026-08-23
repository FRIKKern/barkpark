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
# EXIT CODES  0 = no conflicted PR asserts a stale green
#             1 = at least one does — RED, and it will red again in 30 minutes
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
#
# USAGE
#   scripts/stale-verdict-watch.sh
#   scripts/stale-verdict-watch.sh --repo FRIKKern/barkpark --min-commits 1
#   scripts/stale-verdict-watch.sh --fixture prs.json --commits main-commits.txt
#
# The two fixture flags make every classification hermetically provable; see
# scripts/stale-verdict-watch.test.sh.

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
ATTEMPTS=3
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

PR_FIELDS="number,mergeable,mergeStateStatus,headRefOid,updatedAt,statusCheckRollup"

# One call returns every field the verdict needs (measured at 6.28s over 40 open
# PRs). Re-polled while any row is still UNKNOWN.
fetch_prs() { # -> prints JSON array, or the error body on failure
  local repo="$1" out i=0 sleep_for unknown
  while [ "$i" -lt "$ATTEMPTS" ]; do
    i=$((i + 1))
    if out="$(gh pr list --repo "$repo" --state open --limit 100 --json "$PR_FIELDS" 2>&1)"; then
      unknown="$(jq '[.[] | select(.mergeable == "UNKNOWN")] | length' <<<"$out" 2>/dev/null || echo 0)"
      if [ "${unknown:-0}" = "0" ] || [ "$i" -ge "$ATTEMPTS" ]; then
        printf '%s' "$out"
        return 0
      fi
      red "  poll $i/$ATTEMPTS: $unknown row(s) answered mergeable=UNKNOWN (lazily computed) — re-polling"
    else
      if is_config_fault "$out"; then
        printf '%s' "$out"
        return 3
      fi
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

render() { # reads the verdict JSON on stdin
  jq -r '
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
    (if (.reported | length) > 0
     then "RED — \(.reported | length) CONFLICTING pull request(s) assert a green required verdict main has moved past. A conflicted PR re-dispatches NOTHING: this cannot clear itself."
     elif .blind
     then "BLIND — classified 0 of \(.open) open pull request(s): the mergeability of every row was still UNKNOWN after re-polling, so this run classified NOTHING. This is NOT a green — a run that could not look cannot report the population clean."
     elif (.unknown | length) > 0
     then "INCONCLUSIVE — classified \(.classified) of \(.open) open pull request(s); \(.unknown | length) row(s) went unread. No CONFLICTING row in the part this run COULD read is asserting a stale green — that says nothing about the rows below."
     else "ok — no CONFLICTING pull request is asserting a green required verdict that main has moved past (classified \(.classified) of \(.open) open)." end),
    (.reported | sort_by(.number)[] |
      "",
      "  #\(.number)  \(.mergeStateStatus)  head \(.headRefOid[0:9])  verdict as of \(.updatedAt)",
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

state_read() { # <reported> <classified> <open> — only a run that READ may call this
  [ -n "$STATE_SVW" ] || return 0
  echo "READ $(date -u +%Y-%m-%dT%H:%M:%SZ) reported=$1 classified=$2 open=$3" >> "$STATE_SVW" 2>/dev/null || true
}

trend_report() { # <reported> — how the count moved since the last READ run
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
      --attempts)
        ATTEMPTS="${2:-}"
        case "$ATTEMPTS" in
          ''|*[!0-9]*) red "--attempts must be a positive integer, got: '${ATTEMPTS}'"; exit 3 ;;
        esac
        [ "$ATTEMPTS" -ge 1 ] || { red "--attempts must be at least 1: 0 polls is not a read, and a run that never polls cannot report anything about the pull requests."; exit 3; }
        shift 2 ;;
      --min-commits) MIN_COMMITS="${2:-}"; shift 2 ;;
      --state-file) STATE_SVW="${2:-}"; shift 2 ;;
      -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
      *) red "unknown argument: $1"; exit 3 ;;
    esac
  done

  local repo req prs commits rc window verdict
  repo="${REPO_OVERRIDE:-$(spec_repo)}"
  req="$(required_contexts)" || { red "cannot read the required-check spec at $SPEC — this verdict has no set to check against"; exit 3; }
  [ -n "$req" ] && [ "$req" != "null" ] || { red "the spec at $SPEC lists no required contexts"; exit 3; }

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

  printf '%s' "$verdict" | render

  local reported unknown open classified
  reported="$(jq '.reported | length' <<<"$verdict")"
  unknown="$(jq '.unknown | length' <<<"$verdict")"
  open="$(jq '.open' <<<"$verdict")"
  classified="$(jq '.classified' <<<"$verdict")"
  # The trend is computed BEFORE this run writes its own READ line, so the
  # baseline is always a PREVIOUS read — and only a run that actually read
  # (classified > 0, or a legitimately empty population) becomes one. A BLIND
  # run writes no READ: its dangling START is the next run's UNREAD count.
  say ""
  trend_report "$reported"
  if [ "${open:-0}" -eq 0 ] || [ "${classified:-0}" -gt 0 ]; then # MUT:G-READLINE
    state_read "$reported" "$classified" "$open"
  fi
  if [ "$reported" -gt 0 ]; then return 1; fi
  # BEFORE the unknown check: a run that classified nothing is a stronger
  # statement than "some rows went unread", and 2 is mapped to success by the
  # workflow. An empty population is not blind — it is a read that found no
  # pull requests, which is a legitimate 0.
  if [ "${open:-0}" -gt 0 ] && [ "${classified:-0}" -eq 0 ]; then return 5; fi
  if [ "$unknown" -gt 0 ]; then return 2; fi
  return 0
}

main "$@"
