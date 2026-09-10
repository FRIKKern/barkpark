#!/usr/bin/env bash
# merge-sweep.sh — while lane leads are down (quota), squash-merge campaign PRs whose FOUR required
# checks are green by head sha. Skips drafts, "DO NOT MERGE", and PRs whose title says WIP/hold.
# Never closes ledger rows (that is the lead's judgment); logs every merge to $ORCH/merge-sweep.log.
#
# THE SQUASH BODY IS NOT THE PR BODY — measured 2026-09-09T22:47Z by lead-cli.
# This repo's squash setting is COMMIT_MESSAGES, so `gh pr merge --squash` with no --subject/--body
# writes the BRANCH's commit messages onto main. The `Task:` trailer lives in the PR BODY (that is
# where pr-task-gate reads it), so every PR this sweep merged that way landed a commit with NO
# trailer, .github/workflows/landed-mark.yml read nothing, and the row stayed open with a stale
# assignee and no claim — the exact state landed-mark exists to remove. Over origin/main
# 2026-09-09 16:00Z..23:00Z that was 30 squash commits and 28 distinct rows, none marked.
# So this sweep now passes --subject/--body explicitly, and REFUSES to merge a PR whose body has no
# column-0 `Task:` line at all: merging it would strand the landing a second way, and the required
# `PR references an active task` gate means a body without one is an anomaly worth a human's eye.
#
# scripts/landed-mark.sh now ALSO falls back from the commit body to the PR body via REST, so a
# landing is marked even when a sweep somewhere forgets this. Belt and braces, deliberately: this
# half is the cheap one and it keeps main's history readable.
#
# USAGE: bash merge-sweep.sh [owner/repo]   ·   bash merge-sweep.sh --selftest   (hermetic, no gh)
# EXIT: 0 swept · 3 at least one PR could not be MEASURED (CANNOT READ) — never folded into skipped.
set -u

# The trailer PRESENCE probe. It is deliberately NOT a second grammar: scripts/pr-task-gate.sh owns
# the `Task:` rule and the required merge gate has already run it against this PR. This only asks
# whether a column-0 trailer is there at all, so the sweep can refuse to squash a body that would
# land trailer-less. A here-string, never `printf | grep -q`: under `pipefail` the writer takes
# SIGPIPE when grep exits at the first match and the pipeline reports 141 — a false NO under load.
has_task_trailer() { # $1 body -> rc 0 when a column-0 Task: trailer is present
  grep -qiE '^task:[[:space:]]*`?[a-z0-9]' <<<"${1:-}"
}

if [ "${1:-}" = "--selftest" ]; then
  # Hermetic: no gh, no network, no repo. It exercises the arm that decides whether a PR is merged.
  p=0; f=0
  t() { if [ "$2" = "$3" ]; then p=$((p+1)); echo "  PASS  $1"; else f=$((f+1)); echo "  FAIL  $1 (want $3, got $2)"; fi; }
  y() { has_task_trailer "$1" && echo yes || echo no; }
  echo "merge-sweep --selftest"
  t "a column-0 trailer is found"            "$(y "$(printf 'prose\n\nTask: task-abc123\n')")" yes
  # shellcheck disable=SC2016  # the backticks are the FIXTURE — the #5290 shape, not a substitution.
  t "a backtick-wrapped id is found (#5290)" "$(y "$(printf 'Task: `task-abc123`\n')")"        yes
  t "a lowercase label is found"             "$(y "$(printf 'task: task-abc123\n')")"          yes
  t "an INDENTED example is NOT a trailer"   "$(y "$(printf 'see this:\n\n    Task: task-abc\n')")" no
  t "a mid-sentence mention is NOT a trailer" "$(y "$(printf 'closes the Task: task-abc row\n')")" no
  t "a label with no id is NOT a trailer"    "$(y "$(printf 'Task:\n')")"                      no
  t "an EMPTY body is NOT a trailer"         "$(y "")"                                         no
  echo "merge-sweep --selftest: ${p} passed, ${f} failed"
  [ "$f" -eq 0 ] || exit 1
  exit 0
fi

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
merged=0; skipped=0; refused=0; trailerless=0
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
  # The title and body ARE the squash commit now, so a failed read of either is a CANNOT READ and
  # never a merge with a default message: falling back to the default is how the 30 trailer-less
  # squashes happened, and it would look identical in the log to a clean merge.
  meta=$(gh pr view "$pr" --repo "$REPO" --json title,body 2>/dev/null)
  if [ -z "$meta" ]; then
    refused=$((refused+1))
    echo "$(date -u +%H:%MZ) CANNOT READ #$pr: gh pr view returned nothing — title/body unknown, NOT merged (this is not 'no trailer')" >> "$ORCH/merge-sweep.log"
    continue
  fi
  title=$(printf '%s' "$meta" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("title") or "")')
  body=$(printf '%s' "$meta" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("body") or "")')
  if ! has_task_trailer "$body"; then
    trailerless=$((trailerless+1))
    echo "$(date -u +%H:%MZ) SKIPPED #$pr: no Task: trailer in PR body" >> "$ORCH/merge-sweep.log"
    continue
  fi
  if out=$(gh pr merge "$pr" --repo "$REPO" --squash --delete-branch --subject "$title (#$pr)" --body "$body" 2>&1); then
    merged=$((merged+1)); echo "$(date -u +%H:%MZ) MERGED #$pr $(printf '%s' "$title" | cut -c1-80)" >> "$ORCH/merge-sweep.log"
  else
    echo "$(date -u +%H:%MZ) REFUSED #$pr: $(echo "$out" | tail -1 | cut -c1-140)" >> "$ORCH/merge-sweep.log"
  fi
done
if [ "$refused" -gt 0 ]; then
  echo "$(date -u +%H:%MZ) merge-sweep: merged $merged, not-yet $skipped, no-trailer $trailerless, CANNOT READ $refused (those $refused were NOT measured — they are not 'not yet')"
  exit 3
fi
echo "$(date -u +%H:%MZ) merge-sweep: merged $merged, not-yet $skipped, no-trailer $trailerless, CANNOT READ 0"
