# Barkpark Plugin Highway

> Public API surface for Barkpark plugin authors.

Reference for every `Barkpark.*` module and function plugin code is allowed
to call, every `Barkpark.Plugin` callback the host invokes, and every
`Barkpark.Plugins.Registry` collector that funnels plugin contributions back
into host UI. Companion docs:
[`INSTALL.md`](INSTALL.md) for the schema bootstrap path,
[`SCHEMA_V2.md`](SCHEMA_V2.md) for the nested field-type DSL,
[`codelists-byo.md`](codelists-byo.md) for codelist seeding,
[`ARCHITECTURE.md`](ARCHITECTURE.md) for the system-shape narrative.

---

## 1. The Highway Principle

The architectural rule, in the user's words:

> We must have a first class highway for plugins to use native barkpark
> solutions — plugins are enhanced by barkpark, and barkpark is enhanced
> by plugins — the most important is that we can turn off all plugins
> and it still work fine.

Three binding claims fall out of that sentence:

1. **First-class highway.** The set of `Barkpark.*` modules plugins are
   allowed to call is documented, stable, and intentional. Every primitive
   below — `Barkpark.Content.*`, `Barkpark.Plugin`, `Barkpark.Plugins.Hooks`,
   `Barkpark.Plugins.Registry`, `Barkpark.ApiTestRunner.Asserts`,
   `Barkpark.Content.Codelists`, `Barkpark.Plugins.Settings`,
   `BarkparkWeb.Router.Plugins.plugin_routes/1` — is a public road. Anything
   not on this highway is internal host code; reaching for it is flagged in
   plan reviews and may break without notice.
2. **Bidirectional enhancement.** Plugins are enhanced *by* Barkpark — their
   schemas auto-render, their hooks fire at the right moments, their assert
   tuples evaluate, the Registry's resolver chain folds their contributions
   into host UI. Barkpark is enhanced *by* plugins — their callback returns
   surface inside the host's existing surfaces (Studio top-menu, desk pane,
   editor header actions, settings LV, preview pane). No plugin-owned admin
   shells; no host-side `if plugin == :onixedit do …` branches.
3. **Fresh-install invariant.** With `Application.put_env(:barkpark, :plugins, [])`,
   Barkpark must still boot, Studio must still load, the public API must still
   serve exactly the 8 seed schemas, and host code under `lib/barkpark` +
   `lib/barkpark_web` must not name any plugin module. See §2.

This document captures the highway. The boot test in §2 enforces the
fresh-install invariant. Together they are the contract.

---

## 2. The Fresh-Install Invariant

Boot Barkpark with `:plugins` set to the empty list and the system must
keep working. Verify locally:

```elixir
Application.put_env(:barkpark, :plugins, [])
Application.stop(:barkpark)
{:ok, _} = Application.ensure_all_started(:barkpark)
```

…then:

* `GET /studio/production` → 200, body contains the `"Structure"` nav marker.
* `GET /api/schemas` → 200, JSON lists exactly the 8 seed schemas
  (`post`, `page`, `author`, `category`, `project`, `siteSettings`,
  `navigation`, `colors`).
* The Studio HTML contains none of the strings `OnixEdit`, `Bokbasen`, `book`.
* `grep -r 'Barkpark.Plugins.OnixEdit' lib/barkpark lib/barkpark_web/` returns
  zero hits (paths under `lib/barkpark/plugins/onixedit/` excluded).
* `Supervisor.which_children(Barkpark.Supervisor)` contains no
  `Barkpark.Plugins.OnixEdit.*` child specs.

The regression bar is `api/test/barkpark/plugin_free_boot_test.exs`. It is
tagged `:boot_test` and excluded from the default `mix test` run; invoke
explicitly:

```bash
cd api
mix test --only boot_test test/barkpark/plugin_free_boot_test.exs
```

Any future change that drifts the host into plugin awareness fails this test.
Use it as the gate when reviewing plans that add new plugin callbacks or new
shared primitives — if the plan can't preserve the invariant, re-scope.

---

## 3. The Plugin Behaviour — Every Callback

Source of truth: `api/lib/barkpark/plugin.ex`. Every callback below is
`@optional_callbacks` — plugins opt in by overriding the default supplied by
`use Barkpark.Plugin`. The defaults are listed for each entry so authors know
what they inherit by doing nothing.

The 14 host-invoked callbacks split into three groups: identity + registration
(manifest, register_*, validate_settings), additive contributions (the seven
`*_entries` / `*_seeders` callbacks that feed the resolver chain), and direct
host hooks (lifecycle, api_tests, content_renderer, test_connection). The
eight resolver-pair callbacks (`resolve_*/2`) are listed at the end — plugins
override one of these whenever they need to *mutate* the running accumulator
rather than just append to it.

### `manifest/0`

* **Signature.** `@callback manifest() :: map()`.
* **When fires.** Compile-time read by `use Barkpark.Plugin.__using__/1`,
  available at runtime via `Module.manifest/0`. The `Plugins.Registry`
  GenServer stores it alongside the module pointer; the admin Plugin Settings
  LV displays the title / version / author it carries.
* **Returns.** The decoded + validated `plugin.json` map. Validated against
  `api/priv/plugin_manifest_schema.json` via `Barkpark.Plugins.Manifest.validate!/1`.
* **Default.** The `__using__/1` macro reads `../plugin.json` relative to the
  module's source file, runs `Jason.decode!` then `Manifest.validate!`, and
  freezes the result as a literal — plugins never override `manifest/0`
  themselves.
* **Example.** See `priv/plugins/onixedit/plugin.json`.

### `register_schemas/1`

