# Barkpark

A headless CMS inspired by Sanity. Three ways to manage content: a web Studio, a terminal TUI, or the API directly.

**Live demo:** http://89.167.28.206/studio

## Interfaces

### Web Studio (LiveView)

Multi-pane desk structure at `/studio` — drill into content types, filter by status, edit documents with autosave, publish/unpublish. Real-time updates across tabs via PubSub.

```
 Structure    | Post         | All Post       | Editor
--------------+--------------+----------------+---------------------
 Post       > | All Post     | * Getting S..  | Title
 Page         |--------------| * Why Headl..  | [Getting Started   ]
 Project      | Draft        | o Content M..  |
--------------| Published    |                | Slug        string
 Author       | Archived     |                | [getting-started   ]
 Category     |              |                |
--------------+              |                |
 Settings   > |              |                |
```

### Terminal TUI (Go + Bubble Tea)

Same desk structure in the terminal. Keyboard-driven: `hjkl` navigation, `Enter` to edit, `Ctrl+S` to save. Connects to the Phoenix API over HTTP + SSE for real-time sync.

| Key | Action |
|-----|--------|
| `j` / `k` | Move up/down |
| `h` / `l` | Switch panes / drill in |
| `Enter` | Select / edit field |
| `Space` | Toggle boolean / cycle select |
| `Ctrl+S` | Save |
| `Esc` | Back |
| `q` | Quit |

### API

RESTful content API with Sanity-compatible mutation format. Public reads, authenticated writes.

```bash
# Read (public)
curl localhost:4000/v1/data/query/production/post
curl localhost:4000/v1/data/query/production/post?perspective=drafts
curl localhost:4000/v1/data/doc/production/post/p1

# Write (requires auth)
TOKEN="barkpark-dev-token"

curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"create":{"_type":"post","_id":"my-post","title":"Hello"}}]}'

# Publish / Unpublish
-d '{"mutations":[{"publish":{"id":"my-post","type":"post"}}]}'
-d '{"mutations":[{"unpublish":{"id":"my-post","type":"post"}}]}'

# Real-time (SSE)
curl -N -H "Authorization: Bearer $TOKEN" localhost:4000/v1/data/listen/production
```

## Desk Structure

Content types with a `status` field (Post, Project) get filtered sub-views automatically — just like Sanity Studio's desk tool. Private schemas appear as singletons under Settings.

```
Structure
  Post             -> All Post / Draft / Published / Archived
  Page             -> document list
  Project          -> All Projects / Active / Planning / Completed
  --------
  Author           -> document list
  Category         -> document list
  --------
  Settings         -> Site Settings / Navigation / Brand Colors (singletons)
```

The desk structure is auto-generated from schemas. Add a new schema via the API and it appears in both the Web Studio and TUI.

## Draft/Published Model

| State | doc_id | Public API |
|-------|--------|------------|
| Draft | `drafts.my-post` | Hidden |
| Published | `my-post` | Visible |

Editing a published document creates a draft overlay. Publishing copies the draft to published and deletes the draft. Three perspectives: `published` (default), `drafts` (studio), `raw` (everything).

## Quick Start

### Local development

```bash
git clone https://github.com/FRIKKern/barkpark.git
cd barkpark

# Setup API
cd api && mix deps.get && mix ecto.setup && cd ..

# Run both
make dev

# Or separately
make api    # Phoenix on :4000
make tui    # Go TUI
```

Open http://localhost:4000/studio for the web interface.

### Deploy to a VPS

One-command setup on any Ubuntu 22.04+ server (ARM64 or x86_64):

```bash
ssh root@YOUR_VPS_IP 'bash -s' < deploy.sh
```

Installs PostgreSQL, Erlang/Elixir (via ASDF), Go, Caddy, and a systemd service. First run takes 10-15 minutes on ARM (Erlang compiles from source).

After setup:

```bash
ssh root@YOUR_VPS_IP
cd /opt/barkpark
make deploy    # git pull + rebuild + restart
make status    # service health
make logs      # tail logs
```

## Schema & Field Types

Create schemas via API — they drive the Studio UI, TUI, and desk structure automatically.

