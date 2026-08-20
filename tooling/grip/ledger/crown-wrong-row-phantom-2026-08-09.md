# Re-derivation recipe — the crown's "wrong=1/29" row for 8e83b709a (2026-08-09)

VERDICT: the phantom is NOT a phantom. The recorder is right; `crown-reconcile.sh`'s
WRONG axis is wrong. Hypothesis (cancelled/skipped-leg leaves `delivered=true`) REFUTED.

## Re-derive

    # 1. run 31311133833 (#11203's own merge) recorded NOTHING — record job SKIPPED
    gh run view 31311133833 --json conclusion,createdAt,updatedAt,jobs \
      -q '[.conclusion,.createdAt,.updatedAt,([.jobs[]|.name+"="+.conclusion]|join(";"))]|@tsv'

    # 2. no deploy.yml run on main ever had headSha 8e83b709a (coalesced away)
    gh run list --workflow=deploy.yml --branch main --limit 60 \
      --json databaseId,headSha,conclusion,createdAt \
      -q '.[]|[.databaseId,.headSha[0:9],.conclusion,.createdAt]|@tsv'

    # 3. the row, and the whole range its delivering run wrote
    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F'|' -c \"select delivering_run_id,target,left(sha,12),carried,serving_since,build_seconds,first_seen_at from platform_deliveries order by first_seen_at desc limit 14\""

    # 4. the accusation itself
    gh run view 31311887504 --log | grep -v crown-reconcile.test.sh | grep -E 'WRONG|BEHIND|VERDICT|POPULATION'

    # 5. the rule that produces it
    git show origin/main:scripts/crown-reconcile.sh | sed -n '395,470p'

## Mechanism

`5f3813659` (#11207) merged 13:34:49+02; `8e83b709a` (#11210) merged 13:35:02+02.
`8e83b709a` never triggered a deploy.yml run of its own (concurrency coalescing).
Run **31311142804** (headSha `5f3813659`) pulled origin/main at deploy time, the box
served `8e83b709a`, and #11203 made the recorder record **the sha the box served**:

    31311142804|cp|8e83b709a4f1|carried=f   <- the served head
    31311142804|cp|5f381365913e|carried=t   <- its own trigger sha, carried
    31311142804|cp|9562316d81a6|carried=t
    31311142804|cp|66d9bd7e97e7|carried=t

`crown-reconcile.sh` builds its alibi set from **delivering-run HEAD shas**
(`wide-shas.txt`, :397-404) and accuses any **non-carried** row absent from it
(:461). Post-#11203 the non-carried row is the SERVED head and the trigger sha is
`carried=true`. Whenever the deploy's pull races past the trigger — routine under
coalescing — the alibi set structurally cannot contain the served sha.

BEHIND does not have this bug: it asks "any row for this sha", carried or not (:416),
and `5f3813659` has a carried row, so run 31311142804 was correctly not BEHIND.
The bug is asymmetric and lives only in WRONG.

## Fix shape (cheapest correct)

The row already carries `delivering_run_id`, and `PlatformDelivery.to_json/1`
(platform_delivery.ex:448) plus the SQL fallback (crown-reconcile.sh:252) both emit it.
A non-carried row is legitimate iff its `delivering_run_id` is in the delivering set —
no ancestry walk, no new field, no route change. Falling back to headSha only when
`delivering_run_id` is absent keeps the honest-unmeasured path.

## Non-conclusions

BEHIND=17/21 is a separate question (all 17 runs predate #11203's 11:34:36Z merge;
oldest checked 7d76e4383 2026-08-08T12:27:30Z, newest 48a200aa7 2026-08-09T08:39:42Z).
Not adjudicated here.
