defmodule Barkpark.Plugins.OnixEdit do
  @moduledoc """
  ONIX 3.0 book metadata editor plugin (Phase 4 — WI1 skeleton).

  This module is the top-level entrypoint for the OnixEdit plugin. The
  manifest at `priv/plugins/onixedit/plugin.json` is read and validated at
  compile time by `Barkpark.Plugin.__using__/1` (decision D7 — no runtime
  eval). The book schema at `priv/plugins/onixedit/schemas/book.json`
  declares ~200 ONIX 3.0 book fields using Schema Definition v2 — composites,
  arrayOf, codelist references, plus placeholders for WI2's contributors /
  Thema / localizedText shapes.

  The companion work-items in Phase 4:

    * **WI2** owns the inner shape of `contributors` (arrayOf composite with
      contributor role + name parts + biographicalNote localizedText) and
      the localizedText blurb under `collateralDetail.textContents`.

    * **WI3** owns the EDItEUR codelist registry seeding (`Barkpark.Codelists.EDItEUR`,
      `mix barkpark.codelists.import`). The codelist requirements declared by
      `codelist_requirements/0` here are the contract WI3 reads to know which
      lists must be importable; the actual seed data is BYO per D21 — no
      EDItEUR XML ships with this plugin.

    * **WI4** owns the LiveView Studio surfaces for editing book documents.

  Per D12 the Go TUI stays read-only for plugin schemas; book documents
  render as JSON dumps in the TUI. Editing happens in Studio.
  """

  use Barkpark.Plugin,
    manifest_path: "../../../priv/plugins/onixedit/plugin.json"

  # Installed but OFF by default — surfaced under the "Plugins" node only when
  # an admin enables it for the workspace.
  @impl Barkpark.Plugin
  def default_enabled?, do: false

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Plugins.OnixEdit.Schemas.{Contributor, TextContent}

  # Facade sub-modules — each large data-building callback delegates to a
  # focused module under `onixedit/` that returns the same shape verbatim.
  alias Barkpark.Plugins.OnixEdit.ApiTests
  alias Barkpark.Plugins.OnixEdit.Cli
  alias Barkpark.Plugins.OnixEdit.CodelistSeeders
  alias Barkpark.Plugins.OnixEdit.Menu
  alias Barkpark.Plugins.OnixEdit.PluginSettings
  alias Barkpark.Plugins.OnixEdit.Routes
  alias Barkpark.Plugins.OnixEdit.SyncEntries

  @plugin_name "onixedit"
  # Resolved at RUNTIME, deliberately not frozen into an attribute.
  # `Application.app_dir/2` finds priv under BOTH deploy models: the source-tree
  # one (Barkpark compiles + runs in place under /opt/barkpark, where Mix
  # symlinks _build/<env>/lib/barkpark/priv at ./priv) and an OTP release, where
  # priv lives at lib/barkpark-<vsn>/priv. The previous
  # `Path.expand("../../../priv/...", __DIR__)` attribute served only the first:
  # it froze the BUILD machine's absolute path, so every released build raised
  # File.Error enoent here and this plugin's schemas never registered.
  # Precedent: the plugin loader already resolves priv this way — see
  # registry/discovery.ex default_paths/0.
  @schemas_subdir "priv/plugins/onixedit/schemas"
  defp schemas_dir, do: Application.app_dir(:barkpark, @schemas_subdir)

  @doc """
  Returns the plugin's discriminator name (D20).
  """
  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @doc """
  Returns the parsed `book` schema as a `%SchemaDefinition.Parsed{}`.

  Raises if the JSON file is missing or fails v2 parsing — we want this loud
  in dev/test so a malformed schema is caught at first use, not at request
  time.

  The raw book.json declares `contributors.of.fields: []` and a partial
  `textContents.of.fields` placeholder; this function splices in the full
  shapes from `Contributor.definition_map/0` and `TextContent.definition_map/0`
  before handing the merged map to `SchemaDefinition.parse/2`. That way both
  this parsed view and `register_schemas/1` (which derives off the same
  pipeline) see the same enriched contributors / textContents subfields.
  """
  @spec book_schema!() :: SchemaDefinition.Parsed.t()
  def book_schema! do
    case book_raw_with_subschemas()
         |> SchemaDefinition.parse(plugin: @plugin_name) do
      {:ok, parsed} -> parsed
      {:error, reason} -> raise "OnixEdit book schema failed to parse: #{inspect(reason)}"
    end
  end

  @impl Barkpark.Plugin
  def action_handlers do
    %{
      "publish_to_bokbasen" => &Barkpark.Plugins.OnixEdit.Actions.publish_to_bokbasen/3
    }
  end

  @doc """
  Resolver form of `action_handlers/0` (barkpark-zdvi).

  The plugin `action_handler` contract is fixed arity-3
  `(doc_id, dataset, mode)`, so the dispatching StudioLive can't pass the
  tenancy scope as a 4th positional arg. Instead the resolver reads
  `ctx.scope` (the dispatching session's
  `[workspace_id: ..., project_id: ...]`, set by
  `ScopeHelpers.scope_opts/1`) and CLOSES OVER it in an arity-3 wrapper —
  preserving the contract while routing the book read through
  `Actions.publish_to_bokbasen/4`. The captured scope is also threaded into
  the enqueued `PublishWorker` job args for the `:real` path.

  Falls back to the bare arity-3 handler (Default resolution) when no scope
  is present in ctx — keeping the legacy (and test/cached-snapshot) behaviour
  for callers that don't supply a scope.
  """
  @impl Barkpark.Plugin
  def resolve_action_handlers(prev, ctx) do
    scope = scope_from_ctx(ctx)

    handler =
      if scope == [] do
        &Barkpark.Plugins.OnixEdit.Actions.publish_to_bokbasen/3
      else
        fn doc_id, dataset, mode ->
          Barkpark.Plugins.OnixEdit.Actions.publish_to_bokbasen(doc_id, dataset, mode, scope)
        end
      end

    Map.put(prev, "publish_to_bokbasen", handler)
  end

  defp scope_from_ctx(%{scope: scope}) when is_list(scope), do: scope
  defp scope_from_ctx(_), do: []

  @doc """
  Test the live Bokbasen OAuth connection (Goal `barkpark-G3`, task s1).

  Called by `Plugins.Registry.collect_test_connection/2` from the admin
  Plugin Settings LiveView's "Test connection" button. Pulls a token
  via `Bokbasen.Auth.token/0` (which uses the encrypted credentials
  already persisted via the settings form) and shapes the result into
  the host's first-wins contract.

  This relocates the body that used to live as a host-side
  `defp test_connection("Bokbasen")` clause in
  `plugin_settings_live.ex`. The user-visible flash strings are
  preserved verbatim so the admin sees no behaviour change. The host
  no longer branches by plugin name — every plugin opts in via this
  callback or inherits the `{:error, :not_implemented}` default.
  """
  @impl Barkpark.Plugin
  def test_connection(_settings) do
    auth_module = Barkpark.Plugins.OnixEdit.Bokbasen.Auth

    cond do
      not Code.ensure_loaded?(auth_module) ->
        {:error, "Bokbasen auth client not loaded."}

      not function_exported?(auth_module, :token, 0) ->
        {:error, "Bokbasen auth client not loaded."}

      true ->
        case auth_module.token() do
          {:ok, _bearer} -> {:ok, %{message: "Bokbasen reachable: token OK."}}
          {:error, %{message: msg}} -> {:error, "Bokbasen unreachable: #{msg}"}
          {:error, reason} -> {:error, "Bokbasen unreachable: #{inspect(reason)}"}
        end
    end
  end

  @doc """
  Contribute the side-pane preview for `"book"` documents (Goal
  `barkpark-G1`, task s3). Wraps the existing ONIX 3.0 XML exporter
  in the host's first-wins renderer contract — `{:ok, iodata}` lands
  in the preview pane's `<pre>`, `:skip` hides the pane.

  Three behaviours folded into one callback:

    * **Other doc types** → `:skip` so the host falls through to the
      next plugin (and ultimately hides the pane).
    * **`Export.to_string/1` returns `{:error, _}`** (in-progress edits
      routinely fail the XSD gate) → `:skip` rather than surface a
      half-rendered preview. The pane disappears until the next
      autosave succeeds — the soft-error badge that lived in the
      old hardcoded path is intentionally dropped here because the
      generic renderer contract has no envelope for it. We can layer
      a `{:ok, iodata, meta}` shape on later if a publisher actually
      wants the "export failed" badge back.
    * **`Export.to_string/1` raises** → caught by the `rescue :skip`
      below so the host never crashes because a renderer exploded
      mid-edit. The Registry's own rescue layer would also catch
      this, but defending here keeps the host trace clean.
  """
  @impl Barkpark.Plugin
  def content_renderer("book", content, _ctx) when is_map(content) do
    case Barkpark.Plugins.OnixEdit.Export.to_string(content) do
      {:ok, xml} when is_binary(xml) -> {:ok, xml}
      _other -> :skip
    end
  rescue
    _ -> :skip
  end

  def content_renderer(_doc_type, _content, _ctx), do: :skip

  @doc """
  Plugin-contributed supervision children (Goal `barkpark-G1`, task s2).

  Returns the OAuth2 token cache used by the Bokbasen client. Folded into
  the host supervision tree by `Barkpark.Plugins.Registry.collect_workers/1`
  during `Barkpark.Application.start/2` — see that callsite for the
  ordering rationale (Vault must be up so `Auth` can decrypt the stored
  client_secret; endpoint must be down so traffic does not race the token
  cache coming up).

  Lazy GenServer — does NOT fetch a token at boot; the first `Auth.token/0`
  call triggers the first fetch.
  """
  @impl Barkpark.Plugin
  def register_workers(_ctx) do
    [
      Barkpark.Plugins.OnixEdit.Bokbasen.Auth
    ]
  end

  @doc """
  Plugin-contributed routes.

  Four routes today, mounted at compile time by the host router's
  `plugin_routes/1` macro:

    * `/studio/onixedit/ping` — pilot route from G2 s4 (admin-only,
      default `auth: :admin`). Confirms the highway is wired up.
    * `/admin/onixedit/bokbasen` — operations console for Bokbasen
      publish submissions (Goal `barkpark-G3` s4, was
      `BarkparkWeb.Admin.BokbasenLive` at `/admin/bokbasen`). `auth: :ops`
      so the dedicated `ops` role can reach it without inheriting full
      admin.
    * `/admin/onixedit/staleness` — operations console for ONIX
      codelist drift (Goal `barkpark-G3` s4, was
      `BarkparkWeb.Admin.OnixeditStalenessLive` — same URL kept;
      lived in host namespace before this move).
    * `/v1/plugins/onixedit/export/:dataset/:id` — admin-only HTTP
      controller that streams a `book` document as ONIX 3.0 XML
      (Goal `barkpark-G3` s5, was
      `BarkparkWeb.OnixeditExportController`). `auth: :api` mounts it
      under the host's `[:api, :require_admin]` pipeline via the
      `plugin_routes(scope: :api)` callsite inside
      `scope "/v1/plugins"`. URL preserved.

  Path mounting: each plugin path is relative to the host scope that
  wraps the matching `plugin_routes/1` callsite. The pilot lives under
  `scope "/studio"` (admin scope, default `:admin` auth) → `/studio` +
  `/onixedit/ping`. The two consoles live under `scope "/admin"` (ops
  scope) → `/admin` + `/onixedit/<console>`. The export controller
  lives under `scope "/v1/plugins"` (api scope) → `/v1/plugins` +
  `/onixedit/export/:dataset/:id`.

  The old `/admin/bokbasen` URL is kept alive by a 301 redirect in
  `BarkparkWeb.Router` (back-compat per Goal `barkpark-G3` Q3 grill
  decision).
  """
  @impl Barkpark.Plugin
  def register_routes(_ctx), do: Routes.all()

  @doc """
  Resolve the editor-header doc-action list — drops the
  `publish_to_bokbasen` entry while the book's Bokbasen submission is
  in-flight.

  The four in-flight states are `queued`, `staging`, `staged`, and
  `polling` (per the resolver plan §3). Once the worker moves to
  `accepted` or `rejected`, the button comes back so the publisher can
  re-publish (e.g. after a metadata fix).

  Only filters when `doc_type == "book"`; non-book documents are
  untouched. The companion `action_handlers/0` entry stays registered
  — the handler still runs whenever the action is NOT hidden.

  This is the concrete proof of the Goal `barkpark-cjs` resolver
  refactor: a plugin conditionally removes a host-baseline action from
  the rendered list using nothing but the Plugin behaviour + the
  Registry resolver chain.
  """
  @impl Barkpark.Plugin
  def resolve_doc_actions(prev, ctx) do
    if hide_publish_action?(ctx) do
      Enum.reject(prev, fn action -> action["name"] == "publish_to_bokbasen" end)
    else
      prev
    end
  end

  # `bp_export_status` lives under the doc's `content` map. The doc may arrive
  # as a `%Document{}` struct (atom `:content` field), a plain map with an atom
  # `:content`, or a plain map with a string `"content"` key.
  # `ContentProbe.content_get/2` reads every shape WITHOUT raising — a bare
  # `get_in(doc, ["content", ...])` against a real `%Document{}` struct raises
  # `Document does not implement the Access behaviour` (masked as Registry log
  # spam). If neither shape holds an in-flight state, leave the action list
  # untouched.
  defp hide_publish_action?(%{doc_type: "book", doc: %{} = doc}) do
    Barkpark.Plugins.ContentProbe.content_get(doc, ["bp_export_status", "state"]) in [
      "queued",
      "staging",
      "staged",
      "polling"
    ]
  end

  defp hide_publish_action?(_), do: false

  @doc """
  Lifecycle-hook registrations (Goal `barkpark-9lq`).

  One entry today: `:after_publish` runs
  `Lifecycle.publish_to_bokbasen_if_book/1`, which enqueues
  `Bokbasen.PublishWorker` whenever a `book` document is published.
  This collapses the two-click "Publish + Publish-to-Bokbasen" flow
  into a single click in Studio — Bokbasen submission becomes an
  automatic side-effect of normal Publish for book documents.

  The hook bails on `ctx.source == :worker` (recursion guard) and on
  non-book documents. The manual `publish_to_bokbasen` action stays
  on the editor header because it is still the way to run a dry-run
  and to retry after a rejection.

  See `Barkpark.Plugins.OnixEdit.Lifecycle` for the hook fn itself.
  """
  @impl Barkpark.Plugin
  def lifecycle_hooks do
    %{
      after_publish: [&Barkpark.Plugins.OnixEdit.Lifecycle.publish_to_bokbasen_if_book/1]
    }
  end

  @impl Barkpark.Plugin
  def external_sync_entries, do: SyncEntries.entries()

  @impl Barkpark.Plugin
  def codelist_seeders, do: CodelistSeeders.seeders()

  @doc """
  Declarative API test specs the runner can fire on demand. See
  `Barkpark.Plugins.OnixEdit.ApiTests` (the `specs/0` implementation)
  for the full catalog and the Bokbasen dryrun TODO.
  """
  @impl Barkpark.Plugin
  def api_tests, do: ApiTests.specs()

  @doc """
  Declarative settings form for the admin Plugin Settings LiveView.

  Field names are dot-namespaced: the leading segment is the `plugin_settings`
  row the value lands in (`"bokbasen"` here), and the remainder is the flat
  key inside that row. This is the exact shape
  `Barkpark.Plugins.OnixEdit.Bokbasen.Settings.get_credentials/0` reads
  back — the LiveView does not invent a new storage layout, it mirrors
  what the runtime client already expects.
  """
  @impl Barkpark.Plugin
  def settings_schema, do: PluginSettings.schema()

  @doc """
  Plugin-contributed top-menu tab — surfaces "Bokbasen" in the Studio
  topbar next to Structure / Media / API. Points at the existing
  staleness console which lives at `/admin/onixedit/staleness` (the
  console is admin-gated; the tab is rendered to everyone but the
  route enforces). Active for any path that begins with
  `/admin/onixedit/`.
  """
  @impl Barkpark.Plugin
  def top_menu_entries, do: Menu.top_menu_entries()

  @doc """
  Plugin-contributed desk items — appended after the host's auto-
  generated schema items in the root Structure pane. Two entries:

    * A divider labelled "Bokbasen" that visually anchors the group.
    * A `:link` row that jumps to the staleness console.

  `:document_list` / `:nested` shapes are accepted by the host
  PaneBuilder (see `BarkparkWeb.Studio.PaneBuilder`) but OnixEdit
  v1 only contributes the simpler two — the `book` schema already
  appears via the standard schema-discovery path, and adding extra
  pre-filtered views from the plugin side would duplicate it.
  """
  @impl Barkpark.Plugin
  def desk_items(dataset), do: Menu.desk_items(dataset)

  @doc """
  Ergonomic CLI verbs OnixEdit contributes to the `/v1/capabilities` manifest
  (M3). Grounded ONLY in routes `register_routes/1` actually mounts.

  OnixEdit's single HTTP/API route is the ONIX exporter:

    * `export` — `GET /v1/plugins/onixedit/export/:dataset/:id` streams a `book`
      document as ONIX 3.0 XML. The route's `auth: :api` opt mounts it under the
      host's `[:api, :require_admin]` pipeline, so its required `auth_tier` is
      `"admin"`.

  Its other surfaces are NOT API verbs and so contribute no CLI command:
  `/admin/onixedit/bokbasen` + `/admin/onixedit/staleness` are admin-gated
  browser LiveViews (no flat `http.path_template`), and `publish_to_bokbasen` is
  an `action_handler`/lifecycle side-effect dispatched through the core mutate +
  Studio paths, not a dedicated HTTP route. Declaring `import` / `bokbasen-*` /
  `codelists` verbs would invent endpoints that do not exist, so they are
  intentionally omitted (additive: add them here the day a real route lands).
  """
  @impl Barkpark.Plugin
  def cli_commands, do: Cli.commands()

  @impl Barkpark.Plugin
  def register_schemas(_opts) do
    raw = book_raw_with_subschemas()

    # Force a parse round-trip up front: we want the same loud failure as
    # `book_schema!/0` if the spliced shape is malformed, even though we
    # persist the raw (string-keyed) map.
    parsed = book_schema!()

    [
      %SchemaDefinition{
        name: parsed.name,
        title: parsed.title,
        icon: Map.get(raw, "icon"),
        visibility: Map.get(raw, "visibility", "private"),
        fields: Map.get(raw, "fields", []),
        groups: Map.get(raw, "groups", []),
        desk_groups: Map.get(raw, "deskGroups", []),
        initial_values: Map.get(raw, "initial_values", %{}),
        cross_validations: Map.get(raw, "cross_validations", []),
        dataset: "production",
        actions: document_actions()
      }
    ]
  end

  # ─── sub-schema splicing ──────────────────────────────────────────────────

  # Reads book.json from disk, then walks the `fields` tree and replaces the
  # empty `contributors.of.fields` and the partial `textContents.of.fields`
  # placeholders with the full string-keyed sub-schemas exposed by
  # `Contributor.definition_map/0` / `TextContent.definition_map/0`. Both
  # sources are `Jason.decode!`'d JSON, so the keys are already strings — no
  # atom/string normalisation is needed (decision recorded in the task brief).
  # Reachability: the only path read is the runtime-resolved schemas dir joined
  # with a compile-time literal filename — no runtime input reaches `File.read!/1`.
  # Inline rather than a `.sobelow-skips` row on purpose: a baseline entry is
  # pinned to a LINE, so any edit above the call silently kills the waiver and the
  # finding returns as new. The annotation binds by AST adjacency and survives moves.
  # sobelow_skip ["Traversal.FileModule"]
  @spec book_raw_with_subschemas() :: map()
  defp book_raw_with_subschemas do
    path = Path.join(schemas_dir(), "book.json")

    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.update("fields", [], &splice_subschemas/1)
  end

  @spec splice_subschemas([map()]) :: [map()]
  defp splice_subschemas(fields) when is_list(fields) do
    Enum.map(fields, &splice_field/1)
  end

  defp splice_field(%{"name" => "contributors", "type" => "arrayOf"} = field) do
    put_inner_fields(field, fetch_subschema_fields(Contributor))
  end

  defp splice_field(%{"name" => "textContents", "type" => "arrayOf"} = field) do
    put_inner_fields(field, fetch_subschema_fields(TextContent))
  end

  defp splice_field(%{"type" => "composite", "fields" => inner} = field) when is_list(inner) do
    %{field | "fields" => splice_subschemas(inner)}
  end

  defp splice_field(
         %{"type" => "arrayOf", "of" => %{"type" => "composite", "fields" => inner} = of} = field
       )
       when is_list(inner) do
    %{field | "of" => %{of | "fields" => splice_subschemas(inner)}}
  end

  defp splice_field(field), do: field

  # Replace the inner `of.fields` while preserving every other key the book
  # schema sets on the `of` composite (title, name, type, etc.).
  defp put_inner_fields(%{"of" => of} = field, replacement_fields) when is_map(of) do
    %{field | "of" => Map.put(of, "fields", replacement_fields)}
  end

  # Sub-schemas declare their full shape at the top level (name, title,
  # fields, …). We only want the `fields` list — the surrounding metadata
  # belongs to the sub-schema as a standalone document; the book composite
  # already carries its own name/title.
  defp fetch_subschema_fields(module) do
    module.definition_map()
    |> Map.get("fields", [])
  end

  @doc """
  Document-level actions advertised by the `book` schema (Task #16 — schema
  action registry). Each entry is a string-keyed map that Studio's generic
  action-bar renderer understands:

    * `kind: "link"`  — render `<a href=...>`; `:dataset` and `:id` get
      substituted at render time.
    * `kind: "modal"` — render `<button phx-click="schema_action" ...>`;
      Studio opens a `ConfirmModal` with the two-step dry-run-then-real flow.

  These replace the `phx-click="export_onix"` / `phx-click="publish_to_bokbasen"`
  buttons that previously only existed inside the dedicated `book_editor`
  LiveView. With these landing in the schema row, the generic Studio editor
  pane renders the same affordances — no plugin LiveView needed to expose
  document-level actions.
  """
  @spec document_actions() :: [map()]
  def document_actions do
    [
      %{
        "name" => "export_onix",
        "label" => "Export ONIX",
        "kind" => "link",
        "href" => "/v1/plugins/onixedit/export/:dataset/:id",
        "icon" => "download"
      },
      %{
        "name" => "publish_to_bokbasen",
        "label" => "Publish to Bokbasen",
        "kind" => "modal",
        "modal" => %{
          "title" => "Publish to Bokbasen?",
          "body" => "We'll run a dry-run first, then ask again before sending for real.",
          "steps" => ["dryrun", "real"]
        },
        # Editor-header glyph (task barkpark-jl4x). `cloud-upload` so the
        # button reads as "ship this off-platform" — distinct from the
        # in-system Publish action (which uses `send`).
        "icon" => "cloud-upload"
      }
    ]
  end

  @doc """
  Codelist requirements declared by the OnixEdit plugin.

  Each entry names a codelist that the plugin's schema references. Seeding is
  **WI3's job** — these declarations are the contract WI3 reads. Per D21 we
  do NOT bundle EDItEUR XML; the publisher brings their licensed snapshot
  and `mix barkpark.codelists.import` (WI3) populates the registry.

  The shape is intentionally simple: a list of maps with `:plugin_name`,
  `:list_id`, and `:issue`. WI3 may extend this to richer metadata once the
  importer exists; until then, this is the soft hand-off point.
  """
  @spec codelist_requirements() :: [
          %{plugin_name: String.t(), list_id: String.t(), issue: String.t()}
        ]
  def codelist_requirements, do: CodelistSeeders.requirements()
end
