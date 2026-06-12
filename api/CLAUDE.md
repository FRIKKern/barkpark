<!-- doc-tier: agent | canonical-for: api-surface | budget: 1600tok -->
# api/ — Phoenix API + LiveView Studio

Elixir/Phoenix backend: all CRUD, real-time, plugins, Studio. Dev: `mix phx.server` on `:4000`. Deep dives: `docs/cards/` via the root CLAUDE.md routing table. Plugin contract canon: `lib/barkpark/plugin.ex` @moduledoc.

## Key files

| File | Purpose |
|---|---|
| `lib/barkpark/content.ex` | Document + schema CRUD, publish/unpublish, perspectives, PubSub broadcasts |
| `lib/barkpark/plugin.ex` | `Barkpark.Plugin` behaviour — CANONICAL plugin contract (@moduledoc) |
| `lib/barkpark/plugins/` | Registry, resolver chain, Bootstrap, `tasks.ex`, `bulldocs.ex`, `sheets.ex` (§§ below), `onixedit/` |
| `lib/barkpark/plugins/onixedit/export/*.ex` | ONIX 3.0 export submodules (header, message, codelists, validator, detail composites) |
| `lib/barkpark/tasks.ex` | Task substrate utilities — claim/close/relabel, `mutation_events` emit |
| `lib/barkpark_web/router.ex` | All routes incl. `GET /v1/capabilities`; scoped `/w/:ws/p/:proj` mirror (~:672) |
| `lib/barkpark_web/live/studio/studio_live.ex` | Multi-pane Studio LiveView — section index in its header comment |
| `lib/barkpark_web/studio/pane_builder.ex` | Pane construction — **NOTE: under `studio/`, NOT `live/studio/`** |
| `lib/barkpark_web/studio/presence_state.ex` | Studio presence tracking |
| `lib/barkpark_web/controllers/` | Query (also `/v1/preview`), Mutate, Schema, Listen, Media, Tasks, Capabilities, Webhook, Legacy |
| `priv/repo/seeds.exs` | 8 core schemas + ~27 docs + dev token; plugin schemas via `Bootstrap.register_all_schemas/0` |

## Bulldocs (the Papers surface)

The built-in "Papers"/"paperflow" feature is now the **Bulldocs plugin**. Bulldocs is the plugin/producer brand; a **paper** is the artifact — persisted `type` stays `"paper"`, reader URL stays `/papers/:slug` (no data migration, no public-URL break). **Core keeps the reusable machinery, the plugin is thin wiring.**

- **Core utilities:** `Barkpark.PortableDoc.{Render,Patch,Projection,Synthesis}` (block engine); `Content.upsert_paper/1`, `apply_paper_block_op/3`, `apply_document_block_op/5`, `get_public_paper/1`, `doc_topic/4`; `BarkparkWeb.Plugs.RequireIngestToken`.
- **Bulldocs-owned:** `BarkparkWeb.BulldocsLive` (reader), `BulldocsIngestController` / `BulldocsIntentsController`, `Barkpark.Plugins.Bulldocs.Events`, `layouts/bulldocs.html.heex`.
- **Plugin module:** `register_schemas/1` (the `paper` schema) + `register_routes/1` — reader on the `:public_root` bucket, ingest API on `:ingest` (`/v1/plugins/bulldocs/*`). Any plugin needing a public reader page or token-gated ingest API reuses these buckets.

**Alias-drop gate:** `/v1/paperflow/*` remains an alias of `/v1/plugins/bulldocs/*` until paperflow's `event-on-save.sh` producers repoint — externally gated; do NOT drop unilaterally. `:paperflow_ingest_token` config / `PAPERFLOW_INGEST_TOKEN` env are unchanged. Tracked in `docs/decisions/deferred.md`.

## Sheets

`type:"sheet"` docs (multi-tab, sparse A1 `cells` maps) + a `"sheet"` embed block carrying a dense snapshot — the Bulldocs split again (core machinery, thin plugin wiring; fresh-install invariant).

