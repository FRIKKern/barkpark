<!-- doc-tier: agent | canonical-for: plugin-authoring | budget: 600tok -->
# Plugins

CANONICAL contract = `Barkpark.Plugin` @moduledoc (MUST/MUST-NOT, buckets, fresh-install invariant, idempotency, .beam gotcha). Read it first. Living examples: `tasks.ex`; `sheets.ex` (lifecycle_hooks gate; see api/CLAUDE.md §Sheets).

Add a plugin: (1) `api/lib/barkpark/plugins/<name>.ex` with `use Barkpark.Plugin`; create `priv/plugins/<name>/plugin.json` (`plugin_name`, `module`, `version`, `capabilities`) — auto-discovered on boot, no `registry.ex` edit needed; (2) schema JSON in `priv/plugins/<name>/schemas/` from `register_schemas/1` — auto-installed each boot by `Bootstrap.register_all_schemas/0`; NEVER reintroduce the manual `mix run` workaround on the server; (3) routes from `register_routes/1`, bucket-tagged:

| Bucket | Pipeline | Use |
|---|---|---|
| :admin / :ops | browser + on_mount auth | admin/ops consoles |
| :public | browser, no auth | in-studio public LV |
| :public_root | browser, own root_layout | public readers (`/papers/:slug`, `/sheets/:slug`) |
| :api / :token | `/v1/plugins`, admin / bearer | controller APIs |
| :token_root | host `/v1`, bearer | root token API (`/v1/tasks`) |
| :ingest | RequireIngestToken (shared secret) | ingest APIs (`/v1/plugins/<name>/*`) |

Rules:
- **No deletion in v1** — removing a schema file keeps the `schema_definitions` row (protects documents); removal is manual ops.
- **Late registration is missed** — registry reads once per boot; re-run `Bootstrap.register_all_schemas/0` from a console.

Anti-patterns:
- Don't clone the desk — use schema metadata (`groups`/`actions`/`visibleWhen`/`desk_groups`/`cross_validations`).
- No hand-mounted routes, plugin CSS, or plugin field renderers — use native v2 components.
- No plugin-private PubSub vocab — `external_sync:<system>:<doc_id>`.
- Missing capability ⇒ add a bucket/callback/generic in CORE; never route around the host.
- Schema bugs hide behind UI bugs — check schema + sub-schema splice first.

## Code anchors
- api/lib/barkpark/plugin.ex — Barkpark.Plugin (moduledoc = contract)
- api/lib/barkpark/plugins/tasks.ex — register_schemas, register_routes
- api/lib/barkpark/plugins/sheets.ex — lifecycle_hooks, register_routes
- api/lib/barkpark/plugins/bootstrap.ex — register_all_schemas
- api/lib/barkpark/plugins/registry.ex — all
