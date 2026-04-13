# Barkpark

A headless CMS inspired by Sanity. Three ways to manage content: a web Studio, a terminal TUI, or the API directly.

**Live demo:** http://89.167.28.206/studio

## Interfaces

### Web Studio (LiveView)

Multi-pane desk structure at `/studio` — drill into content types, filter by status, edit documents with autosave, publish/unpublish. Real-time updates across tabs via PubSub.

```
┌─────────────────────────────────────────────────────────────────┐
│ ▣ Barkpark Studio                                               │
├───────────┬──────────────┬──────────────┬───────────────────────┤
│ Structure │ Post         │ All Post     │ Title                 │
│───────────│──────────────│──────────────│ ┌───────────────────┐ │
│ 📄 Post  ▸│ All Post     │ ● Getting S. │ │Getting Started    │ │
│ 📑 Page   │──────────────│ ● Why Headl. │ └───────────────────┘ │
│ 💼 Project│ Draft        │ ○ Content M. │                       │
│───────────│ Published    │              │ Slug        string    │
│ 👤 Author │ Archived     │              │ ┌───────────────────┐ │
│ 🏷 Categor│              │              │ │getting-started    │ │
│───────────│              │              │ └───────────────────┘ │
│ ⚙ Setting│              │              │                       │
└───────────┴──────────────┴──────────────┴───────────────────────┘
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
├── 📄 Post          → All Post / Draft / Published / Archived
├── 📑 Page          → document list
├── 💼 Project       → All Projects / Active / Planning / Completed
├── ──────────
├── 👤 Author        → document list
├── 🏷 Category      → document list
├── ──────────
└── ⚙ Settings      → Site Settings / Navigation / Brand Colors (singletons)
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
    "icon": "📅",
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

## Architecture

```
Browser / Apps              Server
┌─────────────┐            ┌───────────────────────────┐
│ Web Studio  │◄──WS/LV──►│ Phoenix      :4000        │
│ (LiveView)  │            │ ├── LiveView Studio        │
└─────────────┘            │ ├── REST API (CRUD)        │
                           │ ├── SSE (real-time)         │
┌─────────────┐            │ ├── Media uploads           │
│ Go TUI      │◄──HTTP───►│ └── Schema management       │
│ (Bubble Tea)│◄──SSE────►│                              │
└─────────────┘            │ PostgreSQL                   │
                           │ └── documents, schemas,      │
┌─────────────┐            │     tokens, media            │
│ Frontend /  │◄──HTTP───►│                              │
│ Mobile App  │            │ Caddy (reverse proxy :80)    │
└─────────────┘            └───────────────────────────────┘
```

## Project Structure

```
barkpark/
├── main.go                  # TUI entry point
├── tui.go                   # Bubble Tea multi-pane UI + editor
├── store.go                 # HTTP + SSE API client
├── schema.go                # Schema types, loaded from API
├── structure.go             # Desk structure builder (mirrors Sanity)
├── styles.go                # Lip Gloss terminal styles
├── api/                     # Phoenix backend
│   ├── lib/sanity_api/
│   │   ├── content.ex           # Document + schema CRUD, publish
│   │   ├── structure.ex         # Desk structure (mirrors Go)
│   │   ├── media.ex             # File uploads
│   │   └── auth.ex              # Token auth (SHA256)
│   ├── lib/sanity_api_web/
│   │   ├── router.ex            # Routes (API + Studio + Media)
│   │   ├── live/studio/
│   │   │   └── studio_live.ex   # Multi-pane desk (LiveView)
│   │   └── controllers/         # Query, Mutate, Schema, Listen, Media
│   ├── priv/repo/seeds.exs      # 8 schemas, sample docs, dev token
│   └── start.sh                 # Systemd wrapper
├── deploy.sh                # VPS setup script
├── Makefile                 # All operations
└── CLAUDE.md                # Agent guide
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
