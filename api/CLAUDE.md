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
| `priv/repo/seeds.exs` | Seed data (8 schemas, 27 docs, dev token) |

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

1. POST to `/v1/schemas/production` with auth
2. The Go TUI will pick it up on next restart (schemas loaded at startup)
3. To make it appear in the TUI navigation, add it to `structure.go` in sanity-tui

## PubSub

After every mutation, `Content` broadcasts to `"documents:#{dataset}"` topic.
The `/v1/data/listen/:dataset` endpoint streams these as SSE events.
