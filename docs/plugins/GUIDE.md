# Building a Barkpark Plugin

> The front door. Read this first; the rest of `docs/plugins/` are the
> reference manuals behind it.

Barkpark is a headless CMS — a Phoenix/Elixir API, a LiveView Studio, and a Go
TUI client, all over one PostgreSQL store. A plugin extends that host with new
**data and behaviour**: a document type, a publish action, an external-sync
status pill, a background worker, a data endpoint. This guide takes you from
`mix barkpark.plugin.new` to a deployed plugin and tells you exactly which of
the host's ~25 callbacks to reach for, and which surfaces are off-limits.

Everything below is grounded in `api/lib/barkpark/plugin.ex` (the behaviour),
`api/lib/barkpark/plugins/registry.ex` (the discovery + resolver engine), and
`api/lib/barkpark/plugins/onixedit.ex` (the richest reference plugin — alongside
the `bulldocs`, `tasks`, `frt`, and `media` plugins now shipping in-tree). Where this guide
is brief, it links to the deep reference. Where it disagrees with an older doc,
trust this one — it was reconciled against source.

---

## 1. What a plugin is (and isn't)

A plugin is a directory of trusted, first-party Elixir code under
`api/priv/plugins/<slug>/` plus a namespaced module tree under
`api/lib/barkpark/plugins/<slug>/`. It contributes **data** (schemas,
codelists, settings fields) and **behaviour** (action handlers, lifecycle
hooks, workers, routes) through the `Barkpark.Plugin` behaviour. The host walks
those contributions and folds them into its own UI.

**The host owns the UI.** A plugin does not ship its own editor, its own field
renderers, its own Structure sidebar, its own modals. It declares a schema and
the host renders the editor. It declares a `top_menu_entries/0` map and the
host draws the tab. It calls `ExternalSync.broadcast/4` and the host's pill
flips colour. When you are tempted to ship a LiveView that edits a document,
stop — that is host territory (see §7 and INTEGRATION_LESSONS.md).

```
   plugin contributes                    host renders
   ──────────────────                    ────────────
   register_schemas/1        ───────▶    Studio editor pane, field forms
   action_handlers/0         ───────▶    editor-header action buttons
   external_sync_entries/0   ───────▶    document status pill
   top_menu_entries/0        ───────▶    Studio top-bar tab
   desk_items/1              ───────▶    Structure-pane rows
   content_renderer/3        ───────▶    preview pane <pre>
```

### The fresh-install invariant

This is the contract that makes the host plugin-agnostic. With

```elixir
config :barkpark, :plugins, []
```

Barkpark must boot fully: Studio loads, the public API serves exactly the eight
seed schemas (`post`, `page`, `author`, `category`, `project`, `siteSettings`,
`navigation`, `colors`), and **no host code under `lib/barkpark/` or
`lib/barkpark_web/` names any plugin module**. Confirmed in
`Registry.discover_and_register/0`: an explicit empty `:plugins` list is the
kill switch — it short-circuits and registers nothing. Confirmed again in
`collect_routes/1` and `collect_workers/1`, which both return `[]` for an
explicit `[]`, so the router compiles plugin-free and the supervision tree
starts plugin-free.

The regression bar is `api/test/barkpark/plugin_free_boot_test.exs` (tagged
`:boot_test`). If you add a callback or a shared primitive and the host can no
longer boot empty, re-scope. The host is never allowed to write
`if plugin == :onixedit do …`.

---

## 2. Quickstart (5 minutes)

Scaffold a manifest-based plugin with the generator:

```bash
cd api
mix barkpark.plugin.new my_plugin --capabilities schemas,settings
```

> **Use `barkpark.plugin.new`, not `barkpark.gen.plugin`.** The latter is
> DEPRECATED — it once emitted a host-side module that never registered, and
> now just prints a notice and delegates to `plugin.new`. Don't call it.

