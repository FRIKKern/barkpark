# Space rows silently shorten every metrics chart window (wave 5 verifier)

Claim: `GET /v1/barkparks/:id/metrics` passes `points` as the ROW limit to
`Registry.recent_events/2`, which is type-blind; `Metrics.build/3` then keeps
only `"health"`. Every non-health row inside the fetched N costs one chart
point while the envelope still reports `points: N`. At the shipped space
cadence (health 60s, space 15m = 1 in 16) a 200-point window renders 188.

All commands from repo root unless noted. `origin/main` = bf97452bb38488d04cfbb596c2528a3f34ad5baf.

## 1. The read path (three lines, two files)

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '7719,7742p'
    # points = parse_limit(conn.query_params["points"], 30, 200)
    # events = Registry.recent_events(bp, points)
    # json(conn, 200, Metrics.build(bp, events, points: points))

    git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '2722,2736p'
    # no type predicate in the where clause

    git show origin/main:cloud/lib/barkpark_cloud/metrics.ex | sed -n '118,136p'
    # health_newest_first = for %AgentEvent{type: "health"} = e <- events, do: e
    # points: points        <- echoed from opts, NOT length(series)

## 2. The existing unit test is structurally blind

    cd cloud && CC=clang mix test test/barkpark_cloud/metrics_test.exs
    # 14 tests, 0 failures in 0.07s — pure, hand-built event lists, no DB,
    # never calls recent_events/2, so the limit can never appear.

## 3. Proof over the real HTTP path, TODAY, with no schema change

Uses `"status"` (already in `@types`) as the stand-in slow-axis row, so the
defect is present-tense rather than pending the space slice. Probe lives at
`scratchpad/metrics_route_dilution_probe_test.exs` (not committed); shape:

- seed 60 health beats 60s apart + one non-health row every 15th beat
- `GET /v1/barkparks/:id/metrics`            -> points 30,  series.cpu 29
- control, all-health stream                 -> points 30,  series.cpu 30
- `?points=200` over 240 beats + 15 non-health -> points 200, series.cpu 188

    cd cloud && CC=clang mix test <probe>.exs
    # [HTTP] envelope points = 30 / series.cpu length = 29 / SHORTFALL = 1 of 30
    # [HTTP-cap] points = 200, series.cpu = 188, SHORTFALL = 12

## 4. `record_event` with type "space" fails today

    cd cloud && CC=clang mix test <probe>.exs   # test A
    # errors: [type: {"is invalid", [validation: :inclusion,
    #   enum: ["health","status","backup","tls","content","verify"]}]

    git grep -n 'agent/space\|"space"' origin/main -- cloud/lib cloud/test
    # (no output) — route absent, allowlist unwidened

## 5. Retention worker needs NO change

    git show origin/main:cloud/lib/barkpark_cloud/workers/agent_retention_worker.ex
    # from(e in AgentEvent, where: e.inserted_at < ^events_cutoff) |> Repo.delete_all()
    # type-agnostic; +96 space rows/day/box on ~1440 health = +6.7% rows, 14d window unchanged.
    # Its moduledoc's "one `health` row per 60s beat" and "recent_events/2's
    # limit-50 tail is unaffected" become stale prose once space lands.

## 6. The other three recent_events consumers

    git grep -n 'recent_events' origin/main -- cloud/lib

- `usage.ex:605` `Enum.find(recent_events(bp, 100), health)` — nil unmeters BOTH
  `db_size` and `disk` (usage.ex:259-281). Safe at 1-in-16; breaks if cadence rises.
- `router.ex` telemetry route (hard-coded 100) — same shape, and its comment
  states the assumption verbatim: "the per-cycle health beat is by far the most
  frequent event kind".
- `router.ex` events timeline (limit 50/200) — space rows are wanted here.

## 7. Fix shape

Filter by type in the query (`recent_health_events/2`, or a `type` opt on
`recent_events/2`) so `points` health rows are fetched. Index
`agent_events(barkpark_id, inserted_at)` (migration 20260626193200) still backs
it; no new index needed at 14-day retention. Regression guard belongs in
`cloud/test/barkpark_cloud/web/metrics_route_test.exs` (DB-backed), NOT
`metrics_test.exs` (pure): assert `length(series.cpu) == points` on a
mixed-type stream.
