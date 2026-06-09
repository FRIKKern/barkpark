<!-- doc-tier: agent | canonical-for: plugin-authoring | budget: 600tok -->
# Plugins

CANONICAL contract = the `Barkpark.Plugin` @moduledoc (MUST/MUST-NOT, route buckets, fresh-install invariant, register_schemas idempotency, .beam compile-cache gotcha). Read it first. Living example: `tasks.ex`.

Add a plugin: (1) module under `api/lib/barkpark/plugins/<name>.ex` with `use Barkpark.Plugin`, listed in `registry.ex`; (2) schema JSON in `api/priv/plugins/<name>/schemas/`, returned from `register_schemas/1` — auto-installs every boot via `Bootstrap.register_all_schemas/0`; NEVER reintroduce manual `mix run -e "...register_schemas..."` on the server; (3) routes from `register_routes/1`, tagged with a bucket:

| Bucket | Pipeline | Use |
|---|---|---|
| :admin / :ops | browser + on_mount auth | admin / operator consoles |
| :public | browser, no auth | in-studio public LV |
| :public_root | browser, own root_layout | public reader (`/papers/:slug`) |
| :api / :token | `/v1/plugins`, admin / bearer | controller APIs |
| :token_root | host `/v1`, bearer | root token API (`/v1/tasks`) |
| :ingest | RequireIngestToken (shared secret) | ingest API |

Rules:
- **No deletion in v1** — a schema that vanishes from disk keeps its `schema_definitions` row (protects documents); removal is manual ops.
- **Late registration is missed** — registry is read once per boot; call `Bootstrap.register_all_schemas/0` from a remote console.

Anti-patterns (retro: `_attic` ex-INTEGRATION_LESSONS):
- Don't clone the editor desk — extend it via schema metadata (`groups`, `actions`, `visibleWhen`, `desk_groups`, `cross_validations`).
- No hand-mounted routes, plugin CSS files, or plugin field renderers (extend native v2 components for ALL plugins).
- No plugin-private PubSub vocab — use `external_sync:<system>:<doc_id>`.
- Missing capability ⇒ add a bucket/callback/generic in CORE; never route around the host.
- Schema bugs hide behind UI bugs — check schema + sub-schema splice before the renderer.

## Code anchors
- api/lib/barkpark/plugin.ex — defmodule Barkpark.Plugin (moduledoc = contract)
- api/lib/barkpark/plugins/tasks.ex — def register_schemas, def register_routes
- api/lib/barkpark/plugins/bootstrap.ex — def register_all_schemas
- api/lib/barkpark/plugins/registry.ex — def all
