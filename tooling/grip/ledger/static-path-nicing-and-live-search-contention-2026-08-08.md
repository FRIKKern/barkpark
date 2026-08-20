# static-path-nicing — re-derivation recipes (wave 20 verifier, 2026-08-08)

Assignment premise named `deploy/site-deploy-static.sh`. That file does not exist on
origin/main. The ASTRO/static engine is `deploy/site-deploy.sh`. Both engines are niced.
But the "search latency is historical" verdict is REFUTED by the box's own latency series.

## R1 — the static engine is niced (premise refuted)

    git show origin/main:deploy/site-deploy.sh      | sed -n '2120,2128p'
    git show origin/main:deploy/site-deploy-node.sh | sed -n '1675,1680p'
    git log -1 --format='%H %ad %s' --date=iso -S 'BP_NICE' origin/main -- deploy/

## R2 — nice + ionice really are inherited by the build's children

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'BP_NICE="nice -n 19"; command -v ionice >/dev/null 2>&1 && BP_NICE="nice -n 19 ionice -c3"; \
       $BP_NICE bash -c "echo self: \$(ionice -p \$\$) ni=\$(ps -o ni= -p \$\$)"'

## R3 — the historical search-latency series (this is the metric, validated)

`search_intel_events.duration_ms` IS the `ms` field the search route returns; validated by
looking up a `searchEventId` from a live call and matching the value.

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      "su postgres -c \"psql -d barkpark_prod -c 'select source,count(*),round(avg(duration_ms)) from search_intel_events where duration_ms is not null group by 1'\""

## R4 — THE DECISIVE MEASUREMENT: latency vs live build concurrency

Build windows come from `/opt/barkpark/.bp-site-deploy-runs/*.terminal.json`
(`started_at` / `finished_at`). Sweep them into a concurrency step function, bucket every
`search_intel_events` row by the concurrency in force at its `inserted_at`.

    # on the box, python3:
    #   iv  = [(started_at, finished_at)] from every *.terminal.json
    #   cc  = sweep of +1/-1 events -> concurrency(t)
    #   rows= \copy of (epoch, duration_ms, result_count) from search_intel_events
    #   group duration_ms by min(concurrency(t),5)

Result (window 2026-08-06T11:31Z .. 2026-08-08T00:06Z, POST-nicing, n=4,280):
concurrency 0 p50 1,246ms · 1 p50 3,585ms · 2 p50 8,631ms · 3 p50 8,473ms ·
4 p50 7,959ms · 5 p50 8,374ms. Holds after banding on `result_count`.

## R5 — how much of the time is ≥2 builds live

Same sweep, integrate wall time per concurrency level: 12.03% of wall time at ≥2,
8.02% at ≥3, peak 6. Build duration p50 52s / p95 250s / max 445s over 964 runs.

## R6 — nothing caps cross-site build concurrency

    git show origin/main:cloud/config/config.exs | sed -n '216,228p'          # site_deploy: 1
    git show origin/main:cloud/lib/barkpark_cloud/sites/auto_deploy_worker.ex | sed -n '263,270p'  # {:ok, :started} -> :ok
    git show origin/main:deploy/site-deploy.sh | sed -n '1770,1786p'          # lock is PER-SLUG

The Oban queue serializes the START step only; the flock is per-site. Five sites storm freely.

## R7 — the "8s cold path" is not cold

Five never-before-seen queries, box idle: 77-92ms wall. Cold cache is ruled out.
The 8s number is the ≥2-concurrent-build median from R4.
