<!-- doc-tier: agent | canonical-for: local-first-sync-handoff | budget: 2400tok -->
# Local-first sync — agent handoff

Branch `feat/local-first-sync`. This is the working handoff for the **local-first
Barkpark** initiative: run a local Barkpark that mirrors a live workspace, keep
working when live disconnects, reconcile when reconnected.

**Canonical design:** Barkpark paper `2026-06-25-local-first-barkpark`
(workspace `gyldendal`, reader `/w/gyldendal/p/default/papers/2026-06-25-local-first-barkpark`).
Read it first — it has the architecture, the Cody review, and the phase plan.

## Where the work is tracked

Tasks live in the **Default** workspace (NOT `gyldendal`) because `/v1/tasks/*` is
not tenancy-mirrored yet — see task `plat-tasks-tenancy-mirror`. Drive the board
with `bp task prime --worker <you>` / `bp task ready` / `bp task next <you>`.

| Task id | State |
|---|---|
| `lf-goal` | goal (root) |
| `lf-p0-connect-clone` | **done** — cloned live `gyldendal` (13 papers) → local, live `pull_cursor=4179` (in `~/.barkpark-sync/gyldendal-production.json`) |
| `lf-p1-pull-daemon` | **done** — this branch |
| `lf-p1b-harden-validate` | **hardening done** (unresolved hard-backoff + dead-letter + worker reconnect test, this branch); **live run still open** |
| `lf-p2-outbox-push` | open — next substantive phase |
| `lf-p3-conflict-ux` | open |
| `lf-p4-bp-sync` | open |

## What Phase 1 shipped (this branch)

`Barkpark.Sync` — a one-way PULL daemon, an isolated context:

- `sync.ex` — facade: `enabled?/0`, `config/0`, `apply_frames/2` (the drain seam), `context/1`.
- `sync/sse.ex` — pure SSE frame parser (`parse_frames/1`). The deterministic wire seam.
- `sync/applier.ex` — `apply_event/2`: cursor echo-dedup → apply via Content's **public** API.
- `sync/worker.ex` — supervised streaming GenServer (Req `into:`), Last-Event-ID resume, capped backoff, reconnect-on-error.
- `sync/cursor.ex` + migration `*_create_sync_cursors.exs` — per-`{source,dataset}` high-water mark.
- `sync/settings.ex` — typed config from `BARKPARK_SYNC_*` env.
- Edits: `application.ex` (gated splice), `config.exs` + `runtime.exs` (config). **No `content.ex`/`tasks.ex` edits.**

Verify: `cd api && mix test test/barkpark/sync/` (13 pass). Clean compile.

## What Phase 1b shipped (this branch)

Hardening on top of Phase 1 (`mix test test/barkpark/sync/` → 18 pass):