* **Signature.** `@callback register_schemas(keyword()) :: [Barkpark.Content.SchemaDefinition.t()]`.
* **When fires.** `Barkpark.Plugins.Bootstrap.register_all_schemas/0` calls
  this on every registered plugin at boot (post-boot Task in
  `Barkpark.Application.start/2`) and on every `mix run priv/repo/seeds.exs`.
  Each returned struct is converted to attrs and upserted via
  `Barkpark.Content.upsert_schema/2`. Idempotent on `(name, dataset)`.
* **Returns.** A list of `%Barkpark.Content.SchemaDefinition{}` structs. May
  use any Schema Definition v2 type (composite, arrayOf, codelist,
  localizedText).
* **Default.** `[]`.
* **Example.** OnixEdit's `register_schemas/1` reads `book.json`, splices in
  `Contributor` + `TextContent` subfields, and returns a single
  SchemaDefinition for `book` in dataset `production`.
* **Failure mode.** A raise inside `register_schemas/1` logs `Logger.error`
  in `Bootstrap.install_for_plugin/1` and skips this plugin — the next
  plugin's schemas still install. The aggregated return is
  `{:error, [{plugin_name, reason}, …]}`.

### `register_routes/1`

* **Signature.** `@callback register_routes(ctx :: map()) :: [route_spec()]`.
  `route_spec()` is the tagged tuple documented in `Barkpark.Plugin` —
  `{:live, path, module, action}` or `{:get|:post|:put|:delete|:patch, path,
  controller, action}`, optionally with an `opts` keyword tail (`auth:`,
  `as:`).
* **When fires.** Compile-time, read by the `plugin_routes/1` macro in
  `BarkparkWeb.Router.Plugins`. The macro filters by the host scope (one of
  `:admin | :ops | :public | :api`) and emits one Phoenix.Router AST node
  per matching route.
* **Returns.** Flat list of route specs. Paths embed the plugin's slug
  (`"/onixedit/ping"`) and are mounted under the host scope wrapping the
  callsite (`scope "/studio"`, `scope "/admin"`, `scope "/v1/plugins"`).
* **Default.** `[]`.
* **Example.** OnixEdit returns four route specs — see §5 for the table and
  §9 for the worked example.
* **Boot-order quirk.** See Appendix B for the router-beam rebuild dance.

### `register_workers/1`

* **Signature.** `@callback register_workers(any()) :: [Supervisor.child_spec()]`.
* **When fires.** `Barkpark.Application.start/2` calls
  `Plugins.Registry.collect_workers/1` synchronously before the rest of the
  supervision tree is built. The returned children are folded into the tree
  between the Vault (which must be up so plugins can decrypt their settings)
  and the Endpoint (which must be down so plugin workers come up before
  traffic).
* **Returns.** Any list of `Supervisor.child_spec()`-compatible terms —
  module atoms, `{Module, opts}` tuples, full child specs.
* **Default.** `[]`.
* **Example.** OnixEdit returns `[Barkpark.Plugins.OnixEdit.Bokbasen.Auth]`
  — a lazy OAuth2 token cache.
* **Failure mode.** A raise or non-list return logs a warning and skips the
  plugin; the boot continues.

### `validate_settings/1`

* **Signature.** `@callback validate_settings(map()) :: :ok | {:error, [{atom(), String.t()}]}`.
* **When fires.** Called by the admin Plugin Settings LiveView
  (`BarkparkWeb.Admin.PluginSettingsLive.run_plugin_validation/2`) on form
  submit. The LV resolves the plugin module by name, shapes the typed form
  values into the nested `%{"<row>" => %{<key> => …}}` map the plugin
  expects, and calls `module.validate_settings/1` **before** persisting. A
  non-`:ok` return blocks the save and the LV surfaces the field-level
  errors.
  **Note — `Barkpark.Plugins.Settings.put/3` does NOT call this.**
  `put/3` is keyed by settings-**row** name and performs no validation; it
  only persists the changeset. `validate_settings/1` is per-**plugin**.
  Because the admin LV is the only caller, **other write paths that reach
  `Settings.put/3` directly — the Studio settings LiveView and the plugin
  settings API controller — currently bypass `validate_settings/1`.** This
  is a known limitation: validation today is gated at the admin form, not at
  the storage layer.
* **Returns.** `:ok` or `{:error, [{field_atom, message_string}, …]}`.
* **Default.** `:ok` — plugins that don't need extra validation rely on the
  declarative `settings_schema/0` typing.

### `checkers/0`

* **Signature.** `@callback checkers() :: [{name :: String.t() | atom(), module()}]`.
* **When fires.** Read by `Plugins.Registry.collect_checkers/1` whenever the
  host enumerates registered checkers (the cross-validation / linter surface).
* **Returns.** List of `{name, module}` pairs; the module must implement the
  `Barkpark.Plugins.Checker` behaviour.
* **Default.** `[]`.
* **Resolver pair.** `resolve_checkers/2` — the default lifts via `prev ++ result`.

### `action_handlers/0`

* **Signature.** `@callback action_handlers() :: %{optional(String.t()) => action_handler()}`.
* **When fires.** Read by `Plugins.Registry.collect_action_handlers/1` when
  `StudioLive.dispatch_action/4` resolves a schema-declared action name to a
  handler function.
* **Returns.** Map keyed by action name, valued by an `action_handler/3`
  function — `(doc_id, dataset, :dryrun | :real) -> {:ok, term} | {:error, term}`.
* **Default.** `%{}`.
* **Resolver pair.** `resolve_action_handlers/2` — the default lifts via
  `Map.merge(prev, result)`.
* **Example.** OnixEdit registers
  `"publish_to_bokbasen" => &OnixEdit.Actions.publish_to_bokbasen/3`.

