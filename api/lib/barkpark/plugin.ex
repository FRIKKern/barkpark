defmodule Barkpark.Plugin do
  @moduledoc """
  Behaviour + `use` macro for first-party Barkpark plugins — and the
  CANONICAL plugin contract. (The former HIGHWAY.md §8 and `ARCHITECTURE.md`
  contract sections are folded in here.)

  Compile-time discovery only. NO `Code.eval_*`, `Code.compile_string`, or any
  runtime macro evaluation (decision D7). Plugins are first-party trusted Elixir
  modules — the manifest JSON is read at compile time of the plugin module via
  `__using__/1`, validated, and frozen as a literal in `manifest/0`.

  ## The plugin contract

  A plugin is **schemas + business logic — never UI**. The host owns Studio
  chrome, every field renderer, every pill, every modal, every route table.
  Plugins extend the host by declaring metadata on schemas and exporting
  pure-function modules the host calls into.

  A plugin **MUST**:

    * Ship a manifest at `priv/plugins/<plugin_name>/plugin.json` declaring
      `plugin_name`, `module`, `version`, `capabilities`.
    * Implement a top-level module that `use Barkpark.Plugin`s the manifest
      and exports `register_schemas/1` (possibly returning `[]`).
    * Use the `<plugin_name>:<list_id>` codelist naming convention
      (e.g. `vlie:status_code`).
    * Use the `bp_<field>` prefix for non-standard fields stashed on
      documents (e.g. `bp_export_status`).

  A plugin **MUST NOT** (forbidden surfaces — boot-test enforced, see below):

    * Import or alias `Barkpark.Repo` directly — use `Barkpark.Content.*`.
      Direct `Repo` calls bypass the draft-prefix logic, the lifecycle-hook
      dispatcher, the PubSub broadcast, the deferred-broadcast queue, and the
      webhook dispatcher — they WILL break user-facing behaviour.
    * Define modules in `BarkparkWeb.*` or mount LiveViews under
      `lib/barkpark_web/live/`. That namespace is host-only; plugin web
      modules live at `Barkpark.Plugins.<Slug>.Web.*` and mount via
      `register_routes/1`.
    * Ship LiveViews, HEEx templates, or components into the Studio surface
      (`/studio`), nor CSS files, JavaScript, or Web Components.
    * Ship plugin-specific field renderers — extend the native v2 field
      components so all plugins benefit.
    * Add routes at runtime via `Phoenix.Router` — routes are compile-time
      only, through `register_routes/1`.
    * Reach into `Barkpark.Plugins.Registry` internals (GenServer state,
      `:persistent_term` snapshot) — use the public `collect_*` / `lookup/1`.
    * Mutate `Application.put_env(:barkpark, :plugins, …)` at runtime — the
      registry reads it on every chain walk; mutating it silently breaks
      sibling plugins.
    * Reach into another plugin's modules — cross-plugin coordination flows
      through the resolver chain only.
    * Broadcast plugin-specific PubSub messages when the generic
      `external_sync:<system>:<doc_id>` topic fits.
    * Reach into StudioLive assigns or socket state — use schema-declared
      actions, never a `phx-click` rooted in plugin code.

  ## Fresh-install invariant

  With `Application.put_env(:barkpark, :plugins, [])`, Barkpark must still
  boot, Studio must load, and the public API must serve exactly the 8 seed
  schemas.

  The host-code coupling rule is NOT "never name a plugin module" — that
  literal reading is false by construction: the host owns ALL Studio UI (a
  plugin ships none), so `Studio.SheetGrid` necessarily names
  `Barkpark.Plugins.Sheets.*` and the Bulldocs reader names
  `Barkpark.Plugins.Bulldocs.Events`; `application.ex` declares
  `Sheets.Supervisor` as an always-present core-static child; and host
  controllers/plugs back plugin `register_routes/1` surfaces. The ENFORCED
  rule is:

  > Host code under `lib/barkpark` + `lib/barkpark_web` (excluding
  > `lib/barkpark/plugins/`) must not name a **removable** plugin module on a
  > code path that runs while that plugin is disabled — and every legitimate
  > exception is enumerated in a reviewed allowlist.

  Regression bar: `api/test/barkpark/plugin_free_boot_test.exs` tier 5. It
  sweeps EVERY registered (== removable) plugin namespace — derived from
  `priv/plugins/*/plugin.json` so a newly added plugin is covered
  automatically — via AST detection of real module references (a mention in a
  `@moduledoc` or comment is not a coupling), and asserts the detected
  coupling set EQUALS the allowlist (`@sanctioned_host_plugin_coupling`,
  grouped by why each is sanctioned). A NEW reference outside the allowlist
  reds the gate. Tagged `:boot_test`, excluded from default runs — invoke
  with `mix test --only boot_test test/barkpark/plugin_free_boot_test.exs`.

  ## Route buckets

  `register_routes/1` specs carry an `auth:` opt that buckets each route into
  a host router scope (`BarkparkWeb.Router.Plugins.plugin_routes/1`). Beyond
  the studio-scoped basics (`:admin` default under `/studio`, `:ops` under
  `/admin`, `:public`/`:none`, `:api` and `:token` under `/v1/plugins`):

    * `:token_root` — `[:api, :require_token, RequireWriteForMutation]`
      pipeline mounted at the host `/v1` top level (the tasks plugin's
      `"/tasks/ready"` lands at `/v1/tasks/ready`). A GET/HEAD/OPTIONS route
      needs only a token; every other method ALSO needs `write`/`admin`
      permission (task-a87a3346b8ff736a — a read-only token used to claim,
      stamp and close tasks here).
    * `:ingest` — `RequireIngestToken` shared-secret pipeline under
      `/v1/plugins/<slug>` (the Bulldocs paper-ingest API).
    * `:public_root` — public LiveView at the host top-level scope with its
      OWN `root_layout:` and no studio chrome (the Bulldocs reader at
      `/papers/:slug`).

  Full per-bucket semantics in the `route_spec()` typedoc below.

  ## Schema registration is idempotent

  `Barkpark.Plugins.Bootstrap.register_all_schemas/0` (post-boot Task in
  `Barkpark.Application.start/2`; also called by `seeds.exs`) invokes every
  plugin's `register_schemas/1` and upserts via `Content.upsert_schema/2` —
  **idempotent on `(name, dataset)`**. A raise inside one plugin's callback
  logs and skips that plugin; sibling schemas still install. Never
  reintroduce manual `mix run -e "...register_schemas..."` registration.

  ## Schema-metadata columns a plugin can populate

  The host reads these `Barkpark.Content.SchemaDefinition` columns
  declaratively and renders generically:

  | Column | Type | What it drives |
  |---|---|---|
  | `fields` | `{:array, :map}` | Field definitions — v1 primitives + v2 nested types (composite, arrayOf, codelist, localizedText) |
  | `groups` | `{:array, :map}` | Tab bar in the editor pane (`%{"name", "title"}`; fields tag one `group`) |
  | `desk_groups` | `{:array, :map}` | Filter chips on the document-list pane; bookmarkable via `?desk=...` |
  | `actions` | `{:array, :map}` | Action-bar buttons in the editor header; kinds `link` / `event` / `modal` |
  | `initial_values` | `:map` | Deep-merged into new documents at create time; resolves `$today.year` |
  | `cross_validations` | `{:array, :map}` | `any`/`all` predicate rules; banner in the editor header |
  | `visibility` | `:string` | `"public"` (unauthenticated query API) or `"private"` (admin token) |

  ## Compile-cache gotcha (.beam)

  Mix does not reliably pick up `register_routes/1` changes: it tracks the
  plugin module's source mtime, but the router's `plugin_routes/1` macro
  reads the plugin's compiled `.beam` via `Application.app_dir/2`, and
  Phoenix's recompilation tracking doesn't see through that indirection.
  After editing a plugin's `register_routes/1`, nuke the router beam and
  recompile:

      cd api
      trash _build/dev/lib/barkpark/ebin/Elixir.BarkparkWeb.Router.beam
      mix compile

  Same dance for tests with `_build/test/...` + `MIX_ENV=test mix compile`.

  ## Usage

      defmodule MyApp.Plugins.Hello do
        use Barkpark.Plugin
      end

  By default the macro reads `plugin.json` from the parent directory of the
  using module's source file (e.g. for a plugin named `<name>`, a
  `priv/plugins/<name>/plugin.json` manifest beside a
  `priv/plugins/<name>/lib/<name>.ex` module). Pass
  `manifest_path: "..."` to override.

  ## Resolver callbacks (Goal barkpark-cjs)

  Eight of the collector callbacks (`checkers/0`, `action_handlers/0`,
  `external_sync_entries/0`, `codelist_seeders/0`, `settings_schema/0`,
  `top_menu_entries/0`, `desk_items/1`) and the brand-new `doc_actions`
  collector have a companion `resolve_X/2` callback of shape
  `(prev, ctx) -> next`. The host seeds `prev` with its built-in baseline
  (or, for `doc_actions`, the schema-declared list); each plugin sees the
  running accumulator and returns a transformed value, so plugins can
  mutate, reorder, or remove entries — not just append.

  Both the additive form and the resolver form are listed in
  `@optional_callbacks`. The `__using__/1` macro supplies a `defoverridable`
  default for every resolver that lifts the additive return value into
  the resolver shape (concatenation for list-shaped callbacks; `Map.merge`
  for map-shaped ones — `action_handlers`, `external_sync_entries`,
  `codelist_seeders` returns a list of zero-arg functions; `settings_schema`
  returns a list of fields). When neither form is implemented, the default
  returns `prev` unchanged (identity).
  """

  @typedoc """
  An action handler invoked by `StudioLive.dispatch_action/4` for a named
  schema action. Receives the document id, dataset, and a mode flag
  (`:dryrun` / `:real`); returns a tagged tuple the host folds into its
  modal / flash assigns.
  """
  @type action_handler ::
          (doc_id :: String.t(), dataset :: String.t(), mode :: :dryrun | :real ->
             {:ok, term()} | {:error, term()})

  @typedoc """
  A declarative field shown in the admin Plugin Settings LiveView. The
  `:name` is dot-namespaced (`"<settings-row>.<key>"`); the leading
  segment selects which `plugin_settings` row the value lands in, and
  the remainder is the flat key inside that row. Example:
  `"bokbasen.api_base"` writes `%{"api_base" => …}` to the `"bokbasen"`
  row — the exact shape `Bokbasen.Client` reads back.
  """
  @type setting_field :: %{
          required(:name) => String.t(),
          required(:type) => :string | :password | :url | :select | :boolean,
          required(:label) => String.t(),
          optional(:required) => boolean(),
          optional(:options) => [String.t()],
          optional(:default) => term(),
          optional(:hint) => String.t(),
          optional(:group) => String.t(),
          optional(:masked) => boolean(),
          optional(:placeholder) => String.t()
        }

  @typedoc """
  A top-menu tab contributed by a plugin. Rendered in the Studio topbar
  after the host's built-in tabs (Structure · Media · API). The
  `:active_when` field is matched against the current request path —
  use a string for a prefix match or a `Regex` for richer rules. When
  absent, the tab is active only when the current path equals `:path`.

  Built-in host tabs use `:order` values 10/20/30; plugin tabs default
  to 100 so they sort after the host's tabs unless overridden.
  """
  @type top_menu_entry :: %{
          required(:label) => String.t(),
          required(:path) => String.t(),
          optional(:icon) => String.t(),
          optional(:order) => integer(),
          optional(:active_when) => String.t() | Regex.t()
        }

  @typedoc """
  A structural desk item contributed by a plugin. Rendered in the root
  Structure pane after the host's auto-generated schema items. The
  shape is a tagged map keyed by `:type` so PaneBuilder can dispatch:

    * `:link`           — clickable row that navigates to `:path`
    * `:document_list`  — renders a regular doc-list pane for `:doc_type`,
                          pre-filtered via the optional `:filter` map
                          (shape matches `Content.list_documents/3`'s
                          `:filter_map` option)
    * `:divider`        — visual separator with optional `:label`
    * `:nested`         — collapsible folder containing `:items`
  """
  # `:requires_schema` (optional, on `:link`/`:divider`) names a schema type the
  # node is gated on when the desk is workspace-scoped — for nodes that carry no
  # schema type of their own (e.g. an admin-page link). The host drops them in a
  # workspace where that type is not registered; see
  # `Barkpark.Structure.scope_plugin_nodes/4`.
  @type desk_item ::
          %{
            required(:type) => :link,
            required(:label) => String.t(),
            required(:path) => String.t(),
            optional(:icon) => String.t(),
            optional(:requires_schema) => String.t()
          }
          | %{
              required(:type) => :document_list,
              required(:label) => String.t(),
              required(:doc_type) => String.t(),
              optional(:filter) => map(),
              optional(:icon) => String.t()
            }
          | %{
              required(:type) => :divider,
              optional(:label) => String.t(),
              optional(:requires_schema) => String.t()
            }
          | %{
              required(:type) => :nested,
              required(:label) => String.t(),
              required(:items) => [map()],
              optional(:icon) => String.t()
            }

  @typedoc """
  A per-document action shown in the Studio editor header.

  The shape mirrors the schema-declared `:actions` entry that
  `StudioLive.schema_actions/1` reads today — string-keyed map with
  `"name"`, `"label"`, `"kind"` (`"link"` or `"modal"`), and optional
  `"href"`, `"icon"`, `"modal"` payload. `resolve_doc_actions/2` operates
  on a list of these so plugins can drop, reorder, or amend per-doc
  actions based on the live document payload (e.g. hide a "Publish"
  button while the worker is mid-submission).
  """
  @type doc_action :: %{
          required(String.t()) => term()
        }

  @typedoc """
  A single RAW (unresolved) content-graph edge a plugin projects from a
  document. `from_id`/`to_id` are scope-relative slug `doc_id`s (the core
  Projector pass coalesces them to published twins and resolves dangling).

  `extract_edges/2` is PURE — no DB, no `get_document`. It returns these raw
  edges; the core `Barkpark.EdgeProjector.Projector` pass resolves targets and
  drops the unstorable (dangling) ones. A plugin that resolves targets itself
  double-counts DB round-trips and runs at unexpected times — don't.
  """
  @type edge :: %{
          from_id: String.t(),
          to_id: String.t(),
          kind: String.t()
        }

  @typedoc """
  A registered checker — pair of `{name, module}` where `module`
  implements `Barkpark.Plugins.Checker`.
  """
  @type checker :: {String.t() | atom(), module()}

  @typedoc """
  HTTP verb tag used in the leading position of a controller-style
  `route_spec()` tuple. `:options` exists for CORS preflights on the
  `:public_api` bucket — the router only matches declared verbs, so a
  browser-reachable cross-origin POST needs an OPTIONS sibling route.
  """
  @type http_verb :: :get | :post | :put | :delete | :patch | :options

  @typedoc """
  A single Phoenix route a plugin contributes via `register_routes/1`.
  Tagged-tuple DSL — the first element selects LiveView vs. controller
  dispatch (Goal barkpark-G2 Q1 locked):

    * `{:live, path, module, action}` — LiveView, named action atom
    * `{:live, path, module, action, opts}` — LiveView with options
    * `{verb, path, controller, action}` — controller action for the
      given HTTP verb
    * `{verb, path, controller, action, opts}` — controller with options

  `opts` is a keyword list. Recognised keys:

    * `auth: :admin | :ops | :public | :none | :api | :token | :token_root | :ticket_key | :ingest | :public_root | :public_api` —
      auth gate. Defaults to `:admin`. Buckets routes into the matching scope
      when the host router's `plugin_routes/1` macro expands:
        - `:admin` — admin scope (LiveAuth.:admin, mounts under `/studio`)
        - `:ops`   — ops scope (LiveAuth.:ops, mounts under `/admin`)
        - `:public` / `:none` — no auth gate (mounts under `/studio`)
        - `:api`   — API pipeline + admin required (mounts under `/v1/plugins`)
        - `:token` — API pipeline + token required, NOT admin (mounts under
          `/v1/plugins`)
        - `:token_root` — API pipeline + token required, NOT admin; root-mounted
          sibling of `:token` at the host `/v1` top-level scope (so a route
          `"/tasks/ready"` lands at `/v1/tasks/ready`). A non-GET route on this
          bucket ALSO requires `write`/`admin` permission — the gate is
          method-derived (`Plugs.RequireWriteForMutation`), so a new mutating
          spec is closed by default rather than ungated by omission
        - `:ticket_key` — the low-trust ticket-key tier (RequireTicketKey, NOT an
          api_tokens bearer); root-mounted at the host `/v1` top-level scope (so
          a route `"/tickets"` lands at `/v1/tickets`)
        - `:ingest` — ingest-token pipeline (RequireIngestToken); controller
          routes under `/v1/plugins`
        - `:public_root` — public LiveView at the host's top-level scope with
          its OWN root layout (see `:root_layout`), no studio chrome
        - `:public_api` — anonymous CORS-open JSON pipeline (PublicCors, NO
          auth plug) under `/v1/plugins` — for explicitly-public plugin APIs
          like Pulse; the plugin owns its own abuse caps
    * `root_layout: {module, atom}` — REQUIRED for `:public_root` LiveView
      routes; the full-document root layout the macro applies via a per-route
      live_session. Ignored for other buckets.
    * `as: atom()` — Phoenix route name (`Routes.<as>_path/2`).

  Paths join under the macro's wrapping scope; specs should declare
  relative paths that include the plugin slug (e.g. `"/onixedit/ping"`
  yields `/studio/onixedit/ping` under `:admin`).
  """
  @type route_spec ::
          {:live, path :: String.t(), module :: module(), action :: atom()}
          | {:live, path :: String.t(), module :: module(), action :: atom(), opts :: keyword()}
          | {http_verb(), path :: String.t(), controller :: module(), action :: atom()}
          | {http_verb(), path :: String.t(), controller :: module(), action :: atom(),
             opts :: keyword()}

  # ── Lifecycle hook types (Goal barkpark-9lq) ─────────────────────────

  @typedoc """
  Document lifecycle event a plugin may listen to. The eight events
  bracket the four mutating Content operations (save/publish/unpublish/
  delete) — `before_*` runs synchronously and may halt the operation,
  `after_*` runs asynchronously and its return value is discarded.
  """
  @type lifecycle_event ::
          :before_save
          | :after_save
          | :before_publish
          | :after_publish
          | :before_unpublish
          | :after_unpublish
          | :before_delete
          | :after_delete

  @typedoc """
  The payload passed to every lifecycle hook function.

  * `:event`     — which lifecycle event fired
  * `:doc`       — the document being acted on (post-change for after_*,
                    proposed shape for before_*)
  * `:dataset`   — dataset name (e.g. `"production"`)
  * `:prev_doc`  — previous on-disk shape, or `nil` for creates
  * `:ctx`       — call-site metadata; `:source` lets workers bail out
                    of their own re-fired hooks via the recursion guard
  """
  @type hook_payload :: %{
          event: lifecycle_event(),
          doc: map(),
          dataset: String.t(),
          prev_doc: map() | nil,
          ctx: %{source: :studio | :api | :cli | :worker, user_id: String.t() | nil}
        }

  @typedoc """
  Return value of a `before_*` hook. `:ok` lets the operation proceed;
  `{:halt, reason}` cancels it — the host surfaces
  `{:error, {:halted, reason}}` to the caller. Per plan §0 Q2 there is
  NO `{:ok, map()}` mutation variant.
  """
  @type before_hook_result :: :ok | {:halt, String.t()}

  @typedoc """
  Return value of an `after_*` hook. Always discarded; declared as
  `any()` so plugins may return whatever they want without typespec
  noise.
  """
  @type after_hook_result :: :ok | any()

  @typedoc """
  A lifecycle hook function. Per plan §0 Q3 plugins register **capture
  references** (`&MyMod.fun/1`), not `{module, function}` tuples — the
  host invokes them directly.
  """
  @type hook_fn :: (hook_payload() -> before_hook_result() | after_hook_result())

  @typedoc """
  The map a plugin returns from `lifecycle_hooks/0`. Each key is an
  event; each value is the ordered list of hook functions to invoke
  when that event fires.
  """
  @type lifecycle_hooks :: %{optional(lifecycle_event()) => [hook_fn()]}

  # ── API test runner types (Goal barkpark-bsp) ────────────────────────

  @typedoc """
  A single assertion the API test runner evaluates against a response.

  Tagged-tuple shape so the runner can dispatch via pattern match. The
  fixed set is locked by plan §0 Q2 (`2026-05-18-api-test-runner.html`):

  - `{:status, 200}` — HTTP status must equal the given integer
  - `{:body_contains, "needle"}` — raw response body includes the substring
  - `{:body_regex, ~r/.../}` — raw response body matches the regex
  - `{:json_path, [...keys...], fn val -> bool end}` — decoded JSON at
    the given key path satisfies the predicate
  - `{:json_keys_include, ["a", "b"]}` — top-level JSON map has these keys
  - `{:header, "x-foo", "bar"}` — response header equals the string, or
    satisfies the predicate when the third element is a 1-arity function
  - `:not_empty` — response body is non-empty
  - `{:duration_under_ms, 500}` — request duration under N milliseconds
  """
  @type api_test_assert ::
          {:status, integer()}
          | {:body_contains, String.t()}
          | {:body_regex, Regex.t()}
          | {:json_path, list(), (any() -> boolean())}
          | {:json_keys_include, [String.t()]}
          | {:header, String.t(), String.t() | (String.t() -> boolean())}
          | :not_empty
          | {:duration_under_ms, non_neg_integer()}

  @typedoc """
  Declarative auth mode for an API test spec (plan §0 Q3).

  - `:none` — no Authorization header
  - `:admin` — runner injects the configured admin/dev token
  - `{:token, "raw-token"}` — literal bearer token
  - `{:plugin_setting, "key"}` — runner reads the value from the
    plugin's stored settings row and uses it as a bearer token
  """
  @type api_test_auth ::
          :none
          | :admin
          | {:token, String.t()}
          | {:plugin_setting, String.t()}

  @typedoc """
  A single API test spec (plan §0 Q5 — single-request only). The
  runner fires `:method` + `:path` against the configured base_url,
  evaluates `:asserts`, then ALWAYS fires every `:cleanup` step in
  order, regardless of pass/fail (Q1).
  """
  @type api_test_spec :: %{
          required(:name) => String.t(),
          required(:method) => :get | :post | :put | :patch | :delete,
          required(:path) => String.t(),
          optional(:headers) => %{String.t() => String.t()},
          optional(:body) => map() | nil,
          optional(:auth) => api_test_auth(),
          optional(:asserts) => [api_test_assert()],
          optional(:cleanup) => [
            %{method: atom(), path: String.t(), headers: map() | nil, body: map() | nil}
          ]
        }

  # ── CLI command types (M1 — capabilities manifest) ───────────────────

  @typedoc """
  A single CLI command a plugin contributes to the `/v1/capabilities`
  manifest. Each map matches the frozen `commands[]` per-command schema in
  `docs/cli/manifest.schema.json` field-for-field — the controller folds
  these straight into `commands[]` (after stamping provenance), so the field
  names are load-bearing.

  Plugins do NOT set `source` themselves; the capabilities controller derives
  `source: "plugin:<name>"` from the owning plugin's manifest during the fold.
  """
  @type cli_command :: %{
          required(:id) => String.t(),
          required(:noun) => String.t(),
          required(:verb) => String.t(),
          required(:summary) => String.t(),
          required(:http) => %{
            required(:method) => String.t(),
            required(:path_template) => String.t()
          },
          required(:auth_tier) => String.t(),
          required(:args) => [
            %{
              required(:name) => String.t(),
              required(:required) => boolean(),
              required(:type) => String.t(),
              required(:summary) => String.t()
            }
          ],
          required(:flags) => [
            %{
              required(:name) => String.t(),
              required(:type) => String.t(),
              required(:summary) => String.t(),
              optional(:default) => term(),
              optional(:repeatable) => boolean()
            }
          ],
          # `writes` is a SAFETY bit, not decoration: the MCP bridge derives
          # ReadOnlyHint from it and `bp` gates the prod write confirmation on
          # it. `required(...)` here is a TYPESPEC — dialyzer-only, zero runtime
          # force. The runtime owner is
          # `Barkpark.Plugins.Capabilities.declare_writes_fail_closed/2`, which
          # emits `writes: true` (assume it mutates) plus a Logger.warning for
          # any plugin command that omits the key. Declare it anyway: a
          # fail-closed default makes a plugin READ look like a mutator.
          required(:writes) => boolean(),
          required(:batch) => boolean(),
          required(:paginated) => boolean(),
          required(:dry_run) => boolean(),
          required(:default_output) => String.t(),
          optional(:scoped_prefix) => String.t() | nil
        }

  @callback manifest() :: map()

  @doc """
  Plugin contributes Phoenix routes that mount under the host's `/studio` scope.

  Each spec is a tagged tuple:

      {:live, path, module, action}             # LiveView, default action :index
      {:live, path, module, action, opts}       # LiveView with options
      {:get, path, controller, action}          # controller action
      {:get, path, controller, action, opts}    # controller with options

  `opts` is a keyword list. Recognised keys:

    * `auth: :admin | :ops | :public | :none | :api | :token | :token_root | :ticket_key | :ingest | :public_root` —
      auth gate (defaults to `:admin`). Buckets the route into the matching
      `plugin_routes/1` scope: `:admin` under `/studio`, `:ops` under `/admin`,
      `:public`/`:none` under `/studio` with no gate, `:api` under
      `/v1/plugins` with the API pipeline + admin required, `:token` under
      `/v1/plugins` with the API pipeline + token required (not admin),
      `:token_root` at the host's `/v1` top-level scope with the API pipeline +
      token required, plus `write`/`admin` on every non-GET method
      (root-mounted sibling of `:token`),
      `:ticket_key` at the host's `/v1` top-level scope gated by
      RequireTicketKey (the low-trust ticket-key tier),
      `:ingest` under `/v1/plugins` with the RequireIngestToken pipeline,
      `:public_root` at the host's top-level scope with the spec's own
      `root_layout:`.
    * `root_layout: {module, atom}` — REQUIRED for `:public_root` routes; the
      full-document root layout applied via a per-route live_session.
    * `as: atom()` — Phoenix route name (`Routes.<as>_path/2`).

  Paths join under the macro's wrapping scope; plugins declare relative
  paths that include the plugin slug (e.g. `"/onixedit/ping"` resolves
  to `/studio/onixedit/ping` under the `:admin` scope).

  `ctx` is the call-time context — `%{scope: :admin}` from the host router
  macro today, may grow later. Pattern-match defensively or ignore it.

  The default no-op returns `[]`; plugins opt in by overriding.
  """
  @callback register_routes(ctx :: map()) :: [route_spec()]

  @callback register_workers(any()) :: [Supervisor.child_spec()]

  @doc """
  Contribute Oban Cron entries to be merged into the host's Oban config
  at boot.

  Returns a list of crontab elements matching Oban's
  `Oban.Plugins.Cron` `:crontab` shape — each is either a
  `{cron_expr, worker_module}` pair or a `{cron_expr, worker_module, opts}`
  triple, where `cron_expr` is a 5-field POSIX cron string (e.g.
  `"* * * * *"`).

  The default no-op returns `[]`; plugins opt in by overriding. The host
  (`Barkpark.Application.start/2`) appends every plugin's contribution to
  the `Oban.Plugins.Cron` entry's `:crontab` before starting Oban.
  """
  @callback oban_crontab() :: [
              {String.t(), module()} | {String.t(), module(), keyword()}
            ]

  @callback register_schemas(keyword()) :: [Barkpark.Content.SchemaDefinition.t()]
  @callback validate_settings(map()) :: :ok | {:error, [{atom(), String.t()}]}

  @callback checkers() :: [checker()]
  @callback action_handlers() :: %{optional(String.t()) => action_handler()}
  @callback external_sync_entries() :: %{optional(String.t()) => map()}
  @callback codelist_seeders() :: [(-> any())]
  @callback settings_schema() :: [setting_field()]
  @callback top_menu_entries() :: [top_menu_entry()]
  @callback desk_items(dataset :: String.t()) :: [desk_item()]

  # ── Resolver callbacks (Goal barkpark-cjs) ───────────────────────────
  #
  # Each `resolve_X/2` is `(prev, ctx) -> next`. The host seeds prev with
  # its built-in baseline; plugins thread the accumulator. Default impls
  # (supplied by `__using__/1` via `defoverridable`) lift the additive
  # form into the resolver shape — see module doc for details.

  @doc """
  Resolve the list of registered checkers.

  `ctx` shape: `%{dataset: String.t()}`.

  Default implementation lifts `checkers/0` via `prev ++ result`.
  """
  @callback resolve_checkers(prev :: [checker()], ctx :: %{dataset: String.t()}) ::
              [checker()]

  @doc """
  Resolve the action-name → handler-fn map.

  `ctx` shape: `%{dataset: String.t(), doc_id: String.t(),
  doc_type: String.t(), doc: map()}`.

  Default implementation lifts `action_handlers/0` via `Map.merge(prev, result)`.
  """
  @callback resolve_action_handlers(
              prev :: %{optional(String.t()) => action_handler()},
              ctx :: %{
                dataset: String.t(),
                doc_id: String.t(),
                doc_type: String.t(),
                doc: map()
              }
            ) :: %{optional(String.t()) => action_handler()}

  @doc """
  Resolve the external-sync entries registry.

  `ctx` shape: `%{dataset: String.t()}`.

  Default implementation lifts `external_sync_entries/0` via
  `Map.merge(prev, result)`.
  """
  @callback resolve_external_sync_entries(
              prev :: %{optional(String.t()) => map()},
              ctx :: %{dataset: String.t()}
            ) :: %{optional(String.t()) => map()}

  @doc """
  Resolve the list of zero-arg codelist seeder functions.

  `ctx` shape: `%{dataset: String.t()}`.

  Default implementation lifts `codelist_seeders/0` via `prev ++ result`.
  Note that the additive `codelist_seeders/0` returns a list (not a map)
  even though seeders run for side-effect — concatenation is the natural
  lift.
  """
  @callback resolve_codelist_seeders(
              prev :: [(-> any())],
              ctx :: %{dataset: String.t()}
            ) :: [(-> any())]

  @doc """
  Resolve the declarative settings-form field list shown by the admin
  Plugin Settings LiveView.

  `ctx` shape: `%{plugin_name: String.t()}`.

  Default implementation lifts `settings_schema/0` via `prev ++ result`.
  """
  @callback resolve_settings_schema(
              prev :: [setting_field()],
              ctx :: %{plugin_name: String.t()}
            ) :: [setting_field()]

  @doc """
  Resolve the Studio top-menu tab list.

  `ctx` shape: `%{dataset: String.t(), current_path: String.t()}`.

  Default implementation lifts `top_menu_entries/0` via `prev ++ result`.
  """
  @callback resolve_top_menu_entries(
              prev :: [top_menu_entry()],
              ctx :: %{dataset: String.t(), current_path: String.t()}
            ) :: [top_menu_entry()]

  @doc """
  Resolve the root Structure pane's desk-item list.

  `ctx` shape: `%{dataset: String.t(), current_path: String.t()}`.

  Default implementation lifts `desk_items(ctx.dataset)` via
  `prev ++ result`.
  """
  @callback resolve_desk_items(
              prev :: [desk_item()],
              ctx :: %{dataset: String.t(), current_path: String.t()}
            ) :: [desk_item()]

  @doc """
  Resolve the per-document action list shown in the Studio editor
  header.

  `ctx` shape: `%{dataset: String.t(), doc_id: String.t(),
  doc_type: String.t(), doc: map()}`.

  No additive predecessor — `prev` is seeded by the host with the
  schema-declared `:actions` list. The default implementation returns
  `prev` unchanged (identity).
  """
  @callback resolve_doc_actions(
              prev :: [doc_action()],
              ctx :: %{
                dataset: String.t(),
                doc_id: String.t(),
                doc_type: String.t(),
                doc: map()
              }
            ) :: [doc_action()]

  # ── Content-graph edge extraction (Goal ges/graph-edge-seam) ─────────

  @doc """
  Project the RAW (unresolved) content-graph edges a document contributes.

  Called by the core `Barkpark.EdgeProjector.Projector` pass via
  `Barkpark.Plugins.Registry.collect_edge_extractors/1`. MUST be PURE — no DB,
  no `get_document`. Return the raw edges off the document payload ONLY;
  dangling resolution belongs to the core Projector pass, never here.

  Default implementation (supplied by `use Barkpark.Plugin`) returns `[]` —
  it ignores its first arg, so a `nil` doc is safe in the default.
  """
  @callback extract_edges(doc :: map(), ctx :: map()) :: [edge()]

  @doc """
  Resolve the content-graph edge list for one document.

  No additive predecessor in the registry metadata — the `@resolver_callbacks`
  entry is `{nil, nil, nil, :none}` (the `resolve_doc_actions` precedent), so
  plugins implement `resolve_extract_edges/2` DIRECTLY. The default
  implementation supplied by `use Barkpark.Plugin` provides the additive lift
  `prev ++ extract_edges(ctx.doc, ctx)` via a `function_exported?` guard.

  A plugin override MUST guard a `nil` `ctx.doc` and return `prev` unchanged —
  unlike `resolve_doc_actions`, this seam reads `ctx.doc`, and the
  `{nil, nil, nil, :none}` entry skips the registration-time fingerprint, so a
  nil-doc crash surfaces only at collection time. Guard it.
  """
  @callback resolve_extract_edges(
              prev :: [edge()],
              ctx :: %{optional(:doc) => map()}
            ) :: [edge()]

  @doc """
  Resolve the list of API test specs the runner can fire on demand.

  `ctx` shape: `%{}` — no per-callback context today; the runner fires
  every spec with the same base_url/auth resolution rules regardless of
  the calling plugin.

  Default implementation lifts `api_tests/0` via `prev ++ result`.
  Plugins wanting to reorder, remove, or amend sibling-plugin specs
  override `resolve_api_tests/2` directly.
  """
  @callback resolve_api_tests(
              prev :: [api_test_spec()],
              ctx :: map()
            ) :: [api_test_spec()]

  # ── Lifecycle hooks callback (Goal barkpark-9lq) ─────────────────────

  @doc """
  Declare lifecycle event listeners.

  Returns a map of `lifecycle_event() => [hook_fn()]`. Each hook function
  receives `hook_payload()` and returns:

  - `:ok` — pass (before_*) or notification (after_*)
  - `{:halt, reason}` — cancel the operation (before_* only); the host
    surfaces `{:error, {:halted, reason}}` to the caller

  `after_*` hooks run asynchronously via `Task.async_stream` (5s timeout)
  and their return values are discarded.

  Recursion guard: the plugin's hook function should inspect
  `payload.ctx.source` and bail when it equals `:worker` — this prevents
  a worker like `Bokbasen.PublishWorker` (which calls
  `Content.publish_document/3` to write final state) from re-firing its
  own `after_publish` hook.
  """
  @callback lifecycle_hooks() :: lifecycle_hooks()

  # ── Content renderer callback (Goal barkpark-G1, task s3) ────────────

  @typedoc """
  Return value of a `content_renderer/3` callback. `{:ok, iodata}` wins
  the first-wins resolver chain in `Plugins.Registry.collect_content_renderer/3`
  (StudioLive pipes the iodata straight into the preview pane's `<pre>`);
  `:skip` falls through to the next plugin.
  """
  @type content_renderer_result :: {:ok, iodata()} | :skip

  @doc """
  Plugin contributes a content-preview renderer for a doc_type.

  Called by StudioLive's preview pane via
  `Plugins.Registry.collect_content_renderer/3`. First plugin to return
  `{:ok, iodata}` wins (priority via the same load-order chain other
  resolvers use); subsequent plugins are skipped. When every plugin
  returns `:skip` the host returns `:none` and the preview pane is
  hidden — no special-case wiring per plugin.

  `ctx` carries `:current_user`, `:dataset`, `:perspective`, and
  whatever else the StudioLive context provides. Plugins should
  pattern-match on `doc_type` and return `:skip` for types they don't
  handle. Failures inside the callback should be caught by the plugin
  (`rescue :skip`) so the host never crashes because a renderer
  exploded mid-edit.
  """
  @callback content_renderer(doc_type :: String.t(), content :: map(), ctx :: map()) ::
              content_renderer_result()

  # ── Connection-test callback (Goal barkpark-G3, task s1) ─────────────

  @typedoc """
  Return value of a `test_connection/1` callback. `{:ok, payload}` is
  surfaced as a success flash by `Plugins.Registry.collect_test_connection/2`
  (the admin Plugin Settings LiveView reads `payload[:message]`); `{:error,
  reason}` is surfaced as the failure flash.
  """
  @type test_connection_result :: {:ok, payload :: map()} | {:error, reason :: term()}

  @doc """
  Plugin tests an external connection (API auth, ingestion endpoint, etc.)
  using the settings the user has configured. Returns `{:ok, payload}`
  with details for the UI banner or `{:error, reason}` for the failure
  flash.

  Called from `Plugins.Registry.collect_test_connection/2` — first-wins
  by plugin name. The default returns `{:error, :not_implemented}` so
  plugins without a real connection (e.g. format-only plugins) opt out
  cleanly.
  """
  @callback test_connection(settings :: map()) :: test_connection_result()

  # ── API test runner callback (Goal barkpark-bsp) ─────────────────────

  @doc """
  Declare API test specs the runner can fire on demand.

  Returns a list of `api_test_spec()` maps. Each spec is fired by
  `Barkpark.ApiTestRunner` via `Req` against the configured base_url
  (Application env `:api_test_runner_base_url`, default `http://localhost:4000`).

  Asserts are evaluated per-spec; the runner returns structured results
  (pass/fail/error) per the locked decisions in plan §0 (barkpark-bsp).

  Mutating tests should declare `:cleanup` steps — the runner ALWAYS
  fires cleanup after asserts, regardless of pass/fail.
  """
  @callback api_tests() :: [api_test_spec()]

  # ── CLI command callback (M1 — capabilities manifest) ────────────────

  @doc """
  Declare ergonomic CLI verbs the plugin contributes to the
  `/v1/capabilities` manifest's `commands[]` array.

  Returns a list of `cli_command()` maps, each matching the frozen
  `commands[]` per-command schema in `docs/cli/manifest.schema.json`
  exactly. The capabilities controller lifts these via
  `resolve_cli_commands/2`, collects them with
  `Plugins.Registry.collect_cli_commands/1`, stamps provenance
  (`source: "plugin:<name>"`), and folds them into `commands[]`.

  Default implementation (supplied by `use Barkpark.Plugin`) returns `[]`.
  """
  @callback cli_commands() :: [cli_command()]

  @doc """
  Resolve the list of CLI commands the plugin contributes.

  `ctx` shape: `%{}` — no per-callback context today; the capabilities
  controller folds every command with the same provenance-stamping rules
  regardless of the calling plugin.

  Default implementation lifts `cli_commands/0` via `prev ++ result`.
  Plugins wanting to reorder, remove, or amend sibling-plugin commands
  override `resolve_cli_commands/2` directly.
  """
  @callback resolve_cli_commands(
              prev :: [cli_command()],
              ctx :: map()
            ) :: [cli_command()]

  # ── Per-workspace enablement declaration (ssp-w1-plugin-enablement) ───
  #
  # Two OPTIONAL callbacks that let a plugin declare, at compile time, how it
  # participates in a fresh workspace's Desk Structure. The `__using__/1`
  # defaults (`default_enabled?/0 => true`, `structure_placement/0 => :plugins`)
  # keep every existing plugin unchanged unless it overrides them. The
  # per-workspace `workspaces.settings["plugins"]` override map (resolved by
  # `Barkpark.Plugins.Enablement.effective/1`) wins over these declarations —
  # this is only the baked-in default a fresh workspace starts from.

  @doc """
  Whether this plugin is SURFACED by default in a fresh workspace's Studio /
  desk. `false` means the plugin is still installed/loaded (schemas, routes,
  and workers all register at boot) but hidden from the three surfacing
  collectors — desk items, top-menu tabs, doc actions — until an admin turns
  it on for that workspace. The default (`use Barkpark.Plugin`) is `true`.
  """
  @callback default_enabled?() :: boolean()

  @doc """
  Where this plugin's desk items land in the tiered Desk Structure:

    * `:main`     — top-level in the MAIN tier alongside Papers/Sheets/Tasks
    * `:plugins`  — under the collapsed "Plugins" node (the default)
    * `:top_menu` — out of the tree entirely; reached via a top-menu tab

  Consumed by the tiered-tree builder; a per-workspace override promotes or
  demotes a specific plugin. The default (`use Barkpark.Plugin`) is `:plugins`.
  """
  @callback structure_placement() :: :main | :plugins | :top_menu

  @doc """
  The set of schema `name`s this plugin OWNS — the harvested truth the host's
  Desk Structure builder uses to (a) claim a plugin's types for its top-menu
  surface so they never leak into …Rest, and (b) reject a plugin-owned PRIVATE
  schema from the host "Settings" AND "Content" catch-alls (issue #8463 —
  "Settings" is for host singletons like siteSettings/navigation, "Content" is
  the generic consumer-content fallback; neither is for a plugin's private
  types). Ownership, not enablement: a DISABLED plugin still owns its types
  (they fall to …Rest, never Settings/Content).

  The `use Barkpark.Plugin` default derives this from the plugin's own
  `register_schemas([])` (`|> Enum.map(& &1.name)`), wrapped in a `try/rescue`
  that degrades to `[]` — one malformed plugin must never kill the desk build
  (mirrors `Barkpark.Plugins.Bootstrap`'s guard). Schema `name`s are
  dataset-independent, so the empty-opts call is safe. A plugin whose
  `register_schemas/1` is EXPENSIVE (e.g. frt parses 25 JSON files) SHOULD
  override this with a cheap compile-time list so a desk build never re-parses.
  """
  @callback owned_schema_types() :: [String.t()]

  @optional_callbacks register_routes: 1,
                      register_workers: 1,
                      oban_crontab: 0,
                      default_enabled?: 0,
                      structure_placement: 0,
                      owned_schema_types: 0,
                      register_schemas: 1,
                      validate_settings: 1,
                      checkers: 0,
                      action_handlers: 0,
                      external_sync_entries: 0,
                      codelist_seeders: 0,
                      settings_schema: 0,
                      top_menu_entries: 0,
                      desk_items: 1,
                      resolve_checkers: 2,
                      resolve_action_handlers: 2,
                      resolve_external_sync_entries: 2,
                      resolve_codelist_seeders: 2,
                      resolve_settings_schema: 2,
                      resolve_top_menu_entries: 2,
                      resolve_desk_items: 2,
                      resolve_doc_actions: 2,
                      extract_edges: 2,
                      resolve_extract_edges: 2,
                      lifecycle_hooks: 0,
                      api_tests: 0,
                      resolve_api_tests: 2,
                      cli_commands: 0,
                      resolve_cli_commands: 2,
                      content_renderer: 3,
                      test_connection: 1

  defmacro __using__(opts) do
    caller_dir = Path.dirname(__CALLER__.file)

    manifest_path =
      case Keyword.fetch(opts, :manifest_path) do
        {:ok, p} -> Path.expand(p, caller_dir)
        :error -> Path.expand("../plugin.json", caller_dir)
      end

    manifest =
      manifest_path
      |> File.read!()
      |> Jason.decode!()
      |> Barkpark.Plugins.Manifest.validate!()

    quote do
      @behaviour Barkpark.Plugin
      @external_resource unquote(manifest_path)
      @barkpark_plugin_manifest unquote(Macro.escape(manifest))
      @barkpark_plugin_manifest_path unquote(manifest_path)

      @impl Barkpark.Plugin
      def manifest, do: @barkpark_plugin_manifest

      @impl Barkpark.Plugin
      def register_routes(_ctx), do: []

      @impl Barkpark.Plugin
      def register_workers(_supervisor), do: []

      @impl Barkpark.Plugin
      def oban_crontab, do: []

      @impl Barkpark.Plugin
      def register_schemas(_opts), do: []

      @impl Barkpark.Plugin
      def validate_settings(_settings), do: :ok

      @impl Barkpark.Plugin
      def checkers, do: []

      @impl Barkpark.Plugin
      def action_handlers, do: %{}

      @impl Barkpark.Plugin
      def external_sync_entries, do: %{}

      @impl Barkpark.Plugin
      def codelist_seeders, do: []

      @impl Barkpark.Plugin
      def settings_schema, do: []

      @impl Barkpark.Plugin
      def top_menu_entries, do: []

      @impl Barkpark.Plugin
      def desk_items(_dataset), do: []

      # ── Per-workspace enablement declaration defaults (ssp-w1) ──────
      #
      # A fresh workspace surfaces the plugin (`default_enabled?/0 => true`)
      # under the "Plugins" node (`structure_placement/0 => :plugins`).
      # Plugins that belong in MAIN, live in the top menu, or ship off by
      # default override these.
      @impl Barkpark.Plugin
      def default_enabled?, do: true

      @impl Barkpark.Plugin
      def structure_placement, do: :plugins

      # ── Owned-schema harvest default (ssp-w2-owned-types-settings) ──
      #
      # Derive the owned type names from the plugin's own register_schemas/1.
      # Wrapped in try/rescue → [] so a plugin whose register_schemas/1 raises
      # (malformed JSON, missing file) degrades to "owns nothing" rather than
      # crashing the desk build (mirrors Bootstrap's per-plugin guard). Schema
      # `name`s are dataset-independent so the empty-opts call is safe. A plugin
      # with an EXPENSIVE register_schemas/1 (frt) overrides this with a cheap
      # compile-time list.
      @impl Barkpark.Plugin
      def owned_schema_types do
        try do
          register_schemas([]) |> Enum.map(& &1.name)
        rescue
          _ -> []
        end
      end

      # ── Resolver defaults ──────────────────────────────────────────
      #
      # Each `resolve_X/2` default calls the additive form (when
      # exported by the plugin module) and lifts the result into the
      # resolver shape. When the additive form is not exported, the
      # default returns `prev` unchanged.

      @impl Barkpark.Plugin
      def resolve_checkers(prev, _ctx) do
        if function_exported?(__MODULE__, :checkers, 0) do
          result = __MODULE__.checkers()
          if is_list(result), do: prev ++ result, else: prev
        else
          prev
        end
      end

      @impl Barkpark.Plugin
      def resolve_action_handlers(prev, _ctx) do
        if function_exported?(__MODULE__, :action_handlers, 0) do
          result = __MODULE__.action_handlers()
          if is_map(result), do: Map.merge(prev, result), else: prev
        else
          prev
        end
      end

      @impl Barkpark.Plugin
      def resolve_external_sync_entries(prev, _ctx) do
        if function_exported?(__MODULE__, :external_sync_entries, 0) do
          result = __MODULE__.external_sync_entries()
          if is_map(result), do: Map.merge(prev, result), else: prev
        else
          prev
        end
      end

      @impl Barkpark.Plugin
      def resolve_codelist_seeders(prev, _ctx) do
        if function_exported?(__MODULE__, :codelist_seeders, 0) do
          result = __MODULE__.codelist_seeders()
          if is_list(result), do: prev ++ result, else: prev
        else
          prev
        end
      end

      @impl Barkpark.Plugin
      def resolve_settings_schema(prev, _ctx) do
        if function_exported?(__MODULE__, :settings_schema, 0) do
          result = __MODULE__.settings_schema()
          if is_list(result), do: prev ++ result, else: prev
        else
          prev
        end
      end

      @impl Barkpark.Plugin
      def resolve_top_menu_entries(prev, _ctx) do
        if function_exported?(__MODULE__, :top_menu_entries, 0) do
          result = __MODULE__.top_menu_entries()
          if is_list(result), do: prev ++ result, else: prev
        else
          prev
        end
      end

      @impl Barkpark.Plugin
      def resolve_desk_items(prev, ctx) do
        if function_exported?(__MODULE__, :desk_items, 1) do
          dataset = Map.get(ctx, :dataset, "production")
          result = __MODULE__.desk_items(dataset)
          if is_list(result), do: prev ++ result, else: prev
        else
          prev
        end
      end

      @impl Barkpark.Plugin
      def resolve_doc_actions(prev, _ctx), do: prev

      # No-op edge extraction by default. `extract_edges/2` ignores its first
      # arg so a nil doc is safe; the default `resolve_extract_edges/2` lifts
      # the additive `extract_edges/2` form (when the plugin exports an
      # override) onto `prev` — `prev ++ extract_edges(ctx.doc, ctx)`. With no
      # override the lift adds the default's `[]`, so `prev` is returned
      # unchanged. PURE — no DB.
      @impl Barkpark.Plugin
      def extract_edges(_doc, _ctx), do: []

      @impl Barkpark.Plugin
      def resolve_extract_edges(prev, ctx) do
        if function_exported?(__MODULE__, :extract_edges, 2) do
          result = __MODULE__.extract_edges(Map.get(ctx, :doc), ctx)
          if is_list(result), do: prev ++ result, else: prev
        else
          prev
        end
      end

      @impl Barkpark.Plugin
      def lifecycle_hooks, do: %{}

      @impl Barkpark.Plugin
      def api_tests, do: []

      @impl Barkpark.Plugin
      def resolve_api_tests(prev, _ctx) do
        if function_exported?(__MODULE__, :api_tests, 0) do
          result = __MODULE__.api_tests()
          if is_list(result), do: prev ++ result, else: prev
        else
          prev
        end
      end

      @impl Barkpark.Plugin
      def cli_commands, do: []

      @impl Barkpark.Plugin
      def resolve_cli_commands(prev, _ctx) do
        if function_exported?(__MODULE__, :cli_commands, 0) do
          result = __MODULE__.cli_commands()
          if is_list(result), do: prev ++ result, else: prev
        else
          prev
        end
      end

      # Default content_renderer: opt out. Plugins that contribute a
      # preview override this clause with a pattern-matched
      # `content_renderer/3` and return `{:ok, iodata}` for the types
      # they handle.
      @impl Barkpark.Plugin
      def content_renderer(_doc_type, _content, _ctx), do: :skip

      # Default test_connection: opt out. Plugins that wrap an external
      # service override this with their own auth / ping logic and return
      # `{:ok, payload}` on success.
      @impl Barkpark.Plugin
      def test_connection(_settings), do: {:error, :not_implemented}

      defoverridable manifest: 0,
                     register_routes: 1,
                     register_workers: 1,
                     oban_crontab: 0,
                     default_enabled?: 0,
                     structure_placement: 0,
                     owned_schema_types: 0,
                     register_schemas: 1,
                     validate_settings: 1,
                     checkers: 0,
                     action_handlers: 0,
                     external_sync_entries: 0,
                     codelist_seeders: 0,
                     settings_schema: 0,
                     top_menu_entries: 0,
                     desk_items: 1,
                     resolve_checkers: 2,
                     resolve_action_handlers: 2,
                     resolve_external_sync_entries: 2,
                     resolve_codelist_seeders: 2,
                     resolve_settings_schema: 2,
                     resolve_top_menu_entries: 2,
                     resolve_desk_items: 2,
                     resolve_doc_actions: 2,
                     extract_edges: 2,
                     resolve_extract_edges: 2,
                     lifecycle_hooks: 0,
                     api_tests: 0,
                     resolve_api_tests: 2,
                     cli_commands: 0,
                     resolve_cli_commands: 2,
                     content_renderer: 3,
                     test_connection: 1
    end
  end
end
