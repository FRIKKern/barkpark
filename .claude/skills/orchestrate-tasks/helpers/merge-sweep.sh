#!/usr/bin/env bash
# merge-sweep.sh — while lane leads are down (quota), squash-merge campaign PRs whose FOUR required
# checks are green by head sha. Skips drafts, "DO NOT MERGE", and PRs whose title says WIP/hold.
# Never closes ledger rows (that is the lead's judgment); logs every merge to $ORCH/merge-sweep.log.
set -u
ORCH="${ORCH:?}"
# Resolve owner/repo WITHOUT GraphQL and WITHOUT depending on the cwd (which resets between tool
# calls in this harness): arg 1, then $GH_REPO, then the git remote of the cwd, then gh repo view.
# An empty $REPO here makes every pr-required.sh call below read a "repos//…" 404 (see the
# CANNOT READ note in helpers/pr-required.sh); refuse instead of sweeping against nothing.
REPO="${1:-${GH_REPO:-}}"
if [ -z "$REPO" ]; then
  u=$(git config --get remote.origin.url 2>/dev/null || true); u="${u%.git}"; u="${u%/}"
  case "$u" in *[:/]*/*) REPO="$(basename "$(dirname "$u")")/$(basename "$u")";; esac
fi
[ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
if [ -z "$REPO" ]; then
  echo "CANNOT READ: merge-sweep could not resolve owner/repo — pass it as arg 1 or set GH_REPO. Nothing was swept; this is NOT 'zero PRs mergeable'."
  exit 3
fi
merged=0; skipped=0; refused=0
for pr in $(gh pr list --repo "$REPO" --state open --limit 300 --json number,headRefName,baseRefName,isDraft,title --jq '.[]|select(.isDraft|not)|select(.baseRefName=="main")|select(.headRefName|test("^(security|sec2|gates|deploy|console|cli|cli2|studio|docs|pds|grip|instr|chat|orch)/"))|select(.title|test("DO NOT MERGE|WIP|HOLD";"i")|not)|.number'); do
  v=$(bash "$ORCH/pr-required.sh" "$pr" "$REPO" 2>/dev/null | tail -1)
  # A REFUSAL is not a NOT-YET. pr-required.sh prints a "CANNOT READ" last line and exits 3 when a
  # read failed; folding that into $skipped reproduces, one level up, the very lie this instrument
  # was hardened against — "not-yet 6" would read identically whether six PRs were red or the
  # instrument could not see any of them. Count and name them separately.
  case "$v" in
    MERGEABLE*)   ;;
    "CANNOT READ"*) refused=$((refused+1))
                  echo "$(date -u +%H:%MZ) CANNOT READ #$pr: $(printf '%s' "$v" | cut -c1-140)" >> "$ORCH/merge-sweep.log"
                  continue;;
    *)            skipped=$((skipped+1)); continue;;
  esac
  if out=$(gh pr merge "$pr" --repo "$REPO" --squash --delete-branch 2>&1); then
    merged=$((merged+1)); echo "$(date -u +%H:%MZ) MERGED #$pr $(gh pr view "$pr" --repo "$REPO" --json title --jq .title | cut -c1-80)" >> "$ORCH/merge-sweep.log"
  else
    echo "$(date -u +%H:%MZ) REFUSED #$pr: $(echo "$out" | tail -1 | cut -c1-140)" >> "$ORCH/merge-sweep.log"
  fi
done
if [ "$refused" -gt 0 ]; then
  echo "$(date -u +%H:%MZ) merge-sweep: merged $merged, not-yet $skipped, CANNOT READ $refused (those $refused were NOT measured — they are not 'not yet')"
  exit 3
fi
echo "$(date -u +%H:%MZ) merge-sweep: merged $merged, not-yet $skipped, CANNOT READ 0"