### `external_sync_entries/0`

* **Signature.** `@callback external_sync_entries() :: %{optional(String.t()) => map()}`.
* **When fires.** Read by `Plugins.Registry.collect_external_sync_entries/1`
  whenever the host renders the per-document status pill that tracks an
  outbound sync (Bokbasen submission, third-party indexer, etc.).
* **Returns.** Map keyed by sync name, valued by a map of
  `%{label, states: %{state_string => %{color, label}}}`.
* **Default.** `%{}`.
* **Resolver pair.** `resolve_external_sync_entries/2` — default merges via
  `Map.merge`.

### `codelist_seeders/0`

* **Signature.** `@callback codelist_seeders() :: [(-> any())]`.
* **When fires.** Read by `Plugins.Registry.run_all_codelist_seeders/0` at
  boot and again from the admin LV's per-plugin "Reload" button (via
  `run_codelist_seeders_by_name/1`). Each zero-arg function is invoked in
  registration order inside `try/rescue` — one failing seeder doesn't abort
  the rest. Results land in `Barkpark.Plugins.RunStatus`.
* **Returns.** List of zero-arg functions that side-effect into the codelist
  registry (typically calling `Barkpark.Content.Codelists.register/3`).
* **Default.** `[]`.
* **Resolver pair.** `resolve_codelist_seeders/2` — default lifts via
  `prev ++ result`. The list shape is preserved even though seeders run for
  side-effect.
* **Example.** OnixEdit returns
  `[&Barkpark.Codelists.EDItEUR.seed_bundled/0, &Barkpark.Codelists.EDItEUR.seed_thema/0]`.

### `settings_schema/0`

* **Signature.** `@callback settings_schema() :: [setting_field()]`.
* **When fires.** Read by the admin Plugin Settings LiveView when it builds
  the form for a specific plugin. The wider, cross-plugin view consults
  `Plugins.Registry.collect_settings_schema/1`.
* **Returns.** Ordered list of `setting_field()` maps — `name` (dot-namespaced
  `"<settings-row>.<key>"`), `type` (`:string | :password | :url | :select |
  :boolean`), `label`, plus optional `required`, `default`, `hint`, `group`,
  `masked`, `placeholder`, `options`.
* **Default.** `[]`.
* **Resolver pair.** `resolve_settings_schema/2` — default lifts via
  `prev ++ result`.
* **Example.** OnixEdit declares five Bokbasen credential fields, all in
  group `"Bokbasen"`, with `client_secret` typed `:password` + masked.

### `top_menu_entries/0`

* **Signature.** `@callback top_menu_entries() :: [top_menu_entry()]`.
* **When fires.** Read by `Plugins.Registry.collect_top_menu_entries/1` when
  Studio renders its top bar. The collector normalises (defaults `:order` to
  100) and sorts by `{order, label}`. Built-in tabs use orders 10/20/30;
  plugin tabs default to 100 and sort to the right unless overridden.
* **Returns.** List of `%{label, path, icon?, order?, active_when?}` maps.
  `active_when` is matched against the current request path (string =
  prefix, `Regex` = pattern); absent ≡ exact-match-on-`path`.
* **Default.** `[]`.
* **Resolver pair.** `resolve_top_menu_entries/2` — default lifts via
  `prev ++ result`.
* **Example.** OnixEdit contributes one entry:
  `%{label: "Bokbasen", path: "/admin/onixedit/staleness", icon: "send", order: 50, active_when: "/admin/onixedit/"}`.

### `desk_items/1`

* **Signature.** `@callback desk_items(dataset :: String.t()) :: [desk_item()]`.
* **When fires.** Read by `Plugins.Registry.collect_desk_items/1` (or the
  legacy binary-arg form) when StudioLive builds the root Structure pane.
  Appended after the host's auto-generated schema items.
* **Returns.** List of tagged desk items keyed by `:type` —
  `:link | :document_list | :divider | :nested`. `PaneBuilder` dispatches per
  type.
* **Default.** `[]`.
* **Resolver pair.** `resolve_desk_items/2` — default reads
  `ctx.dataset || "production"`, calls the additive form, and lifts via
  `prev ++ result`.
* **Example.** OnixEdit contributes a `:divider` labelled "Bokbasen" and a
  `:link` row jumping to the staleness console.

### `lifecycle_hooks/0`

* **Signature.** `@callback lifecycle_hooks() :: %{optional(lifecycle_event()) => [hook_fn()]}`.
  Events: `:before_save`, `:after_save`, `:before_publish`, `:after_publish`,
  `:before_unpublish`, `:after_unpublish`, `:before_delete`, `:after_delete`
  (the four mutating Content operations, bracketed before/after).
* **When fires.** `Barkpark.Plugins.Hooks.fire/2` is invoked from inside
  every `Content.{create,upsert,publish,unpublish,delete}_document` call.
  `before_*` runs synchronously in plugin load order — the first
  `{:halt, reason}` short-circuits the chain and surfaces
  `{:error, {:halted, reason}}` to the caller. `after_*` runs asynchronously
  via `Task.async_stream` (5s per-hook timeout, results discarded; slow hooks
  over 100ms log a warning, plus telemetry emits
  `[:barkpark, :hooks, <event>, :hook]`).
* **Hook signature.** Each hook function takes one `hook_payload()` arg —
  `%{event, doc, dataset, prev_doc, ctx: %{source: :studio | :api | :cli | :worker,
  user_id: nil | String.t()}}`. **Recursion guard:** hooks that run inside a
  worker (Bokbasen.PublishWorker etc.) should bail when
  `payload.ctx.source == :worker` to avoid re-firing their own writes.
