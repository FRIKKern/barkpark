# which-clocks-are-real — re-derivation recipes (deploy-reliability W27 verify)

Every row below re-derives a fact quoted in the W27 verify return. Run from any
clone; nothing here mutates anything. Ground tree:
`git archive origin/main | tar -x -C /tmp/w27v` at `da47f61aa`.

## R1 — the sampled real deploy run and its four clocks

    RID=$(gh run list --workflow=deploy.yml --branch=main --status=success --limit=1 --json databaseId -q '.[0].databaseId')
    gh api repos/FRIKKern/barkpark/actions/runs/$RID --jq '{created_at,run_started_at,head_sha,conclusion}'
    gh api repos/FRIKKern/barkpark/actions/runs/$RID/jobs --jq '.jobs[]|{name,created_at,started_at,completed_at,conclusion}'
    gh api repos/FRIKKern/barkpark/commits/$(gh api repos/FRIKKern/barkpark/actions/runs/$RID --jq .head_sha)/pulls --jq '.[0]|{number,merged_at}'

Pinned sample (run 31301300597, sha da47f61aa, PR #11121):
merged_at 07:30:17Z · run created/started 07:30:19Z · changes job created
07:32:26 started 07:32:29 · control-plane 07:32:48→07:34:38 · instance SKIPPED.
Decomposition (D438 rule B, precedence self>stall>pickup):
queued_seconds 2 · legA 130 · self 126 (overlap with the previous deploy run
31301272785's control-plane window 07:29:58→07:32:25) · pickup 4 · build 110.

## R2 — merged_at needs no pulls API

    for SHA in da47f61aa39c0bd66afc658270ae1a92ecba2c9f bf58260d1d216f670bdab2a0d9504db7384d9cbf fdfdcfc955141bc8e4d7e1807faa131aa1144f10 da4b7730b5bb6cf347795e2bdc0be3bd192db2e3; do
      echo "$SHA committer=$(gh api repos/FRIKKern/barkpark/commits/$SHA --jq .commit.committer.date) merged_at=$(gh api repos/FRIKKern/barkpark/commits/$SHA/pulls --jq '.[0].merged_at')"; done

4/4 agree within 0–1s. `github.event.head_commit.timestamp` is therefore a free
fallback that needs no `pull-requests: read`.

## R3 — the site-deploy path in the W27 direction is WRONG (404 vs 401)

    curl -s -o /dev/null -w '%{http_code}\n' https://guerrilla.barkpark.cloud/instance/site-deploy      # 404
    curl -s -o /dev/null -w '%{http_code}\n' https://guerrilla.barkpark.cloud/v1/instance/site-deploy   # 401
    grep -n 'instance/site-deploy' /tmp/w27v/api/lib/barkpark_web/router.ex                             # 1643, inside scope "/v1"

## R4 — the control plane's sha/serving surface is ANONYMOUS

    curl -s https://barkpark.cloud/health

Returns `git_sha`, `serving_sha`, `serving_since`, `serving_since_basis`.
`serving_since` is self-labelled process-derived (BEAM start), not first-seen.

## R5 — the instance has NO health route and NO materialised ServingMemory

    grep -n 'health\|version' /tmp/w27v/api/lib/barkpark_web/router.ex        # one comment hit only
    curl -s -o /dev/null -w '%{http_code}\n' https://guerrilla.barkpark.cloud/health   # 404
    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'ls /opt/barkpark/.bp-site-deploy-runs/serving-memory.json'   # No such file
    grep -rn 'ServingMemory\.' /tmp/w27v/api/lib | grep -v serving_memory.ex   # exactly ONE prod caller (the authed controller)

## R6 — the instance's tokenless sha record

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'cat /opt/barkpark/.instance-deploy-last; stat -c %y /opt/barkpark/.instance-deploy-last; \
       for f in /opt/barkpark/.slots/blue.sha /opt/barkpark/.slots/green.sha; do echo -n "$f="; cat $f; stat -c " %y" $f; done'

Live: `.instance-deploy-last` = 0e9246447… mtime 2026-08-09 04:14 (matching run
31293937814's instance job completing 04:14:47Z); blue.sha 0e9246447 04:13:24,
green.sha 989b19577 02:24:41. A restart does not rewrite these files.
