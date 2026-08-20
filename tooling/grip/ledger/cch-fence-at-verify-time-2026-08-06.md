# Re-derivation recipes — cch fence at verify time (2026-08-06, deploy-reliability wave 5)

Every row below is a literal command that re-derives one fact from scratch. No prose stands in for a run.

## 1. #9802 is MERGED — the cession is no longer L3

    gh pr view 9802 --json number,state,mergedAt,title --jq '[.number,.state,.mergedAt,.title]|@tsv'
    # 9802  MERGED  2026-08-06T14:40:45Z  epic-charter/cloud-console-hardening-…  wave 36 decisions

Cession text now reads from main, byte-identical to the PR body:

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | sed -n '754,760p'

## 2. #9677 (the D31 carrier D392 caveated as unmerged) is also MERGED

    gh pr view 9677 --json state,mergedAt --jq '[.state,.mergedAt]|@tsv'   # MERGED 2026-08-06T03:10:04Z
    git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | grep -c 'CORRECTS D18'   # 1

## 3. Open-PR file census over the six contested files

    for p in $(gh pr list --state open --limit 60 --json number --jq '.[].number'); do
      echo "--- $p"; gh pr diff $p --name-only; done |
      grep -E '^---|cloud_status_cmd|cloudclient|attention_order|scenarios\.mjs|__app\.test\.mjs|web/router\.ex|app\.js|semrole'

## 4. Hunk bands, #6028 (the only open PR in the region) vs dr-w3-s7's region

    gh pr diff 6028 | awk '/^\+\+\+ b\/cloud\/priv\/static\/app.js/{f=1;next} /^\+\+\+ b\//{f=0} f&&/^@@/{print}'
    git show origin/main:cloud/priv/static/app.js | grep -n -E 'ATTENTION_RANK|function bucketOf|function classifyBp|function statusOf'
    git show origin/main:cloud/priv/static/__app.test.mjs | grep -n 'KINDS'

## 5. cch's bare fence swallows all three cloud/priv/static files

    sed -n '123,126p' <(git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md)
    # "**In fence:** `cloud/`, `api/lib/barkpark_web/live/`."

## 6. cch's charter never names dr-w3-s7

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -c 'dr-w3'   # 0

## 7. The attention_order.json fixture IS asserted — from Go, hard-fatal on count

    grep -rn 'attention_order' --include='*.mjs' --include='*.go' --include='*.js' --include='*.ex' . | grep -v worktrees
    git show origin/main:internal/cli/cloud_status_cmd_test.go | sed -n '67,95p'

## 8. Go is 8 rungs, the SPA is 9 — they are ALREADY two-tier

    git show origin/main:internal/cli/cloud_status_cmd.go | sed -n '76,88p'      # attentionRankOrder, 8 entries
    git show origin/main:cloud/priv/static/app.js | sed -n '5268,5292p'          # ATTENTION_RANK, 9 entries; bucketOf r<=6 / r<=8

## 9. dr-w3-s7's filed files array

    bp task get dr-w3-s7-strained-reaches-triage -o json |
      python3 -c 'import sys,json;print(json.load(sys.stdin)["doc"]["content"]["files"])'

## 10. The co-scoped OPEN handover nobody re-checked

    bp task get dr-bl-spa-unknown-state-buckets-healthy -o json |
      python3 -c 'import sys,json;c=json.load(sys.stdin)["doc"]["content"];print(c["lifecycle_status"],c["github"],c["files"])'
    # open · issue 9760 · ['cloud/priv/static/app.js','cloud/priv/static/__app.test.mjs']
