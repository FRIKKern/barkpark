<!-- doc-tier: human | canonical-for: swarm-candidate-oban-substrate | budget: 1200tok -->
# oban-substrate — Oban background-job + cron engine for `cloud/`

**Status:** swarm CANDIDATE (judge before merge). Branch `swarm/oban-substrate`.
**Target app:** `cloud/` (`BarkparkCloud`). **Complexity:** M.

## What

Add the cloud control plane's background-job + cron engine by porting Barkpark's
own already-proven `api/` Oban setup into `cloud/`. Self-contained infra: it
ships a working queue + cron engine plus one real sample worker and stops there.
No dependency on any sibling swarm feature.

Six touch points:

1. `{:oban, "~> 2.17"}` in `cloud/mix.exs` — same major as `api/`, Postgres-backed
   via the existing `BarkparkCloud.Repo`. No Redis, no new secret.
2. `config :barkpark_cloud, Oban` in `config/config.exs` — `default: 10` +
   `maintenance: 2` queues, `Oban.Plugins.Pruner` (7-day retention) and
   `Oban.Plugins.Cron`.
3. `testing: :manual` in `config/test.exs` so the SQL.Sandbox stays deterministic.
4. `{Oban, fetch_env!(...)}` child in `application.ex`, positioned right after
   `Repo`.
5. An `oban_jobs` migration that calls the packaged `Oban.Migrations.up/down`
   (bigserial-id table, standalone, no FKs by design).
6. One real sample worker — `StaleProvisionJobReaper` (queue `:maintenance`,
   `unique` 60s, cron `* * * * *`) calling a new `Registry.reap_stale_provision_jobs/0`.

## Why

The scheduled-jobs / scheduled-backups gap analyses name "add Oban to the cloud
control plane" as the prerequisite both depend on. Rather than invent a pattern,
this ports a Barkpark-internal precedent verbatim. The sample worker earns its
keep: today provision-job staleness recovery is **lazy** — a `claimed` job whose
worker crashed is only re-claimed/failed on the next `Registry.claim_next_job/1`.
If no new claims arrive, a wedged job sits in `claimed` indefinitely and the
customer's barkpark stays "provisioning" forever. The reaper sweeps these
proactively every minute, reusing the SAME threshold/budget as the lazy path so
the two can never diverge — the cloud analog of api/'s per-minute `TtlSweeper`.

The deliberate Coolify divergence carries forward: Coolify's scheduler runs
free-text shell `command`s inside containers; this substrate only ever runs
**named Elixir workers with typed args** — Oban gives that for free.

## Coolify source anchors (the substrate this adapts)

- `app/Jobs/ScheduledJobManager.php` — Coolify's per-minute scheduler dispatcher.
- `app/Console/Kernel.php` — the Laravel cron registration the substrate replaces.
- The container-exec half (free-text `command` strings) is intentionally DROPPED.

## Barkpark port source (the precedent copied)

- `api/mix.exs` — the `{:oban, "~> 2.17"}` dep.
- `api/config/config.exs` — the `config :barkpark, Oban` block: queues + `Oban.Plugins.Pruner` + `Oban.Plugins.Cron`.
- `api/config/test.exs` — `config :barkpark, Oban, testing: :manual`.
- `api/lib/barkpark/application.ex` — `{Oban, oban_config}` child after Repo.
- `api/priv/repo/migrations/20260426100001_create_oban_jobs.exs` — `Oban.Migrations.up()`.
- `api/lib/barkpark/workers/smoke.ex` — the trivial-worker shape (the offered fallback).
- `api/lib/barkpark/tasks/ttl_sweeper.ex` — the per-minute staleness-sweep precedent.

## Barkpark files touched (this candidate)

| File | Change |
|---|---|
| `cloud/mix.exs` | add `{:oban, "~> 2.17"}` |
| `cloud/config/config.exs` | add `config :barkpark_cloud, Oban` (repo, queues, Pruner, Cron) |
| `cloud/config/test.exs` | add `testing: :manual` |
| `cloud/config/runtime.exs` | optional `OBAN_QUEUES_DISABLED` prod knob (additive) |
| `cloud/lib/barkpark_cloud/application.ex` | add `{Oban, fetch_env!(...)}` child after Repo |
| `cloud/priv/repo/migrations/20260629120000_add_oban_jobs.exs` | `Oban.Migrations.up/down` |
| `cloud/lib/barkpark_cloud/workers/stale_provision_job_reaper.ex` | the sample worker |
| `cloud/lib/barkpark_cloud/registry.ex` | add `reap_stale_provision_jobs/0` |
| `cloud/test/barkpark_cloud/workers/stale_provision_job_reaper_test.exs` | worker + wiring test |

## How to test

Deps are not provisioned in the worktree, so this was NOT compiled. Once
`cd cloud && mix deps.get` resolves `oban ~> 2.17`:

```
cd cloud
mix ecto.migrate          # runs Oban.Migrations.up() → creates oban_jobs
mix test test/barkpark_cloud/workers/stale_provision_job_reaper_test.exs
```

The test (`async: true`, safe under `:manual`) covers five cases: cron+queue
wiring, the happy re-pend path, idempotent no-op, the attempt-budget fail path,
and an `oban_jobs`-exists migration smoke. It drives the worker synchronously via
`Oban.Testing.perform_job/2` inside the Sandbox transaction.

## Caveats / review decisions

- **Reaper vs smoke as THE sample.** Shipped the reaper (real value, still
  self-contained). `api/`'s `smoke.ex` is the zero-coupling fallback — if chosen,
  drop the `config.exs` crontab entry (smoke has no schedule).
- **Queue names.** `default` + `maintenance` leave room for sibling slugs to add
  `backups` / `notifications` queues without renaming.
- **Reaper cadence.** Every minute mirrors `api/`'s `TtlSweeper`; provision SLO is
  minutes-not-seconds, so `*/2` or `*/5` would also be defensible.
- **Pruner `max_age`.** 7 days copied from `api/`; cloud volume is far lower, so
  harmless and keeps a useful audit window.
- **Re-pend vs direct re-claim.** The reaper re-pends an under-budget stale job
  (rather than re-claiming it like the lazy path) and leaves `attempts` for the
  next claim to bump — so the per-claim attempt accounting stays identical to the
  lazy path. The row CAS (`status == "claimed"`) makes a race with the lazy path a
  clean no-op.
- **No compile.** Read-judged per the swarm brief; `mix format` could not run
  (formatter imports ecto deps that aren't provisioned). Code follows the repo's
  2-space idiomatic style.
