<!-- doc-tier: agent | canonical-for: repo-router | budget: 2500tok -->
# Barkpark — Router

## Identity

Headless CMS, one content model, many surfaces: **Go TUI + `bp` CLI** (repo root + `internal/cli/` — one binary, manifest-driven from `GET /v1/capabilities`), **Phoenix API + LiveView Studio** (`api/`), **JS SDK monorepo** (`js/`), **Next.js web demo** (`web/`). Plugins ride the `Barkpark.Plugin` behaviour (OnixEdit, Bulldocs, Tasks, Media, Frt) — with all plugins off, Barkpark still works. Prod runs on Hetzner ARM64.

## Golden Rules

1. **NEVER compile without cleaning first.** Always `rm -rf api/_build/prod` before `mix compile` on the server. Use `make rebuild`.
2. **NEVER partially clean.** Cleaning just `lib/barkpark` leaves stale HEEx templates. Nuke the entire `_build/prod`.
3. **NEVER skip `systemctl restart`** after compiling. The old BEAM process stays in memory.
4. **NEVER add blocking `<script>` in `<head>`** in root.html.heex. Use `async` at the bottom. (Lucide was 400KB blocking and killed page load.)
5. **NEVER use `force_ssl` without HTTPS.** It causes 301 redirect loops. Currently disabled in prod.exs.
6. **ALWAYS test after deploy.** At minimum: `curl http://localhost:4000/api/schemas`
7. **ALWAYS use `make rebuild` or `make deploy`** on the server. Never raw `mix compile`.

## Routing table

Load exactly ONE card, read it fully, follow its Code anchors. Do not load a second card unless routed there. Never load `_attic/`.

| Group | Task pattern | Load |
|---|---|---|
| Ops | deploy / migration / prod / rollback server | `docs/ops/PROD_OPS.md` |
| Ops | npm release / npm rollback | `docs/ops/npm-rollback-playbook.md` |
| Ops | domain / TLS / DNS | `docs/ops/adding-a-domain.md` |
| Ops | CI / merge gates | `docs/ops/merge-gates.md` |
| API/SDK | HTTP API contract | `docs/api-v1.md` |
| API/SDK | auth / tokens | `docs/auth.md` |
| API/SDK | tenancy / workspace / project / dataset scoping | `docs/contracts/tenancy.md` |
| API/SDK | webhooks / cache revalidation | `docs/contracts/webhook-realtime.md` |
| API/SDK | consume from JS / Next.js | `docs/cards/js-sdk.md` |
| Plugins/ONIX | build or modify a plugin | `docs/cards/plugins.md` |
| Plugins/ONIX | schema v2 field types | `docs/contracts/schema-v2.md` |
| Plugins/ONIX | Bokbasen / ONIX export | `docs/cards/onix-bokbasen.md` |
| Plugins/ONIX | Papers / Bulldocs / PortableDoc / pdrender ingest | `api/CLAUDE.md` §Bulldocs |
| Tasks | task system / task board / claim queue / bp task | `docs/setup/TASK-SYSTEM.md` |
| CLI/TUI | bp CLI | `docs/cards/cli.md` |
| CLI/TUI | Go TUI / pdrender | `docs/cards/tui.md` |
| Studio | LiveView Studio UI | `docs/cards/studio.md` |
| Search | search / media / analytics | `docs/cards/search-media.md` |
| Meta | "is X deferred?" / anything else | `docs/decisions/deferred.md` / `docs/INDEX.md` |

## Prod micro-block

`89.167.28.206` · `/opt/barkpark` · systemd `barkpark.service` · `make deploy` — canonical: `docs/ops/PROD_OPS.md`.

## Quick commands

`make dev` (local tmux: Phoenix + TUI) · `make deploy` (server: pull + clean + compile + restart) · `make rebuild` (nuke `_build/prod` + recompile + restart) · `make logs`. Local setup: `docs/setup/SETUP.md`.

Smoke test after any deploy:

```bash
curl -s http://89.167.28.206/api/schemas | head -20    # API works
curl -sL http://89.167.28.206/studio | grep "pane-layout" # Studio renders (302s to the scoped URL)
curl -s http://89.167.28.206/v1/data/query/production/post | grep "count" # Documents
```

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

## Task layer + session completion

**Tasks are `type:task` documents in Barkpark's own Postgres**, driven through the `bp task` CLI (over `/v1/tasks`). Beads (`bd`/`.beads/`) is RETIRED (removed 2026-06-22) — do not reinstate it. Use `bp task` for ALL task tracking — do NOT use TodoWrite or markdown TODO lists. Full guide: `docs/setup/TASK-SYSTEM.md`.

```bash
bp task ready            # Find available work
bp task show <id>        # View task details (carries children + child_count)
bp task next <worker>    # Atomically claim the next ready task
bp task close <id> <worker> <epoch>   # Complete work (CAS on the claim epoch)
```

**When ending a work session, work is NOT complete until `git push` succeeds:**

1. File tasks for remaining work
2. Run quality gates if code changed (tests, linters, builds)
3. Close finished tasks, update in-progress ones
4. **PUSH TO REMOTE** — mandatory: `git pull --rebase && git push && git status` (must show "up to date with origin")
5. Clean up stashes, prune remote branches
6. Hand off context for the next session

NEVER stop before pushing — that strands work locally. NEVER say "ready to push when you are" — YOU push. If push fails, resolve and retry until it succeeds.

## Doc contract

Three tiers: `agent` (router/cards/contracts — loaded via the routing table), `human` (READMEs), `cold` (`_attic/` — never load). First line of every active doc: `<!-- doc-tier: agent|human|cold | canonical-for: <topic> | budget: <N>tok -->`; `canonical-for` is unique repo-wide — one owner per fact-topic. A new durable fact goes into its existing owner; **creating a new card requires retiring or merging one** (hard cap: 7 cards). Touched a file a card anchors? Update the card or `scripts/docs-anchors-check.sh` fails. Byte budgets are CI-enforced (`scripts/check-doc-budgets.sh`) — on overflow, split to the owning contract/runbook or retire content; never raise the cap. Golden Rules and Past Mistakes above are verbatim-exempt: any edit requires explicit owner sign-off.