* **Returns from a hook.** `before_*`: `:ok | {:halt, reason_string}`.
  `after_*`: anything; discarded.
* **Registration shape.** Per plan §0 Q3, hooks are **capture references**
  (`&MyMod.fun/1`), not `{module, function}` tuples — the host invokes them
  directly.
* **Default callback.** `%{}`.
* **Example.** OnixEdit registers
  `%{after_publish: [&OnixEdit.Lifecycle.publish_to_bokbasen_if_book/1]}` —
  publishing a `book` document automatically enqueues a Bokbasen submission,
  while the hook bails on non-book docs and on `ctx.source == :worker`.

### `api_tests/0`

* **Signature.** `@callback api_tests() :: [api_test_spec()]`.
* **When fires.** Read by `Plugins.Registry.collect_api_tests/1` when the
  admin "Run API tests" surface (driven by `Barkpark.ApiTestRunner.run/2`)
  fires every registered spec.
* **Returns.** List of single-request specs (plan §0 Q5) — each spec has
  `name`, `method`, `path`, optional `headers`, `body`, `auth`, `asserts`,
  `cleanup`. The runner ALWAYS fires `cleanup` after asserts, pass or fail
  (plan §0 Q1).
* **Auth modes (Q3).** `:none | :admin | {:token, "raw"} | {:plugin_setting, "key"}`.
* **Assert tuples (Q2).** Eight evaluators — see §3a (Assert reference) below
  and `Barkpark.ApiTestRunner.Asserts.evaluate/2` in
  `api/lib/barkpark/api_test_runner/asserts.ex`.
* **Default.** `[]`.
* **Resolver pair.** `resolve_api_tests/2` — default lifts via `prev ++ result`.
* **Example.** OnixEdit declares four smokes: book-schema-reachable on the
  public route, same on the admin route, top-menu tab renders in Studio, and a
  mutation round-trip with `cleanup` deleting the probe.

### `content_renderer/3`

* **Signature.** `@callback content_renderer(doc_type :: String.t(), content :: map(), ctx :: map()) :: {:ok, iodata()} | :skip`.
* **When fires.** StudioLive's preview pane calls
  `Plugins.Registry.collect_content_renderer/3` on every doc-edit render.
  The collector walks plugins in load order and returns the **first**
  `{:ok, iodata}` it gets back; the iodata flows straight into the preview
  pane's `<pre>`. When every plugin returns `:skip`, the collector returns
  `:none` and the preview pane is hidden — no special-case wiring per plugin.
* **Returns.** `{:ok, iodata}` to claim the doc_type, `:skip` to fall through.
* **Default.** `:skip` — plugins opt in by pattern-matching on `doc_type`.
* **Failure mode.** A raise inside the callback is caught both by the plugin
  (the recommended `rescue :skip` clause) and by the Registry's own
  `safe_content_renderer_call/4` rescue layer — the chain continues and the
  host never crashes mid-edit.
* **Example.** OnixEdit's clause:
  `content_renderer("book", content, _ctx)` calls `OnixEdit.Export.to_string/1`
  and returns `{:ok, xml}` on success, `:skip` on `{:error, _}`, `:skip` on
  raise. Other doc_types fall through.

### `test_connection/1`

* **Signature.** `@callback test_connection(settings :: map()) :: {:ok, payload :: map()} | {:error, reason :: term()}`.
* **When fires.** Admin Plugin Settings LV's "Test connection" button calls
  `Plugins.Registry.collect_test_connection/2` with the live form's current
  `settings` map.