`--capabilities` accepts full names or single-letter shortcuts
(`r`→routes, `w`→workers, `s`→schemas, `n`→node, `c`→codelists, `t`→settings).
The generator emits the working, OnixEdit-shaped layout — manifest, README, and
schemas under `priv/`, the entry module in the **compiled** `lib/` tree, and the
test on the `mix test` path:

```
priv/plugins/my_plugin/
├── plugin.json          # validated manifest (carries the "module" key)
├── schemas/
│   └── .gitkeep
└── README.md
lib/barkpark/plugins/my_plugin.ex          # entry module — compiled tree
test/barkpark/plugins/my_plugin_test.exs   # on the mix test path
```

The generated `plugin.json` carries an explicit `module` key so discovery
resolves it:

```json
{
  "plugin_name": "my_plugin",
  "version": "0.1.0",
  "description": "A Barkpark plugin named my_plugin.",
  "capabilities": ["schemas", "settings"],
  "module": "Barkpark.Plugins.MyPlugin"
}
```

The generated entry module lives in the compiled tree and points back at the
manifest:

```elixir
defmodule Barkpark.Plugins.MyPlugin do
  use Barkpark.Plugin,
    manifest_path: "../../../priv/plugins/my_plugin/plugin.json"
end
```

`use Barkpark.Plugin` reads that manifest at compile time, validates it against
`priv/plugin_manifest_schema.json`, freezes it into `manifest/0`, and injects a
no-op default for **every** other callback.

```bash
mix compile          # compiles your entry module
mix phx.server       # restart → Registry discovers + registers my_plugin
```

Now the plugin auto-registers on restart and does precisely nothing — until you
override a callback.

> **Why the module lands in `lib/`, not under `priv/plugins/<name>/`.**
> `elixirc_paths` is `["lib"]`, so a module under `priv/plugins/<name>/lib/`
> would never compile. The generator therefore puts the entry module in the
> compiled tree and keeps the manifest + schemas in `priv/` — exactly OnixEdit's
> layout — and the manifest's `module` key is what lets `Registry` find the
> compiled module. (`--root PATH` scaffolds under a different base; `--module
> Mod` overrides the derived module name.)

---

## 3. How the host finds and runs your plugin

```
 plugin.json  ──read+validate at compile time──▶  use Barkpark.Plugin
      │                                                   │
      │                                          injects no-op defaults
      │                                          for ~25 callbacks
      ▼                                                   ▼
 Barkpark.Plugins.Registry.discover_and_register/0   (boot, post-supervisor Task)
      │  walks priv/plugins/* (+ deps_path in dev/test)
      │  one dir-with-plugin.json == one plugin; failures logged, never raise
      ▼
 GenServer state  +  :persistent_term snapshot (cached resolver results)
      │
      ▼
 host reads contributions at runtime via Registry.collect_*/1
      every plugin call wrapped in try/rescue → a plugin can NEVER crash the host
```

Discovery walks `Application.app_dir(:barkpark, "priv/plugins")` (and
`Mix.Project.deps_path/0` when Mix is loaded, i.e. dev/test). Each subdirectory
holding a `plugin.json` is a plugin; the entry module comes from the manifest's
`module` key, else PascalCased from `plugin_name` under
`Barkpark.Plugins.<Name>`. A module that fails to load is logged and skipped —
**discovery never raises**.

At runtime, host UI reads plugin contributions through the Registry's
`collect_*/1` collectors. Every per-plugin call goes through a `try/rescue`
(and `catch`) wrapper that logs and falls back to the running accumulator. A
plugin whose callback raises contributes nothing; the host keeps serving.

### The `:plugins` application env

| `config :barkpark, :plugins` | Behaviour |
|---|---|
| **unset** (absent) | Auto-discover everything on disk. Production / fresh-install default. |
| `[]` (explicit empty list) | **Kill switch.** Register nothing. The fresh-install invariant (§1). |
| `["my_plugin", …]` (non-empty) | **Whitelist.** Walk disk, register only plugins whose `plugin_name` matches. Entries may be names, `{name, module}` tuples, or module atoms. |

