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
| `lf-p1b-harden-validate` | **done** — hardening + **live pull validated** (cursor 4000→4158 from prod `gyldendal`, real events applied) |
| `lf-p2-outbox-push` | **done** — outbox/push/bootstrap/fail-closed-CAS + **live push validated** (throwaway doc created on prod with CAS; stale-base → `rev_mismatch` not overwrite; cleaned up) |
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

## What Phase 2 shipped (this branch)

The REVERSE direction — push LOCAL edits to the remote (`mix test test/barkpark/sync/` → 36 pass). New modules under `sync/`: `outbox.ex` (reads `mutation_events` `id > push_cursor` excluding `source="sync"`), `pusher.ex` (per-event replay + the pure `drain/3` seam), `push_worker.ex` (poll/drain GenServer, injected `push_fun`/`claim_fun`/`close_fun`/`tick_fun`/`backoff_fun`), `push_cursor.ex` (SEPARATE high-water mark in LOCAL `mutation_events.id` space), `push_doc_rev.ex` (per-doc remote-rev CAS ledger), `push_conflict.ex` (durable conflict quarantine). Migrations: `add_source_to_mutation_events` + `create_sync_push_{cursors,doc_revs,conflicts}`.

Three correctness pillars (each adversarially verified — an earlier cut shipped all three BROKEN, so do not regress them):
- **Echo-suppression** = a `source` column on `mutation_events` (the only viable crash-safe marker — a side-ledger has an uncloseable window). PULL writes stamp `source="sync"` (applier passes `source: :sync` → `broadcast.ex save_event`); the outbox excludes them. This required additive `source \\ :api` default params on `content/broadcast.ex` + `content/{writer,lifecycle}.ex` call sites + `tasks/internal.ex` + the `mutation_event.ex` schema. **`content.ex`/`tasks.ex` themselves are NOT touched** (invariant #1 literal); the default keeps every existing caller behaviour-identical.
- **First-enable bootstrap** (`PushCursor.bootstrap_if_absent/2`, called in `push_worker handle_continue(:schedule)`) seeds the cursor to `MAX(mutation_events.id)` for the dataset when absent (`on_conflict: :nothing` → idempotent, never rewinds). Skips ALL pre-enable history (cloned/pulled rows, regardless of the migration's `"api"` backfill) → no ping-pong of the clone on first push.
- **Fail-closed CAS** (`pusher.ex primary_mutation/2`): a known base rev → `createOrReplace` + `ifRevisionID`; `base_rev=nil` → `create` (fail-if-exists, remote 409 → `PushConflict`, **never an unconditional overwrite**). The pull applier primes `PushDocRev` with the remote `_rev` so clone→edit→push uses real CAS. Same `Settings.source` on both legs; doc_id primed under both `<id>` and `drafts.<id>` forms.

Tasks reconcile via the claim/epoch contract (`task.claimed`/`task.closed` → claim/close transports with `observed_epoch`), never a content merge.

## Live validation (2026-06-26) — two wire bugs the deterministic tests could not catch

The injected-transport tests never exercised the real HTTP wire; the live run against prod `gyldendal` exposed two REAL bugs (now fixed + regression-tested):
- **Flat vs scoped URL.** `worker.ex listen_url/1` and `pusher.ex mutate_url`/`base` built the FLAT `/v1/data/{listen,mutate}/:dataset` — which resolves to the **Default** workspace, NOT the configured source. Fixed to the scoped `/w/<ws>/p/<proj>/...`. Added a `project` setting (`BARKPARK_SYNC_PROJECT`, default `"default"`) to `Settings` + `push_context`.
- **`Accept: text/event-stream` → HTTP 406.** The listen endpoint's content negotiation rejects an explicit `text/event-stream` Accept (it sets the SSE content-type itself), so `Req.get!` returned immediately and the stream "closed" with zero events. Fixed to `Accept: */*`. (Server-side quirk — the SSE endpoint arguably SHOULD accept `text/event-stream`; left as a client workaround, not a prod-web change.) Resume correctly rides the `Last-Event-ID` header (a `?since=` query is ignored server-side).

Live ops notes: mint a scoped read+write token with `start.sh mix run <eval>` (no `PHX_SERVER` → no port bind); the dedicated `Barkpark.Sync.Finch` pool is spliced ONLY when `enabled?` — a script calling `Pusher.push` directly must set `BARKPARK_SYNC_ENABLED=1` or the pool is absent (`{:error, :transient}`). Revoke the token after (`delete_all api_tokens where label`).

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
- **P2 (outbox + push)** — DONE except the **live push run** (mirror the P1b live-run env + a write token; confirm a local edit lands on the remote with CAS, and a stale-base edit records a `PushConflict` instead of overwriting). Open follow-ups left for P3: prime `PushDocRev` is keyed by `Settings.source` — if a future config DECOUPLES the pull URL from the push URL the keys diverge and priming silently no-ops (F2 still keeps it SAFE — a missed prime becomes a conflict, not an overwrite); task events are always `source="api"` (a remote-claim mirror-back tag through `tasks.ex` is deferred).
- **P3 (doc conflict UX)** — `previous_rev` CAS; on stale base, preserve the loser (drafts./conflict) + a Studio Conflicts pane.
- **P4 (`bp sync`)** — thin CLI over this context (`status` / `pull` / start-stop); add a `replica` server kind to `barkpark.json`.
