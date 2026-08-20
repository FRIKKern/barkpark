# crown-rc2-structural — the serving grace laundered a real SERVING-UNRECORDED, four times, permanently

Wave 30 verifier, 2026-08-09. Tree: origin/main `02475d0ecaf41f8fcd464c543a07e1825defc090`.

## Re-derivation recipes

Test suite (63/63, exit 0 — the mutation proofs are alive):

    T=$(mktemp -d); git archive origin/main | tar -x -C $T; cd $T && bash scripts/crown-reconcile.test.sh; echo RC=$?

The grace arm and the exit-2 message that does not name it:

    git show origin/main:scripts/crown-reconcile.sh | sed -n '555,575p;625,640p'
    git show origin/main:scripts/crown-reconcile.sh | grep -n 'UNREADABLE=1'   # 8 sites; :633 names 3 counters

Every crown-reconcile run and its trigger:

    gh run list --workflow=crown-reconcile.yml --limit 40 --json databaseId,event,createdAt,conclusion \
      -q '.[]|[.databaseId,.event,.createdAt,.conclusion]|@tsv'

The four laundered runs (ages -3s / 53s / 105s / 200s, all on sha 4c8314c94):

    for id in 31316144030 31316187416 31316233833 31316266634; do
      gh run view $id --log | grep -E 'only -?[0-9]+s old|COULD NOT FULLY READ|RECONCILED:'
    done

The three genuine greens (same day, same trigger — the premise "push runs are condemned" is refuted):

    for id in 31316057500 31316075489 31316124609; do gh run view $id --log | grep -oE 'RECONCILED: all [0-9]+'; done

The sha the box served with no delivering run at all:

    gh run view 31316124617 --json jobs -q '.jobs[]|[.name,.conclusion]|@tsv'   # EMPTY — cancelled before any job
    curl -s https://barkpark.cloud/health

## The finding in one line

Push runs are not structurally condemned; the grace arm is. It fires only on the
CURRENT serving sha, it re-arms nothing, and once the box moves on the accusation
can never be made again — which is exactly what happened to `4c8314c94` between
13:34Z and 13:42Z today.
