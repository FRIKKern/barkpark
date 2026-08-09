# Crown negative control — wave 33 re-derivation recipes (2026-08-09)

Verifier lane `crown-negative-control`. Every row below re-derives one claim from scratch.
All timestamps UTC. Read-only; nothing here mutates.

## R1 — the armed grace RETIRED, it did not fire

    gh run view 31333565555 --log | grep -E 'RE-ASK LIST:|recorded after all|RECONCILED'

Expect: `RE-ASK LIST: … — PRESENT; loaded 1 entry(ies)`, then
`note: the graced sha 5a11c43dbb901fbc1c374b39547a2d0dadf20bb9 was recorded after all — retired`,
then `RECONCILED: …`. Run conclusion `success`. GRACED-UNRECORDED did NOT fire.

## R2 — the full three-run round trip (ABSENT → PRESENT-EMPTY → PRESENT → retired)

    for id in 31332605576 31332716688 31332806984 31333052697 31333565555; do \
      gh run view $id --log | grep -E 'RE-ASK LIST:|SERVING GRACE|recorded after all'; done

## R3 — the re-ask list on the box, post-retirement

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
      'ls -la /var/lib/crown-reconcile/; cat /var/lib/crown-reconcile/graced.txt'

Expect 92 bytes, header comment only, zero sha entries.

## R4 — the schedule arm has NEVER reached the product step

    gh run list --workflow crown-reconcile.yml -e schedule --limit 30 \
      --json databaseId,conclusion,createdAt
    gh run view 31329626697 --json jobs   # step 3 failure, step 5 skipped
    gh run view 31314281701 --json jobs

## R5 — the ONE live rc=1 page, and that it was a false positive

    gh run view 31332764821 --log | grep -E 'SERVING-CLOCK-SKEW|SERVING-UNRECORDED|VERDICT:'
    gh run view 31333052697 --log | grep 'cc10b0c0'   # same sha, "recorded after all"

## R6 — the skew arm has zero tolerance

    git show origin/main:scripts/crown-reconcile.sh | sed -n '935,956p'

`age < 0` ⇒ SERVING_RED=1. No epsilon.

## R7 — reader is still 100% postgres-container fallback

    gh run view 31333565555 --log | grep 'READER:'

Expect `route=0, postgres-container=21, fixture=0, unreadable=0` and the HTTP 401 sentence.

## R8 — control-plane clock is healthy (so R5's skew was jitter, not drift)

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud 'timedatectl'
