<!-- doc-tier: agent | canonical-for: repo-router | budget: 2500tok -->
# Barkpark — Router

## Identity

Headless CMS, one content model, many surfaces: **Go TUI + `bp` CLI** (repo root + `internal/cli/` — one binary, manifest-driven from `GET /v1/capabilities`), **Phoenix API + LiveView Studio** (`api/`), **JS SDK monorepo** (`js/`), **Next.js web demo** (`web/`). Plugins ride the `Barkpark.Plugin` behaviour — 12 today (Bulldocs, Frt, Github, Grip, Media, OnixEdit, Pulse, Quiz, Scaffy, Sheets, Tasks, Tickets); with all plugins off, Barkpark still works. That roster is DERIVED, not curated — one `use Barkpark.Plugin` per file in `api/lib/barkpark/plugins/*.ex`, diffed against this line by `scripts/roster-drift-check.sh`. Prod runs on Hetzner ARM64.

## Golden Rules

1. **NEVER build by hand on prod.** `make rebuild` runs `scripts/deploy-rebuild.sh`: builds ASIDE in `api/_build_next`, migrates, swaps. Never `rm -rf api/_build/prod` (LIVE).
2. **NEVER partially clean.** Subtree cleans leave stale HEEx; the engine nukes the whole aside root.
3. **NEVER skip `systemctl restart`** after compiling. The old BEAM process stays in memory.
4. **NEVER add blocking `<script>` in `<head>`** in root.html.heex. Use `async` at the bottom. (Lucide was 400KB blocking and killed page load.)
5. **NEVER use `force_ssl` without HTTPS.** It causes 301 redirect loops. Currently disabled in prod.exs.
6. **ALWAYS test after deploy.** At minimum: `curl http://localhost:4000/api/schemas`
7. **`git pull` IS the deploy** (single-box): `.githooks/post-merge` runs `scripts/deploy-rebuild.sh`; `.slots` hosts: use `deploy/instance-deploy.sh`. Never raw `mix compile`.
8. **The main checkout stays on `main` — ALWAYS. No branch jumps, period.** Never `git switch` / `git checkout <branch>` / `-b` / detached HEAD here — not even "briefly, then back." Code reaches this checkout one way only: merge to origin/main, then pull (`make update`). Need another branch? That IS the worktree signal: `git worktree add <dir> <branch>` (agents use EnterWorktree); remove it when the branch merges. Many concurrent sessions share this checkout — any switch strands or clobbers their work (uncommitted edits are silently lost on switch).

## Routing table

Load exactly ONE card, read it fully, follow its Code anchors. Do not load a second card unless routed there.

| Group | Task pattern | Load |
|---|---|---|
| Ops | deploy / migration / prod / rollback server | `docs/ops/PROD_OPS.md` |
| Ops | continuous deployment / auto-deploy on merge / cloud hosts | `deploy/README.md` |
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
| CLI/TUI | bp CLI / scaffy catalog chore | `docs/cards/cli.md` |
| CLI/TUI | Go TUI / pdrender | `docs/cards/tui.md` |
| Studio | LiveView Studio UI | `docs/cards/studio.md` |
| Search | search / media / analytics | `docs/cards/search-media.md` |
| Meta | "is X deferred?" / anything else | `docs/decisions/deferred.md` / `docs/INDEX.md` |

## Prod micro-block

`89.167.28.206` · `/opt/barkpark` · systemd `barkpark.service` · deploy = `git pull` ON THE BOX (post-merge hook rebuilds) — canonical: `docs/ops/PROD_OPS.md`. **Not a `deploy.yml` target** (its only SSH hosts are `CP_HOST`/`GUERRILLA_HOST`), so a merge is not live until pulled.

## Quick commands

`make update` (**local**: pull + diff-driven refresh of bp/deps/migrations + digest — use instead of bare `git pull`) · `make doctor` (**local**: read-only staleness report — behind? bp stale? migrations pending?) · `make dev` (local tmux: Phoenix + TUI) · `make deploy` (server: `git pull` — the `.githooks/post-merge` hook does the clean rebuild + restart) · `make rebuild` (nuke `_build/prod` + recompile + restart) · `make logs`. Local setup: `docs/setup/SETUP.md`.

Smoke test. A 200 proves the box ANSWERS, never that your merge shipped — ask which commit:

```bash
curl -s http://89.167.28.206/status.json | jq -r .commit  # what the box RUNS
curl -s https://barkpark.cloud/health | jq -r .git_sha    # deploy.yml's check: IDENTITY, not liveness
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

**Tasks are `type:task` documents in Barkpark's own Postgres**, driven through the `bp task` CLI (over `/v1/tasks`). Use `bp task` for ALL task tracking — do NOT use TodoWrite or markdown TODO lists. Full guide: `docs/setup/TASK-SYSTEM.md`.

`bp task ready` · `show <id>` (carries children) · `next <worker>` (atomic claim) · `close <id> <worker> <epoch>` (CAS on the claim epoch). Flags and criteria writes: the guide above.

**When ending a work session, work is NOT complete until `git push` succeeds:**

1. File tasks for remaining work
2. Run quality gates if code changed (tests, linters, builds)
3. Close finished tasks, update in-progress ones — log closes to the open session (`bp session log`; never blocks)
4. **PUSH TO REMOTE**, by ref: on a branch, `git pull --rebase && git push`, open a PR; on `main`, move commits to a branch, push that; `bp session log <slug> --kind push --ref <sha>`
5. Clean up stashes, prune remote branches
6. Hand off context for the next session

NEVER stop before pushing — it strands work locally. NEVER say "ready to push when you are" — YOU push. A push protection refusal (GH006) is CORRECT, not a retry cue.

## Doc contract

Three tiers: `agent` (router/cards/contracts — loaded via the routing table), `human` (READMEs), `cold` (retired docs — never load; commands need a dated `HISTORICAL RECORD` banner). First line of every active doc: `<!-- doc-tier: agent|human|cold | canonical-for: <topic> | budget: <N>tok -->`; `canonical-for` is unique repo-wide — one owner per topic. A new durable fact goes into its owner; **creating a new card requires retiring or merging one** (hard cap: 7 cards). Touched a file a card anchors? Update the card or `scripts/docs-anchors-check.sh` reds. It and the byte budgets (`scripts/check-doc-budgets.sh`) run in CI as one job, `Doc budgets + anchors`, which is ADVISORY: it reds its own check run on every PR touching matching paths, and CANNOT block a merge — that context is an explicit S4 exclusion in `.github/required-checks.json`, whose required set is only `Cloud gate`/`Console gate`/`Elixir gate`/`PR references an active task`. On overflow, split or retire content; never raise the cap — policy held by review, not by the merge button (`docs/ops/merge-gates.md`). Golden Rules and Past Mistakes above are verbatim-exempt: any edit requires explicit owner sign-off.

**Canonical-impl markers (code-side `canonical-for`).** `@canonical capability:<slug> [aka:…] [doc:…]` above a capability's public entry point; `grep -rn '@canonical capability:'` IS the index. Demand-driven, not universal. Full contract — syntax, when to stamp, what §8/§8b enforce: `docs/contracts/canonical-impl-markers.md`.