* **Returns.** `{:ok, %{message: "…"}}` lands as the success flash;
  `{:error, reason}` lands as the failure flash (the LV inspects `:message`
  when it's a binary, else stringifies the reason).
* **Default.** `{:error, :not_implemented}` — plugins without an external
  service (format-only plugins, schema-only plugins) opt out cleanly.
* **Failure mode.** A raise inside the callback is caught by the Registry's
  `safe_test_connection/2` and collapsed to `{:error, {:raised, message}}` —
  the LV stays alive.
* **Example.** OnixEdit's `test_connection/1` calls
  `Bokbasen.Auth.token/0` and returns either
  `{:ok, %{message: "Bokbasen reachable: token OK."}}` or
  `{:error, "Bokbasen unreachable: <reason>"}`.

### Resolver-pair callbacks (`resolve_*/2`)

Eight of the additive callbacks above have a companion `resolve_X/2` of shape
`(prev, ctx) -> next`. The host seeds `prev` with its built-in baseline
(or the schema-declared list for `resolve_doc_actions/2`); each plugin sees
the running accumulator and may transform it. The default supplied by
`use Barkpark.Plugin` calls the additive form (when exported) and lifts the
result — concatenation for list-shaped callbacks, `Map.merge` for map-shaped.
Override `resolve_X/2` directly when you need to **drop, reorder, or amend**
entries from the running list rather than just append.

| Resolver | Additive lift | `ctx` shape |
|---|---|---|
| `resolve_checkers/2` | `prev ++ checkers()` | `%{dataset}` |
| `resolve_action_handlers/2` | `Map.merge(prev, action_handlers())` | `%{dataset, doc_id, doc_type, doc}` |
| `resolve_external_sync_entries/2` | `Map.merge(prev, external_sync_entries())` | `%{dataset}` |
| `resolve_codelist_seeders/2` | `prev ++ codelist_seeders()` | `%{dataset}` |
| `resolve_settings_schema/2` | `prev ++ settings_schema()` | `%{plugin_name}` |
| `resolve_top_menu_entries/2` | `prev ++ top_menu_entries()` | `%{dataset, current_path}` |
| `resolve_desk_items/2` | `prev ++ desk_items(ctx.dataset)` | `%{dataset, current_path}` |
| `resolve_doc_actions/2` | identity (`prev`) — no additive predecessor | `%{dataset, doc_id, doc_type, doc}` |
| `resolve_api_tests/2` | `prev ++ api_tests()` | `%{}` |

Defining **both** the resolver and the additive form for the same callback
triggers a `Logger.warning` from `Registry.warn_duplicate_forms/0` on every
register sweep — the resolver wins, the additive code is dead. Pick one.

**Example.** OnixEdit's `resolve_doc_actions/2` drops the `"publish_to_bokbasen"`
entry from `prev` while the book's Bokbasen submission is in-flight
(`queued | staging | staged | polling`) — proof that a plugin can
conditionally remove a host-baseline action with nothing but the Plugin
behaviour + Registry chain.

### 3a. Assert tuple reference

`api_tests/0` specs carry `:asserts` — a list of tagged tuples evaluated by
`Barkpark.ApiTestRunner.Asserts.evaluate/2`. Eight evaluators ship in v1
(plan §0 Q2, locked):

| Tuple | Pass condition |
|---|---|
| `{:status, integer}` | HTTP status equals the integer |
| `{:body_contains, "needle"}` | Raw response body includes the substring |
| `{:body_regex, ~r/…/}` | Raw response body matches the regex |
| `{:json_path, [keys], fn val -> bool end}` | Decoded JSON at the key path satisfies the predicate |
| `{:json_keys_include, ["a", "b"]}` | Top-level JSON map has these keys |
| `{:header, "x-foo", "bar"}` | Header equals the string, or the 1-arity predicate returns true |
| `:not_empty` | Response body is non-empty |
| `{:duration_under_ms, 500}` | Request completed in under N ms |

Errors during evaluation (e.g. body isn't valid JSON for `:json_path`)
return `{:fail, "<error>"}` rather than raising — runner isolation is
preserved.

---

## 4. The Plugins.Registry Public API

Source of truth: `api/lib/barkpark/plugins/registry.ex`. Every `collect_*`
below is the host's read-path into the resolver chain — plugins author the
additive (or resolver-form) callbacks in §3; host code reads them back here.

### Resolver-chain collectors

Each accepts a keyword list with two optional keys: `:baseline` (initial
`prev` value, default `[]` or `%{}` depending on shape) and `:ctx` (per-
callback ctx map, default `%{}`). Legacy zero-arg callers
(`collect_top_menu_entries()`) keep working — `prev` defaults to the empty
baseline, `ctx` to `%{}`. Cached calls short-circuit through the
`:persistent_term` snapshot only when called with no opts.

| Function | Signature | Called from | Returns |
|---|---|---|---|
| `collect_action_handlers/1` | `(opts) -> %{name => handler_fn}` | StudioLive.dispatch_action/4 | merged handler map |
| `collect_external_sync_entries/1` | `(opts) -> %{name => entry_map}` | Studio sync-pill renderer | merged registry map |
| `collect_top_menu_entries/1` | `(opts) -> [entry]` | Studio top bar | normalised + sorted list (`{order, label}`) |
| `collect_desk_items/1` | `(binary or opts) -> [item]` | StudioLive root Structure pane | concatenated list, not cached |
| `collect_checkers/1` | `(opts) -> [{name, module}]` | cross-validation surface | concatenated list, not cached |
| `collect_codelist_seeders/1` | `(opts) -> [zero-arg fn]` | admin reload + observability | concatenated list (use `run_all_codelist_seeders/0` to execute) |
| `collect_settings_schema/1` | `(opts) -> [field]` | admin Plugin Settings LV (cross-plugin) | concatenated list |
| `collect_doc_actions/1` | `(opts) -> [action_map]` | Studio editor header | host seeds `:baseline` with schema-declared actions |
| `collect_api_tests/1` | `(opts) -> [spec]` | `Barkpark.ApiTestRunner.run/2` | concatenated list, not cached |

### First-wins collectors

These don't fold — they walk plugins in load order and return the **first**
match.

* `collect_content_renderer(doc_type, content, ctx \\ %{}) :: {:ok, iodata} | :none` —
  StudioLive preview pane. First plugin returning `{:ok, iodata}` wins;
  every `:skip` (and every raise) is swallowed by the safe-call wrapper.
  Three reasons it isn't an additive fold: only one preview can render per
  surface; the host has no built-in baseline; the iodata flows straight to
  the rendered pane.
* `collect_test_connection(plugin_name, settings) :: {:ok, payload} | {:error, reason} | {:error, :plugin_not_found}` —
  admin Plugin Settings LV's "Test connection" button. Looks up one plugin
  by name (the URL segment) and calls its `test_connection/1`. Raises
  collapse to `{:error, {:raised, msg}}`.

### Compile-time collectors

These don't require the Registry GenServer to be alive — they run while the
supervision tree is still being built (`collect_workers/1`) or while the
router is compiling (`collect_routes/1`). Both walk plugin modules
synchronously via `plugin_modules_sync/0`, which respects the same source-of-
truth precedence as the runtime chain, with one twist: an *explicit*
`Application.put_env(:barkpark, :plugins, [])` returns `[]` (the fresh-install
invariant); an *unset* value walks `Application.app_dir(:barkpark, "priv/plugins")`
on disk and folds bundled plugins in.

* `collect_workers(ctx \\ %{}) :: [Supervisor.child_spec()]` — called from
  `Barkpark.Application.start/2`. Folds plugin children into the host
  supervision tree.
* `collect_routes(ctx \\ %{}) :: [route_spec()]` — called at compile time
  from the `plugin_routes/1` macro in `BarkparkWeb.Router.Plugins`.

Per-plugin error isolation in both compile-time collectors: a raise, a
non-list return, or a missing module logs a warning and skips the plugin;
the host boot or compile continues.

### Lookup + ceremony

* `all/0 :: [%{module, manifest, name}]` — list every registered plugin.
  Cached read via `:persistent_term`.
* `lookup/1 :: (plugin_name :: String.t()) -> {:ok, entry} | :error` —
  by-name lookup; always goes through the GenServer.
* `register/2 :: (module, manifest) -> :ok | {:error, :no_plugin_name}` —
  used by discovery; rarely called by plugin code.
* `discover_and_register/0` and `discover_and_register/1` — walk the default
  discovery roots (or a custom list) and register every plugin found.
  Logs + skips on per-plugin errors; never raises.
* `run_all_codelist_seeders/0 :: :ok` — execute every plugin's seeders in
  alphabetical-by-name order, per-seeder isolation. Records into
  `Barkpark.Plugins.RunStatus`.
* `run_codelist_seeders_by_name/1 :: (binary) -> :ok | {:error, :unknown_plugin}` —
  per-plugin reload, used by the admin LV.
* `warn_duplicate_forms/0 :: :ok` — log one warning per `{plugin, callback}`
  pair that defines both the additive and resolver form. Idempotent; called
  from `init/1` after first discovery and again on every `register/2`.

### Lifecycle hook dispatcher

`Barkpark.Plugins.Hooks.fire/2` is the single internal driver behind every
lifecycle event. Plugin code never calls it directly — the Content context
fires hooks inside `create_document/4`, `upsert_document/4`,
`publish_document/4`, `unpublish_document/4`, `delete_document/4`. The
public-facing contract is `lifecycle_hooks/0` (§3); `Hooks.fire/2` is
documented here for reviewers who want to read the load-order and isolation
semantics in one place.

* Sequential `before_*` reduce — first `{:halt, reason}` short-circuits.
* Parallel `after_*` via `Task.async_stream` — 5s per-hook timeout,
  `on_timeout: :kill_task`, slow-hook warning at 100ms.
* Telemetry: `[:barkpark, :hooks, <event>]` (count metric on entry),
  `[:barkpark, :hooks, <event>, :hook]` (per-hook duration_ms).
* Plugin module source-of-truth: `Application.get_env(:barkpark, :plugins, [])`
  when set, else `Registry.all/0` sorted alphabetically — same as the resolver
  chain.

---

## 5. URL Paths Plugins Claim

The route highway. Plugins implement `register_routes/1` (§3) returning a
list of `route_spec()` tuples; the host router's
`BarkparkWeb.Router.Plugins.plugin_routes/1` macro reads them at compile time
and emits Phoenix.Router AST.

The host router wraps each `plugin_routes/1` call in its own scope +
live_session (or scope + pipe_through) block. The `scope:` opt selects which
auth bucket to emit:

| Scope tag | Filters routes whose `auth:` is | Typical host wrapper | Mount prefix |
|---|---|---|---|
| `:admin` (default) | `:admin` | `pipe_through :browser` + `live_session on_mount: …:admin` | `/studio` |
| `:ops` | `:ops` | `pipe_through :browser` + `live_session on_mount: …:ops` | `/admin` |
| `:public` | `:public` or `:none` | `pipe_through :browser` + `live_session` (no on_mount) | `/studio` |
| `:api` | `:api` | `pipe_through [:api, :require_admin]` (controller routes only) | `/v1/plugins` |

A 4-tuple route spec (`{:live, path, mod, action}`) has no opts and gets the
default `auth: :admin`. A 5-tuple reads `:auth` from the opts list; the macro
also strips `:auth` before forwarding opts to the Phoenix macro so the
underlying `live/4` / `get/4` call doesn't trip on the unknown key.

Path mounting: each spec writes the path relative to the host scope (e.g.
`"/onixedit/ping"`), and the host scope (`scope "/studio"`) contributes the
`/studio` prefix. The macro itself **does not** prepend the slug — plugins
embed their slug in the path so the route table reads naturally
(`/studio/onixedit/ping`, not `/studio/ping`).

Worked example — OnixEdit's four routes:

| Spec | Mounted at | Auth |
|---|---|---|
| `{:live, "/onixedit/ping", PingLive, :index}` | `/studio/onixedit/ping` | `:admin` (default) |
| `{:live, "/onixedit/bokbasen", Web.BokbasenLive, :index, auth: :ops}` | `/admin/onixedit/bokbasen` | `:ops` |
| `{:live, "/onixedit/staleness", Web.StalenessLive, :index, auth: :ops}` | `/admin/onixedit/staleness` | `:ops` |
| `{:get, "/onixedit/export/:dataset/:id", Web.ExportController, :show, auth: :api}` | `/v1/plugins/onixedit/export/:dataset/:id` | `:api` |

With `:plugins` set to `[]`, `collect_routes/1` returns `[]` and every
`plugin_routes/1` callsite expands to an empty list — the fresh-install
invariant from §2 holds even at the router level.

---

## 6. Auth Model

Recognised `auth:` opt values inside a `route_spec()` tail:

* `:admin` — strict admin gate, mounted under `/studio` with
  `LiveAuth.on_mount(:admin, …)`. **This is the default when `opts` is absent
  or doesn't carry an `:auth` key.**
* `:ops` — looser ops-team gate via `LiveAuth.on_mount(:ops, …)`, for the
  publish-ops console and equivalents. Mounted under `/admin`.
* `:public` — no auth, mounted under `/studio` with a bare `live_session`.
  Use for routes that legitimately need to be reachable without a session
  (e.g. an OAuth provider's callback). At the callsite the scope tag is
  `:public`; at the spec level the matching `auth:` value is `:none` —
  chosen so plugin authors read `auth: :none` as "no auth required."
* `:api` — controller routes only, mounted under `/v1/plugins` with the
  `[:api, :require_admin]` pipeline. No `live_session`.

Example — a plugin contributing a public OAuth callback alongside its admin
console:

```elixir
[
  {:live, "/myplugin/console", Console, :index},                    # default :admin
  {:get,  "/myplugin/oauth/callback", Callback, :show, auth: :none}  # public callback
]
```

The host router has two separate `plugin_routes/1` callsites — one inside
`scope "/studio"` with `scope: :admin` (emits the console route), one inside
`scope "/studio"` with `scope: :public` (emits the callback route). Each
callsite filters the plugin's specs to its own bucket and emits only those.

---

## 7. Plugin File Layout

Recommended on-disk structure:

```
api/
  priv/plugins/<slug>/
    plugin.json                          # validated manifest
    schemas/
      <type>.json                        # plugin-shipped schema JSON

  lib/barkpark/plugins/<slug>.ex         # the main plugin module
                                         # — `use Barkpark.Plugin`
  lib/barkpark/plugins/<slug>/           # plugin-internal namespace
    actions.ex
    lifecycle.ex
    export.ex
    schemas.ex
    ping_live.ex                         # Barkpark.Plugins.OnixEdit.PingLive
                                         #   (NOT under web/)
    bokbasen/                            # sub-namespaces
      auth.ex
      publish_worker.ex
    web/                                 # plugin-contributed LVs + controllers
      bokbasen_live.ex
      staleness_live.ex
      export_controller.ex

  test/barkpark/plugins/<slug>/          # tests mirror lib/
    web/
      bokbasen_live_test.exs
    tasks/
      bokbasen_status_test.exs
```

The `lib/barkpark/plugins/<slug>/` prefix is significant: the
`plugin_free_boot_test.exs` module-graph grep EXCLUDES this path when
checking that host code doesn't reference plugin modules. Everything inside
this tree is plugin-internal — name it freely. Everything outside is host
code, and the boot test will catch any plugin-name reference.

Plugin web modules live at `Barkpark.Plugins.<Slug>.Web.*`, not
`BarkparkWeb.*`. The `BarkparkWeb.*` namespace is reserved for host code.

---

## 8. Forbidden Surfaces

Plugins MUST NOT:

* Import or alias `Barkpark.Repo` directly. Use the `Barkpark.Content.*`
  functions in §3 (`list_documents/3`, `get_document/3`, `create_document/4`,
  `upsert_document/4`, `publish_document/4`, `unpublish_document/4`,
  `discard_draft/3`, `delete_document/4`, `apply_mutations/3`,
  `find_referencing_docs/2`, `disconnect_references/2`, `list_schemas/1`,
  `get_schema/2`, `upsert_schema/2`, `schema_hash_for_schema/1`,
  `list_revisions/4`, `restore_revision/4`, etc.). Direct `Repo` calls
  bypass the draft-prefix logic, the lifecycle-hook dispatcher, the PubSub
  broadcast, the deferred-broadcast queue, and the webhook dispatcher — they
  WILL break user-facing behaviour.
* Reach into `Barkpark.Plugins.Registry`'s internal state (the GenServer's
  `state.plugins` map, the `:persistent_term` snapshot, the
  `@resolver_callbacks` metadata). Use the public `collect_*` and `lookup/1`
  surfaces only.
* Modify `Application.put_env(:barkpark, :plugins, …)` at runtime. The
  registry's source-of-truth precedence reads this on every chain walk; a
  plugin that mutates it can silently break sibling plugins.
* Define modules in the `BarkparkWeb.*` namespace. That's reserved for host
  code. Plugin LVs + controllers live under `Barkpark.Plugins.<Slug>.Web.*`.
* Add routes at runtime via `Phoenix.Router`. Routes are compile-time only —
  use `register_routes/1` (§3) which the macro reads at compile time.
* Mount LiveViews directly in `lib/barkpark_web/live/`. Use the plugin
  namespace (§7) and contribute via `register_routes/1`.
* Reach into another plugin's modules. Cross-plugin coordination flows
  through the resolver chain — emit your callback contributions and let the
  Registry fold them with sibling-plugin contributions.

Boot-test enforced: with `:plugins` set to `[]`, host code under
`lib/barkpark/` + `lib/barkpark_web/` (excluding `lib/barkpark/plugins/`) must
not name any `Barkpark.Plugins.<Slug>` module. The boot test in
`api/test/barkpark/plugin_free_boot_test.exs` shells out to `grep -r` and
fails on a single hit.

---

## 9. Working Example — OnixEdit

OnixEdit is the canonical plugin shipped with Barkpark and exercises every
callback path. Walk through `api/lib/barkpark/plugins/onixedit.ex`:

| Surface | What OnixEdit does |
|---|---|
| `use Barkpark.Plugin, manifest_path: "../../../priv/plugins/onixedit/plugin.json"` | Loads + validates manifest at compile time. |
| `manifest/0` | Inherits the default — returns the manifest map literal. |
| `register_schemas/1` | Reads `priv/plugins/onixedit/schemas/book.json`, splices `Contributor` + `TextContent` subschemas via `book_raw_with_subschemas/0`, returns one `%SchemaDefinition{}` for `book` in dataset `"production"` with the document-level actions from `document_actions/0`. |
| `register_workers/1` | Returns `[Barkpark.Plugins.OnixEdit.Bokbasen.Auth]` — lazy OAuth2 token cache, folded into the host supervision tree between Vault and Endpoint. |
| `register_routes/1` | Four route specs across three scope tags (§5 table). |
| `validate_settings/1` | Inherits the default `:ok`. The declarative `settings_schema/0` typing is the only validation in v1. |
| `checkers/0` | Inherits `[]`. |
| `action_handlers/0` | `%{"publish_to_bokbasen" => &Actions.publish_to_bokbasen/3}`. |
| `external_sync_entries/0` | `%{"bokbasen" => %{label: "Bokbasen", states: %{…}}}` — 10 states from `pending` through `cancelled`, each with `{color, label}`. |
| `codelist_seeders/0` | `[&Barkpark.Codelists.EDItEUR.seed_bundled/0, &Barkpark.Codelists.EDItEUR.seed_thema/0]`. |
| `settings_schema/0` | Five Bokbasen credential fields, grouped, with `client_secret` masked + `:password`-typed. |
| `top_menu_entries/0` | One entry: `Bokbasen` tab → `/admin/onixedit/staleness`, icon `send`, order 50, active when path starts with `/admin/onixedit/`. |
| `desk_items/1` | A `:divider` + a `:link` to the staleness console. |
| `lifecycle_hooks/0` | `%{after_publish: [&Lifecycle.publish_to_bokbasen_if_book/1]}` — book publish auto-enqueues Bokbasen submission. Hook bails on non-book and on `ctx.source == :worker`. |
| `api_tests/0` | Four smokes — public schema fetch, admin schema fetch, Studio top-menu render, mutation round-trip with `cleanup` deleting the probe. |
| `content_renderer/3` | Pattern-matched on `"book"` — calls `OnixEdit.Export.to_string/1`, returns `{:ok, xml}` on success, `:skip` on `{:error, _}` or raise. |
| `test_connection/1` | Calls `Bokbasen.Auth.token/0`, returns `{:ok, %{message: "Bokbasen reachable: token OK."}}` or `{:error, "Bokbasen unreachable: …"}`. |
| `resolve_doc_actions/2` | Drops `"publish_to_bokbasen"` from `prev` while the book's `bp_export_status.state` is in `["queued", "staging", "staged", "polling"]`. The companion `action_handlers/0` entry stays registered — the handler still runs whenever the action isn't hidden. Proof of the Goal `barkpark-cjs` resolver refactor. |
| `codelist_requirements/0` | Plugin-internal helper (not a Plugin behaviour callback) — declares the ~70 EDItEUR list IDs the schema references. Consumed by `mix barkpark.codelists.seed`. |

The plugin's whole public-API contract with the host is the table above.
Every other Elixir module under `Barkpark.Plugins.OnixEdit.*` is internal
to the plugin — see `lib/barkpark/plugins/onixedit/` for the file tree.

---

## Appendix A — Migration Notes

For plugin authors who built against the pre-G2 surface:

* **Pre-G1:** the host hardcoded `Barkpark.Plugins.OnixEdit.Bokbasen.Auth`
  as a child spec inside `Barkpark.Application`. Now the supervisor reads
  `Plugins.Registry.collect_workers/1` — plugins fold their children in via
  `register_workers/1`.
* **Pre-G1 (s3, content_renderer split):** StudioLive's preview pane had a
  hardcoded clause that called `OnixEdit.Export.to_string/1` for `book`
  documents. Now the pane calls `Plugins.Registry.collect_content_renderer/3`
  — plugins claim the doc_type via `content_renderer/3`.
* **Pre-G2 (s3, route highway):** plugin admin LVs lived in the `BarkparkWeb.*`
  namespace (e.g. `BarkparkWeb.Admin.BokbasenLive` at `/admin/bokbasen`) and
  the host router hardcoded each one. Now plugin LVs live at
  `Barkpark.Plugins.<Slug>.Web.*` and contribute routes via
  `register_routes/1` (default return changed `:ok` → `[]`). The old URLs are
  kept alive by 301 redirects in `BarkparkWeb.Router` per the G3 Q3 grill
  decision.
* **Pre-G3 (s1, test_connection split):** the admin Plugin Settings LV had a
  host-side `defp test_connection("Bokbasen")` clause. Now it calls
  `Plugins.Registry.collect_test_connection/2` and every plugin opts in via
  `test_connection/1` (default `{:error, :not_implemented}`).
* **Pre-cjs (resolver refactor):** the eight collectors above were simple
  additive merges. Now each has a `resolve_X/2` companion — `(prev, ctx) ->
  next` — so plugins can drop, reorder, or amend running entries. The
  additive callbacks still work; the resolver default wraps them.

---

## Appendix B — Boot-Order Quirk

The Mix compiler does not always pick up `register_routes/1` changes: it
tracks the plugin module's source mtime, but the router's
`plugin_routes/1` macro reads the plugin's compiled `.beam` via
`Application.app_dir/2` and Phoenix's recompilation tracking doesn't see
through that indirection. After editing a plugin's `register_routes/1`,
nuke the router beam and recompile:

```bash
cd api
trash _build/dev/lib/barkpark/ebin/Elixir.BarkparkWeb.Router.beam
mix compile
```

Same dance for the test environment:

```bash
trash _build/test/lib/barkpark/ebin/Elixir.BarkparkWeb.Router.beam
MIX_ENV=test mix compile
```

This is a known paperflow follow-up — the long-term fix is either a Mix
manifest-level dependency declaration or moving `plugin_routes/1` to a
runtime read (which has its own trade-offs around `mix phx.routes` output).
Until the follow-up lands, the rebuild dance is the documented workaround.
