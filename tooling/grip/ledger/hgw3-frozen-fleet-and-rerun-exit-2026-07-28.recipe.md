# Re-derivation recipes — hgw3 verify: frozen fleet + non-push exits (2026-07-28)

Wave: honest-gates-wave-2026-07-28 · Verifier lane: `frozen-fleet-and-rerun-exit`
All probe branches (`hgw3-vfy-cancel-base/head`) and their protection were torn down; `main` was never protected.

## R1 — 12/12 open PRs are frozen by requiring `Elixir gate`

```
cd /Volumes/SATECHI/github/barkpark && git fetch origin --quiet && \
for p in $(gh pr list --state open --limit 40 --json number --jq '.[].number'); do \
  sha=$(gh pr view $p --json headRefOid --jq .headRefOid); \
  anc=$(git merge-base --is-ancestor fdd170be2528b04d16e0afb567b461c516340d8d $sha && echo YES || echo NO); \
  gate=$(gh api repos/FRIKKern/barkpark/commits/$sha/check-runs --jq '[.check_runs[]|select(.name=="Elixir gate")]|length'); \
  echo "PR#$p ancestor=$anc gate=$gate"; done
```
Expected 2026-07-28: every line `ancestor=NO gate=0`.

## R2 — a rerun can never conjure `Elixir gate` on a pre-shim head

```
sha=$(gh pr view 6414 --json headRefOid --jq .headRefOid); \
git cat-file -p "$sha:.github/workflows/elixir.yml" | grep -c "Elixir gate"   # -> 0
git cat-file -p origin/main:.github/workflows/elixir.yml | grep -n "name: Elixir gate"  # -> 581
```

## R3 — `gh run rerun` REPLACES the check run for that name (same suite, new id)

```
gh api repos/FRIKKern/barkpark/commits/<sha>/check-runs --jq '.check_runs[]|[.id,.name,.conclusion]|@tsv'
gh run rerun <failed-run-id> --failed
sleep 25
gh api "repos/FRIKKern/barkpark/commits/<sha>/check-runs?check_name=<urlencoded-name>" --jq '[.total_count]+[.check_runs[]|{id,conclusion}]'
```
Observed on `1f9e360a0` / run `29962836818`: `89067653560` -> `90153340185`, `total_count: 1`, `check_suite.id` unchanged (`81175050609`).

## R4 — the three merge-refusal messages (throwaway protected base, `enforce_admins:true`)

```
gh api -X PUT repos/FRIKKern/barkpark/branches/<probe-base>/protection --input - <<'EOF'
{"required_status_checks":{"strict":false,"checks":[{"context":"<NAME>","app_id":15368}]},"enforce_admins":true,"required_pull_request_reviews":null,"restrictions":null}
EOF
gh pr merge <probe-pr> --squash --admin
```
| latest check run for the required name | message | exit |
|---|---|---|
| never reported | `Required status check "Elixir gate" is expected.` | 1 |
| `failure` | `Required status check "Elixir gate" is failing.` | 1 |
| `cancelled` | `Required status check "Test (Elixir 1.18.1 / OTP 27.0)" is cancelled.` | 1 |
| `success` | (merges; plain `gh pr merge --squash`, no `--admin`, exit 0) | 0 |

## R5 — `edited` re-fires the task gate and the newer green wins (non-push exit)

```
gh pr edit <pr> --body "...\n\nTask: <task-id>"
sleep 45
gh api "repos/FRIKKern/barkpark/commits/<sha>/check-runs?check_name=PR%20references%20an%20active%20task" \
  --jq '[.total_count]+[.check_runs[]|{id,conclusion,started:.started_at}]'
```
Observed: two check runs of the same name coexist on one sha (different suites); the one with the later `started_at` is what the required-status evaluator uses — `mergeStateStatus` went `BLOCKED` -> `UNSTABLE` and the merge succeeded.

## R6 — D23 lapse-grace, first real-PR execution

```
gh run view <pr-task-gate-run-id> --log | grep "lapse grace"
```
Observed: `pr-task-gate: PASS: task 'hgw2-s1-elixir-skip-shim' is task-backed — open, but the claim by 'epic-builder-skip-shim-for-elixir-yml-a-dispatcher-jo' was reaped only 12769s ago (within the 21600s lapse grace)`
