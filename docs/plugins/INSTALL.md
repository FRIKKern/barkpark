# Plugin schema bootstrap

How plugin-declared schemas land in the `schema_definitions` table.

> Source of truth: `api/lib/barkpark/plugins/bootstrap.ex`. Companion docs:
> [`SCHEMA_V2.md`](SCHEMA_V2.md) for the field-type DSL, [`codelists-byo.md`](codelists-byo.md)
> for codelist seeding.

## Two install paths, one helper

Both paths call the same function:

```elixir
Barkpark.Plugins.Bootstrap.register_all_schemas()
```

| Path | When it runs | Triggered by |
| --- | --- | --- |
| (a) Fresh database | After v1 seed loop in `priv/repo/seeds.exs` | `mix ecto.reset` / `mix run priv/repo/seeds.exs` |
| (b) Every server start | Post-boot Task in `Barkpark.Application.start/2` | `iex -S mix phx.server`, `make rebuild`, `make deploy`, systemd restart |

Path (b) means a fresh deploy of new plugin code installs the new schemas
automatically — no manual step. Path (a) means a fresh-cloned repo running
`mix ecto.reset` ends up with the exact same DB state as a long-running prod
node.

## What `register_all_schemas/0` does

1. Walks `Barkpark.Plugins.Registry.all/0` (populated earlier in the same boot
   Task by `Plugins.Registry.discover_and_register/0`).
2. For each registered plugin, ensures the module is loaded and exports
   `register_schemas/1`. Plugins that don't export the callback are skipped
   silently.
3. Calls `module.register_schemas([])` inside a per-plugin `try/rescue`. A
   raise in one plugin logs `Logger.error` and continues to the next plugin —
   it never crashes the BEAM and never aborts other plugins' installs.
4. Each returned `%Barkpark.Content.SchemaDefinition{}` struct is converted to
   an attrs map (`Map.from_struct |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])`)
   and passed to `Barkpark.Content.upsert_schema/2`.
5. Returns `{:ok, count}` when every upsert succeeded, or
   `{:error, [{plugin_name, reason}, ...]}` when any plugin or upsert failed.
   Successful upserts in the same sweep are still committed.

## Idempotency

The `schema_definitions` table has a composite unique index on
`(name, dataset)` (see migration `20260412090737_create_initial_tables.exs`).
`Content.upsert_schema/2` reads first via `get_schema(name, dataset)`:
existing rows go through `Repo.update`, missing rows through `Repo.insert`.

Calling `register_all_schemas/0` N times in a row produces exactly one row
per `(name, dataset)`. Field values are refreshed from the plugin's current
code on every run — the DB is "pinned to whatever the plugin code currently
declares."

## Adding a new plugin

1. Create `api/priv/plugins/<name>/plugin.json` declaring `plugin_name`,
   `module`, and `capabilities: ["schemas"]`. See
   `api/priv/plugins/onixedit/plugin.json` for the canonical example, and the
   bundled JSON Schema at `api/priv/plugin_manifest_schema.json` for the
   manifest contract.
2. Implement the module. `use Barkpark.Plugin`, then implement
   `register_schemas/1`:

   ```elixir
   defmodule Barkpark.Plugins.MyPlugin do
     use Barkpark.Plugin, manifest: "priv/plugins/myplugin/plugin.json"

     alias Barkpark.Content.SchemaDefinition

     @impl Barkpark.Plugin
     def register_schemas(_opts) do
       [
         %SchemaDefinition{
           name: "widget",
           title: "Widget",
           visibility: "private",
           fields: [%{"name" => "label", "type" => "string"}],
           dataset: "production"
         }
       ]
     end
   end
   ```

   Return `[]` (the default) if your plugin owns no schemas.

3. Restart the server (or run `mix ecto.reset`). `Barkpark.Plugins.Bootstrap`
   picks up the new manifest on the next boot Task and installs the schemas.

That's it — no separate registration step, no mix task to remember.

## Verifying after a deploy or reset

```bash
cd api
MIX_ENV=dev mix ecto.reset            # drops, migrates, seeds — fires path (a)
mix phx.server &                      # boot the app — fires path (b)
sleep 2
curl -s -H "Authorization: Bearer barkpark-dev-token" \
  http://localhost:4000/v1/schemas/production | jq '.[] | .name'
```

You should see every v1 seed schema (`post`, `page`, `author`, …) plus every
plugin schema (`book` from OnixEdit, plus whatever new plugins declared).
Path (a) and path (b) overlap on a typical local run — both succeed; the
second is a no-op upsert on identical fields.

## Behavioural notes

- **No deletion in v1.** If a plugin disappears from disk (or stops exporting
  a schema name), the previously-installed row stays in `schema_definitions`
  to preserve any documents tied to it. Removing a schema is a manual ops
  decision, not an automatic side effect.
- **Late registration is missed.** Bootstrap iterates the registry once per
  boot. If application code calls `Plugins.Registry.register/2` after boot
  (rare), invoke `Bootstrap.register_all_schemas/0` from a remote console to
  install that plugin's schemas.
- **Visibility.** Plugin schemas typically use `visibility: "private"`,
  which puts them behind admin-token auth on `GET /v1/schemas/production`.
  Both `"public"` and `"private"` round-trip through the changeset.
- **Bokbasen.** Despite the name, `Barkpark.Plugins.OnixEdit.Bokbasen.*`
  is a sub-namespace of the OnixEdit plugin — it implements the publish
  pipeline (OAuth, HTTP client, Oban worker, status persistence) and ships
  no schemas of its own. Wiring OnixEdit transitively covers it.

## History note

Before Task 5, OnixEdit's `book` schema was installed by an out-of-band
`mix run -e "Barkpark.Plugins.OnixEdit.register_schemas(...)"` command run
manually on the server. New deploys without that command produced an empty
`/v1/schemas/production` for the plugin. That workaround is obsolete — the
post-boot Task and seeds path now cover both fresh deploys and fresh
databases. Do not reintroduce manual `mix run -e` invocations for schema
install.
