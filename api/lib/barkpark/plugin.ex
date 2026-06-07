defmodule Barkpark.Plugin do
  @moduledoc """
  Behaviour + `use` macro for first-party Barkpark plugins.

  Compile-time discovery only. NO `Code.eval_*`, `Code.compile_string`, or any
  runtime macro evaluation (decision D7 from
  `.doey/plans/masterplan-20260425-085425.md`). Plugins are first-party trusted
  Elixir modules — the manifest JSON is read at compile time of the plugin
  module via `__using__/1`, validated, and frozen as a literal in
  `manifest/0`.

  ## Usage

      defmodule MyApp.Plugins.Hello do
        use Barkpark.Plugin
      end

  By default the macro reads `plugin.json` from the parent directory of the
  using module's source file (e.g. `priv/plugins/hello/plugin.json` when the
  module lives at `priv/plugins/hello/lib/hello.ex`). Pass
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

  See `~/docs/paperflow/plans/2026-05-17-plugin-resolvers.html` §0 for the
  full decision record (Q1 callback shape, Q3 ctx shape, Q4 host seeds
  prev).
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
  @type desk_item ::
          %{
            required(:type) => :link,
            required(:label) => String.t(),
            required(:path) => String.t(),
            optional(:icon) => String.t()
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
              optional(:label) => String.t()
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
  A registered checker — pair of `{name, module}` where `module`
  implements `Barkpark.Plugins.Checker`.
  """
  @type checker :: {String.t() | atom(), module()}

  @typedoc """
  HTTP verb tag used in the leading position of a controller-style
  `route_spec()` tuple.
  """
  @type http_verb :: :get | :post | :put | :delete | :patch

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

    * `auth: :admin | :ops | :public | :none | :api | :ingest | :public_root` —
      auth gate. Defaults to `:admin`. Buckets routes into the matching scope
      when the host router's `plugin_routes/1` macro expands:
        - `:admin` — admin scope (LiveAuth.:admin, mounts under `/studio`)
        - `:ops`   — ops scope (LiveAuth.:ops, mounts under `/admin`)
        - `:public` / `:none` — no auth gate (mounts under `/studio`)
        - `:api`   — API pipeline + admin required (mounts under `/v1/plugins`)
        - `:ingest` — ingest-token pipeline (RequireIngestToken); controller
          routes under `/v1/plugins`
        - `:public_root` — public LiveView at the host's top-level scope with
          its OWN root layout (see `:root_layout`), no studio chrome
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
          | {:live, path :: String.t(), module :: module(), action :: atom(),
             opts :: keyword()}
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

    * `auth: :admin | :ops | :public | :none | :api | :ingest | :public_root` —
      auth gate (defaults to `:admin`). Buckets the route into the matching
      `plugin_routes/1` scope: `:admin` under `/studio`, `:ops` under `/admin`,
      `:public`/`:none` under `/studio` with no gate, `:api` under
      `/v1/plugins` with the API pipeline + admin required, `:ingest` under
      `/v1/plugins` with the RequireIngestToken pipeline, `:public_root` at the
      host's top-level scope with the spec's own `root_layout:`.
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

  @optional_callbacks register_routes: 1,
                      register_workers: 1,
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
