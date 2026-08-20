# Re-derivation recipes — graph-class vs memory/build windows (wave 8, 2026-08-07 ~01:00Z)

Lane: memory-vs-incident. Hosts: guerrilla 157.180.90.121, cloud-db-1 178.105.92.191.
Key `~/.ssh/barkpark_indx`. All timestamps UTC.

## R1 — Which slice runs what (answers "can MemorySwapMax separate victim from aggressor")

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'systemctl show barkpark-slot@green -p Slice -p MainPID -p MemorySwapMax; \
       systemctl show barkpark-slot@green -p MainPID --value | xargs -I{} cat /proc/{}/cgroup; \
       journalctl --since "2026-08-06 23:30" --until "2026-08-06 23:50" -o json --no-pager \
         | python3 -c "import sys,json
for l in sys.stdin:
    d=json.loads(l)
    m=d.get(\"MESSAGE\",\"\")
    if isinstance(m,str) and \"Compiled successfully\" in m: print(d.get(\"_SYSTEMD_UNIT\"))"'

Expect three distinct cgroups: serving BEAM in
`system.slice/system-barkpark\x2dslot.slice/barkpark-slot@<slot>.service`; site builds in
per-build TRANSIENT units `system.slice/bp-site-build-<site>-<hash>-<epoch>.service`;
the API `mix compile` in `user.slice/user-0.slice/session-<n>.scope`.

## R2 — Build windows vs graph-class failures (the "one finding" test)

    # A. build windows (end timestamp + duration)
    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'journalctl --since "2026-08-05 17:00" --no-pager -o short-iso \
        | grep -oE "^[0-9T:+-]+ .*Compiled successfully in [0-9.]+s" \
        | sed -E "s/^([0-9T:+-]+) .*in ([0-9.]+)s/\1 \2/"' > builds.txt

    # B. graph-class failure instants
    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -At -c \
       \"select to_char(inserted_at,'YYYY-MM-DD HH24:MI:SS') from deployments \
         where inserted_at > now()-interval '30 hours' and status='failed' \
         and failure_reason ~ 'graph (5|0)' order by 1;\"" > graphfails.txt

    # C. intersect: merge build windows, count failures falling inside, compare to
    #    the build-busy share of wall clock. Enrichment > 1.0 supports causation.
    # Result 2026-08-07: busy 11030s / 93624s = 11.8% of wall; 13/261 = 5.0% of
    # failures inside a window. RR = 0.42 — ANTI-correlated. Hypothesis REFUTED.

## R3 — The onset is an artifact of the producer fix, not a real onset

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -At -F'|' -c \
       \"select to_char(date_trunc('hour',inserted_at),'MM-DD HH24'), \
          count(*) filter (where failure_reason ~ 'bp-doc-id marker is empty' \
                             and failure_reason !~ 'graph (5|0)') as no_suffix, \
          count(*) filter (where failure_reason ~ 'graph (5|0)') as with_suffix \
        from deployments where inserted_at > now()-interval '30 hours' \
        and status='failed' group by 1 order by 1;\""

Expect a hard crossover at 08-05 21: every hour BEFORE it is all-no_suffix
(19h=23/0, 20h=36/0), every hour AFTER is all-with_suffix. That is the producer
fix landing, not graph failures starting.

## R4 — API-side truth vs ledger truth (the silent hours)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'journalctl --since "2026-08-05 19:00" --no-pager \
        | grep "derive_graph_corpus" | awk "{print \$1, \$2, substr(\$3,1,2)}" | uniq -c'

Compare per-hour against R3's with_suffix column. 2026-08-07 reading: 08-05 23h
threw 703 API-side graph errors while the ledger attributed 0 graph-class rows
across 168 deployments.

## R5 — Global OOM kills of the serving BEAM

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'journalctl --since "2026-08-05" --no-pager \
        | grep -E "Out of memory: Killed process|oom-kill:constraint"'

Expect `constraint=CONSTRAINT_NONE ... global_oom` with
`task_memcg=.../barkpark-slot@blue.service, task=beam.smp`. The API is the OOM
VICTIM under a GLOBAL kill — no cgroup limit is involved, so capping the slot
would only make it the victim sooner.

## R6 — S1 precision: graph-status rows outside the DOC_ID_EMPTY arm

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -At -F'|' -c \
       \"select case when failure_reason ~ 'bp-doc-id marker is empty' \
            then 'DOCID_arm' else 'OTHER_arm' end, \
          substring(failure_reason from 'graph [0-9]+'), count(*) \
        from deployments where inserted_at > now()-interval '30 hours' \
        and status='failed' and failure_reason ~ 'graph (5|0)' group by 1,2 order by 3 desc;\""

2026-08-07: DOCID_arm 251 (500=131, 0=62, 503=58); OTHER_arm 10 (all `graph 500`,
stage=BUILD exit 12, `Caught error rendering /graph.json`). Editing only the
HEALTH/DOC_ID_EMPTY arm leaves those 10 wearing BUILD_FAILED.
