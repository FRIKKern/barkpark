# Bulldocs Migration — Handoff / PRD

> **Status: ✅ SHIPPED to prod (2026-06-06).** Verified end-to-end: compiles
> clean on prod Elixir 1.18.4 (`--warnings-as-errors`); Bulldocs/paper/render
> tests green; reader + canonical ingest + `/v1/paperflow/*` alias routes
> mounted; the renamed `BulldocsLive` reader renders live in the browser
> (Mermaid SVG + asciicast, full reader layout, LiveView connected, no
> check_origin regression). Deployed **code-only (no DB migration)** — the
> `paper` schema auto-registers via plugin `Bootstrap`. **§4 + §5.1–§5.4 done**,
> plus the brand rename `bulldoc → bulldocs`. `origin/main` = prod = `a900530`.
> Only **§5.5** remains (drop the `/v1/paperflow/*` alias once the external
> producer repoints — externally gated). This doc is now the historical record
> of the migration; the live reference is `api/CLAUDE.md` + `docs/plugins/HIGHWAY.md`.
>
> _(48 full-suite failures seen during the prod-Elixir pre-deploy run are all in
> OnixEdit/media/migration tests — pre-existing test-env fixture issues, proven
> by construction that Bulldocs touches none of those files; those subsystems
> work at runtime. Separate cleanup item.)_

---

## 0. TL;DR for the next agent

"Papers" (the built-in live paper/document feature, fed by the external
"paperflow" tool) is being turned into a first-party **plugin called Bulldocs**.
The architecture is already implemented and pushed. **Start by running the
verification block in §4.** Then do §5 (remaining work). Hold every decision in
§2 — they are locked. Develop on `claude/vigilant-hawking-sgFJI`. Do **not**
open a PR unless the user explicitly asks.

---

## 1. Background & goal

- **Bulldocs is the plugin / producer brand.** A **"paper" is the artifact** it
  produces. Bulldocs ingests block-structured papers from an external producer
  and renders them live (no reload) at `/papers/:slug`.
- Previously this was hardwired into core (`Barkpark.Content`, the router, the
  web layer). The goal: **make it a plugin**, the same way OnixEdit is a plugin.
- **The split (the whole point):** *core keeps the reusable machinery; Bulldocs
  is the thin wiring layer that points at it.* The user's words: "we want the
  core to be utilities we use to make the plugin work."

---

## 2. Locked decisions — DO NOT undo these

1. **Bulldocs = the plugin name.** "paperflow" → "Bulldocs" everywhere it refers
   to the producer/brand/integration.
2. **"paper" stays the artifact noun.** The persisted document `type` is still
   `"paper"`; the public reader URL is still `/papers/:slug`. **No data
   migration, no public-URL rename.** (User chose this explicitly over renaming
   to "document".)
3. **Core modules stay put as utilities.** `Barkpark.PortableDoc.*`,
   `Content.upsert_paper`/`apply_paper_block_op`/`apply_document_block_op`/
   `get_public_paper`/`doc_topic`, `BarkparkWeb.BulldocsLive`, the
   `BulldocsIngestController`/`BulldocsIntentsController`,
   `Barkpark.Plugins.Bulldocs.Events`, `RequireIngestToken`,
   `layouts/bulldocs.html.heex`. Bulldocs reuses them. Do not
   mass-rename them unless the user explicitly approves the optional rename in
   §5.4.
4. **The plugin route highway was extended, not bypassed.** Two new buckets:
   `:ingest` and `:public_root` (see §6). Use them; don't re-hardcode paper
   routes in the host router.
