# Barkpark — Agent Guide

> Everything an AI agent needs to work with this repo without making mistakes.

## What this is

A headless CMS with three interfaces:
- **Go TUI** (root) — terminal Studio client, connects to the API
- **Phoenix API** (`api/`) — Elixir backend, PostgreSQL, all CRUD + real-time
- **Web Studio** (`api/` LiveView) — browser UI at `/studio`, multi-pane like Sanity

## Golden Rules

1. **NEVER compile without cleaning first.** Always `rm -rf api/_build/prod` before `mix compile` on the server. Use `make rebuild`.
2. **NEVER partially clean.** Cleaning just `lib/barkpark` leaves stale HEEx templates. Nuke the entire `_build/prod`.
3. **NEVER skip `systemctl restart`** after compiling. The old BEAM process stays in memory.
4. **NEVER add blocking `<script>` in `<head>`** in root.html.heex. Use `async` at the bottom. (Lucide was 400KB blocking and killed page load.)
5. **NEVER use `force_ssl` without HTTPS.** It causes 301 redirect loops. Currently disabled in prod.exs.
6. **ALWAYS test after deploy.** At minimum: `curl http://localhost:4000/api/schemas`
7. **ALWAYS use `make rebuild` or `make deploy`** on the server. Never raw `mix compile`.

## Production Server

- **IP:** 89.167.28.206
- **Arch:** ARM64 (aarch64) — Hetzner cax11
- **OS:** Ubuntu 22.04
- **App dir:** /opt/barkpark
- **Caddy:** reverse proxy on port 80 → localhost:4000 (Caddyfile at /etc/caddy/Caddyfile)
- **URLs:**
  - http://89.167.28.206/studio (web Studio)
  - http://89.167.28.206/api/documents/post (API)
  - http://89.167.28.206:4000 (direct Phoenix)
- **Erlang/Elixir:** via ASDF (not system packages — no ARM support in Erlang Solutions)
- **Go:** /usr/local/go/bin/go (official ARM64 binary)
- **Env file:** /opt/barkpark/.env (DATABASE_URL, SECRET_KEY_BASE)
- **Service:** systemd `barkpark.service`
- **Start script:** `api/start.sh` (sources ASDF + .env for systemd)
- **Logs:** `journalctl -u barkpark -f`

## Deploy to Server

**Option 1: Auto-deploy (recommended)**
```bash
ssh root@89.167.28.206
cd /opt/barkpark
git pull    # post-merge hook auto-rebuilds and restarts
```

**Option 2: Manual**
```bash
ssh root@89.167.28.206
cd /opt/barkpark
make deploy   # git pull + clean + compile + restart
```

**Option 3: Fresh server**
```bash
ssh root@YOUR_VPS_IP 'bash -s' < deploy.sh
```

## Running Locally

```bash
# Both in tmux
make dev

# Or separately
cd api && mix phx.server    # terminal 1
go run .                     # terminal 2

# Connect TUI to remote server
BARKPARK_API_URL=http://89.167.28.206:4000 go run .
```

## Auth

Dev token: `barkpark-dev-token` (read + write + admin)
Header: `Authorization: Bearer barkpark-dev-token`
Tokens hashed with SHA256 in `api_tokens` table.

## API Quick Reference

```bash
TOKEN="barkpark-dev-token"

# Read (public, no auth)
curl localhost:4000/v1/data/query/production/post
curl localhost:4000/v1/data/query/production/post?perspective=drafts
curl localhost:4000/v1/data/doc/production/post/p1

# Write (requires auth)
curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"mutations":[{"create":{"_type":"post","_id":"x","title":"New"}}]}'

# Publish/unpublish
-d '{"mutations":[{"publish":{"id":"x","type":"post"}}]}'
-d '{"mutations":[{"unpublish":{"id":"x","type":"post"}}]}'

# Schemas (requires admin)
curl -H "Authorization: Bearer $TOKEN" localhost:4000/v1/schemas/production

# Media
curl -X POST localhost:4000/media/upload -H "Authorization: Bearer $TOKEN" -F "file=@photo.jpg"
curl localhost:4000/media
```

