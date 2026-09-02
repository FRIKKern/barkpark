#!/usr/bin/env bash
# pr-required.sh <pr-number> [owner/repo] — the truth about a PR's REQUIRED checks, by head sha.
# `gh pr checks` renders cancelled/queued in the same column as fail; this reads check-runs for the
# PR's current head and prints one line per required context with its real status/conclusion.
#
# CONTRACT: the verdict line ("MERGEABLE: 4/4 …" / "NOT YET: n/4 …" / "CONFLICTING: 4/4 … DIRTY") is ALWAYS THE LAST LINE. MERGEABLE now also means not DIRTY.
# Callers do `| tail -1`. Anything appended after it silently swaps what every wrapper reads
# (measured 2026-09-02: an EARLY RED section appended here made a lane's watcher report a job
# name where the verdict should be, and would have stopped the merge sweep merging anything).
set -u
PR="${1:?pr number}"; # `gh repo view --json` ALSO goes over GraphQL, and it is resolved from the CALLER'S cwd — which
# resets between tool calls in this harness. Both failure modes yield an EMPTY $REPO, and every
# URL below then becomes "repos//..." which 404s. Same lie as the sha: refuse, do not report 0/4.
REPO="${2:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"
if [ -z "$REPO" ]; then
  echo "CANNOT READ: no owner/repo — pass it as arg 2, or run from inside the repo. GraphQL (which gh repo view uses) may also be spent. This is NOT a verdict, and NOT 0/4."
  exit 3
fi
REQ='Elixir gate|PR references an active task|Cloud gate|Console gate'
# READ THE HEAD SHA, AND REFUSE IF IT CANNOT BE READ (lead-silent, 2026-09-02).
# `gh pr view --json` goes over GraphQL, which has its OWN per-user limit that empties long
# before REST does — `gh api rate_limit` can report graphql 5000/5000 remaining while every
# gh pr view returns "API rate limit already exceeded for user ID". When that happened, SHA
# went EMPTY, the check-runs URL became .../commits//check-runs and 404'd, RUNS was empty, and
# this script printed "NOT YET: 0/4 required green on " AND EXITED 0. A failed read was
# byte-identical to "nothing is green" for every one of the eighteen lanes reading `| tail -1`,
# and the merge sweep would have stalled the whole campaign without one error anyone could see.
# So: fall back to REST (which still works when GraphQL is spent), and if BOTH fail, REFUSE on
# the LAST line with a non-zero exit rather than reporting a number we did not measure.
SHA=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null || true)
if [ -z "$SHA" ]; then
  SHA=$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha 2>/dev/null || true)
fi
if [ -z "$SHA" ]; then
  echo "CANNOT READ: pr #$PR head sha unreadable over BOTH GraphQL and REST — this is NOT a verdict, and NOT 0/4. Check \`gh auth status\` and \`gh api rate_limit\`; GraphQL empties before REST does."
  exit 3
fi
# MERGE STATE: four green checks do NOT mean the PR can merge; a DIRTY branch is refused by GitHub regardless.
# Read mergeable_state over REST (one call) so the LAST LINE never says MERGEABLE for a conflicting branch.
MSTATE=$(gh api "repos/$REPO/pulls/$PR" --jq '.mergeable_state // "-"' 2>/dev/null || echo "-")
if ! RUNS=$(gh api "repos/$REPO/commits/$SHA/check-runs?per_page=100" --paginate \
  --jq '.check_runs[] | "\(.name)\t\(.status)\t\(.conclusion // "-")\t\(.started_at // "-")"' 2>/dev/null); then
  echo "CANNOT READ: check-runs for $REPO@${SHA:0:10} could not be fetched — this is NOT a verdict, and NOT 0/4."
  exit 3
fi
# A head with ZERO check runs is also not a verdict: CI has not started, or the read was empty
# for a reason we cannot see. Saying "0/4" there is the same lie in a quieter voice.
if [ -z "$RUNS" ]; then
  echo "CANNOT READ: $REPO@${SHA:0:10} has NO check runs at all — CI has not started, or the read came back empty. This is NOT a verdict, and NOT 0/4."
  exit 3
fi

# EARLY RED, printed BEFORE the verdict: the aggregate "Elixir gate" context stays QUEUED for
# 20+ min while the `Test (Elixir …)` job it depends on has already FAILED. Advisory jobs are
# excluded by name — Format/Boundary/spec-drift are advisory and most api PRs carry one, so
# naming them here would make the line fire on everything and stop discriminating.
printf '%s\n' "$RUNS" | awk -F'\t' '$3=="failure"{print $1}' \
  | grep -viE 'advisory' | grep -vE "^($REQ)$" | sort -u \
  | sed 's/^/  RED non-required job (blocks the aggregate ONLY if it is in elixir.yml needs; security.yml reds do NOT): /'

# ABSENT vs FAILED: a required context with NO check run on this head (its dispatcher was cancelled, or the run
# was evicted) reads as "3/4" exactly like a failing one, and needs the OPPOSITE remedy (re-fire the dispatcher /
# update-branch, not fix the code). Name the absent ones explicitly, before the verdict.
ABSENT=$(printf '%s\n' "$REQ" | tr '|' '\n' | while read -r ctx; do printf '%s\n' "$RUNS" | grep -qF "$ctx	" || printf '%s; ' "$ctx"; done)
[ -n "$ABSENT" ] && echo "  ABSENT required context (no check run on this head — re-fire with: gh api -X PUT repos/$REPO/pulls/$PR/update-branch): ${ABSENT%; }"
printf '%s\n' "$RUNS" | grep -E "^($REQ)	" | sort -t$'\t' -k1,1 -k4,4r | awk -F'\t' '!seen[$1]++' \
  | awk -F'\t' -v sha="$SHA" -v ms="$MSTATE" -v absent="$ABSENT" 'BEGIN{ok=0;n=0} {n++; printf "%-32s %-12s %s\n",$1,$2,$3; if($3=="success")ok++} END{ if(ok==4 && ms=="dirty") printf "CONFLICTING: 4/4 required green on %s but the branch is DIRTY — rebase before merge\n",substr(sha,1,10); else if(ok<4 && absent!="") printf "NOT YET: %d/4 required green on %s (%d ABSENT — re-fire, do not debug)\n",ok,substr(sha,1,10),4-n; else printf "%s: %d/4 required green on %s\n",(ok==4?"MERGEABLE":"NOT YET"),ok,substr(sha,1,10)}'