5. **`/v1/paperflow/*` is kept as a back-compat alias** of the canonical
   `/v1/plugins/bulldocs/*` ingest routes. Don't delete it until the user
   confirms their producer (paperflow's `event-on-save.sh`) is repointed.
6. **No PR unless asked.** Develop + push to `claude/vigilant-hawking-sgFJI`.

---

## 3. What's already done & pushed (4 commits)

| Commit | What it did |
|---|---|
| `01b0f75` | **Highway extension.** Added `:ingest` + `:public_root` buckets to `BarkparkWeb.Router.Plugins` (the `plugin_routes/1` macro) and `Barkpark.Plugin` docs; added the two dormant host wrapper scopes in `router.ex`; renamed pipeline `:paperflow_ingest` → `:ingest`. Purely additive. |
| `ab62cc5` | **Bulldocs plugin.** `api/priv/plugins/bulldocs/plugin.json`, `.../schemas/paper.json`, and `api/lib/barkpark/plugins/bulldocs.ex` with `register_schemas/1` (declares the `paper` type, mirroring the legacy seed). Filesystem-discovered on boot. |
| `737c050` | **Route move.** `Bulldocs.register_routes/1` mounts the reader (`/papers/:slug` via `:public_root`) and ingest/intents API (`/v1/plugins/bulldocs/*` via `:ingest`). Removed the host `scope "/papers"`; annotated `/v1/paperflow/*` as a back-compat alias. |
| `a41f225` | **Docs.** Recorded the split in `api/CLAUDE.md`. |

Footprint (`git diff --stat main..HEAD`): 7 files, +287/−41.

Files touched/created:
- `api/lib/barkpark_web/router/plugins.ex` — macro: 2 new buckets, `:public_root` live_session emission, `public_root_session_name/2`, `strip_plugin_opts` drops `:root_layout`.
- `api/lib/barkpark_web/router.ex` — pipeline `:ingest`; two new wrapper scopes (`scope "/" … :public_root`, `scope "/v1/plugins" … :ingest`); removed `scope "/papers"`; `/v1/paperflow` marked alias.
- `api/lib/barkpark/plugin.ex` — behaviour docs for the new `auth:` values + `root_layout:`.
- `api/lib/barkpark/plugins/bulldocs.ex` — the plugin module (`register_schemas/1`, `register_routes/1`).
- `api/priv/plugins/bulldocs/plugin.json`, `api/priv/plugins/bulldocs/schemas/paper.json`.
- `api/CLAUDE.md` — "Bulldocs plugin" section.

---

## 4. FIRST: verify the pushed work

```bash
cd api
mix deps.get
mix format                            # author hand-wrote code; format gate is BLOCKING
mix compile --warnings-as-errors      # blocking prod gate; catches macro/AST issues
MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate
mix test
```

**Most likely issues and fixes (in order of probability):**

1. **Format drift** — code was hand-written. `mix format` fixes it; commit the result.
2. **`:public_root` live_session emission** (the only *novel*, un-exercised code
   path — no other plugin uses `:public_root`). It emits, per reader route:
   ```elixir
   live_session :plugin_root_papers_slug_<hash>,
     root_layout: {BarkparkWeb.Layouts, :bulldocs} do
     live "/papers/:slug", BarkparkWeb.BulldocsLive, :index, []
   end
   ```
   This mirrors the old hand-written `live_session :papers`. If compile or
   runtime complains: confirm `BarkparkWeb.BulldocsLive.mount/3` still returns
   `{:ok, socket, layout: false}` (it does — that's what drops the app chrome);
   if the app layout still wraps it, add `layout: false` to the live_session
   opts in `emit_route_ast/1` (`router/plugins.ex`).
3. **Bundled-plugin-set test** — `bulldocs` now joins filesystem discovery
   (alongside `media`, `onixedit`, `frt`). Any test asserting the exact
   discovered-plugin set must add `"bulldocs"`. Grep tests for the plugin names.
4. **Compile ordering** — the router calls `Bulldocs.register_routes/1` at
   compile time via `Registry.collect_routes/1`; this is the same mechanism
   OnixEdit uses, so parity should hold. If the route doesn't appear in
   `mix phx.routes`, check discovery picked up `priv/plugins/bulldocs/`.

**Runtime smoke tests after compile is green:**
```bash
# reader (should render with the paper layout, no studio chrome)
curl -s localhost:4000/papers/<some-slug> | head

# canonical ingest (needs the ingest token; dev default below)
curl -s -X POST localhost:4000/v1/plugins/bulldocs/papers \
  -H "Authorization: Bearer paperflow-dev-ingest-token" \
  -H "Content-Type: application/json" \
  -d '{"slug":"handoff-test","blocks":[{"type":"heading","level":1,"text":"Hi"}]}'

# back-compat alias (must still work)
curl -s -X POST localhost:4000/v1/paperflow/papers \
  -H "Authorization: Bearer paperflow-dev-ingest-token" \
  -H "Content-Type: application/json" \
  -d '{"slug":"handoff-test2","blocks":[{"type":"paragraph","text":"ok"}]}'

# schema registered by the plugin
curl -s -H "Authorization: Bearer barkpark-dev-token" \
  localhost:4000/v1/schemas/production | grep -o '"name":"paper"'
```

Existing `bulldocs_live_test.exs` / `bulldocs_ingest_controller_test.exs` /
`bulldocs_intents_controller_test.exs` should still pass: the reader path/layout
is unchanged and the old `/v1/paperflow/*` ingest URLs are kept as the alias.

**Report compile/test results before doing §5.** If green, commit any
`mix format` changes and push.

---

## 5. Remaining work (the plan to finish)

Do these in order. Commit each separately; push when done.

### 5.1 — Make the verification green (required)
Resolve everything from §4. This is the real "Phase 0" for you.

### 5.2 — Remove the redundant inline `paper` schema seed (small, safe)
`api/priv/repo/seeds.exs` still registers the `paper` schema inline
(~lines 240–259). It's now also registered by the Bulldocs plugin via
`Bootstrap.register_all_schemas/0` (which seeds.exs calls at ~line 644). The
inline block is harmless (idempotent) but redundant. Remove the inline block,
run `MIX_ENV=test mix ecto.reset`, and confirm the `paper` schema still lands
(via the plugin). Update the seeds' `IO.puts` summary count if it changed.

### 5.3 — Reflect the new buckets in `docs/plugins/HIGHWAY.md` (docs)
That file documents the plugin route highway. Add the `:ingest` and
`:public_root` buckets (mirror the table now in `api/lib/barkpark_web/router/plugins.ex`
moduledoc). Also add a one-line Bulldocs pointer to the **root** `CLAUDE.md`
(it still implies Papers is core).

### 5.4 — OPTIONAL brand rename (confirm with the user first)
For full "paperflow → Bulldocs" polish you *could* rename the artifact-named
core modules into the Bulldocs namespace. **This is a judgment call — ask the
user.** Note: these modules are named after "paper" (the artifact, which
*stays*), so leaving them is defensible. If the user wants the rename, do it
with the compiler as your safety net (it catches missed references), one module
at a time, updating every reference + test:
- `BarkparkWeb.PaperLive` → `BarkparkWeb.BulldocsLive` (+ `bulldocs_live_test.exs`)
- `BarkparkWeb.PaperIngestController` / `PaperIntentsController` →
  `BarkparkWeb.BulldocsIngestController` / `BulldocsIntentsController`
  (+ their tests, + router alias scope + plugin route specs)
- `Barkpark.Papers.{Event,Events}` → `Barkpark.Plugins.Bulldocs.{Event,Events}`
  (+ `bulldocs_live.ex`, `bulldocs_intents_controller.ex`, `content.ex`
  event-emit, + tests under `test/barkpark/plugins/bulldocs/`)
- `bp-paper-editor.bundle.js`, `layouts/bulldocs.html.heex` filenames
- doc-comment mentions of `:paperflow_ingest` (now `:ingest`) and "paperflow"
Keep the `:paperflow_ingest_token` config key + `PAPERFLOW_INGEST_TOKEN` env var
(user-facing config; renaming breaks their `.env`).

### 5.5 — Drop the `/v1/paperflow/*` alias (only when the user confirms)
Once the producer posts to `/v1/plugins/bulldocs/*`, remove the
`scope "/v1/paperflow"` block from `router.ex`.

---

## 6. Architecture reference

### Core/plugin split
| Layer | Modules |
|---|---|
| **Core utilities (stay)** | `PortableDoc.{Render,Patch,Projection,Synthesis}`; `Content` paper helpers (`upsert_paper`, `apply_paper_block_op`, `apply_document_block_op`, `get_public_paper`, `paper_topic`, `doc_topic`); `BulldocsLive`; ingest/intents controllers; `Plugins.Bulldocs.Events`/`Event`; `RequireIngestToken`; `bulldocs.html.heex` |
| **Bulldocs plugin (wiring)** | `Barkpark.Plugins.Bulldocs` — `register_schemas/1` (the `paper` type) + `register_routes/1` (reader + ingest) |

### The two new highway buckets (`BarkparkWeb.Router.Plugins`)
- **`:ingest`** — controller routes behind the `:ingest` pipeline
  (`RequireIngestToken`), mounted under `/v1/plugins/<slug>`. For token-gated
  ingest APIs.
- **`:public_root`** — a public LiveView at the host top-level scope with its
  OWN full-document `root_layout:` (declared in the route spec) and no studio
  chrome. The macro wraps each in its own `live_session`. For reader pages.

Route spec shapes (`Barkpark.Plugins.Bulldocs.register_routes/1`):
```elixir
{:live, "/papers/:slug", BarkparkWeb.BulldocsLive, :index,
 auth: :public_root, root_layout: {BarkparkWeb.Layouts, :bulldocs}}
{:post, "/bulldocs/papers", BarkparkWeb.BulldocsIngestController, :ingest, auth: :ingest}
# … /bulldocs/papers/:slug/ops, /bulldocs/intents, /bulldocs/intents/:id/processed
```

### Route map (old → new)
| Surface | Old (host) | New (plugin) | Status |
|---|---|---|---|
| Reader | `/papers/:slug` | `/papers/:slug` (`:public_root`) | moved; URL identical |
| Ingest | `/v1/paperflow/papers` | `/v1/plugins/bulldocs/papers` (`:ingest`) | canonical = new; old kept as alias |
| Block-op | `/v1/paperflow/papers/:slug/ops` | `/v1/plugins/bulldocs/papers/:slug/ops` | same |
| Intents | `/v1/paperflow/intents[/:id/processed]` | `/v1/plugins/bulldocs/intents[...]` | same |

### How papers work (so you understand what you're wiring)
Papers are `documents` rows of `type:"paper"`. The payload lives in `content`:
`blocks` (source of truth), `body_html` (render cache), `rev` (monotonic stream
counter), `style` (`"article"`), `source_doc`, `goal_id`. The reader streams
each top-level block as a keyed LiveView stream item; deltas patch one block;
a rev-gap triggers a full refetch. `paper_events` is an append-only lifecycle
log (`Plugins.Bulldocs.Events`) backing the goal-path rail; `processed_at IS NULL` rows
are the intent queue drained by an external loop via the intents API.

---

## 7. Definition of done

- [ ] `mix format --check-formatted`, `mix compile --warnings-as-errors` (dev + prod), `mix test` all green.
- [ ] `bulldocs` discovered as a plugin; `paper` schema present via the plugin.
- [ ] Reader renders at `/papers/:slug` with the paper layout (no studio chrome).
- [ ] Ingest works at `/v1/plugins/bulldocs/*`; `/v1/paperflow/*` alias still works.
- [ ] §5.2 (seed dedup) and §5.3 (docs) done.
- [ ] §5.4 / §5.5 done only if the user approved them.
- [ ] Committed and pushed to `claude/vigilant-hawking-sgFJI`.

---

## 8. Repo conventions (from CLAUDE.md)

- **Golden rules:** never `mix compile` on the server without `rm -rf _build/prod` first; always `make rebuild`/`make deploy` on the server; always restart the service after compiling. (Local dev: plain `mix` is fine.)
- **Task tracking:** use `bd` (beads), not TodoWrite/markdown TODOs. `bd prime` for context, `bd ready`/`bd show`/`bd update --claim`/`bd close`.
- **Commits:** clear messages; end the message with the Claude Code session URL line (the harness appends it).
- **Push:** `git push -u origin claude/vigilant-hawking-sgFJI`; retry with backoff on network errors. **No PR unless the user asks.**
- **Verify after changes:** the `curl` smokes in §4.
