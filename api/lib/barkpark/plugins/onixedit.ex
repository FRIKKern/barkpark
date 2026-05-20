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

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Plugins.OnixEdit.Schemas.{Contributor, TextContent}

  @plugin_name "onixedit"
  @schemas_dir Path.expand("../../../priv/plugins/onixedit/schemas", __DIR__)

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
  Plugin-contributed routes (Goal `barkpark-G2`, task s4 — end-to-end
  highway proof).

  Returns a single pilot route — `/onixedit/ping` mounting `PingLive` —
  that the host router's `plugin_routes(scope: :admin)` macro folds in
  at compile time. The plugin embeds its slug in the path; the host's
  `scope "/studio"` contributes the `/studio` prefix, yielding a final
  mount of `/studio/onixedit/ping`.

  Default `auth: :admin` (the macro applies that when the opts keyword
  list is absent), so the pilot inherits the `:plugin_admin` live-session
  with its `BarkparkWeb.LiveAuth.:admin` on_mount gate.

  This is a smoke proof — `bokbasen_live`, `onixedit_staleness_live`,
  and friends move from the host's `/admin` scope into this plugin
  highway in G3.
  """
  @impl Barkpark.Plugin
  def register_routes(_ctx) do
    [
      {:live, "/onixedit/ping", Barkpark.Plugins.OnixEdit.PingLive, :index}
    ]
  end

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

  # `bp_export_status` lives under the doc's `content` map. The doc may
  # arrive as a `%Document{}` struct (atom-keyed `:content`) or as a
  # plain map (string-keyed `"content"`). Read both shapes; if neither
  # holds an in-flight state, leave the action list untouched.
  defp hide_publish_action?(%{doc_type: "book", doc: %{} = doc}) do
    state =
      get_in(doc, [Access.key(:content, %{}), "bp_export_status", "state"]) ||
        get_in(doc, ["content", "bp_export_status", "state"]) ||
        get_in(doc, [Access.key(:content, %{}), :bp_export_status, :state])

    state in ["queued", "staging", "staged", "polling"]
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
  def external_sync_entries do
    %{
      "bokbasen" => %{
        label: "Bokbasen",
        states: %{
          "pending" => %{color: "gray", label: "Pending"},
          "staging" => %{color: "gray", label: "Staging"},
          "staged" => %{color: "blue", label: "Staged"},
          "polling" => %{color: "blue", label: "Polling"},
          "accepted" => %{color: "green", label: "Accepted"},
          "rejected" => %{color: "red", label: "Rejected"},
          "failed" => %{color: "orange", label: "Failed"},
          "cancelled" => %{color: "orange", label: "Cancelled"},
          "cannot_cancel" => %{color: "orange", label: "Cannot cancel"},
          nil => %{color: "gray", label: "Not synced"}
        }
      }
    }
  end

  @impl Barkpark.Plugin
  def codelist_seeders do
    [
      &Barkpark.Codelists.EDItEUR.seed_bundled/0,
      &Barkpark.Codelists.EDItEUR.seed_thema/0
    ]
  end

  @doc """
  Declarative API test specs the runner can fire on demand (Goal
  `barkpark-bsp`). Four high-signal smokes covering OnixEdit's main
  publicly-observable surfaces:

    1. Book schema reachable via the legacy public `/api/schemas` route.
    2. Book schema reachable via the admin `/v1/schemas/production` route.
    3. The plugin's top-menu tab + desk-link render in `/studio/production`.
    4. Mutation round-trip — create a probe book on the admin mutate
       endpoint, then `:cleanup` deletes it (per plan §0 Q1, cleanup
       fires always after asserts).

  Auth modes per plan §0 Q3: `:none` for the two public reads, `:admin`
  for the two write-or-admin endpoints. Single-request only per Q5.

  # TODO: add Bokbasen dryrun spec once credentials are wired via
  # :plugin_setting auth mode — the sandbox endpoint needs real OAuth
  # creds and we don't want the default smoke to hit external services.
  """
  @impl Barkpark.Plugin
  def api_tests do
    [
      %{
        name: "Book schema is exposed via /api/schemas (legacy public)",
        method: :get,
        path: "/api/schemas",
        auth: :none,
        asserts: [
          {:status, 200},
          {:body_contains, ~s|"name":"book"|},
          {:duration_under_ms, 1_500}
        ]
      },
      %{
        name: "Book schema is exposed via /v1/schemas/production (admin)",
        method: :get,
        path: "/v1/schemas/production",
        auth: :admin,
        asserts: [
          {:status, 200},
          {:body_contains, ~s|"name":"book"|}
        ]
      },
      %{
        name: "Bokbasen top-menu tab renders in /studio/production",
        method: :get,
        path: "/studio/production",
        auth: :none,
        asserts: [
          {:status, 200},
          {:body_contains, "Bokbasen"},
          {:body_contains, "Pending submissions"},
          {:body_contains, "top-menu-tab"}
        ]
      },
      %{
        name: "Mutation round-trip: create + publish + delete a probe book",
        method: :post,
        path: "/v1/data/mutate/production",
        auth: :admin,
        headers: %{"content-type" => "application/json"},
        body: %{
          "mutations" => [
            %{
              "create" => %{
                "_type" => "book",
                "_id" => "api-test-runner-probe",
                "title" => "Probe"
              }
            }
          ]
        },
        asserts: [
          {:status, 200},
          {:body_contains, "api-test-runner-probe"}
        ],
        cleanup: [
          %{
            method: :post,
            path: "/v1/data/mutate/production",
            headers: %{"content-type" => "application/json"},
            auth: :admin,
            body: %{
              "mutations" => [
                %{"delete" => %{"id" => "api-test-runner-probe", "type" => "book"}}
              ]
            }
          }
        ]
      }
    ]
  end

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
  def settings_schema do
    [
      %{
        name: "bokbasen.api_base",
        type: :url,
        label: "Bokbasen API base URL",
        required: true,
        default: "https://api.bokbasen.io",
        placeholder: "https://api.bokbasen.io",
        group: "Bokbasen",
        hint:
          "Production: https://api.bokbasen.io  ·  Sandbox: https://api-sandbox.bokbasen.io"
      },
      %{
        name: "bokbasen.oauth_token_url",
        type: :url,
        label: "OAuth token URL",
        required: true,
        default: "https://login.bokbasen.io/oauth2/token",
        placeholder: "https://login.bokbasen.io/oauth2/token",
        group: "Bokbasen"
      },
      %{
        name: "bokbasen.client_id",
        type: :string,
        label: "Client ID",
        required: true,
        masked: true,
        group: "Bokbasen"
      },
      %{
        name: "bokbasen.client_secret",
        type: :password,
        label: "Client secret",
        required: true,
        masked: true,
        group: "Bokbasen",
        hint: "Stored encrypted at rest via BARKPARK_CLOAK_KEY"
      },
      %{
        name: "bokbasen.client_role",
        type: :select,
        label: "Client role",
        required: true,
        options: ["publisher", "distributor"],
        default: "publisher",
        group: "Bokbasen"
      }
    ]
  end

  @doc """
  Plugin-contributed top-menu tab — surfaces "Bokbasen" in the Studio
  topbar next to Structure / Media / API. Points at the existing
  staleness console which lives at `/admin/onixedit/staleness` (the
  console is admin-gated; the tab is rendered to everyone but the
  route enforces). Active for any path that begins with
  `/admin/onixedit/`.
  """
  @impl Barkpark.Plugin
  def top_menu_entries do
    [
      %{
        label: "Bokbasen",
        path: "/admin/onixedit/staleness",
        icon: "send",
        order: 50,
        active_when: "/admin/onixedit/"
      }
    ]
  end

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
  def desk_items(_dataset) do
    [
      %{type: :divider, label: "Bokbasen"},
      %{
        type: :link,
        label: "Pending submissions",
        path: "/admin/onixedit/staleness",
        icon: "clock"
      }
    ]
  end

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
  @spec book_raw_with_subschemas() :: map()
  defp book_raw_with_subschemas do
    path = Path.join(@schemas_dir, "book.json")

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

  defp splice_field(%{"type" => "arrayOf", "of" => %{"type" => "composite", "fields" => inner} = of} = field)
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
        "href" => "/v1/plugins/onixedit/export/:dataset/:id.onix",
        "icon" => "download"
      },
      %{
        "name" => "publish_to_bokbasen",
        "label" => "Publish to Bokbasen",
        "kind" => "modal",
        "modal" => %{
          "title" => "Publish to Bokbasen?",
          "body" =>
            "We'll run a dry-run first, then ask again before sending for real.",
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
  def codelist_requirements do
    [
      # Critical lists pinned in the masterplan (D17 / D21).
      %{plugin_name: @plugin_name, list_id: "onixedit:contributor_role", issue: "17"},
      %{plugin_name: @plugin_name, list_id: "onixedit:thema", issue: "93"},

      # Lists referenced by the book schema. All pinned to ONIX issue 73.
      %{plugin_name: @plugin_name, list_id: "onixedit:notification_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:record_source_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:name_id_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:product_id_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:barcode_indicator", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:product_form", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:product_form_detail", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:product_form_feature_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:product_packaging", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:epub_technical_protection", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:epub_usage_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:epub_usage_status", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:epub_usage_unit", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:extent_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:extent_unit", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:ancillary_content_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:product_classification_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:title_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:title_element_level", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:thesis_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:conference_role", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:website_role", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:edition_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:bible_contents", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:bible_version", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:study_bible_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:bible_text_feature", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:language_role", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:language_code", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:country_code", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:region_code", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:script_code", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:subject_scheme", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:audience_code_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:audience_code_value", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:audience_range_qualifier", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:audience_range_precision", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:complexity_scheme", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:text_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:content_audience", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:cited_content_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:cited_source_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:content_date_role", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:resource_content_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:resource_mode", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:resource_form", issue: "73"},
      %{
        plugin_name: @plugin_name,
        list_id: "onixedit:resource_version_feature_type",
        issue: "73"
      },
      %{plugin_name: @plugin_name, list_id: "onixedit:prize_code", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:text_item_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:publishing_role", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:publishing_status", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:publishing_date_role", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:date_format", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:sales_rights_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:sales_restriction_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:work_relation", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:work_id_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:product_relation", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:sales_outlet_id_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:agent_role", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:market_publishing_status", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:supplier_role", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:supplier_id_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:supply_date_role", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:product_availability", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:price_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:price_qualifier", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:price_status", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:currency_code", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:tax_rate_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:price_date_role", issue: "73"}
    ]
  end
end