## Draft/Published Model

- Create → `drafts.{id}` (always a draft)
- Publish → copies `drafts.{id}` to `{id}`, deletes draft
- Unpublish → moves `{id}` back to `drafts.{id}`
- Perspectives: `published` (default public), `drafts` (studio view), `raw` (everything)

## Document Shape

```json
{
  "_id": "p1",
  "_type": "post",
  "_draft": false,
  "_publishedId": "p1",
  "title": "My Post",
  "status": "published",
  "content": {"category": "Tech", "author": "Knut"},
  "_createdAt": "2026-04-12T09:11:20Z",
  "_updatedAt": "2026-04-12T09:11:20Z"
}
```

## Schema Visibility

- `"public"` — accessible on public API without auth
- `"private"` — returns 404 on public API, requires token

## Field Types

string, slug, text (rows), richText, image, select (options), boolean, datetime, color, reference (refType), array

## Plugin schemas (Schema Definition v2 — TUI constraint)

The Phase 0 plugin foundation introduces four nested field types beyond the v1 primitives above:

- `composite` — object with named subfields
- `arrayOf` — homogeneous array with `ordered: true|false`
- `codelist` — registry-backed enum pinned to an `issue` version (e.g. ONIX issue 73)
- `localizedText` — multi-language string with `languages`, `format`, and `fallbackChain`

**The Go TUI is read-only for plugin schemas in v1** (decision 12 in `.doey/plans/masterplan-20260425-085425.md`). Documents whose schema declares any of the four v2 types render as **JSON dumps** in the TUI; edits go through the LiveView Studio at `/studio`. The TUI editor menus skip composite / array / codelist / localizedText fields entirely — there is no inline form for them.

This is a declared v1 constraint, NOT a missing feature. v2 may add TUI editing for these types once a publisher actually demands it; until then, Studio is the editing surface.

Concrete example: when the OnixEdit plugin lands (Phase 4–5), its `book` schema (~200 fields, deeply nested composites + arrayOf contributors + Thema codelist + localizedText blurbs) will open in the TUI as a JSON view only. Editing happens in Studio.

The legacy seed schemas (post, page, author, category, project, siteSettings, navigation, colors) use only v1 primitives and continue to work in the TUI exactly as before — they go through the validator's permanent `flat_mode` branch with no behavioural change. See `docs/plugins/SCHEMA_V2.md` for the full v2 reference.

## Project Structure

```
barkpark/
├── main.go              # TUI entry, connects to Phoenix
├── tui.go               # Bubble Tea panes + editor
├── store.go             # HTTP + SSE client to Phoenix
├── schema.go            # Load schemas from API
├── structure.go         # Auto-generate nav tree from schemas
├── styles.go            # Lip Gloss styles
├── api/                 # Phoenix API + Web Studio
│   ├── lib/barkpark/
│   │   ├── content.ex           # Document + schema CRUD, publish, perspectives
│   │   ├── content/document.ex  # Ecto document schema
│   │   ├── content/schema_definition.ex
│   │   ├── structure.ex         # Navigation tree builder
│   │   ├── media.ex             # File upload/storage
│   │   └── auth.ex              # Token verification
│   ├── lib/barkpark_web/
│   │   ├── router.ex            # All routes (API + Studio + Media)
│   │   ├── layouts/root.html.heex  # HTML shell, CSS, CDN scripts
│   │   ├── layouts/app.html.heex   # Top bar (permanent)
│   │   ├── live/studio/studio_live.ex  # Multi-pane Studio (main)
│   │   ├── live/studio/media_live.ex   # Media library
│   │   ├── controllers/            # Query, Mutate, Schema, Listen, Media, Legacy
│   │   ├── plugs/require_token.ex  # Auth middleware
│   │   └── components/icons.ex     # Lucide icon mapping
│   ├── config/
│   │   ├── prod.exs        # NO force_ssl (disabled)
│   │   └── runtime.exs     # HTTP scheme by default (PHX_SCHEME env)
│   ├── start.sh            # Systemd wrapper (sources ASDF + .env)
│   ├── priv/repo/seeds.exs # 8 schemas, 27 docs, dev token
│   └── Dockerfile          # For Docker deployment (alternative)
├── .githooks/post-merge    # Auto-rebuild on git pull
├── deploy.sh              # Fresh server setup (ARM + x86)
├── Makefile               # All operations
├── docker-compose.yml     # Docker alternative
└── CLAUDE.md              # This file
```

