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
| `lf-p1b-harden-validate` | open — deferred robustness + the live run |
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

- **P1b** — make `:unresolved_workspace` a permanent hard-backoff (not 1Hz reconnect); dead-letter/max-attempts for a poison event so it can't block the cursor; a Worker reconnect-path test; the live run above.
- **P2 (outbox + push)** — the reverse direction. Outbox = local `mutation_events` with `id > push_cursor` whose rev did not originate from sync; replay to the remote `/v1/data/mutate` with `previous_rev` CAS. Tasks reconcile via the existing claim/epoch contract (no content merge). Keep a SEPARATE `push_cursor` in local id-space — never share the pull cursor.
- **P3 (doc conflict UX)** — `previous_rev` CAS; on stale base, preserve the loser (drafts./conflict) + a Studio Conflicts pane.
- **P4 (`bp sync`)** — thin CLI over this context (`status` / `pull` / start-stop); add a `replica` server kind to `barkpark.json`.
