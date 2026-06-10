<!-- doc-tier: agent | canonical-for: api-surface | budget: 1600tok -->
# api/ — Phoenix API + LiveView Studio

Elixir/Phoenix backend: all CRUD, real-time, plugins, Studio. Dev: `mix phx.server` on `:4000`. Deep dives live in `docs/cards/` (studio · plugins · onix-bokbasen · search-media · cli · tui · js-sdk) — load via the root CLAUDE.md routing table. Plugin contract canon: `lib/barkpark/plugin.ex` @moduledoc.

## Key files

| File | Purpose |
|---|---|
| `lib/barkpark/content.ex` | Document + schema CRUD, publish/unpublish, perspectives, PubSub broadcasts |
| `lib/barkpark/plugin.ex` | `Barkpark.Plugin` behaviour — CANONICAL plugin contract (@moduledoc) |
| `lib/barkpark/plugins/` | Registry, resolver chain, Bootstrap, `tasks.ex`, `bulldocs.ex`, `onixedit/` |
| `lib/barkpark/plugins/bulldocs.ex` | Bulldocs plugin — papers reader + ingest wiring (§Bulldocs below) |
| `lib/barkpark/plugins/onixedit/export/*.ex` | ONIX 3.0 export submodules: `descriptive_detail`, `publishing_detail`, `collateral_detail`, `product_supply`, `header`, `message`, `codelists`, `validator` |
| `lib/barkpark/tasks.ex` | Task substrate utilities — claim/close/relabel, `mutation_events` emit |
| `lib/barkpark_web/router.ex` | All routes incl. `GET /v1/capabilities`; scoped `/w/:ws/p/:proj` mirror (~:672) |
| `lib/barkpark_web/live/studio/studio_live.ex` | Multi-pane Studio LiveView — section index in its header comment |
| `lib/barkpark_web/studio/pane_builder.ex` | Pane construction — **NOTE: under `studio/`, NOT `live/studio/`** |
| `lib/barkpark_web/studio/presence_state.ex` | Studio presence tracking |
| `lib/barkpark_web/controllers/` | Query (also `/v1/preview`), Mutate, Schema, Listen, Media, Tasks, Capabilities, Webhook, Legacy |
| `priv/repo/seeds.exs` | 8 core schemas + ~27 docs + dev token; plugin schemas via `Bootstrap.register_all_schemas/0` |

## Bulldocs (the Papers surface)

The built-in "Papers"/"paperflow" feature is now the **Bulldocs plugin**. Bulldocs is the plugin/producer brand; a **paper** is the artifact — persisted `type` stays `"paper"`, reader URL stays `/papers/:slug` (no data migration, no public-URL break). The split is deliberate: **core keeps the reusable machinery, the plugin is thin wiring.**

- **Core utilities:** `Barkpark.PortableDoc.{Render,Patch,Projection,Synthesis}` (block engine); `Content.upsert_paper/1`, `apply_paper_block_op/3`, `apply_document_block_op/5`, `get_public_paper/1`, `doc_topic/4`; `BarkparkWeb.Plugs.RequireIngestToken`.
- **Bulldocs-owned:** `BarkparkWeb.BulldocsLive` (reader), `BulldocsIngestController` / `BulldocsIntentsController`, `Barkpark.Plugins.Bulldocs.Events`, `layouts/bulldocs.html.heex`.
- **Plugin module:** `register_schemas/1` (the `paper` schema) + `register_routes/1` — reader on the `:public_root` bucket, ingest API on `:ingest` (`/v1/plugins/bulldocs/*`). Any plugin needing a public reader page or token-gated ingest API reuses these buckets.

**Alias-drop gate:** `/v1/paperflow/*` remains an alias of `/v1/plugins/bulldocs/*` until paperflow's `event-on-save.sh` producers repoint — externally gated; do NOT drop unilaterally. `:paperflow_ingest_token` config / `PAPERFLOW_INGEST_TOKEN` env are unchanged. Tracked in `docs/decisions/deferred.md`.

## Adding a document type: plugin-declared vs ad-hoc

Schemas are tenant-scoped (`workspace_id`/`project_id`; docs also carry `dataset_id`). Scoped reads filter `WHERE dataset_id = <id>` with NO NULL-fallback — a NULL-scope row is invisible.

| | Plugin-declared (preferred) | Ad-hoc (fallback) |
|---|---|---|
| When | the type belongs to a plugin's domain | one-off / user content type |
| How | add to the plugin's `register_schemas/1` | `POST /v1/schemas/production` (admin auth) |
| Registration | auto on every boot via `Bootstrap.register_all_schemas/0` (also seeds.exs); idempotent on `(name, dataset)` | endpoint stamps tenant from request scope |
| Trap | never reintroduce the legacy `mix run -e "...register_schemas..."` workaround | never hand-insert rows with NULL scope |

TUI picks up new schemas on restart; add to `structure.go` for TUI navigation.

## Dev constants

Token `barkpark-dev-token` (all permissions) — `Authorization: Bearer barkpark-dev-token`. SHA256-hashed in `api_tokens` (`ApiToken.hash_token/1`). Rotate before any prod use — see `docs/auth.md`.

## Document shape + draft/published

```json
{"_id":"p1","_type":"post","_draft":false,"_publishedId":"p1",
 "title":"My Post","status":"published","content":{"author":"Knut"},
 "_createdAt":"…","_updatedAt":"…"}
```

Sanity's `drafts.` prefix convention: create → always `drafts.{id}`; publish → copies draft to `{id}`, deletes draft; unpublish → moves back to `drafts.{id}`. See `Content.publish_document/3`, `unpublish_document/3`, `discard_draft/3`. Perspectives: `published` (default public), `drafts` (Studio/TUI), `raw` (everything). Schema `visibility`: `"public"` = anonymous reads; `"private"` = 404 on public API, token required.

## PubSub topics

After every mutation `Content` broadcasts (content.ex ~:2153/:2172):

- `"documents:#{dataset}"` — global per-dataset stream (legacy, untouched)
- `"documents:ws:#{workspace_id}:#{dataset}"` — additive workspace-scoped stream (only when the doc carries a `workspace_id`)

`/v1/data/listen/:dataset` streams these as SSE. Task mutations emit `mutation_events` rows: `task.claimed/closed/mutated/relabeled` (`tasks.ex`), `task.lease_expired` (`tasks/ttl_sweeper.ex`), `task.compacted/compaction_restored` (`tasks/compactor.ex`).
