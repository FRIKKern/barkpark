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
# EXIT CODES  0 = no conflicted PR asserts a stale green
#             1 = at least one does — RED, and it will red again in 30 minutes
#             2 = no red, but rows stayed UNKNOWN after re-polling (warning)
#             3 = CONFIGURATION fault: the credential cannot list PRs
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

SPEC="$REPO_ROOT/.github/required-checks.json"
REPO_OVERRIDE=""
BRANCH="main"
FIXTURE=""
COMMITS_FILE=""
ATTEMPTS=3
MIN_COMMITS=1
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
    (if (.reported | length) == 0
     then "ok — no CONFLICTING pull request is asserting a green required verdict that main has moved past."
     else "RED — \(.reported | length) CONFLICTING pull request(s) assert a green required verdict main has moved past. A conflicted PR re-dispatches NOTHING: this cannot clear itself." end),
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

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) REPO_OVERRIDE="${2:-}"; shift 2 ;;
      --branch) BRANCH="${2:-}"; shift 2 ;;
      --spec) SPEC="${2:-}"; shift 2 ;;
      --fixture) FIXTURE="${2:-}"; shift 2 ;;
      --commits) COMMITS_FILE="${2:-}"; shift 2 ;;
      --attempts) ATTEMPTS="${2:-}"; shift 2 ;;
      --min-commits) MIN_COMMITS="${2:-}"; shift 2 ;;
      -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
      *) red "unknown argument: $1"; exit 3 ;;
    esac
  done

  local repo req prs commits rc window verdict
  repo="${REPO_OVERRIDE:-$(spec_repo)}"
  req="$(required_contexts)" || { red "cannot read the required-check spec at $SPEC — this verdict has no set to check against"; exit 3; }
  [ -n "$req" ] && [ "$req" != "null" ] || { red "the spec at $SPEC lists no required contexts"; exit 3; }

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
      *) red "could not list pull requests after $ATTEMPTS attempts — this is a transport silence, not a green."
         return 2 ;;
    esac
  fi

  if [ -n "$COMMITS_FILE" ]; then
    [ -f "$COMMITS_FILE" ] || { red "no such commits fixture: $COMMITS_FILE"; exit 3; }
    commits="$(grep -v '^[[:space:]]*$' "$COMMITS_FILE")"
  else
    commits="$(fetch_commits "$repo")" || {
      red "main's commit history could not be read — the staleness distance is unknowable this run, which is a silence, not a green."
      return 2
    }
  fi

  window="$(printf '%s\n' "$commits" | grep -c . || true)"
  [ -n "$window" ] || window=0

  verdict="$(jq -c -n \
      --argjson prs "$prs" \
      --argjson req "$req" \
      --argjson commits "$(printf '%s\n' "$commits" | grep . | jq -R . | jq -s -c .)" \
      --argjson min "$MIN_COMMITS" \
      --argjson window "$window" \
      "\$prs | $VERDICT_JQ")" || { red "the verdict could not be computed from the payload"; return 3; }

  printf '%s' "$verdict" | render

  local reported unknown
  reported="$(jq '.reported | length' <<<"$verdict")"
  unknown="$(jq '.unknown | length' <<<"$verdict")"
  if [ "$reported" -gt 0 ]; then return 1; fi
  if [ "$unknown" -gt 0 ]; then return 2; fi
  return 0
}

main "$@"
