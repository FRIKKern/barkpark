#!/usr/bin/env bash
# pr-required.sh <pr-number> [owner/repo] — the truth about a PR's REQUIRED checks, by head sha.
# `gh pr checks` renders cancelled/queued in the same column as fail; this reads check-runs for the
# PR's current head and prints one line per required context with its real status/conclusion.
set -u
PR="${1:?pr number}"; REPO="${2:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
REQ='Elixir gate|PR references an active task|Cloud gate|Console gate'
SHA=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid)
gh api "repos/$REPO/commits/$SHA/check-runs?per_page=100" --paginate \
  --jq '.check_runs[] | "\(.name)\t\(.status)\t\(.conclusion // "-")\t\(.started_at // "-")"' \
  | grep -E "^($REQ)	" | sort -t$'\t' -k1,1 -k4,4r | awk -F'\t' '!seen[$1]++' \
  | awk -F'\t' -v sha="$SHA" 'BEGIN{ok=0;n=0} {n++; printf "%-32s %-12s %s\n",$1,$2,$3; if($3=="success")ok++} END{printf "%s: %d/4 required green on %s\n",(ok==4?"MERGEABLE":"NOT YET"),ok,substr(sha,1,10)}'

# EARLY RED: the aggregate "Elixir gate" context stays QUEUED for 20+ min while the
# `Test (Elixir …)` job it depends on has already FAILED (measured 2026-09-02 by lead-papers-o).
# Surface any failed underlying job so a lead does not read "queued" as "still waiting".
gh api "repos/$REPO/commits/$SHA/check-runs?per_page=100" --paginate \
  --jq '.check_runs[] | select(.conclusion=="failure") | select(.name|test("^(Elixir gate|PR references an active task|Cloud gate|Console gate)$")|not) | .name' 2>/dev/null \
  | sort -u | sed 's/^/  EARLY RED (underlying job): /'
