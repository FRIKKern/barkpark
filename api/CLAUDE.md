# Barkpark — Phoenix Backend

## What this is

Elixir/Phoenix API backend for Barkpark. Serves the Go TUI client.

## Running

```bash
mix phx.server          # starts on :4000
mix ecto.reset          # drop, create, migrate, seed
mix run priv/repo/seeds.exs  # just reseed
```

## Key files

| File | Purpose |
|------|---------|
| `lib/barkpark/content.ex` | Content context — all document + schema CRUD |
| `lib/barkpark/content/document.ex` | Document Ecto schema |
| `lib/barkpark/content/schema_definition.ex` | SchemaDefinition Ecto schema |
| `lib/barkpark/auth.ex` | Token auth context |
| `lib/barkpark_web/router.ex` | All routes |
| `lib/barkpark_web/controllers/mutate_controller.ex` | Mutation endpoint (create/patch/publish/unpublish/delete) |
| `lib/barkpark_web/controllers/query_controller.ex` | Public read endpoint with perspectives |
| `lib/barkpark_web/controllers/schema_controller.ex` | Schema CRUD |
| `lib/barkpark_web/controllers/legacy_controller.ex` | Go TUI backward compat |
| `lib/barkpark_web/controllers/listen_controller.ex` | SSE real-time stream |
| `lib/barkpark/tasks.ex` | W7 task substrate — goal/phase/task/event docs, claim/close/relabel, `mutation_events` emit |
| `lib/barkpark/tenancy.ex` | W2 workspace/project tenancy context |
| `lib/barkpark/content/scope.ex` | `Barkpark.Content.Scope` — query-level tenant WHERE-clause scoping (`scope_to_workspace/3`); nil workspace fails CLOSED |
| `lib/barkpark_web/plugs/scope_helpers.ex` | `BarkparkWeb.ScopeHelpers` — HTTP/LiveView scope extractor (`scope_opts/1`) every controller calls |
| `lib/barkpark_web/controllers/tasks_controller.ex` | `/v1/tasks` (router ~:460) — task index/ready/claim/edges |
| `lib/barkpark_web/controllers/rail_controller.ex` | `/v1/rail` (router ~:501) — goal-path / event / diff for the Bulldoc rail |
| `lib/barkpark/plugins/bulldoc.ex` | **Bulldoc plugin** — the paper/document surface as a plugin. `register_schemas/1` declares the `paper` type; `register_routes/1` mounts the reader (`/papers/:slug`, `:public_root`) + ingest/intents API (`/v1/plugins/bulldoc/*`, `:ingest`). Reuses core modules as utilities — see "Bulldoc plugin" below. |
| `priv/repo/seeds.exs` | Seed data — 13 schema rows (8 core + `paper` + 4 W7a task/goal/phase/event) + ~27 docs + dev token; plugin schemas (e.g. `book`) auto-register via `Bootstrap.register_all_schemas/0`. See the seed's `IO.puts` summary lines (~:229/:259/:289/:590/:646). |

Tenancy note: alongside the flat routes there is a scoped route family
`/w/:workspace_slug/p/:project_slug/*` (router ~:618) mirroring the flat
endpoints under explicit workspace/project slugs.

## Bulldoc plugin (the Papers surface)

What used to be the built-in "Papers"/"paperflow" feature is now the
**Bulldoc plugin** (`lib/barkpark/plugins/bulldoc.ex`,
`priv/plugins/bulldoc/`). **Bulldoc is the plugin/producer brand; a "paper" is
the artifact it produces** — the persisted `type` is still `"paper"` and the
reader URL is still `/papers/:slug` (no data migration, no public-URL break).

The split is deliberate: **core stays the reusable machinery; Bulldoc is the
thin wiring layer.**

- **Core utilities (stay in `Barkpark.*` / `BarkparkWeb.*`):**
  `Barkpark.PortableDoc.{Render,Patch,Projection,Synthesis}` (the block
  engine); `Content.upsert_paper/1`, `apply_paper_block_op/3`,
  `apply_document_block_op/5`, `get_public_paper/1`, `doc_topic/4` (generic
  block-document write/stream paths); `BarkparkWeb.PaperLive`; the
  `PaperIngestController` / `PaperIntentsController`; `Barkpark.Papers.Events`;
  the `RequireIngestToken` plug; `layouts/paper.html.heex`.
