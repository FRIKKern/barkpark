# exclude-or-name: there is no lifecycle to exclude on (wave 33 verifier)

Re-derivation recipes for the ruling that the two "lifecycle-dead" production
sites are NOT formally dead, that the only available exclusion proxy is
coextensive with the stuck-customer state, and that excluding them does NOT
take `never_covered` to zero.

## 1. The sites table has no lifecycle column (35 columns, zero of them)

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB -c \"\\d sites\"'" \
      | grep -icE "lifecycle|archived|decommission|deleted_at|retired"

Expect `0`. Deletion is hard-delete: `deployments.site_id` is
`references(:sites, on_delete: :delete_all)` (deploy_ledger.ex:95), so a truly
retired site takes its deployment rows with it. Rows that persist prove the
site was never retired.

## 2. The two production sites, in full

    cat <<'SQL' | ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec -i cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB'"
    \x on
    select * from sites where slug in ('perfect-demo','nodeproof-20260718-73191');
    SQL

Expect `current_deployment_id` empty on both, `serving_mode = direct`,
`domains = {}`. No dead-flag exists to read.

## 3. THE REFUTATION — "no live row ever" is the stuck state, not a dead state

    cat <<'SQL' | ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec -i cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB'"
    with f as (
      select d.site_id, s.slug,
             (array_agg(d.status order by d.inserted_at))[1] as first_status,
             min(d.inserted_at) as first_at,
             min(d.inserted_at) filter (where d.status='live') as first_live_at,
             count(*) filter (where d.status='live') as live_rows, count(*) as rows
      from deployments d join sites s on s.id=d.site_id
      group by d.site_id, s.slug)
    select slug, first_status, rows, live_rows, first_live_at - first_at as dark_window
    from f order by first_at;
    SQL

Expect `perfect-demo-2 | failed | 5 | 2 | 15 days 21:48:36.278779`. Eight of
twelve sites opened with a failed deploy; six recovered, dark windows 19
minutes to 15.9 days. An exclusion keyed on `current_deployment_id IS NULL`
would have hidden perfect-demo-2 for sixteen days.

## 4. Excluding both production sites does NOT reach zero

    cat <<'SQL' | ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec -i cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB'"
    select s.slug, d.environment, d.status, d.inserted_at
    from deployments d join sites s on s.id=d.site_id
    where d.status in ('failed','deferred')
      and not exists (select 1 from deployments l
        where l.site_id=d.site_id and l.environment=d.environment
          and l.status='live' and l.inserted_at > d.inserted_at)
      and d.inserted_at < now() - interval '1 day'
    order by d.environment, d.inserted_at;
    SQL

Expect five rows: `jarl-website|preview` x2, `perfect-demo|production` x2,
`nodeproof-20260718-73191|production` x1. The preview pair belongs to
jarl-website, which has 23 live production builds and a non-null
`current_deployment_id`. 5 - 3 = 2, not 0.

## 5. Preview is never_covered BY CONSTRUCTION

    cat <<'SQL' | ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec -i cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB'"
    select environment, status, count(*) from deployments group by 1,2 order by 1;
    SQL

Expect the whole table's preview population to be `preview|failed|2` and no
`preview|live` row to exist at all. Coverage requires a later `live` row on the
same `{site, environment}` (@coverage_clock), so no preview row can ever be
covered. Two of the epic's last five non-zeros are a definitional artifact.

## 6. The shipped gauge, on the running container

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      'docker exec cloud-control_plane_green-1 /app/bin/barkpark_cloud rpc "
    to = DateTime.utc_now(); from = DateTime.add(to, -365*86400, :second)
    c = BarkparkCloud.DeployLedger.census(from, to)
    Enum.each(c.coverage_cohorts.cohorts, fn ch -> IO.puts(ch.cohort <> \" never_covered=\" <>
      to_string(ch.never_covered) <> \" \" <> inspect(ch.never_covered_by_environment)) end)"'

Note the container name: `cloud-control_plane_blue-1` is NOT running; blue/green
means the live slot moves. Resolve it with `docker ps | grep control` first.

## 7. No site-level predicate exists in the coverage query

    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | sed -n '1504,1520p'
    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | sed -n '1616,1620p'

`coverage_cohorts/2` selects five deployment columns and joins nothing;
`scope_to_sites/2` is an id-list `where`, supplied by the caller. The gauge has
no channel through which a lifecycle fact could reach it.