- **Unresolved-workspace hard-backoff** — `worker.ex` re-probes on a long fixed delay (`@unresolved_backoff_ms` 300s) instead of a ~1Hz storm; does NOT bump the connection `attempt` (config error, not a flaky link); `do_connect` re-runs `Sync.context/1` so it **self-heals** once the workspace resolves (no manual seam). `halted_reason` is exposed in state.
- **Dead-letter / max-attempts** — `sync/dead_letter.ex` (+ `*_create_sync_dead_letters.exs` table) durably quarantines a poison event keyed `{source,dataset,event_id}`, envelope written on INSERT only. `applier.ex` `apply_event` `{:error,reason}` branch: `record_failure` (durable, attempts++) → only at `attempts >= max_attempts` (default 5, `BARKPARK_SYNC_MAX_ATTEMPTS`) does `mark_dead` → `Logger.error` → **then** `Cursor.put` → `{:ok,:dead_lettered}`. Below threshold returns `{:error,_}` (halt+replay, invariant #3 unchanged). Write-then-advance = inspectable quarantine via `DeadLetter.list_dead/2`, **never a silent skip**.
- **Worker reconnect test** — `test/barkpark/sync/worker_test.exs`, deterministic via injected `stream_fun`/`backoff_fun`/`unresolved_backoff_fun` (no network, no sleeps).

## INVARIANTS the next agent MUST preserve

1. **Never edit `content.ex` or `tasks.ex`** (Cody: #1 hotspot + god-modules). Use their public API only.
2. **Default-off.** `enabled?/0` requires url+token+dataset+**workspace**; the worker is only spliced in when enabled (fresh-install invariant).
3. **Cursor discipline.** The cursor is a single monotonic high-water mark. `apply_frames` HALTS at the first `{:error,_}` so the cursor never advances past a gap; the worker reconnects and the producer replays `id > cursor`. Do not "skip and continue" past a failed event — that is silent data loss.
4. **No NULL-scope writes.** An unresolvable workspace → `:unresolved` scope → applier refuses. Keep that guard.
5. **Wire seams ship with deterministic tests** (no network, no sleeps) — this is what keeps Cody's Contract score at 100.

## Gotchas discovered (don't relearn the hard way)

- **`rev` is uselss for dedup.** Every local write mints a fresh *random* rev and drops the incoming `_rev`, so source-rev ≠ local-rev. Dedup is cursor-based + idempotent `createOrReplace`, not rev-match.
- **Generic `createOrReplace` of a paper lands as a DRAFT.** To publish, ingest via Bulldocs (`/v1/plugins/bulldocs/papers`) or append a `publish` mutation in the same batch (see `applier.ex maybe_publish`).
- **`mutate delete drafts.<id>` normalizes to the bare id and deletes the PUBLISHED doc.** Use a discard-draft path, never `delete` to drop an overlay.
- **A new migration 503s the running dev server** (`Phoenix.Ecto.PendingMigrationError`) until `mix ecto.migrate` runs.

## To run Phase 1 live (Phase 1b, criterion 4)

```
export BARKPARK_SYNC_URL=https://api.barkpark.cloud
export BARKPARK_SYNC_TOKEN=<a live read token>
export BARKPARK_SYNC_WORKSPACE=gyldendal
export BARKPARK_SYNC_DATASET=production
export BARKPARK_SYNC_ENABLED=1
# restart the dev server so application.ex splices the worker; watch logs tail from cursor 4179
```
Live access is via `ssh root@89.167.28.206` (key `~/.ssh/id_ed25519_frikkern`); a read token can be minted on the box (see `Barkpark.Auth.create_token/4` / `PublicRead`). Do prod work read-only.

## Next phases (from the paper)

- **P1b** — DONE except the live run above (still required for criterion 4). **Known follow-up gap (reviewer-flagged):** dead-lettering keys off attempt-count alone, with NO transient-vs-permanent classification. An event that fails by *returning* `{:error,_}` (not raising) for an environmental reason — schema not-yet-registered during a deploy/migration window, a temporarily-failing plugin `before_save` gate — can after `max_attempts` be dead-lettered and the cursor advance past a *valid* mutation. It is loud + queryable + recoverable (`list_dead/2`), NOT silent loss, and most true infra blips *raise* (→ crash+replay, not counted) — but a real fix classifies retryable vs terminal errors. The worker error arm for a non-`:unresolved` reason isn't directly worker-tested (covered at the applier level).
- **P2 (outbox + push)** — the reverse direction. Outbox = local `mutation_events` with `id > push_cursor` whose rev did not originate from sync; replay to the remote `/v1/data/mutate` with `previous_rev` CAS. Tasks reconcile via the existing claim/epoch contract (no content merge). Keep a SEPARATE `push_cursor` in local id-space — never share the pull cursor.
- **P3 (doc conflict UX)** — `previous_rev` CAS; on stale base, preserve the loser (drafts./conflict) + a Studio Conflicts pane.
- **P4 (`bp sync`)** — thin CLI over this context (`status` / `pull` / start-stop); add a `replica` server kind to `barkpark.json`.
