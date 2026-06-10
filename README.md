<!-- doc-tier: human | canonical-for: project-overview | budget: 1500tok -->
# Barkpark

**The workspace your AI works in.** Barkpark is a headless CMS built for AI agents: a place where an AI stores, sorts, and structures content — **tasks, papers, media** — while you edit the same documents in a browser Studio. The agent drives the API; you drive the panes; both see every change in real time.

**Live demo:** https://api.barkpark.cloud/studio

## Your AI's task board

Task management is the headline use case. Tasks are plain documents with a lifecycle (`open → in_progress → done`, plus `blocked`/`cancelled`), a dependency graph, priorities, labels, and an atomic claim/close contract built for concurrent workers (fencing epochs, 300s lease sweeps):

```bash
bp task ready                # what's unblocked, priority-ordered
bp task next agent-1         # atomically claim the next ready task
bp task close t1 agent-1 1   # CAS on the claim epoch
bp task ls --limit 20        # everything, goals included
```

Open `/studio` and the same queue is the **Tasks ✅** pane: you flip lifecycle states and set priority/assignee while the agent claims and closes over HTTP (claims and dependencies render read-only — the API owns them). A root task is a goal; subtasks nest under it via `parent_id`. Guide: [`docs/setup/TASK-SYSTEM.md`](docs/setup/TASK-SYSTEM.md) · cheatsheet: [`docs/cheatsheets/tasks.md`](docs/cheatsheets/tasks.md).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp setup        # wizard: local dev · deploy a server · connect — tasks + papers pre-checked
bp task ready   # you're in
```

The wizard covers every route: local stack (native or Docker), SSH deploy to any Ubuntu 22.04+ box (ARM64 or x86_64), or connect to a running server. Walkthrough: [`docs/setup/QUICKSTART.md`](docs/setup/QUICKSTART.md). Hacking on Barkpark itself: [`docs/setup/SETUP.md`](docs/setup/SETUP.md).

## Play around without stacking up mess

One call spins up a **workspace** — it arrives with you as owner, a Default project, and a production dataset. Experiments live in their own workspace with their own schemas, tasks, papers, and media; when the spike is done, nothing leaks back into your real work:

```bash
bp workspace create Spike
bp -w spike workspace project-create agents-v2
```

## Four ways in

| Surface | What it is |
|---|---|
| **`bp` CLI** | One static binary that speaks the whole API — `bp <noun> <verb>`, assembled live from `GET /v1/capabilities`. Same binary as the TUI. |
| **Web Studio** | Multi-pane LiveView desk at `/studio` — drill, filter, edit-with-autosave, publish. Real-time across tabs. |
| **Terminal TUI** | The same desk in your terminal, keyboard-driven (`barkpark` with no args). |
| **REST API** | Public reads, token-authed writes, Sanity-compatible mutation envelope, SSE change stream. |

Stack: Elixir 1.15+ / Phoenix LiveView 1.1 / PostgreSQL / Oban · Go 1.24+ (CLI + TUI, one binary) · Caddy. 2400+ mix tests, 89 HTTP integration tests.

## Design philosophy

- **Built for agents.** `bp capabilities -o json` teaches the whole API in one call; JSON defaults when piped; atomic batch writes via `-f`; `--dry-run` previews; `-q` minimal receipts; stable exit codes.
- **One schema, multiple surfaces.** A single SchemaDefinition drives the Studio panes, the TUI desk, the REST contract, and the CLI command surface.
- **Manifest-driven contract.** The server projects nouns, verbs, and routes into `GET /v1/capabilities`; every client reads the same projection. Default-deny and existence-hiding, keyed on the caller's auth tier.
- **The plugin highway.** Plugins are first-party Elixir modules riding the documented `Barkpark.Plugin` behaviour — schemas, routes, workers, cron, resolvers, desk items, CLI verbs travel from Elixir module to manifest to `bp` shell with no client code at any hop. **With all plugins off, Barkpark still works** — the fresh-install invariant is the test of correctness.

Bundled plugins: **Tasks** (the `/v1/tasks/*` board above) · **Bulldocs** (portable-doc papers at `/papers/:slug`) · **Media** (asset library) · **OnixEdit** (ONIX 3.0 book metadata + Bokbasen submission) · **Frt** (Godot game content).

## v1 scope, honestly

No MCP server yet (deferred); `bp login`/`completion` are stubs; `scoped_prefix` has no effect yet; `--dry-run` is a client-side preview. The TUI edits v1 primitive fields natively — v2 plugin types render as JSON there (edit in Studio). Plugins disable, never delete. Ledger: [`docs/decisions/deferred.md`](docs/decisions/deferred.md).

## Deploy

One command on any Ubuntu 22.04+ box. `deploy.sh` **requires** `DOMAIN` — the public DNS hostname, never an IP (it pins Phoenix `check_origin`):

```bash
DOMAIN=api.barkpark.cloud ssh root@YOUR_VPS_IP "DOMAIN=$DOMAIN bash -s" < deploy.sh
```

Or let the wizard drive it: `bp setup --target deploy`. Updates: `ssh` in, `cd /opt/barkpark && git pull` (post-merge hook rebuilds + restarts). Ops canon: [`docs/ops/PROD_OPS.md`](docs/ops/PROD_OPS.md).

## Documentation

| Doc | What |
|---|---|
| [`docs/INDEX.md`](docs/INDEX.md) | Catalog of every card, contract, and runbook |
| [`docs/setup/TASK-SYSTEM.md`](docs/setup/TASK-SYSTEM.md) | The task system — agent loop, Studio collaboration, goals |
| [`docs/cli/HANDBOOK.md`](docs/cli/HANDBOOK.md) | Full `bp` CLI manual |
| [`docs/cheatsheets/`](docs/cheatsheets/) | One-pagers: `bp`, tasks, HTTP API, papers |
| [`docs/api-v1.md`](docs/api-v1.md) · [`docs/auth.md`](docs/auth.md) | HTTP contract · tokens and tiers |
| [`docs/cards/plugins.md`](docs/cards/plugins.md) | Build a plugin (contract: `api/lib/barkpark/plugin.ex` moduledoc) |

## License

MIT
