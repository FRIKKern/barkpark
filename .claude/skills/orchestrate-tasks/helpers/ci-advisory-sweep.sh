#!/usr/bin/env bash
# Cancel QUEUED advisory workflow runs on campaign branches so the four required checks get runner slots.
# Keeps: elixir, cloud, console-harness, pr-task-gate (required), go-tests, mobile, Grip suite; doc-gates on docs/*; security on security/* + sec2/*.
set -u
tmp=$(mktemp); gh run list --status queued --limit 700 --json databaseId,headBranch,workflowName \
  --jq '.[]|select(.headBranch|test("^(security|security-r|sec2|gates|deploy|console|cli|cli2|studio|docs|pds|grip|instr|chat|media|sheets|papers|orch)/"))|"\(.databaseId)\t\(.workflowName)\t\(.headBranch)"' > "$tmp" 2>/dev/null
n=0; kept=0
while IFS=$'\t' read -r id wf branch; do
  case "$wf" in elixir|cloud|console-harness|pr-task-gate|go-tests|mobile|"Grip suite") kept=$((kept+1)); continue;;
    doc-gates) case "$branch" in docs/*) kept=$((kept+1)); continue;; esac;;
    security) case "$branch" in security/*|sec2/*) kept=$((kept+1)); continue;; esac;; esac
  gh run cancel "$id" >/dev/null 2>&1; gh api -X POST "repos/FRIKKern/barkpark/actions/runs/$id/force-cancel" >/dev/null 2>&1 && n=$((n+1))
done < "$tmp"; rm -f "$tmp"
echo "$(date -u +%H:%MZ) ci-sweep: cancelled $n advisory, kept $kept required/lane-relevant; queued now $(gh run list --status queued --limit 700 --json databaseId --jq 'length'), running $(gh run list --status in_progress --limit 100 --json databaseId --jq 'length')"
