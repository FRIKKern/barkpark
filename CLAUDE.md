# Sanity TUI — Project Guide

## Architecture

Two projects work together:

- **sanity-tui** (Go, Bubble Tea) — Terminal UI client at `./`
- **sanity-api** (Elixir, Phoenix) — Backend API at `../sanity_api/`
- **PostgreSQL** — Data store (managed by Ecto)

The TUI connects to Phoenix on `http://localhost:4000` (configurable via `SANITY_API_URL`).
Phoenix serves the API and stores everything in Postgres.

## Running

```bash
# Start Phoenix API (terminal 1)
cd ../sanity_api && mix phx.server

# Start Go TUI (terminal 2)
cd . && go run .

# Or use tmux dev script
./dev.sh
```

## API Endpoints

Base URL: `http://localhost:4000`
Dev token: `sanity-dev-token` (read + write + admin)

### Public API (no auth, respects schema visibility)

```
GET /v1/data/query/:dataset/:type          — list documents
GET /v1/data/query/:dataset/:type?perspective=drafts
GET /v1/data/query/:dataset/:type?filter=status=published
GET /v1/data/doc/:dataset/:type/:doc_id    — single document
```

Perspectives: `published` (default), `drafts`, `raw`

### Private API (requires Bearer token)

```
POST /v1/data/mutate/:dataset              — mutations
GET  /v1/data/listen/:dataset              — SSE real-time stream
```

### Schema Management (requires admin token)

```
GET    /v1/schemas/:dataset                — list all schemas
GET    /v1/schemas/:dataset/:name          — single schema
POST   /v1/schemas/:dataset                — create/update schema
DELETE /v1/schemas/:dataset/:name          — delete schema
```

### Legacy API (no auth, for backward compat)

```
GET    /api/documents/:type                — list docs
GET    /api/documents/:type/:id            — single doc
POST   /api/documents/:type                — create/update
DELETE /api/documents/:type/:id            — delete
GET    /api/schemas                        — list schemas
```

## Draft/Published Model

Follows Sanity's convention — drafts and published are separate rows:

- **Published**: `doc_id = "p1"` — visible on public API
- **Draft**: `doc_id = "drafts.p1"` — only visible with `perspective=drafts` or `raw`

Creating always makes a draft. Publishing copies draft to published and removes the draft.

## Common Operations

### Create a document (always starts as draft)

```bash
curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer sanity-dev-token" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"create":{"_type":"post","_id":"my-post","title":"My Post"}}]}'
```

### Edit a document (patch fields)

```bash
curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer sanity-dev-token" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"patch":{"id":"drafts.my-post","type":"post","set":{"title":"New Title","excerpt":"Updated"}}}]}'
```

### Publish a document

```bash
curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer sanity-dev-token" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"publish":{"id":"my-post","type":"post"}}]}'
```

### Unpublish (back to draft)

```bash
curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer sanity-dev-token" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"unpublish":{"id":"my-post","type":"post"}}]}'
```

### Discard draft (keep published)

```bash
curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer sanity-dev-token" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"discardDraft":{"id":"my-post","type":"post"}}]}'
```

### Delete entirely (both draft + published)

```bash
curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer sanity-dev-token" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"delete":{"id":"my-post","type":"post"}}]}'
```

### Add a new schema (document type)

```bash
curl -X POST localhost:4000/v1/schemas/production \
  -H "Authorization: Bearer sanity-dev-token" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "task",
    "title": "Task",
    "icon": "✅",
    "visibility": "private",
    "fields": [
      {"name": "title", "title": "Title", "type": "string"},
      {"name": "assignee", "title": "Assignee", "type": "reference", "refType": "author"},
      {"name": "status", "title": "Status", "type": "select", "options": ["todo", "in_progress", "done"]},
      {"name": "dueDate", "title": "Due Date", "type": "datetime"},
      {"name": "description", "title": "Description", "type": "richText"}
    ]
  }'
```

### Update a schema

Same endpoint as create — POST with the same `name` upserts:

```bash
curl -X POST localhost:4000/v1/schemas/production \
  -H "Authorization: Bearer sanity-dev-token" \
  -H "Content-Type: application/json" \
  -d '{"name": "task", "title": "Task", "icon": "📋", "visibility": "private", "fields": [...]}'
```

### Delete a schema

```bash
curl -X DELETE localhost:4000/v1/schemas/production/task \
  -H "Authorization: Bearer sanity-dev-token"
```

### Schema visibility

- `"public"` — accessible via public API without auth (for website content: post, page, author, category, project)
- `"private"` — only accessible with auth token (for internal: siteSettings, navigation, colors)

## Field Types

Available types for schema fields:

| Type | Description | Extra fields |
|------|-------------|-------------|
| `string` | Single-line text | |
| `slug` | Auto-generated slug | |
| `text` | Multi-line textarea | `rows` (default 3) |
| `richText` | Block editor | |
| `image` | Image upload | |
| `select` | Dropdown | `options: ["a", "b"]` |
| `boolean` | Toggle | |
| `datetime` | Date + time | |
| `color` | Color picker | |
| `reference` | Link to another type | `refType: "author"` |
| `array` | Repeatable list | |

## Dataset

All endpoints use `production` as the dataset. The dataset is part of every URL path.

## Mutation Format

All writes go through `POST /v1/data/mutate/:dataset` with body:

```json
{
  "mutations": [
    {"create": {"_type": "post", "_id": "my-id", "title": "..."}},
    {"createOrReplace": {"_type": "post", "_id": "my-id", "title": "..."}},
    {"patch": {"id": "drafts.my-id", "type": "post", "set": {"title": "..."}}},
    {"publish": {"id": "my-id", "type": "post"}},
    {"unpublish": {"id": "my-id", "type": "post"}},
    {"discardDraft": {"id": "my-id", "type": "post"}},
    {"delete": {"id": "my-id", "type": "post"}}
  ]
}
```

Multiple mutations can be batched in one request.

## Project Structure

### Go TUI (`sanity-tui/`)
```
main.go        — entry point, connects to Phoenix, starts TUI
tui.go         — Bubble Tea model, view, update (panes + editor)
store.go       — APIClient (HTTP calls to Phoenix)
schema.go      — Schema/Field types, loadSchemas() from API
structure.go   — Structure builder API (navigation tree)
styles.go      — Lip Gloss style definitions
```

### Phoenix API (`sanity_api/`)
```
lib/sanity_api/content.ex                — Content context (CRUD, publish, perspectives)
lib/sanity_api/content/document.ex       — Ecto Document schema
lib/sanity_api/content/schema_definition.ex — Ecto SchemaDefinition schema
lib/sanity_api/auth.ex                   — Auth context (token verification)
lib/sanity_api/auth/api_token.ex         — Ecto ApiToken schema
lib/sanity_api_web/router.ex             — All routes
lib/sanity_api_web/controllers/          — Query, Mutate, Schema, Listen, Legacy controllers
lib/sanity_api_web/plugs/require_token.ex — Auth middleware
priv/repo/seeds.exs                      — Seed data
```

## Database

PostgreSQL with three tables:
- `documents` — all content (JSONB `content` field for schema-specific data)
- `schema_definitions` — document type definitions with visibility
- `api_tokens` — authentication tokens

Reset and reseed: `cd ../sanity_api && mix ecto.reset`
