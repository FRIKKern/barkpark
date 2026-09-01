<!-- doc-tier: agent | canonical-for: plugin-authoring | budget: 600tok -->
# Plugins

CANONICAL contract = `Barkpark.Plugin` @moduledoc (MUST/MUST-NOT, route buckets, fresh-install, idempotency, .beam gotcha). Read first. Examples: `tasks.ex`, `sheets.ex` (lifecycle_hooks; api/CLAUDE.md §Sheets).

Add a plugin: (1) `api/lib/barkpark/plugins/<name>.ex` with `use Barkpark.Plugin` + `priv/plugins/<name>/plugin.json` — auto-discovered on boot; (2) schemas in `priv/plugins/<name>/schemas/` from `register_schemas/1`, auto-installed each boot by `Bootstrap.register_all_schemas/0` (no `mix run`); (3) routes from `register_routes/1`, `auth:`-bucketed.

Route buckets (`auth:`; FULL set = `plugin_routes/1`'s guard, `router/plugins.ex`): `:admin`/`:ops`, `:public`/`:none`, `:public_root` (readers, `root_layout:`), `:api`/`:token` (`/v1/plugins`), `:token_root`/`:session_token_root` (host `/v1`), `:ticket_key`, `:ingest`, `:public_api` (anon CORS), `:github_webhook`.

## Per-workspace enablement
Optional callbacks (`__using__` defaults): `default_enabled?/0` (`true`), `structure_placement/0` (`:plugins`; `:main | :plugins | :top_menu`), `owned_schema_types/0` (harvested from `register_schemas` → the desk's ownership map). Surfaced per workspace via `workspaces.settings["plugins"]` (`Tenancy.workspace_plugin_settings/1`); `Enablement.effective/1` merges over the defaults. Boot `:plugins` whitelist = installed, not surfaced.

Rules:
- **No deletion in v1** — removing a schema file keeps the `schema_definitions` row (protects documents); removal is manual ops.
- **Late registration is missed** — registry reads once per boot; re-run the bootstrap.

Anti-patterns:
- Don't clone the desk — use schema metadata (`groups`/`actions`/`visibleWhen`/…).
- No hand-mounted routes, plugin CSS, or field renderers — use native v2 components; PubSub vocab is `external_sync:<system>:<doc_id>`.
- Missing capability ⇒ add a bucket/callback/generic in CORE; never route around the host.

## Code anchors
- api/lib/barkpark/plugin.ex — Barkpark.Plugin contract; def default_enabled?, def structure_placement, def owned_schema_types
- api/lib/barkpark/plugins/tasks.ex — register_schemas, register_routes
- api/lib/barkpark/plugins/enablement.ex — def effective
- api/lib/barkpark/plugins/bootstrap.ex — register_all_schemas
- api/lib/barkpark/plugins/registry.ex — all
