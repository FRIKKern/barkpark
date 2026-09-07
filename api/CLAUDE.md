<!-- doc-tier: agent | canonical-for: api-surface | budget: 1600tok -->
# api/ — Phoenix API + LiveView Studio

Elixir/Phoenix backend: all CRUD, real-time, plugins, Studio. Dev: `mix phx.server` on `:4000`. Deep dives: `docs/cards/` via the root routing table. Plugin contract canon: `lib/barkpark/plugin.ex` @moduledoc.

## Key files

| File | Purpose |
|---|---|
| `lib/barkpark/content.ex` | Document + schema CRUD, publish/unpublish, perspectives, PubSub broadcasts |
| `lib/barkpark/plugin.ex` | `Barkpark.Plugin` behaviour — CANONICAL plugin contract (@moduledoc) |
| `lib/barkpark/plugins/` | Registry, resolver chain, Bootstrap, `tasks.ex`, `bulldocs.ex`, `sheets.ex` (§§ below), `onixedit/` |
| `lib/barkpark/plugins/onixedit/export/*.ex` | ONIX 3.0 export submodules (header, message, codelists, validator, detail composites) |
| `lib/barkpark/tasks.ex` | Task substrate utilities — claim/close/relabel, `mutation_events` emit |
| `lib/barkpark_web/router.ex` | All routes incl. `GET /v1/capabilities`; scoped `/w/:workspace_slug/p/:project_slug` mirror |
| `lib/barkpark_web/live/studio/studio_live.ex` | Multi-pane Studio LiveView — section index in its header comment |
| `lib/barkpark_web/studio/pane_builder.ex` | Pane construction — **under `studio/`, NOT `live/studio/`** |
| `lib/barkpark_web/studio/presence_state.ex` | Studio presence tracking |
| `lib/barkpark_web/controllers/` | Query (also `/v1/preview`), Mutate, Schema, Listen, Media, Tasks, Capabilities, Webhook, Legacy |
| `priv/repo/seeds.exs` → `Barkpark.Seeds.run/0` | dispatches by `BARKPARK_SEED_PROFILE` (`demo`\|`clean`); demo (`seeds/demo.ex`) seeds 8 schemas + ~27 docs + dev token; tail (`seeds.ex`) runs `Bootstrap.register_all_schemas/0` |

## Bulldocs (the Papers surface)

**Papers** is the **Bulldocs plugin** — plugin/producer brand; a **paper** is the artifact (persisted `type` stays `"paper"`, reader URL `/papers/:slug`). **Core keeps the reusable machinery, the plugin is thin wiring.**

- **Core utilities:** `Barkpark.PortableDoc.{Render,Patch,Projection,Synthesis,Bpml}` (block engine); `Content.upsert_paper/1`, `apply_paper_block_op/3`, `apply_document_block_op/5`, `get_public_paper/1`, `doc_topic/4`; `BarkparkWeb.Plugs.RequireIngestToken`.
- **Bulldocs-owned:** `BarkparkWeb.BulldocsLive` (reader), `BulldocsIngestController` / `BulldocsIntentsController`, `Barkpark.Plugins.Bulldocs.Events`, `layouts/bulldocs.html.heex`.
- **Reader editing:** `BulldocsLive.Edit` shares Studio’s canvas/echoes, gates with `PaperViewer`, awaits saves before View. Stage text edits on-page; options stay contextual.
- **Plugin module:** `register_schemas/1` + `register_routes/1` — reader on `:public_root`, ingest API on `:ingest` (`/v1/plugins/bulldocs/*`). Reused by any plugin wanting a reader or token-gated ingest.
- **Sessions:** 2nd blocks type (whitelist `{paper, session}`); routes `/v1/plugins/bulldocs/sessions*`; private+unwalled schema; Studio pane read-only v1 (`bp session publish` writes).

**Alias-drop gate:** `/v1/paperflow/*` aliases `/v1/plugins/bulldocs/*` for legacy producers — externally gated, do NOT drop. Ingest auth: `:ingest_token` from `BARKPARK_INGEST_TOKEN` (legacy `PAPERFLOW_INGEST_TOKEN`). See `docs/decisions/deferred.md`.

## Sheets

`type:"sheet"` docs (multi-tab, sparse A1 `cells` maps) + a `"sheet"` embed block carrying a dense snapshot — Bulldocs split again (core machinery, thin plugin wiring; fresh-install invariant). Core is `Barkpark.Plugins.Sheets.{Core,Engine,Session,Structure}` + `SheetsReaderLive` / `Studio.SheetGrid`; the plugin (`plugins/sheets.ex`) declares the `sheet` schema, a before_save gate, the `:ingest` import/export/ops API and the `/sheets/:slug` reader; embeds refresh via `content/sheets.ex`.

Owner (caps, formula subset, error envelopes, embed pipeline, session deltas): `docs/contracts/sheets-engine.md`.

## Adding a document type: plugin-declared vs ad-hoc

Schemas are tenant-scoped (`workspace_id`/`project_id`; docs add `dataset_id`). A NULL-`dataset_id` row is visible via its `dataset` string; invisible only when that string mismatches.

| | Plugin-declared (preferred) | Ad-hoc (fallback) |
|---|---|---|
| When | the type belongs to a plugin's domain | one-off / user content type |
| How | add to the plugin's `register_schemas/1` | `POST /v1/schemas/production` (admin auth) |
| Registration | auto on every boot via `Bootstrap.register_all_schemas/0` (also seeds.exs); idempotent on `(name, dataset)` | endpoint stamps tenant from request scope |
| Trap | never reintroduce the legacy `mix run` schema workaround | never hand-insert rows with NULL scope |

TUI desk = server tree (`GET /v1/structure/:dataset`).

## Dev constants

Token `barkpark-dev-token` (all permissions); SHA256-hashed in `api_tokens` (`ApiToken.hash_token/1`). Rotate before prod — `docs/auth.md`.

## Document shape + draft/published

```json
{"_id":"p1","_type":"post","_draft":false,"_publishedId":"p1",
 "title":"My Post","status":"published","content":{"author":"Knut"}}
```

Sanity's `drafts.` prefix convention (api-v1.md §6) — `Content.publish_document/3`, `unpublish_document/3`, `discard_draft/3`. Perspectives: `published` (default public), `drafts` (Studio/TUI), `raw` (everything). Schema `visibility`: `"public"` = anonymous reads; `"private"` = 404 on public API, token required.

## PubSub topics

After every mutation `Content` broadcasts (content/broadcast.ex — `tap_broadcast` / `broadcast_document_mutation`):

- `"documents:#{dataset}"` — global per-dataset stream (legacy, untouched)
- `"documents:ws:#{workspace_id}:#{dataset}"` — additive workspace-scoped stream (only when the doc carries a `workspace_id`)

`/v1/data/listen/:dataset` streams these as SSE. Task mutations emit `mutation_events` rows — 17 kinds: `task.{claimed,closed,compacted,compaction_restored,criterion,discharged,engagement_lapsed,landed,lease_expired,lease_renewed,mutated,pulse,referenced,relabeled,released,reparented,staged}` (`tasks.ex`, `tasks/landed.ex`, `tasks/renew.ex`, `tasks/ttl_sweeper.ex`, `tasks/compactor.ex`). The `@event_task_*` attributes own this roster — EMITTED names only, never verbs like `task.get`; `scripts/roster-drift-check.sh` re-derives and diffs this line. A consumer switching on a stale subset drops kinds silently.
