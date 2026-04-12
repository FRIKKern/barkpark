# Barkpark CMS

A headless CMS with a terminal-native Studio interface. Built with Go (TUI) and Elixir/Phoenix (API).

```
┌──────────────────────────────────────────────────────────────────┐
│ ▣ Studio  [Structure]  Structure > Post > Getting Started...    │
├──────────┬──────────┬──────────┬─────────────────────────────────┤
│ Structure│ Post   8 │ ● Gettin │ ● Getting Started... [published]│
│──────────│──────────│   2h ago │─────────────────────────────────│
│ 📄 Post ›│ ● Gettin │ ● Why He │ 📄 Post · 9 fields              │
│ 📑 Page ›│   2h ago │   26h ag │                                 │
│ 👤 Author›│ ● Why He │ ○ Conten │  TITLE                         │
│ 🏷 Categ ›│   26h ag │   50h ag │ ╭───────────────────────────╮  │
│ 💼 Projec›│ ○ Conten │          │ │Getting Started with...    │  │
│──────────│   50h ag │          │ ╰───────────────────────────╯  │
│ ⚙ Settin›│          │          │                                 │
└──────────┴──────────┴──────────┴─────────────────────────────────┘
```

## What is this

- **Headless CMS** — content API for websites, apps, and services
- **Terminal Studio** — manage content from your terminal with a multi-pane UI
- **Developer-first** — edit source code on the server, rebuild instantly, connect from anywhere
- **Draft/publish lifecycle** — drafts, publishing, perspectives, mutations, schemas with visibility

## Architecture

```
Your machine                    Server (Hetzner/any VPS)
┌────────────┐                 ┌──────────────────────────┐
│  Go TUI    │───HTTP/SSE────> │  Phoenix API  :4000      │
│  (client)  │                 │  ├── Public queries       │
└────────────┘                 │  ├── Authenticated CRUD   │
                               │  ├── Media uploads        │
Websites/Apps                  │  ├── SSE real-time         │
┌────────────┐                 │  └── Schema management    │
│  Frontend  │───HTTP GET────> │                            │
└────────────┘                 │  PostgreSQL                │
                               │  └── Documents, Schemas,  │
                               │      Tokens, Media        │
                               └──────────────────────────┘
```

## Quick Start

### Prerequisites

