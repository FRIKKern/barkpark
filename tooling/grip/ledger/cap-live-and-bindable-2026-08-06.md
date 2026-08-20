# cap-live-and-bindable — re-derivation recipes (2026-08-06, wave 6 verify)

Every figure below is re-derivable by exactly one command. `PG` is shorthand for:

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud "docker exec -e PGPASSWORD=78d44f09ad1663acdc470864e3cea1bc cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"<SQL>\""

## 1. ef77af274 has NOT reached guerrilla

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'cd /opt/barkpark && git log -1 --format="%H %cI" && grep -c box_at_capacity api/lib/barkpark/sites/deploy_runner.ex'
    # -> 33bb65496a195cc16f9f4d020d57013907456790 2026-08-06T16:15:45+02:00 / 0

    git merge-base --is-ancestor ef77af274 33bb65496 && echo IN || echo NOT-IN     # -> NOT-IN
    git rev-list --count 33bb65496..origin/main                                    # -> 7

## 2. Why it has not: the Deploy (production) run is QUEUED, not failed

    gh run list --workflow deploy.yml --limit 5 --json createdAt,status,conclusion,headSha
    # -> 2026-08-06T16:52:49Z queued/- sha=ef77af274 ; previous run 14:41:24Z success
    gh run list --limit 100 --json status -q '[.[]|.status]|group_by(.)|map({(.[0]):length})|add'
    # -> {"completed":49,"in_progress":1,"pending":1,"queued":49}

## 3. Ordering: already_running is SLUG-scoped and cannot preempt the cap for a foreign slug

    git show origin/main:api/lib/barkpark/sites/deploy_runner.ex | sed -n '440,470p'   # cond order
    git show origin/main:api/lib/barkpark/sites/deploy_runner.ex | sed -n '581,587p'   # running_slug?(state, slug)
    git show origin/main:api/lib/barkpark/sites/deploy_runner.ex | sed -n '721,745p'   # box_at_capacity? / building_slugs
    git show origin/main:api/lib/barkpark/sites/deploy_runner.ex | grep -n '@build_slot_capacity'  # -> 1

## 4. Ledger census (production)

    PG "select count(*) from deployments where failure_reason ilike '%box_at_capacity%';"   # -> 0
    PG "select status,count(*) from deployments where failure_reason ilike '%already_running%' group by 1;"
    # -> failed 5268 / deferred 603
    PG "select status,count(*) from deployments group by 1 order by 2 desc;"
    # -> failed 18490 / live 9810 / deferred 603 / building 4

## 5. The concurrency the cap would meet (7 days, deferred rows excluded both sides)

    PG "select count(distinct a.id) from deployments a join deployments b on a.site_id<>b.site_id and b.inserted_at between a.inserted_at and a.inserted_at + interval '60 seconds' where a.inserted_at > now() - interval '7 days' and a.status<>'deferred' and b.status<>'deferred';"
    # -> 9189
    PG "select count(*) from deployments where inserted_at > now() - interval '7 days' and status<>'deferred';"
    # -> 11384        (9189/11384 = 80.7%)

## 6. Upstream serialization that does NOT prevent the cap from binding

    git show origin/main:cloud/config/config.exs | sed -n '215,230p'                       # site_deploy: 1
    git show origin/main:cloud/lib/barkpark_cloud/sites/template_freshness_worker.ex | sed -n '57,73p'
    # "The :site_deploy queue's concurrency 1 serializes JOBS, not builds"
    PG "\d deployments"   # deployments_active_site_env_index UNIQUE (site_id, environment) WHERE status in queued/building/pushing

## 7. guerrilla `systemctl is-active barkpark` = inactive is CORRECT

    ssh ... 'systemctl list-unit-files barkpark.service "barkpark-slot@*" --no-legend; systemctl is-active barkpark barkpark-slot@green; ss -lntp | grep 4001'
    # -> barkpark.service disabled ; slot@green active ; beam.smp LISTEN 127.0.0.1... *:4001
    curl -s -o /dev/null -w '%{http_code}' https://guerrilla.barkpark.cloud/api/schemas   # -> 200
    ssh ... 'systemctl show barkpark-slot@blue -p ActiveState -p Result -p ExecMainExitTimestamp'
    # -> failed / timeout / Thu 2026-08-06 14:22:49 UTC   (the idle slot of today's cutover)

## 8. Which box builds sites

    PG "select b.name,b.host,count(s.id) from barkparks b left join sites s on s.barkpark_id=b.id group by 1,2 order by 3 desc;"
    # -> Guerrilla 157.180.90.121 = 12 sites ; jarl 91.98.139.58 = 1 ; six boxes with 0