- **Bulldoc plugin (`Barkpark.Plugins.Bulldoc`):** `register_schemas/1` (the
  `paper` schema) + `register_routes/1` (reader via `:public_root`, ingest via
  `:ingest`), pointing at those core modules.

The plugin route highway grew two buckets to host this (see
`BarkparkWeb.Router.Plugins`): **`:ingest`** (controller routes behind the
shared-secret `:ingest` pipeline, under `/v1/plugins/<slug>`) and
**`:public_root`** (a public LiveView at the host top-level scope with its own
full-document `root_layout:`, no studio chrome). Any future plugin that needs a
public reader page or a token-gated ingest API reuses these.

Back-compat: `/v1/paperflow/*` is kept as an alias of the canonical
`/v1/plugins/bulldoc/*` ingest routes until producers repoint; the
`:paperflow_ingest_token` config key / `PAPERFLOW_INGEST_TOKEN` env var are
unchanged.

## Draft/Published model

Documents use Sanity's `drafts.` prefix convention:
- `doc_id = "p1"` is published
- `doc_id = "drafts.p1"` is a draft
- Creating always makes `drafts.{id}`
- Publishing copies draft to published and deletes draft
- See `Content.publish_document/3`, `Content.unpublish_document/3`, `Content.discard_draft/3`

## Schema visibility

`schema_definitions.visibility` is `"public"` or `"private"`.
- Public: accessible via `/v1/data/query/` without auth
- Private: returns 404 on public API, requires auth token

## Auth

Dev token: `barkpark-dev-token` (all permissions)
Header: `Authorization: Bearer barkpark-dev-token`

Tokens are SHA256 hashed in the DB. See `ApiToken.hash_token/1`.

## Adding a new document type

Schemas are now **tenant-scoped** — every schema row is stamped with `workspace_id`/`project_id` (and documents additionally carry `dataset_id`). Scoped reads filter `WHERE dataset_id = <id>` with NO NULL-fallback, so a schema or doc inserted without a tenant lands invisible to scoped reads (the NULL-`dataset_id` trap). Pick the path that fits the type:

1. **Plugin-declared type (preferred).** Add the type to a plugin's `register_schemas/1` callback. It auto-registers on every server boot via `Barkpark.Plugins.Bootstrap.register_all_schemas/0` (also called by `seeds.exs`), correctly scoped, idempotent on `(name, dataset)`. No manual POST needed. See `docs/plugins/INSTALL.md`.
2. **Ad-hoc type (fallback).** POST to `/v1/schemas/production` with admin auth. The endpoint stamps the tenant from the request scope — do not hand-insert rows with NULL scope, or the type is invisible to scoped reads. Seeded schemas go through `stamp_schema_scope` in `seeds.exs`.
3. The Go TUI picks up new schemas on next restart (schemas loaded at startup).
4. To make it appear in the TUI navigation, add it to `structure.go` in sanity-tui.

## PubSub

After every mutation, `Content` broadcasts to two topics (see `content.ex` ~:2153/:2172):
- `"documents:#{dataset}"` — the global per-dataset stream (untouched legacy topic).
- `"documents:ws:#{workspace_id}:#{dataset}"` — additive workspace-scoped stream, broadcast only when the doc carries a `workspace_id`, so a subscriber can watch one workspace without filtering the global stream.

The `/v1/data/listen/:dataset` endpoint streams these as SSE events.

Task mutations (W7) emit `mutation_events` rows of kind `task.claimed` /
`task.closed` / `task.mutated` / `task.relabeled` (`tasks.ex`), `task.lease_expired`
(`tasks/ttl_sweeper.ex`), and `task.compacted` / `task.compaction_restored`
(`tasks/compactor.ex`). The goal-path rail filters on this kind set in
`rail_controller.ex`.