- **Go** 1.22+ — [go.dev/dl](https://go.dev/dl/)
- **Elixir** 1.18+ — `brew install elixir`
- **PostgreSQL** 17 — `brew install postgresql@17`

### Setup

```bash
git clone https://github.com/FRIKKern/barkpark-cms.git
cd barkpark-cms

# Start PostgreSQL
brew services start postgresql@17

# Setup Phoenix API
cd api
mix deps.get
mix ecto.create
mix ecto.migrate
mix run priv/repo/seeds.exs
cd ..

# Run it
make dev    # tmux: Claude Code + TUI + Phoenix
# OR run separately:
make api    # terminal 1: Phoenix on :4000
make tui    # terminal 2: Go TUI
```

## Using the TUI

### Navigation

| Key | Action |
|-----|--------|
| `j` / `k` | Move up/down |
| `h` / `l` | Switch panes / drill in / go back |
| `Enter` | Select / start editing a field |
| `Esc` | Go back / cancel edit |
| `Space` | Toggle boolean / cycle select options |
| `Ctrl+S` | Save changes |
| `Tab` | Next pane |
| `q` | Quit |

### Editing documents

1. Navigate to a document type and select a document
2. Press `Enter` on a field to edit it
3. Type your changes, press `Enter` to confirm
4. Press `Ctrl+S` to save to the API
5. The `* Unsaved` indicator shows when you have pending changes

## API

Base URL: `http://localhost:4000`

### Public (no auth, respects schema visibility)

```bash
# List published posts
curl localhost:4000/v1/data/query/production/post

# With perspective (published, drafts, raw)
curl "localhost:4000/v1/data/query/production/post?perspective=drafts"

# Single document
curl localhost:4000/v1/data/doc/production/post/p1

# Filter
curl "localhost:4000/v1/data/query/production/post?filter=status=published"
```

### Mutations (requires auth)

All writes go through one endpoint with a mutations array:

```bash
TOKEN="barkpark-dev-token"

# Create (always starts as draft)
curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"create":{"_type":"post","_id":"my-post","title":"Hello World"}}]}'

# Edit (patch fields)
curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"patch":{"id":"drafts.my-post","type":"post","set":{"title":"Updated"}}}]}'

# Publish
curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"publish":{"id":"my-post","type":"post"}}]}'

# Unpublish
curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"unpublish":{"id":"my-post","type":"post"}}]}'

# Delete (both draft + published)
curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"delete":{"id":"my-post","type":"post"}}]}'
```

### Schemas (requires admin auth)

```bash
# List all schemas
curl -H "Authorization: Bearer barkpark-dev-token" \
  localhost:4000/v1/schemas/production

# Create a new document type
curl -X POST localhost:4000/v1/schemas/production \
  -H "Authorization: Bearer barkpark-dev-token" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "task",
    "title": "Task",
    "icon": "✅",
    "visibility": "private",
    "fields": [
      {"name": "title", "title": "Title", "type": "string"},
      {"name": "done", "title": "Done", "type": "boolean"},
      {"name": "assignee", "title": "Assignee", "type": "reference", "refType": "author"}
    ]
  }'
```

### Media

```bash
# Upload
curl -X POST localhost:4000/media/upload \
  -H "Authorization: Bearer barkpark-dev-token" \
  -F "file=@photo.jpg"

# List
curl localhost:4000/media

# Serve file
curl localhost:4000/media/files/2026/04/photo-abc123.jpg

# Delete
curl -X DELETE localhost:4000/media/FILE_ID \
  -H "Authorization: Bearer barkpark-dev-token"
```

### Real-time (SSE)

```bash
curl -N -H "Authorization: Bearer barkpark-dev-token" \
  localhost:4000/v1/data/listen/production
```

## Draft/Published Model

| State | doc_id | Visible on public API |
|-------|--------|-----------------------|
| Draft | `drafts.my-post` | No |
| Published | `my-post` | Yes |
| Both | `drafts.my-post` + `my-post` | Published version only |

**Perspectives**: `published` (default), `drafts` (studio view), `raw` (everything)

## Schema Visibility

- **`public`** — queryable without auth (Post, Page, Author, etc.)
- **`private`** — requires auth token (Settings, Navigation, etc.)

## Field Types

| Type | Description | Extra options |
|------|-------------|---------------|
| `string` | Single-line text | |
| `slug` | Auto-generated slug | |
| `text` | Multi-line textarea | `rows` (default 3) |
| `richText` | Block editor | |
| `image` | Image upload | |
| `select` | Dropdown | `options: ["a", "b"]` |
| `boolean` | Toggle switch | |
| `datetime` | Date + time | |
| `color` | Color picker | |
| `reference` | Link to another type | `refType: "author"` |
| `array` | Repeatable list | |

## Deploy to Hetzner

### One-command setup

```bash
ssh root@YOUR_VPS_IP 'bash -s' < deploy.sh
```

Installs Elixir, Go, PostgreSQL natively. Edit source on the server, rebuild instantly.

### Server workflow

```bash
ssh root@YOUR_VPS_IP
cd /opt/barkpark-cms

nano api/lib/sanity_api/content.ex   # edit code
make rebuild                          # rebuild + restart
make status                           # check service
make logs                             # tail logs
```

### Connect TUI to remote server

```bash
BARKPARK_API_URL=http://YOUR_VPS_IP:4000 go run .
```

### Make commands

| Command | Description |
|---------|-------------|
| `make rebuild` | Rebuild + restart service |
| `make restart` | Restart without rebuild |
| `make status` | Service status |
| `make logs` | Tail logs |
| `make seed` | Re-seed database |
| `make migrate` | Run migrations |
| `make reset-db` | Full DB reset |
| `make dev` | Local tmux dev session |

## Project Structure

```
barkpark-cms/
├── main.go              # TUI entry point
├── tui.go               # Bubble Tea model, panes, editor
├── store.go             # API client (HTTP + SSE)
├── schema.go            # Schema types, load from API
├── structure.go         # Auto-generated nav tree
├── styles.go            # Lip Gloss styles
├── api/                 # Phoenix API server
│   ├── lib/sanity_api/
│   │   ├── content.ex       # Document + schema CRUD
│   │   ├── media.ex         # File upload/storage
│   │   └── auth.ex          # Token auth
│   ├── lib/sanity_api_web/
│   │   ├── router.ex        # All routes
│   │   └── controllers/     # Query, Mutate, Schema, Media, Listen
│   ├── priv/repo/
│   │   ├── migrations/      # Database schema
│   │   └── seeds.exs        # Seed data
│   └── Dockerfile
├── docker-compose.yml
├── deploy.sh            # Hetzner VPS setup script
├── dev.sh               # Tmux dev environment
├── Makefile             # Server + dev commands
└── CLAUDE.md            # AI agent documentation
```

## Tech Stack

| Component | Technology |
|-----------|-----------|
| TUI | Go, Bubble Tea, Lip Gloss |
| API | Elixir, Phoenix |
| Database | PostgreSQL (JSONB documents) |
| Real-time | Server-Sent Events |
| Auth | Bearer tokens (SHA256 hashed) |
| Media | Local disk + DB metadata |

## License

MIT
