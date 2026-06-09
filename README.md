<!-- doc-tier: human | canonical-for: project-overview | budget: 1500tok -->
# Barkpark

**A headless CMS where the command line is a first-class client.** One Sanity-style content model, four ways in: a Phoenix LiveView **Web Studio**, a Go Bubble Tea **Terminal TUI**, a **REST API**, and a single-binary **`bp` CLI** whose entire command tree is assembled live from the server's capabilities.

**Live demo:** http://89.167.28.206/studio

| Surface | What it is |
|---|---|
| **`bp` CLI** | One static binary that **is** your whole API. `bp <noun> <verb>` — built live from `GET /v1/capabilities`. Same binary as the TUI. |
| **Web Studio** | Multi-pane LiveView desk at `/studio` — drill, filter, edit-with-autosave, publish. Real-time across tabs. |
| **Terminal TUI** | The same desk in your terminal, keyboard-driven, over HTTP + SSE. (`barkpark` with no args.) |
| **REST API** | Public reads, token-authed writes, Sanity-compatible mutation envelope, SSE change stream. |

Stack: Elixir 1.15+ / Phoenix LiveView 1.1 / PostgreSQL / Oban · Go 1.24+ (CLI + TUI, one binary) · Caddy. 2300+ mix tests, 89 HTTP integration tests, byte-stable ONIX export round-trip.

## Design philosophy

- **One schema, multiple surfaces.** A single SchemaDefinition drives the Studio panes, the TUI desk, the REST contract, and the CLI command surface.
- **Manifest-driven contract.** The server projects nouns, verbs, and routes into `GET /v1/capabilities`; every client reads the same projection. It is **default-deny and existence-hiding** — keyed on the caller's auth tier, an anonymous caller never learns the names of admin nouns (a golden test enforces it). One `error.code → exit` table; the CLI maps the code, never the HTTP status.
- **The plugin highway.** Plugins are first-party Elixir modules riding the documented `Barkpark.Plugin` behaviour — schemas, routes (on documented buckets: `:ingest` / `:public_root` / `:token` / `:token_root`), workers, cron, resolver chain, lifecycle hooks, CLI verbs. A plugin's verbs travel from Elixir module to manifest to `bp` shell prompt with no client code at any hop. **With all plugins off, Barkpark still works** — the fresh-install invariant is the test of correctness.
- **Built for agents.** `bp capabilities -o json` teaches the whole API in one call; JSON defaults when piped; atomic batch writes via `-f`; `--dry-run` previews; `-q` minimal receipts; stable exit codes.

Reference plugins: **OnixEdit** (ONIX 3.0 book metadata + Bokbasen submission) · **Bulldocs** (portable-doc papers at `/papers/:slug`) · **Tasks** (`/v1/tasks/*` substrate) · **Media** (asset library with metadata-per-asset) · **Frt** (Godot game content model).

## Quickstart

```bash
git clone https://github.com/FRIKKern/barkpark.git
cd barkpark
cd api && mix deps.get && mix ecto.setup && cd ..   # create + migrate + seed
make dev                                            # tmux: Phoenix + TUI side by side
# open http://localhost:4000/studio
make cli-build && dist/bp doc ls post               # build + try the CLI
# or install the released bp:
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp capabilities -o json                             # discover the whole surface
export BARKPARK_API_URL=http://89.167.28.206:4000   # …or point it at the live demo
```

Local DB ops use `mix` directly in `api/` (`mix ecto.setup` / `reset` / `migrate`) — `make seed/migrate/reset-db` are prod-only. Full guide: [`docs/setup/SETUP.md`](docs/setup/SETUP.md).

## v1 scope, honestly

Declared constraints with forward seams, not gaps:

- No MCP server (deferred post-v1); `bp login` and `completion` are stubs; the `scoped_prefix` manifest hint is inert; `--dry-run` is a client-side request preview.
- The TUI handles v1 primitive field types natively; v2 plugin types (`composite`, `arrayOf`, `codelist`, `localizedText`) render as JSON in the TUI — edit those in Studio.
- Plugins cannot be deleted in v1, only disabled.

Deferral ledger: [`docs/decisions/deferred.md`](docs/decisions/deferred.md).

## Deploy

One command on any Ubuntu 22.04+ box (ARM64 or x86_64). `deploy.sh` **requires** `DOMAIN` — the public DNS hostname (it pins Phoenix `check_origin`; baking an IP behind an HTTPS DNS name click-kills the Studio):

```bash
DOMAIN=api.barkpark.cloud ssh root@YOUR_VPS_IP "DOMAIN=$DOMAIN bash -s" < deploy.sh
```

Updates: `ssh` in, `cd /opt/barkpark && git pull` (post-merge hook rebuilds + restarts) or `make deploy`. Ops canon: [`docs/ops/PROD_OPS.md`](docs/ops/PROD_OPS.md).

## Documentation

| Doc | What |
|---|---|
| [`docs/INDEX.md`](docs/INDEX.md) | Catalog of every card, contract, and runbook |
| [`docs/cli/HANDBOOK.md`](docs/cli/HANDBOOK.md) | Full `bp` CLI manual — grammar, flags, auth tiers, batch, exit codes, `bp setup` |
| [`docs/api-v1.md`](docs/api-v1.md) | HTTP API contract |
| [`docs/auth.md`](docs/auth.md) | Tokens, tiers, browser sessions |
| [`docs/cards/plugins.md`](docs/cards/plugins.md) | Build a plugin (contract: `api/lib/barkpark/plugin.ex` moduledoc) |
| [`docs/contracts/schema-v2.md`](docs/contracts/schema-v2.md) | Schema v2 field types |
| [`sdk/README.md`](sdk/README.md) | Bulldocs ingest SDK (TypeScript) — not the general JS SDK; see `js/` |

## License

MIT