## Web Studio (LiveView)

- **URL:** `/studio` (single LiveView manages multi-pane layout)
- **JS dependencies loaded via CDN** (no asset pipeline, no Node.js):
  - Phoenix JS: `cdn.jsdelivr.net/npm/phoenix@1.8.5`
  - LiveView JS: `cdn.jsdelivr.net/npm/phoenix_live_view@1.1.28`
  - Lucide icons: `unpkg.com/lucide@0.460.0` (async, bottom of body)
- **MutationObserver** auto-renders Lucide icons on LiveView DOM updates
- **PubSub** updates panes in real-time when documents change

## Database

PostgreSQL with tables: `documents`, `schema_definitions`, `api_tokens`, `media_files`
- Reset: `cd api && MIX_ENV=prod mix ecto.reset`
- Migrate: `cd api && MIX_ENV=prod mix ecto.migrate`
- Seed: `cd api && MIX_ENV=prod mix run priv/repo/seeds.exs`

## Makefile Commands

| Command | What it does |
|---------|-------------|
| `make rebuild` | Nuke _build, compile deps+app, restart service |
| `make deploy` | git pull + rebuild (one command) |
| `make restart` | Restart without rebuild |
| `make status` | systemctl status |
| `make logs` | journalctl -f |
| `make seed` | Re-seed database |
| `make migrate` | Run migrations |
| `make reset-db` | Drop + create + migrate + seed |
| `make dev` | Local tmux dev session |
| `make api` | Local Phoenix only |
| `make tui` | Local Go TUI only |

## Past Mistakes (NEVER REPEAT)

1. **Partial _build clean** — Cleaned `_build/prod/lib/barkpark` only. HEEx templates in Layouts module stayed stale. Old HTML served for hours.
2. **Missing deps.compile --force** — `Plug.Exception` module undefined at runtime. Must force-recompile deps after nuking _build.
3. **Forgot systemctl restart** — Compiled new code but old BEAM process still running in memory.
4. **Wrong start.sh path** — systemd service pointed to `/opt/barkpark/start.sh` but file was at `api/start.sh`. Process died silently.
5. **force_ssl in prod.exs** — Caused 301 redirects to HTTPS when no HTTPS existed. All API calls returned empty.
6. **Erlang Solutions has no ARM packages** — Must use ASDF on Hetzner cax* (ARM) servers.
7. **Blocking script in head** — Lucide (400KB) loaded synchronously in `<head>`, page hung for seconds. Must use `async` at bottom.
8. **LiveView JS not loaded** — `phx-click` events rendered in HTML but nothing worked. LiveView needs its JS client loaded.
9. **Repo was private** — `git clone` failed on server. Made public for deployment.
10. **Go binary committed** — `barkpark` binary accidentally committed. Added to .gitignore.
11. **Phoenix check_origin drift after TLS cutover** — deploy.sh baked `PHX_HOST=<IP>` into .env. After TLS cutover, browser Origin `https://api.barkpark.cloud` did not match the http://<IP> whitelist → `/live/websocket` returned 403 → LiveView silently dropped → Studio became click-dead. Fix: set `PHX_HOST` to the public DNS hostname and `PHX_SCHEME=https`. See `docs/ops/studio-nav-bug-2026-04-19.md` for full diagnosis and `make domain-cutover DOMAIN=…` for the remediation workflow.

## Testing

After any change, verify with:
```bash
curl -s http://89.167.28.206/api/schemas | head -20    # API works
curl -s http://89.167.28.206/studio | grep "pane-layout" # Studio renders
curl -s http://89.167.28.206/v1/data/query/production/post | grep "count" # Documents
```