```bash
curl -X POST localhost:4000/v1/schemas/production \
  -H "Authorization: Bearer barkpark-dev-token" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "event",
    "title": "Event",
    "icon": "calendar",
    "visibility": "public",
    "fields": [
      {"name": "title", "title": "Title", "type": "string"},
      {"name": "date", "title": "Date", "type": "datetime"},
      {"name": "featured", "title": "Featured", "type": "boolean"}
    ]
  }'
```

| Type | Description | Options |
|------|-------------|---------|
| `string` | Single-line text | |
| `slug` | URL-safe identifier | |
| `text` | Multi-line | `rows` |
| `richText` | Block editor | |
| `image` | Image upload | |
| `select` | Dropdown | `options: ["a", "b"]` |
| `boolean` | Toggle | |
| `datetime` | Date + time | |
| `color` | Color picker | |
| `reference` | Link to type | `refType: "author"` |
| `array` | Repeatable list | |

Schema visibility: `public` (queryable without auth) or `private` (requires token, appears under Settings as singleton).

## Guides

### Creating a new content type

Create a schema and it appears in both Studio and TUI automatically.

```bash
curl -X POST localhost:4000/v1/schemas/production \
  -H "Authorization: Bearer barkpark-dev-token" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "recipe",
    "title": "Recipe",
    "icon": "recipe",
    "visibility": "public",
    "fields": [
      {"name": "title", "title": "Title", "type": "string"},
      {"name": "slug", "title": "Slug", "type": "slug"},
      {"name": "difficulty", "title": "Difficulty", "type": "select", "options": ["easy", "medium", "hard"]},
      {"name": "prepTime", "title": "Prep Time", "type": "string"},
      {"name": "instructions", "title": "Instructions", "type": "richText"},
      {"name": "image", "title": "Photo", "type": "image"},
      {"name": "vegetarian", "title": "Vegetarian", "type": "boolean"},
      {"name": "author", "title": "Author", "type": "reference", "refType": "author"}
    ]
  }'
```

Reload the Studio and "Recipe" appears in the structure. Since it has no `status` field, it shows as a simple document list. Add a `status` field with `options` to get automatic filtered sub-views.

### Adding filtered sub-views to a type

Any schema with a `status` field of type `select` automatically gets filtered sub-views in the desk structure. For example, adding status to the recipe schema:

```json
{"name": "status", "title": "Status", "type": "select", "options": ["draft", "published", "archived"]}
```

This produces:

```
Recipe
  All Recipe
  --------
  Draft
  Published
  Archived
```

Each sub-view only shows documents matching that status value.

### Creating a singleton (settings-style type)

Set `visibility: "private"` and the type appears under Settings as a singleton — one document, no list, direct editor.

```bash
curl -X POST localhost:4000/v1/schemas/production \
  -H "Authorization: Bearer barkpark-dev-token" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "footer",
    "title": "Footer",
    "icon": "link",
    "visibility": "private",
    "fields": [
      {"name": "copyright", "title": "Copyright Text", "type": "string"},
      {"name": "showSocials", "title": "Show Social Links", "type": "boolean"},
      {"name": "backgroundColor", "title": "Background Color", "type": "color"}
    ]
  }'
```

Result in desk structure:

```
Settings
  Site Settings
  Navigation
  Brand Colors
  Footer            <-- new singleton
```

### Customizing the desk structure

The desk structure is defined in two files that should stay in sync:

**Elixir** (Web Studio): `api/lib/barkpark/structure.ex` — the `build_desk_items/1` function.

**Go** (TUI): `structure.go` — the `initRootStructure()` function.

Both use the same pattern: group schemas into content, taxonomy, and settings.

To change the ordering or grouping, edit `build_desk_items/1` (Elixir) and `initRootStructure()` (Go). For example, to add a "Media" section:

```elixir
# In structure.ex, build_desk_items/1:
content_items ++
  [divider()] ++
  taxonomy_items ++
  [divider()] ++
  [%Node{id: "media", title: "Media", icon: "camera", type: :list, items: [
    doc_type_list_item(schemas["photo"]),
    doc_type_list_item(schemas["video"])
  ]}] ++
  [divider()] ++
  settings_items
```

