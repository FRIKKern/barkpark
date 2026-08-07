# Re-derivation recipes — cancelled main-push runs, and the reporter that does not exist

Verifier lane `cancelled-run-cause`, Cloud Console hardening wave 42, 2026-08-07.
origin/main at derivation time: `a476352a4f794e22437be9826b418ffe28d182d9`.

## R1 — No repo actor cancels runs (refutes "external cancel actor")

```
grep -rn 'actions/runs' --include='*.sh' --include='*.yml' --include='*.yaml' \
  --include='*.js' --include='*.mjs' --include='*.py' .github scripts | grep -i cancel
```

Expect: exit 1, no output. The only `actions/runs` hit repo-wide is
`scripts/file-ci-failure-issue.sh:60`, which builds a run URL for an issue body.

Wider sweep (also expected to show no caller):

```
grep -rn -E 'gh run cancel|cancelWorkflowRun' .github scripts tooling/grip
```

## R2 — Cancellation rate per workflow on main pushes

```
for wf in console-harness.yml cloud.yml elixir.yml pr-task-gate.yml; do
  echo "== $wf"
  gh api "repos/FRIKKern/barkpark/actions/workflows/$wf/runs?branch=main&event=push&per_page=100" \
    --jq '[.workflow_runs[].conclusion]|group_by(.)|map({(.[0]|tostring):length})|add'
done
```

At derivation: console-harness `{cancelled:39, failure:9, success:52}`,
cloud `{cancelled:39, success:61}`, elixir `{cancelled:61, null:1, success:38}`,
pr-task-gate `null` (total_count 0 — it has NO `push:` trigger; it is PR-only
and is therefore NOT part of the post-merge net at all).

## R3 — Mean successful run duration, same window (the dose in the dose–response)

```
for wf in console-harness.yml cloud.yml elixir.yml; do
  echo "== $wf"
  gh api "repos/FRIKKern/barkpark/actions/workflows/$wf/runs?branch=main&event=push&per_page=100" \
    --jq '[.workflow_runs[]|select(.conclusion=="success")|((.updated_at|fromdate)-(.created_at|fromdate))]
          | {n:length, avg_s:(add/length|floor), max_s:max}'
done
```

At derivation: console-harness avg 588s / cloud avg 497s / elixir avg 1560s.
Cancel rate tracks duration (39% / 39% / 61%) — the signature of a
queue-depth-1 pending slot, not of an actor.

## R4 — The burst timeline (the mechanism, visible)

```
gh api "repos/FRIKKern/barkpark/actions/workflows/cloud.yml/runs?branch=main&event=push&per_page=100" \
  --jq '.workflow_runs[] | [.id,.conclusion,.created_at,.updated_at,.head_sha[0:8]] | @tsv' | head -30
```

Read the 2026-08-07T05:25:24Z–05:26:23Z block: first push runs, seven middle
pushes are cancelled each ~1s after the NEXT push is created, last push runs.
`cancel-in-progress` evaluates FALSE on main (`.github/workflows/cloud.yml:31`,
`elixir.yml:75`, `console-harness.yml:41`), so these are not in-progress
cancels — they are pending runs displaced from the single pending slot.

## R5 — Cancelled runs never started a job

```
for id in 31150582521 31150577299 31150548114; do
  gh api "repos/FRIKKern/barkpark/actions/runs/$id/jobs" --jq '{total:.total_count,names:[.jobs[].name]}'
done
```

Expect `{"names":[],"total":0}` for each.

## R6 — Every cancelled SHA is an ancestor of a SHA that was fully tested

```
for s in 8be3dede c39a9291 f85b944c 3df1c083; do
  printf "%s " $s
  git merge-base --is-ancestor $s a476352a4 && echo YES || echo NO
done
```

Expect YES four times. Combined with R7 this is why the cancellations do not
leave code untested — only unattributed.

## R7 — The tip run of a burst is a FULL run (no path filter on main)

```
for f in cloud.yml elixir.yml console-harness.yml; do
  git show origin/main:.github/workflows/$f | grep -n -A6 'is not a pull_request'
done
```

Each dispatcher hard-codes every path set to `true` on non-`pull_request`
events. A main-push run is never partially skipped.

## R8 — THE REAL HOLE: no main-push failure reaches a human

```
grep -rn 'file-ci-failure-issue' --include='*.yml' .github/workflows
```

Expect exactly three callers: `paper-readers.yml`, `codebase-intel.yml`,
`renew-mail-cert.yml`. None of console-harness / cloud / elixir.

```
gh api "repos/FRIKKern/barkpark/actions/workflows/console-harness.yml/runs?branch=main&event=push&per_page=100" \
  --jq '.workflow_runs[]|select(.conclusion=="failure")|[.created_at,.head_sha[0:8]]|@tsv'
gh issue list --repo FRIKKern/barkpark --state all --limit 20 --search 'CI failure in:title' \
  --json number,title,createdAt
```

At derivation: 9 failed main-push console-harness runs (six of them between
2026-08-07T00:14Z and 01:00Z, jobs `CSSOM parity` and `Overflow guard`), and
the ONLY auto-filed CI-failure issues in repo history are #5658 paper-readers
and #4966 zz-alert-proof. Zero records exist for any of the nine.

## R9 — A naive reporter drop-in would 403

```
gh api repos/FRIKKern/barkpark/actions/permissions/workflow \
  --jq '{default_workflow_permissions}'
```

Expect `"read"`. None of the three workflows declares a top-level
`permissions:` block (`git show origin/main:.github/workflows/<f> | grep -n -A4 '^permissions:'`
returns nothing for all three), so any reporter job must carry its OWN
job-level `permissions: {contents: read, issues: write}`. Adding a
workflow-level block instead re-scopes every existing job's token.