- **Core:** `Barkpark.Sheets` (A1 + snapshot synthesis, 200k-position cap), `Sheets.Engine` (formula subset; eager-IF deps → `#CYCLE!`), `Sheets.Session` (lazy per-sheet GenServer; serialized cell/structural/undo ops, ≤1000/call, debounced persist 2s/25-ops + terminate), `Sheets.Structure` (ref-shift), `SheetsReaderLive`, `Studio.SheetGrid`.
- **Plugin (`plugins/sheets.ex`):** `sheet` schema; before_save gate (A1 keys, XFD/1,048,576 grid bounds, merge area ≤10k) → mutate 409 `halted`; `:ingest` API `POST /v1/plugins/sheets/import` (xlsx/csv/tsv; 413 `upload_too_large` >15MB / `sheet_too_large` >50k cells, 422 `invalid_xlsx`) · `GET …/:slug/export.{xlsx,csv,tsv,md,html}` (flush-first; 503 `flush_failed` + retry-after) · `POST …/:slug/ops` (422 `batch_too_large`, 503 `session_unavailable` + retry-after); `:public_root` live reader `/sheets/:slug` (published-only).
- **Pipeline:** sheet saves run Engine recompute → write-through refreshes every embedding paper's snapshot; hydration mirrors it when a paper save adds `{"type":"sheet","ref":…}` blocks (content.ex ~:1431/:1552).

Session deltas: `{:sheets_op, %{rev, tab, changed}}` on `doc_topic <> ":sheets:op"`; SSE doc events fire only on the debounced persist.

## Adding a document type: plugin-declared vs ad-hoc

Schemas are tenant-scoped (`workspace_id`/`project_id`; docs also carry `dataset_id`). Scoped reads filter `WHERE dataset_id = <id>` with NO NULL-fallback — a NULL-scope row is invisible.

| | Plugin-declared (preferred) | Ad-hoc (fallback) |
|---|---|---|
| When | the type belongs to a plugin's domain | one-off / user content type |
| How | add to the plugin's `register_schemas/1` | `POST /v1/schemas/production` (admin auth) |
| Registration | auto on every boot via `Bootstrap.register_all_schemas/0` (also seeds.exs); idempotent on `(name, dataset)` | endpoint stamps tenant from request scope |
| Trap | never reintroduce the legacy `mix run` schema workaround | never hand-insert rows with NULL scope |

TUI picks up new schemas on restart; add to `structure.go` for nav.

## Dev constants

Token `barkpark-dev-token` (all permissions); SHA256-hashed in `api_tokens` (`ApiToken.hash_token/1`). Rotate before prod — `docs/auth.md`.

## Document shape + draft/published

```json
{"_id":"p1","_type":"post","_draft":false,"_publishedId":"p1",
 "title":"My Post","status":"published","content":{"author":"Knut"}}
```

Sanity's `drafts.` prefix convention (api-v1.md §6) — `Content.publish_document/3`, `unpublish_document/3`, `discard_draft/3`. Perspectives: `published` (default public), `drafts` (Studio/TUI), `raw` (everything). Schema `visibility`: `"public"` = anonymous reads; `"private"` = 404 on public API, token required.

## PubSub topics

After every mutation `Content` broadcasts (content.ex ~:2153/:2172):

- `"documents:#{dataset}"` — global per-dataset stream (legacy, untouched)
- `"documents:ws:#{workspace_id}:#{dataset}"` — additive workspace-scoped stream (only when the doc carries a `workspace_id`)

`/v1/data/listen/:dataset` streams these as SSE. Task mutations emit `mutation_events` rows: `task.{claimed,closed,mutated,relabeled,lease_expired,compacted,compaction_restored}` (`tasks.ex`, `tasks/ttl_sweeper.ex`, `tasks/compactor.ex`).
