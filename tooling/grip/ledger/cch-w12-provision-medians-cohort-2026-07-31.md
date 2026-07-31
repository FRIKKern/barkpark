# cch-w12 — Do measured phase medians exist? (provision vs deploy cohort, 2026-07-31)

Question: does a queryable cohort of succeeded `provision_jobs` with complete
`started`→`done` pairs per step exist on the live control plane, and is
"server supplies expectedMs, client prefers it" one slice through the
`/v1/barkparks` payload seam plus the already-built row-carried `expectedMs`
consumers?

Answer: SPLIT VERDICT.

* PROVISION rail cohort is FOUR jobs (`kind='provision'`, `status='succeeded'`,
  non-empty `steps`) — n=1..4 pairs per step. Not a median; a sample.
* DEPLOY rail cohort is THOUSANDS — `deployments.console` carries the same
  `{stage,status,at}` shape and 30 days of `status='live'` rows yield 8211
  BUILD pairs, 1468 HEALTH, 689 PLAN, 207 RETIRE, 154 STAGE, 97 SWITCH.
  Six of the thirteen `SERVER_STEP_EXPECTED_MS` constants are deploy stages,
  and those are the six that ARE computable.
* Client seam is REAL and already built (`buildProvisionRow(name, entries, now,
  tables)`, rows carry `expectedMs`, three consumers prefer it and fall back to
  the constant). `deployRailRows` emits NO `expectedMs`, so the deploy rail
  falls through to the constant — one added key there wires it.
* Server seam is a one-key addition: `GET /v1/barkparks` returns a MAP envelope
  (`json(conn, 200, %{barkparks: …})`, router.ex:1799), authed by
  `Auth.require_user_or_pat`.

Caveats that must reach a builder:

* Sub-poll stages quantize. RETIRE/STAGE/SWITCH min durations are 2035/2036/2036 ms
  and p50s 2102/2099/2119 ms — a ~2s reporting cadence floor, NOT stage work.
* Naive `min(running)`→`max(done)` pairing is UNSOUND: HEALTH min is −61637 ms and
  PLAN min is −10282 ms (retry entries re-order within one console array), and
  BUILD max is 111611410 ms (31 h). Per-attempt pairing + outlier trimming are
  required, not optional.

## Re-derivation

    # 1. the client seam (all from origin/main, never the worktree)
    git show origin/main:cloud/priv/static/app.js | sed -n '13387,13399p'   # the 13 constants
    git show origin/main:cloud/priv/static/app.js | grep -n 'expectedMs'    # 13458/13576/13606/13730/14005/14568
    git show origin/main:cloud/priv/static/app.js | sed -n '10247,10278p'   # deployRailRows: no expectedMs
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '1770,1800p'  # map envelope

    # 2. the cohort — READ-ONLY against the live control plane
    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
      "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \
       \"select status, kind, count(*) from provision_jobs group by 1,2 order by 3 desc\""

    # 3. per-step pairs + p50, PROVISION kind only
    #    (with e as (…jsonb_array_elements(to_jsonb(j.steps))…) where kind='provision'
    #     and status='succeeded'; p as (min(at) filter started, max(at) filter done))
    #    -> ready 4, secure 4, verify 4, configure 4, freshen 3, create 3, content 1

    # 4. per-stage pairs + p50, DEPLOY (30d, status='live')
    #    same fold over to_jsonb(d.console), status word is 'running' not 'started'
    #    -> BUILD 8211 p50 14835ms (constant 120000); HEALTH 1468 p50 2098 (18000)
    #       PLAN 689 p50 2046 (3000); RETIRE 207 2102 (4000); STAGE 154 2099 (8000)
    #       SWITCH 97 2119 (3000)

## Measured vs hardcoded (the size of the lie)

| rail | step | constant ms | measured p50 ms | pairs |
|---|---|---|---|---|
| provision | create | 15000 | 344 | 3 |
| provision | freshen | 300000 | 377066 | 3 |
| provision | secure | 45000 | 46902 | 4 |
| provision | configure | 35000 | 34854 | 4 |
| provision | content | 20000 | 501 | 1 |
| provision | verify | 15000 | 409 | 4 |
| provision | ready | 10000 | 43 | 4 |
| deploy | PLAN | 3000 | 2046 | 689 |
| deploy | BUILD | 120000 | 14835 | 8211 |
| deploy | STAGE | 8000 | 2099 | 154 |
| deploy | HEALTH | 18000 | 2098 | 1468 |
| deploy | SWITCH | 3000 | 2119 | 97 |
| deploy | RETIRE | 4000 | 2102 | 207 |
