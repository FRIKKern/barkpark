# Wave 30 — re-derivation recipes for the sixteen unmet criteria

Taken 2026-08-09T14:05–14:15Z. `origin/main` moved DURING this verification:
`02475d0ec` (the direction's ground) → `839453b70`. Re-fetch before quoting.

## roster + the 16 unmet rows

```
for s in dr-w28-s1-crown-records-what-the-box-served dr-w28-s2-crown-reconciler-can-say-behind-or-wrong \
         dr-w28-s3-watch-stops-dying-on-its-own-payload dr-w28-s4-the-deferral-wait-becomes-a-number \
         dr-w28-s5-digest-deploy-health-is-per-team dr-w28-s6-abandonment-stamps-its-own-columns \
         dr-w28-s7-no-seal-reading-from-a-stale-checkout \
         dr-w29-s1-crown-reconciler-stops-manufacturing-a-wrong dr-w29-s2-deferral-wait-reaches-a-human-on-the-census \
         dr-w29-s3-digest-carries-the-wait-and-the-law-gets-a-guard dr-w29-s4-daily-digest-stops-skipping-days \
         dr-w29-s5-blind-watch-run-stops-reporting-green dr-w29-s6-seal-runner-stops-refusing-a-perfect-tree \
         dr-w29-s7-abandonment-reaches-the-machine-surface dr-w29-s8-mains-honesty-gate-goes-green; do
  bp task get "$s" -o json; done > /tmp/roster.json
# criteria live under doc.content.acceptance_criteria[], NOT doc.acceptance_criteria
```

## the 8 wave-29 merge stamps (tree, not the lead's claim)

```
for n in 11252 11253 11254 11255 11256 11257 11259 11270; do
  gh pr view $n --json number,state,mergeCommit,mergedAt -q '[.number,.state,.mergeCommit.oid,.mergedAt]|@tsv'; done
for sha in 45f600160 718461e8b a18cbbc04 4c8314c94 899aa34c0 abce628a0 f69140d3b feac1a0f7; do
  git merge-base --is-ancestor $sha origin/main && echo "$sha IN-TREE"; done
```

Wave-28 PRs are found by HEAD BRANCH, not by number:
`gh pr list --head loop-epic/<slug>-<n>[-r] --state all --json number,state,mergedAt`
→ s1 #11203, s2 #11205, s3 #11206, s4 #11207, s5 #11208, s6 **#11209 OPEN**, s7 #11210.

## live control-plane reads (HTTP /v1/deliveries is 401 to every principal here)

```
ssh -o BatchMode=yes -i ~/.ssh/barkpark_indx root@barkpark.cloud \
 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F'|' -c \"<SQL>\""
```
DB user is `barkpark_cloud`, NOT `postgres` (role does not exist). Deploy rows live in
`deployments`; there is **no `site_deploys` table and no `abandonment_*` column** — only
`deferral_depth` / `deferral_bound` / `deferral_cause`.

- head delivery rows: `select delivering_run_id,target,left(sha,9),build_seconds from platform_deliveries where carried=false`
- deferral census: `select coalesce(deferral_cause,'(NULL)'),count(*) from deployments group by 1`
- abandoned rows: `select count(*),count(deferral_depth),count(deferral_bound),count(deferral_cause) from deployments where failure_reason like '%rebuilds in a row%'`
- failure ranking: `select failure_reason,count(*) from deployments where status='failed' group by 1 order by 2 desc`

## the census a human can actually reach

```
TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['cloud_token'])")
curl -s -H "Authorization: Bearer $TOK" \
  "https://api.barkpark.cloud/v1/deploy-ledger/census?from=...&to=..." | jq .deferral_wait
```
`/v1/operator/deploy-ledger/census` answers **403 `{"scope":"platform","required":"platform_operator"}`**
to this token. The installed `bp` (0789ab90a) has neither `cloud deployments` nor `cloud deliveries`
(both exit 2 with `unknown cloud command`).

## seal reading (w28-s7)

The primary checkout was SHALLOW (`git rev-parse --is-shallow-repository` → true, 450 commits).
`git fetch --unshallow origin` → 5601 commits. Then:
```
git worktree add --detach <scratch>/w30ver 839453b70
cd <scratch>/w30ver && bash scripts/seal-run.sh          # NEVER pipe to tail — tail's rc masks it
```
True rc 3 = shallow refusal, rc 1 = VOUCHED / NO SEAL. `scripts/seal-run.sh` **and**
`scripts/seal-run.test.sh` appear in ZERO of the 48 files under `.github/workflows/` on origin/main:
```
for f in $(git ls-tree -r origin/main --name-only | grep '^\.github/workflows/'); do
  git show origin/main:$f | grep -q "seal-run" && echo "HIT $f"; done
```

## instrument runs

```
gh run list --workflow crown-reconcile.yml    --limit 15 --json databaseId,event,conclusion,createdAt,headSha
gh run list --workflow stale-verdict-watch.yml --limit 20 --json databaseId,event,conclusion,createdAt,headSha
gh run view <id> --log            # must be run INSIDE the repo, else "failed to determine base repo"
```
Scheduled crown-reconcile: **31314281701** (12:50:18Z). Scheduled stale-verdict-watch:
**31314564686** (12:57:09Z) and **31316989714** (13:53:23Z).

## charter

`.claude/workflows/bp-deploy-reliability-charter.md` in the primary checkout is **UNTRACKED**
(`git ls-files --error-unmatch` fails) and 909,184 bytes against origin/main's 925,588 — 16,404 short.
Read the charter as `git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md`.
D3:44 D437:7427 D493:9330 D497:9482 D502:9670 D504:9782 D508:9964 D509:9979; D510 absent (10,176 lines).