The non-empty list also doubles as the **load order** for the resolver chain
(§6). When unset, plugins are processed alphabetically by name.

### Caveat: routes and workers are resolved before the runtime registry exists

There are two different read paths, and they happen at different times:

| Contribution | Read by | When | Source-of-truth |
|---|---|---|---|
| Routes (`register_routes/1`) | `plugin_routes/1` router macro → `collect_routes/1` | **Compile time** | `plugin_modules_sync/0` (disk walk) |
| Workers (`register_workers/1`) | `Application.start/2` → `collect_workers/1` | **Boot, supervisor build** | `plugin_modules_sync/0` (disk walk) |
| Everything else (`action_handlers/0`, hooks, schemas, etc.) | `collect_*/1` resolver chain | **Runtime** | live Registry GenServer |

Both compile-time collectors walk the manifest files on disk directly — they do
**not** consult the runtime Registry GenServer (it isn't alive yet). The
practical consequence: a plugin you drop in and register *after* boot gets
runtime resolver participation (its actions, hooks, menu entries light up) but
**not** routes or workers — Phoenix routes must exist when the router compiles,
and worker child specs must exist when the supervision tree is built. **Declare
your plugin on disk before boot.** (And after editing `register_routes/1`,
nuke the router beam — see HIGHWAY.md Appendix B.)

---

## 4. The manifest (`plugin.json`)

Validated at compile time against `api/priv/plugin_manifest_schema.json` by
`Barkpark.Plugins.Manifest.validate!/1`. `additionalProperties: false` — unknown
keys are a hard failure.

| Key | Required | Meaning |
|---|---|---|
| `plugin_name` | **yes** | Slug discriminator. `^[a-z][a-z0-9_-]*$`, unique across the registry. |
| `version` | **yes** | Semver `MAJOR.MINOR.PATCH` with optional pre-release tag. |
| `description` | **yes** | One-line human-readable purpose (non-empty). |
| `capabilities` | **yes** | Array (unique) drawn from the enum below. Declarative — see note. |
| `module` | no | Elixir module override (PascalCase, dotted). Defaults to auto-derived from `plugin_name`. |
| `dependencies` | no | Array of `{plugin_name, version_req}` — other plugins this one needs. |
| `schemas` | no | Array of `{name, version, file}` — schema JSON shipped with the plugin. |
| `routes` | no | Array of route descriptor strings (advisory metadata; the real route DSL is `register_routes/1`). |
| `workers` | no | Array of `{name, child_spec_module}` — advisory; the real list is `register_workers/1`. |
| `settings_schema` | no | Embedded JSON Schema for settings (advisory — runtime validation is `validate_settings/1`). |
| `codelists` | no | Array of `{issue, name, file}` — bring-your-own codelists shipped with the plugin. |
| `node` | no | `{entrypoint, package, scripts?}` — Node toolchain metadata for plugins with a JS build. |

`capabilities` enum: **`routes`, `workers`, `schemas`, `settings`, `node`,
`codelists`**.

> **Capabilities are declarative documentation, not a gate.** The Registry does
> not consult `capabilities` to decide whether to call `register_routes/1` or
> `register_workers/1` — it always calls every exported callback. OnixEdit
> declares only `["schemas", "codelists"]` yet ships four routes and a worker,
> and they all wire up. List your real capabilities for honest metadata, but
> know that the callbacks are what actually run.

---

## 5. Which callbacks do I implement? — a decision tree

This is the centerpiece. Find your intent on the left; implement the callback
on the right. Every name/arity here is verified against
`api/lib/barkpark/plugin.ex`. All callbacks are optional — `use
Barkpark.Plugin` supplies a working default for each.

| I want to… | Implement | Default | Read back by |
|---|---|---|---|
| Add a new document type | `register_schemas/1` | `[]` | `Bootstrap.register_all_schemas/0` at boot |
| Add a button to the editor header | schema `actions` entry **+** `action_handlers/0` | `%{}` | `collect_action_handlers/1` → `StudioLive.dispatch_action/4` |
| Show an external-sync status pill | `external_sync_entries/0` | `%{}` | `collect_external_sync_entries/1` |
| Add a Studio top-nav tab | `top_menu_entries/0` | `[]` | `collect_top_menu_entries/1` |
| Add a row to the Structure pane | `desk_items/1` | `[]` | `collect_desk_items/1` |
| React to save/publish/unpublish/delete | `lifecycle_hooks/0` | `%{}` | `Plugins.Hooks.fire/2` inside Content ops |
| Render a custom preview pane | `content_renderer/3` | `:skip` | `collect_content_renderer/3` (first-wins) |
| Add a "Test connection" button | `test_connection/1` | `{:error, :not_implemented}` | `collect_test_connection/2` (first-wins) |
| Expose admin config fields | `settings_schema/0` | `[]` | admin Plugin Settings LV |
| Validate those config fields on submit | `validate_settings/1` | `:ok` | admin Plugin Settings LV (only) |
| Run background jobs | `register_workers/1` | `[]` | `collect_workers/1` at boot |
| Ship a data endpoint or ops console | `register_routes/1` | `[]` | `collect_routes/1` at compile (read §7 first) |
| Register cross-validation checkers | `checkers/0` | `[]` | `collect_checkers/1` |
| Seed codelist registry data | `codelist_seeders/0` | `[]` | `run_all_codelist_seeders/0` |
| Declare on-demand API smoke tests | `api_tests/0` | `[]` | `collect_api_tests/1` → `ApiTestRunner.run/2` |
| Remove / reorder / amend host or sibling entries | the matching `resolve_*/2` | identity / lift | the same `collect_*/1` (see §6) |
| Carry identity / declare config | `manifest/0` (auto, never override) | the frozen manifest map | Registry, admin LV |

A few of these compose. "Add a button" is two callbacks: the schema's
`actions` array makes the button *appear* (host renders it from schema
metadata), and `action_handlers/0` maps the action name to the function the
host calls when it's clicked. The RECIPE.md "Vlie" walkthrough wires exactly
this pair.

```
        intent
          │
   ┌──────┴───────────────────────────────────────────┐
   │ data shape          │ host UI surface   │ side-effect │
   ▼                     ▼                   ▼             ▼
register_schemas/1   top_menu_entries/0   lifecycle_hooks/0
codelist_seeders/0   desk_items/1         register_workers/1
settings_schema/0    action_handlers/0    register_routes/1
                     external_sync_…/0    content_renderer/3
                     resolve_doc_actions/2 test_connection/1
```

For the exhaustive per-callback reference — signatures, when each fires,
failure modes, the OnixEdit example for each — go to
[HIGHWAY.md §3](HIGHWAY.md). This guide does not reproduce that table.

---

## 6. Additive vs resolver callbacks

Eight collectors run a **resolver chain**: the host seeds an accumulator
(`prev`), and threads it through every plugin in load order via a
`resolve_X/2` callback of shape `(prev, ctx) -> next`. Each plugin sees the
running accumulator and returns a transformed value.

You almost never write `resolve_X/2` by hand. Implement the **additive** form
— `action_handlers/0` returning a map, `top_menu_entries/0` returning a list —
and the `use Barkpark.Plugin` macro auto-lifts it into the resolver shape:
list-shaped callbacks concatenate (`prev ++ result`), map-shaped callbacks
merge (`Map.merge(prev, result)`).

```
host baseline (prev)
        │
        ▼
 plugin A.resolve_X/2 ──▶ plugin B.resolve_X/2 ──▶ … ──▶ final list/map
   (default lift:           (override: drop/reorder)
    prev ++ A.X())
```

Reach for `resolve_X/2` **only** when you must mutate, reorder, or **remove**
host or sibling entries — not just append. The canonical example is OnixEdit's
`resolve_doc_actions/2`, which drops the `"publish_to_bokbasen"` button while a
book's Bokbasen submission is in-flight:

```elixir
def resolve_doc_actions(prev, ctx) do
  if hide_publish_action?(ctx) do
    Enum.reject(prev, fn action -> action["name"] == "publish_to_bokbasen" end)
  else
    prev
  end
end
```

`resolve_doc_actions/2` is special: it has no additive predecessor (its default
is pure identity), because `prev` is seeded by the host with the
schema-declared `:actions` list. The companion `action_handlers/0` entry stays
registered — hiding the button doesn't unregister the handler; the handler just
won't be reachable while hidden.

> **Don't define both forms.** If a plugin exports both `resolve_X/2` *and* the
> additive `X/0`, `Registry.warn_duplicate_forms/0` logs a warning on every
> register sweep and the **resolver wins** — the additive code is dead. Pick
> one.

The eight resolver pairs and their `ctx` shapes are tabled in
[HIGHWAY.md §3](HIGHWAY.md).

---

## 7. The route & UI rule — read this before you add a route

This is the rule that keeps plugins from metastasizing into parallel CMSes.

**A plugin MUST NOT** ship a route or LiveView that:

- edits documents, or
- duplicates host chrome — the Structure sidebar, the editor pane, field
  renderers, modals, the action bar.

Those surfaces are schema-driven and host-owned. If you find yourself writing a
LiveView with a form that writes to `documents`, you are doing it wrong. Declare
a schema; the host renders the editor. (See INTEGRATION_LESSONS.md for the
retrospective on why this rule exists.)

**A plugin MAY** ship a route for exactly two cases:

1. **A non-HTML DATA endpoint** — a file export, a webhook receiver — mounted
   under `/v1/plugins/<plugin>/` with `auth: :api`.
2. **An OPS/ADMIN console** — operational state the host has no generic
   primitive for: a submission queue, a drift dashboard, a sync-status board —
   mounted under `/admin/<plugin>/` with `auth: :ops`.

(The token-gated and public-reader buckets below — `:token`, `:token_root`,
`:ingest`, `:public_root` — extend these two cases for plugins that expose a
token-scoped data API or a public reader page: the `tasks` plugin mounts its
`/v1/tasks` API at `:token_root`, and the `bulldocs` plugin serves its
`/papers/:slug` reader at `:public_root` and its ingest API at `:ingest`. The
rule that still holds: none of these may reimplement the host's schema-driven
document editor.)

OnixEdit is the reference. Its four routes obey the rule precisely — a Bokbasen
ops console and a codelist-staleness console (`:ops`, under `/admin`), an ONIX
XML export controller (`:api`, under `/v1/plugins`), and a pilot ping
(`:admin`). **None of them touch `/studio` document editing** — book editing
happens entirely through the host's schema-driven Studio editor.

### Auth buckets

The `auth:` opt in a route spec selects the scope, the auth gate, and the mount
prefix. The buckets, from `Barkpark.Plugin`'s `register_routes/1` docs:

| `auth:` | Gate | Mounts under |
|---|---|---|
| `:admin` (default) | strict admin (`LiveAuth :admin`) | `/studio` |
| `:ops` | ops-team gate (`LiveAuth :ops`) | `/admin` |
| `:public` / `:none` | none (bare `live_session`) | `/studio` |
| `:api` | API pipeline + admin required | `/v1/plugins` |
| `:token` | API pipeline + token required (NOT admin) | `/v1/plugins` |
| `:token_root` | API pipeline + token required (NOT admin); root-mounted sibling of `:token` | `/v1` |
| `:ingest` | shared-secret ingest pipeline | `/v1/plugins` |
| `:public_root` | none; own full-document `root_layout:` (no studio chrome) | host top-level scope |

Route specs are tagged tuples — `{:live, path, module, action [, opts]}` for
LiveViews, `{verb, path, controller, action [, opts]}` for controllers. The
path embeds your slug (`"/onixedit/export/:dataset/:id"`); the host scope
contributes the prefix. With `:plugins` set to `[]`, `collect_routes/1` returns
`[]` and every callsite expands empty — the fresh-install invariant holds at
the router level. Full route DSL and the OnixEdit route table:
[HIGHWAY.md §5–6](HIGHWAY.md).

---

## 8. Settings (credentials)

Plugin secrets live in the host-owned `plugin_settings` table, encrypted at
rest via Cloak. Every read, write, reveal, and delete is **audited**; masked
fields stay masked in the UI; and (now) each mutation and its audit row commit
in a single transaction (`Barkpark.Plugins.Settings.put/3` and friends wrap the
audit insert in `Repo.transaction` — an audit failure rolls back the secret).

Settings are keyed by a **settings-row name**. Your `settings_schema/0` fields
are dot-namespaced `"<row>.<key>"` — the leading segment selects the row, the
remainder is the flat key inside it. OnixEdit's
`"bokbasen.client_secret"` field writes `%{"client_secret" => …}` into the
`"bokbasen"` row, which is exactly what `Bokbasen.Settings.get_credentials/0`
reads back. The storage layout mirrors what the runtime client expects — the LV
invents nothing.

**`validate_settings/1` runs in the admin Plugin Settings LiveView, not in
`Settings.put/3`.** The LV calls `module.validate_settings/1` before persisting
and blocks the save on a non-`:ok` return. `Settings.put/3` itself performs no
validation — it only persists the changeset. So write paths that reach
`Settings.put/3` directly (the Studio settings LV, the settings API controller)
currently bypass `validate_settings/1`. This is a known limitation: validation
is gated at the admin form, not at the storage layer.

Configure a row from IEx:

```elixir
Barkpark.Plugins.Settings.put("bokbasen", %{
  "api_base"     => "https://api.bokbasen.io",
  "client_id"    => "…",
  "client_secret"=> "…"
})
```

…or, the normal path, through the admin **Plugin Settings** form, which renders
the `settings_schema/0` fields, runs `validate_settings/1`, and persists on
submit. Your runtime client reads back with `Settings.get("bokbasen")`. Use
`Settings.reveal/2` only when an admin explicitly unmasks a field — it records a
`"reveal"` audit row before returning the plaintext.

---

## 9. Lifecycle hooks

`lifecycle_hooks/0` returns a map of event → `[hook_fn]`. The eight events
bracket the four mutating Content operations:

```
  create / upsert ──▶  :before_save     :after_save
  publish         ──▶  :before_publish  :after_publish
  unpublish       ──▶  :before_unpublish :after_unpublish
  delete          ──▶  :before_delete   :after_delete
```

`before_*` hooks run **synchronously** in load order. Returning `{:halt,
reason}` cancels the operation — the host surfaces `{:error, {:halted,
reason}}` to the caller. (There is no `{:ok, mutated_doc}` variant; before-hooks
gate, they don't rewrite.) `after_*` hooks run **asynchronously** via
`Task.async_stream` with a 5-second per-hook timeout, and their return value is
**discarded**.

Hooks are capture references (`&MyMod.fun/1`), not `{module, function}` tuples
— the host invokes them directly with a single `hook_payload()` arg:

```elixir
%{event:, doc:, dataset:, prev_doc:, ctx: %{source:, user_id:}}
```

### The recursion guard

A worker that re-writes a document (to record final sync state, say) will
re-fire that document's `after_*` hooks. Inspect `payload.ctx.source` and bail
when it's `:worker`:

```elixir
def publish_to_bokbasen_if_book(%{ctx: %{source: :worker}}), do: :ok
def publish_to_bokbasen_if_book(%{doc: %{"_type" => "book"}} = payload), do: …
def publish_to_bokbasen_if_book(_), do: :ok
```

OnixEdit registers exactly this:
`%{after_publish: [&Lifecycle.publish_to_bokbasen_if_book/1]}` — publishing a
`book` auto-enqueues a Bokbasen submission, the hook bails on non-books and on
`:worker`, and the worker's own final write doesn't re-fire it.

---

## 10. Testing your plugin

The discipline mirrors the architecture: the plugin tests its own surface;
LiveView integration is the host's job.

- **Pure-function tests on your handlers.** No LiveView, no Phoenix. Call
  `MyPlugin.Actions.publish_to_x/3` directly and assert the tagged tuple. The
  RECIPE.md "Vlie" `actions_test.exs` is the pattern — `use
  Barkpark.DataCase`, seed a doc, assert `{:ok, %{kind: :xml, …}}`.
- **The `api_tests/0` declarative runner.** Return `[api_test_spec()]` — a
  single HTTP request, a list of assert tuples (`{:status, 200}`,
  `{:body_contains, …}`, `{:json_path, …}`, etc.), an optional `cleanup` list
  the runner *always* fires after asserts. The admin "Run API tests" surface
  fires them via `Barkpark.ApiTestRunner.run/2`. OnixEdit ships four: public
  schema fetch, admin schema fetch, top-menu render, and a mutation round-trip
  with a `cleanup` that deletes the probe. Assert reference: HIGHWAY.md §3a.
- **Bootstrap / round-trip tests.** Confirm `register_schemas/1` upserts and
  the schema reads back; confirm a publish drives your worker's state machine.
  Mirror the OnixEdit test tree under `test/barkpark/plugins/<slug>/`.

---

## 11. Deploying

```bash
git add -A && git commit -m "feat(plugin): add my_plugin"
git push                              # (ask before pushing per repo policy)

ssh root@89.167.28.206
cd /opt/barkpark
git pull                              # post-merge hook rebuilds + restarts
make logs                             # watch for "registered schema … from plugin my_plugin"
```

Verify the contribution surfaced — e.g. that a new document type's schema is
live:

```bash
curl -s -H "Authorization: Bearer barkpark-dev-token" \
  http://89.167.28.206/w/acme/p/web/v1/schemas/production \
  | jq '.[] | select(.name=="my_type") | .name'
```

> Flat alias: `GET /v1/schemas/production` (no `/w/.../p/...` prefix) → resolves the `Default` workspace + project. See `docs/api-v1.md` §1a and §8.

If you edited `register_routes/1`, the router beam may be stale — nuke it and
recompile (HIGHWAY.md Appendix B). And if anything looks off, the
fresh-install invariant is your bisect: `config :barkpark, :plugins, []`,
restart, and confirm the host still boots clean — then re-enable.

---

## 12. Deep dives — where to go next

| Doc | Read it for |
|---|---|
| [HIGHWAY.md](HIGHWAY.md) | The exhaustive callback reference — every signature, when it fires, failure mode, the `collect_*/1` read-paths, the full `auth:` model, the forbidden surfaces. The manual behind this guide. |
| [RECIPE.md](RECIPE.md) | The complete worked example — building the "Vlie" sync plugin file-by-file, eight files and one host edit. Copy this shape. |
| [ARCHITECTURE.md](ARCHITECTURE.md) | The contract and principles — the system-shape narrative, the dispatch return shapes, the boundaries every file conforms to. |
| [SCHEMA_V2.md](SCHEMA_V2.md) | The four nested v2 field types — `composite`, `arrayOf`, `codelist`, `localizedText` — and how the validator and the read-only TUI treat them. |
| [INSTALL.md](INSTALL.md) | The schema bootstrap path — how `register_schemas/1` auto-installs on every server start, idempotent on `(name, dataset)`. |
| [codelists-byo.md](codelists-byo.md) | Bring-your-own codelists — shipping and seeding registry-backed enums pinned to an issue version (e.g. ONIX issue 73). |
| [INTEGRATION_LESSONS.md](INTEGRATION_LESSONS.md) | The *why* behind "no plugin UI" — the retrospective that produced the route & UI rule in §7. |

Start with RECIPE.md if you learn by example; HIGHWAY.md if you need the
precise contract for one callback. Everything here is the map; those are the
territory.
