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
        "icon" => "send"
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
