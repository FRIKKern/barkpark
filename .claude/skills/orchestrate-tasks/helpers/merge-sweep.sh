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
# AN OPEN REVIEW HOLDS THE PR — task-435620b0f02720b2, measured harm 2026-09-06.
# This sweep enforced the four required contexts and nothing else, so it could not tell "green and
# REVIEWED" from "green and AWAITING a lead's review". #16615 was taken at 4/4 about two minutes
# before its author pushed a follow-up; three advisory checks then landed red on main and needed
# #16618 to repair. A console PR was saved only by being converted to draft with ten minutes to
# spare. The only hold that existed was the DO NOT MERGE|WIP|HOLD title regex below — a convention
# living in one script and written down nowhere, which FAILS OPEN: forget the word and the PR lands.
# So the sweep now also reads GitHub's own review state and REFUSES a PR that carries an open one.
# See review_hold() for the signal, the do-nothing default, and why it is the safe one.
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

# THE REVIEW HOLD (task-435620b0f02720b2). The signal is GITHUB'S OWN REVIEW STATE, not a word in
# a title and not a file this script invented:
#
#   HOLD 1  a PENDING REVIEW REQUEST — someone is on the Reviewers list and has not reviewed yet.
#   HOLD 2  an unresolved CHANGES_REQUESTED — a reviewer's latest state is still CHANGES_REQUESTED
#           (a later APPROVED or DISMISSED from that same reviewer clears it).
#
# WHY THIS SIGNAL. It is DISCOVERABLE without reading this script: it is the Reviewers box and the
# "Changes requested" banner in GitHub's own PR sidebar, which every author already sees, and it is
# restated in .claude/skills/orchestrate-tasks/SKILL.md under "Rules that are not optional" — so a
# stranger meets it in two places, neither of which is this file. It is also EMITTED BY THE ACT OF
# REVIEWING: a lead that starts a review requests one or leaves one, and that IS the hold. Nothing
# separate has to be remembered, which is precisely where the title convention failed — there the
# hold was a SECOND act (edit the title), easy to skip while doing the first.
#
# THE DO-NOTHING DEFAULT IS MERGE, AND THAT IS THE SAFE ONE. A PR with nobody requested and no
# review left behaves exactly as it does today. That default is deliberate in both directions:
# making "no review state" a hold would stall every PR in the backlog behind a human, i.e. delete
# the sweep by making it never fire, and it would be indistinguishable from the sweep breaking.
# The property bought here is narrower and it is the one the incidents needed: a lane that HAS
# started looking cannot be overtaken. Crucially the absence of this signal cannot be manufactured
# by forgetting a word — editing, shortening, or retitling a PR does not touch its review state,
# and there is no title spelling that removes a pending request.
#
# A FAILED READ IS NOT AN ABSENCE. An empty or unparseable payload is a CANNOT READ and the PR is
# NOT merged; a review state this script could not see must never be byte-identical to "no review".
#
# TWO REST READS, NO GRAPHQL, and only for a PR that already passed the four required contexts:
#   GET /repos/O/R/pulls/N/requested_reviewers  -> {"users":[{"login":…}],"teams":[{"slug":…}]}
#   GET /repos/O/R/pulls/N/reviews?per_page=100 -> [{"user":{"login":…},"state":…,"submitted_at":…}]
# `gh pr view --json reviewDecision` would answer in one call but it is GraphQL, and this campaign
# has exhausted that shared budget before. The SELECTING is done here, by jq, over the raw arrays —
# so the harness can stub transport and still exercise this decision.
#
# NO TIME DELAY IS ADDED. A timer would slow every merge to catch a rare case and it still cannot
# tell reviewed from unreviewed; it only lengthens the race. Explicitly rejected by the row.
review_hold() { # $1 requested_reviewers JSON, $2 reviews JSON
                # rc 0 no hold · rc 1 HOLD (reason on stdout) · rc 2 CANNOT READ
  local req="${1:-}" revs="${2:-}" pending changes rc
  # EMPTY IS NOT EMPTY-SET. `jq` over no input at all prints nothing and exits 0, which would make a
  # failed REST read indistinguishable from "nobody is reviewing" — the exact laundering this
  # function refuses. The selftest holds this arm ("an EMPTY reviews payload CANNOT READ").
  [ -n "$req" ] && [ -n "$revs" ] || return 2
  pending=$(printf '%s' "$req" | jq -r '
      (if type=="object" then . else error("requested_reviewers payload is not an object") end)
      | [ ((.users // [])[] | .login), ((.teams // [])[] | .slug) ] | join(",")' 2>/dev/null)
  rc=$?; [ "$rc" -eq 0 ] || return 2
  changes=$(printf '%s' "$revs" | jq -r '
      (if type=="array" then . else error("reviews payload is not an array") end)
      | [ .[] | select(.state=="APPROVED" or .state=="CHANGES_REQUESTED" or .state=="DISMISSED") ]
      | group_by(.user.login)
      | map(sort_by(.submitted_at // "") | last)
      | map(select(.state=="CHANGES_REQUESTED") | .user.login)
      | join(",")' 2>/dev/null)
  rc=$?; [ "$rc" -eq 0 ] || return 2
  if [ -n "$changes" ]; then
    echo "an unresolved CHANGES_REQUESTED review from $changes"
    return 1
  fi
  if [ -n "$pending" ]; then
    echo "a pending review request for $pending"
    return 1
  fi
  return 0
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
  # THE REVIEW HOLD arm (task-435620b0f02720b2). `h` prints the rc and the reason together so a
  # CANNOT READ (2) can never read as a silent no-hold (0) in this table.
  h() { local o rc; o=$(review_hold "$1" "$2"); rc=$?; echo "$rc ${o}"; }
  t "no reviewer and no review -> MERGE"      "$(h '{"users":[],"teams":[]}' '[]')" "0 "
  t "a pending user request HOLDS"            "$(h '{"users":[{"login":"lead-gates"}],"teams":[]}' '[]')" "1 a pending review request for lead-gates"
  t "a pending TEAM request HOLDS"            "$(h '{"users":[],"teams":[{"slug":"gates"}]}' '[]')" "1 a pending review request for gates"
  t "an unresolved CHANGES_REQUESTED HOLDS"   "$(h '{"users":[],"teams":[]}' '[{"user":{"login":"lead-cli"},"state":"CHANGES_REQUESTED","submitted_at":"2026-09-12T01:00:00Z"}]')" "1 an unresolved CHANGES_REQUESTED review from lead-cli"
  t "a LATER approval clears it -> MERGE"     "$(h '{"users":[],"teams":[]}' '[{"user":{"login":"lead-cli"},"state":"CHANGES_REQUESTED","submitted_at":"2026-09-12T01:00:00Z"},{"user":{"login":"lead-cli"},"state":"APPROVED","submitted_at":"2026-09-12T02:00:00Z"}]')" "0 "
  t "a COMMENTED review alone -> MERGE"       "$(h '{"users":[],"teams":[]}' '[{"user":{"login":"bot"},"state":"COMMENTED","submitted_at":"2026-09-12T01:00:00Z"}]')" "0 "
  t "an unparseable reviews payload CANNOT READ" "$(h '{"users":[],"teams":[]}' '{"message":"Not Found"}')" "2 "
  t "an unparseable reviewers payload CANNOT READ" "$(h '[]' '[]')" "2 "
  t "an EMPTY reviews payload CANNOT READ"    "$(h '{"users":[],"teams":[]}' '')" "2 "
  t "an EMPTY reviewers payload CANNOT READ"  "$(h '' '[]')"                        "2 "
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
merged=0; skipped=0; refused=0; trailerless=0; held=0
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
  # THE REVIEW HOLD. Two REST reads; an empty answer from either is a CANNOT READ, never a "no
  # review". $held is its own counter for the same reason $refused is: folding a deliberate hold
  # into "not yet" would make a reviewed PR and a red PR read identically in the log.
  rr=$(gh api "repos/$REPO/pulls/$pr/requested_reviewers" 2>/dev/null)
  rv=$(gh api "repos/$REPO/pulls/$pr/reviews?per_page=100" 2>/dev/null)
  if [ -z "$rr" ] || [ -z "$rv" ]; then
    refused=$((refused+1))
    echo "$(date -u +%H:%MZ) CANNOT READ #$pr: review state unreadable (requested_reviewers/reviews returned nothing) — NOT merged, and this is NOT 'no open review'" >> "$ORCH/merge-sweep.log"
    continue
  fi
  hold=$(review_hold "$rr" "$rv"); hrc=$?
  case "$hrc" in
    0) ;;
    1) held=$((held+1))
       echo "$(date -u +%H:%MZ) HELD #$pr: open review — $hold" >> "$ORCH/merge-sweep.log"
       continue;;
    *) refused=$((refused+1))
       echo "$(date -u +%H:%MZ) CANNOT READ #$pr: review state unparseable — NOT merged, and this is NOT 'no open review'" >> "$ORCH/merge-sweep.log"
       continue;;
  esac
  if out=$(gh pr merge "$pr" --repo "$REPO" --squash --delete-branch --subject "$title (#$pr)" --body "$body" 2>&1); then
    merged=$((merged+1)); echo "$(date -u +%H:%MZ) MERGED #$pr $(printf '%s' "$title" | cut -c1-80)" >> "$ORCH/merge-sweep.log"
  else
    echo "$(date -u +%H:%MZ) REFUSED #$pr: $(echo "$out" | tail -1 | cut -c1-140)" >> "$ORCH/merge-sweep.log"
  fi
done
if [ "$refused" -gt 0 ]; then
  echo "$(date -u +%H:%MZ) merge-sweep: merged $merged, not-yet $skipped, held-open-review $held, no-trailer $trailerless, CANNOT READ $refused (those $refused were NOT measured — they are not 'not yet')"
  exit 3
fi
echo "$(date -u +%H:%MZ) merge-sweep: merged $merged, not-yet $skipped, held-open-review $held, no-trailer $trailerless, CANNOT READ 0"