```go
// In structure.go, initRootStructure():
items = append(items, Divider())
items = append(items,
    ListItem().Title("Media").Icon("camera").Child(
        List().ID("media").Title("Media").Items(
            DocumentTypeListItem("photo"),
            DocumentTypeListItem("video"),
        ).Build(),
    ).Build(),
)
```

### Managing documents via the API

```bash
TOKEN="barkpark-dev-token"

# Create a document (always starts as draft)
curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"create":{"_type":"post","_id":"my-post","title":"Hello World"}}]}'

# Edit fields
curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"patch":{"id":"drafts.my-post","type":"post","set":{"title":"Updated Title","body":"New content"}}}]}'

# Publish (copies draft to published, deletes draft)
curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"publish":{"id":"my-post","type":"post"}}]}'

# Unpublish (moves published back to draft)
curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"unpublish":{"id":"my-post","type":"post"}}]}'

# Delete
curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"delete":{"id":"my-post","type":"post"}}]}'
```

### Querying content from a frontend

```bash
# All published posts (public, no auth needed)
curl localhost:4000/v1/data/query/production/post

# Filter by status
curl "localhost:4000/v1/data/query/production/post?filter=status=published"

# Single document
curl localhost:4000/v1/data/doc/production/post/p1

# Drafts perspective (for preview/studio)
curl "localhost:4000/v1/data/query/production/post?perspective=drafts"
```

Response format:

```json
{
  "count": 3,
  "type": "post",
  "documents": [
    {
      "_id": "p1",
      "_type": "post",
      "title": "Getting Started",
      "status": "published",
      "content": {"slug": "getting-started", "body": "..."},
      "_createdAt": "2026-04-12T09:11:20Z",
      "_updatedAt": "2026-04-12T09:11:20Z"
    }
  ]
}
```

### Uploading media

```bash
# Upload a file
curl -X POST localhost:4000/media/upload \
  -H "Authorization: Bearer barkpark-dev-token" \
  -F "file=@photo.jpg"

# List all media
curl localhost:4000/media

# Serve a file
curl localhost:4000/media/files/2026/04/photo-abc123.jpg

# Delete
curl -X DELETE localhost:4000/media/FILE_ID \
  -H "Authorization: Bearer barkpark-dev-token"
```

### Connecting the TUI to a remote server

```bash
BARKPARK_API_URL=http://YOUR_VPS_IP:4000 go run .
```

Or with a custom token:

```bash
BARKPARK_API_URL=http://YOUR_VPS_IP:4000 BARKPARK_API_TOKEN=your-token go run .
```

## Architecture

```
Clients                        Server
                               Phoenix :4000
Web Studio  ---WebSocket--->     LiveView Studio
Go TUI      ---HTTP/SSE---->     REST API (CRUD + SSE)
Frontend    ---HTTP GET----->    Public query API
                                 Media uploads
                                 Schema management

                               PostgreSQL
                                 documents, schemas, tokens, media

                               Caddy :80 -> localhost:4000
```

## Project Structure

```
barkpark/
  main.go                    TUI entry point
  tui.go                     Bubble Tea multi-pane UI + editor
  store.go                   HTTP + SSE API client
  schema.go                  Schema types, loaded from API
  structure.go               Desk structure builder (mirrors Sanity)
  styles.go                  Lip Gloss terminal styles
  api/                       Phoenix backend
    lib/barkpark/
      content.ex             Document + schema CRUD, publish
      structure.ex           Desk structure (mirrors Go)
      media.ex               File uploads
      auth.ex                Token auth (SHA256)
    lib/barkpark_web/
      router.ex              Routes (API + Studio + Media)
      live/studio/
        studio_live.ex       Multi-pane desk (LiveView)
      controllers/           Query, Mutate, Schema, Listen, Media
    priv/repo/seeds.exs      8 schemas, sample docs, dev token
    start.sh                 Systemd wrapper
  deploy.sh                  VPS setup script
  Makefile                   All operations
  CLAUDE.md                  Agent guide
```

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Web Studio | Phoenix LiveView |
| TUI | Go, Bubble Tea, Lip Gloss |
| API | Elixir, Phoenix |
| Database | PostgreSQL (JSONB) |
| Real-time | PubSub (LiveView), SSE (TUI/API) |
| Auth | Bearer tokens (SHA256) |
| Proxy | Caddy |

## License

MIT
