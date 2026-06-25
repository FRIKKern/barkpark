defmodule Barkpark.Structure do
  @moduledoc """
  Builds the navigation structure tree from schema definitions.
  Mirrors Sanity Studio's deskStructure — supports grouping, filtered views,
  singletons, dividers, and nested lists at any depth.
  """

  alias Barkpark.Content

  defmodule Node do
    @moduledoc "A node in the structure tree."
    defstruct [
      :id,
      :title,
      :icon,
      # :list, :document_type_list, :document, :divider
      :type,
      # schema type name (for doc lists/singletons)
      :type_name,
      # "field=value" filter string (used for UI phx-value; converted to filter_map before querying)
      :filter,
      # :public or :private
      :visibility,
      # schema type this node's visibility is gated on when the desk is
      # workspace-scoped (for plugin desk nodes that point at no schema type
      # of their own, e.g. OnixEdit's Bokbasen admin link — see
      # `scope_plugin_nodes/4`). nil = ungated.
      :requires_type,
      # child nodes
      items: [],
      # what opens when selected
      child: nil
    ]
  end

  @doc """
  Build the full structure tree for a dataset.

  `opts` carries tenancy scope (`[workspace_id: ..., project_id: ...]`, as
  produced by `BarkparkWeb.ScopeHelpers.scope_opts/1`). When a `:workspace_id`
  is present the desk is scoped to that workspace: host groups gate on the
  workspace's own schemas (via `Content.list_schemas/2`), and plugin desk
  contributions are filtered to the workspace's types too — otherwise
  globally-registered plugins (e.g. frt's game groups) leak their nodes into
  every workspace's desk. With no scope (`[]`, the flat/Default desk) the
  filter is a no-op, preserving legacy behaviour.
  """
  def build(dataset \\ "production", current_path \\ nil, opts \\ []) do
    # `include_global` so the desk surfaces the workspace's own types PLUS the
    # shared/plugin (nil-workspace) schemas — without leaking OTHER workspaces'
    # types. Unscoped (no :workspace_id) this still reads every tenant's rows.
    schemas = Content.list_schemas(dataset, Keyword.put(opts, :include_global, true))
    schema_map = Map.new(schemas, &{&1.name, &1})

    %Node{
      id: "root",
      title: "Structure",
      type: :list,
      items: build_desk_items(schema_map, dataset, current_path, opts)
    }
  end

  # ── Desk structure definition ──────────────────────────────────────────────
  # This is the equivalent of Sanity's deskStructure export.
  # Edit this function to change the navigation tree.

  defp build_desk_items(schemas, dataset, current_path, opts) do
    host_items =
      [
        build_content_group(schemas),
        build_papers_group(schemas),
        build_sheets_group(schemas),
        build_books_group(schemas),
        build_media_group(schemas, dataset),
        build_taxonomy_group(schemas),
        build_settings_group(schemas)
      ]
      |> maybe_join()

    # Run the plugin resolver chain seeded with the host's built-in desk
    # items as `:baseline`. Plugins that override `resolve_desk_items/2`
    # see the host structure as the leading `%Node{}` slice and can drop
    # / reorder / amend entries symmetric with how they treat sibling-
    # plugin contributions. The default lift (no override) simply
    # appends plugin map entries — behaviour-equivalent to the legacy
    # host-side concat.
    #
    # The chain returns a mixed list of `%Node{}` structs (host
    # baseline + any plugin overrides that returned them) plus
    # plugin-shape maps (`%{type: :link | :document_list | :nested |
    # :divider, …}`). Translate the maps through `plugin_item_to_node/1`
    # and let host structs pass through. A divider between the host
    # slice and plugin-contributed nodes is preserved by
    # `maybe_join/1`'s post-pass on the host/plugin partition.
    resolved =
      safe_collect_desk_items(host_items, %{
        dataset: dataset,
        current_path: current_path,
        scope: opts
      })

    {host_part, plugin_part} =
      Enum.split_with(resolved, fn
        %Node{} -> true
        _ -> false
      end)

    plugin_nodes =
      plugin_part
      |> Enum.map(&plugin_item_to_node/1)
      |> Enum.reject(&is_nil/1)
      |> scope_plugin_nodes(schemas, dataset, opts)

    if plugin_nodes == [] do
      host_part
    else
      maybe_join([host_part, plugin_nodes])
    end
  end

  # When the desk is workspace-scoped, plugin desk contributions must be
  # gated to the workspace's own schemas. Plugins register globally (e.g.
  # frt's game groups, the tasks "Tasks" list) and their `desk_items/1`
  # callbacks are NOT scope-aware, so without this filter every workspace
  # shows every plugin's nodes. Rule: a plugin node is dropped iff it points
  # at a content type that EXISTS in the catalog but is NOT registered in this
  # scope. Nodes pointing at no known type (custom plugin pages) and purely
  # structural nodes (dividers) pass through. Unscoped builds (no
  # `:workspace_id` — the flat/Default desk) skip filtering entirely, so the
  # extra catalog read only happens for scoped requests.
  defp scope_plugin_nodes(nodes, schemas, dataset, opts) do
    if Keyword.get(opts, :workspace_id) do
      in_scope = MapSet.new(Map.keys(schemas))
      gateable = MapSet.new(Enum.map(Content.list_schemas(dataset), & &1.name))

      nodes
      |> Enum.map(&filter_plugin_node(&1, in_scope, gateable))
      |> Enum.reject(&is_nil/1)
    else
      nodes
    end
  end

  # An explicit gating schema (set by the plugin via `requires_schema`) wins —
  # it lets a schema-less node (divider, admin-page link) be gated on a type
  # it can't name structurally.
  defp filter_plugin_node(%Node{requires_type: req} = node, in_scope, gateable)
       when is_binary(req) do
    gate_typed_node(node, req, in_scope, gateable)
  end

  defp filter_plugin_node(
         %Node{type: :plugin_document_list, type_name: type} = node,
         in_scope,
         gateable
       ) do
    gate_typed_node(node, type, in_scope, gateable)
  end

  defp filter_plugin_node(%Node{type: :plugin_link, filter: path} = node, in_scope, gateable) do
    case plugin_link_type(path) do
      nil -> node
      type -> gate_typed_node(node, type, in_scope, gateable)
    end
  end

  defp filter_plugin_node(%Node{type: :list, items: items} = node, in_scope, gateable) do
    kept =
      items
      |> Enum.map(&filter_plugin_node(&1, in_scope, gateable))
      |> Enum.reject(&is_nil/1)

    # Drop a nested group whose content rows were all filtered out (leaving
    # only dividers / an empty list) — a header pointing at nothing.
    if Enum.any?(kept, &content_row?/1), do: %{node | items: kept}, else: nil
  end

  defp filter_plugin_node(%Node{} = node, _in_scope, _gateable), do: node

  # Keep iff in scope; drop iff a real catalog type absent from scope; keep
  # unknown (non-schema) types — we only gate what we can positively classify.
  defp gate_typed_node(node, type, in_scope, gateable) do
    cond do
      MapSet.member?(in_scope, type) -> node
      MapSet.member?(gateable, type) -> nil
      true -> node
    end
  end

  # Singleton desk links carry a flat `/studio/<dataset>/<type>` path (see
  # frt's `singleton_link/4`); pull the trailing type segment back out so the
  # link can be gated like a typed node. Non-conforming paths → nil (un-gated).
  defp plugin_link_type(path) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      ["studio", _dataset, type] -> type
      _ -> nil
    end
  end

  defp plugin_link_type(_), do: nil

  defp content_row?(%Node{type: type})
       when type in [:plugin_document_list, :plugin_link, :document_type_list, :document],
       do: true

  defp content_row?(%Node{type: :list, items: items}), do: Enum.any?(items, &content_row?/1)
  defp content_row?(_), do: false

  defp safe_collect_desk_items(baseline, ctx) do
    try do
      Barkpark.Plugins.Registry.collect_desk_items(baseline: baseline, ctx: ctx)
    rescue
      _ -> baseline
    catch
      _, _ -> baseline
    end
  end

  defp plugin_item_to_node(%{type: :divider} = item) do
    %Node{
      type: :divider,
      id: "plugin-div-#{System.unique_integer([:positive])}",
      title: item[:label],
      requires_type: item[:requires_schema]
    }
  end

  defp plugin_item_to_node(%{type: :link, label: label, path: path} = item) do
    %Node{
      id: "plugin-link-#{:erlang.phash2({label, path})}",
      title: label,
      icon: item[:icon],
      type: :plugin_link,
      filter: path,
      requires_type: item[:requires_schema]
    }
  end

  defp plugin_item_to_node(%{type: :document_list, label: label, doc_type: doc_type} = item) do
    %Node{
      id: "plugin-doclist-#{:erlang.phash2({label, doc_type, item[:filter] || %{}})}",
      title: label,
      icon: item[:icon],
      type: :plugin_document_list,
      type_name: doc_type,
      # `filter` carries the raw filter map (PaneBuilder special-cases the
      # :plugin_document_list branch and reads it as a map, NOT via
      # `Structure.parse_filter/1` which only handles "field=value" strings).
      filter: item[:filter] || %{}
    }
  end

  defp plugin_item_to_node(%{type: :nested, label: label, items: inner} = item)
       when is_list(inner) do
    %Node{
      id: "plugin-nest-#{:erlang.phash2({label, length(inner)})}",
      title: label,
      icon: item[:icon],
      type: :list,
      items: inner |> Enum.map(&plugin_item_to_node/1) |> Enum.reject(&is_nil/1)
    }
  end

  defp plugin_item_to_node(_), do: nil

  # Joins non-empty groups with a single divider between adjacent non-empty
  # groups. Avoids stray dividers when a group is absent. If a group
  # itself begins with its own `:divider` (plugin contributions often do,
  # to label themselves), drop the synthesized one — otherwise the tree
  # ends up with consecutive dividers.
  defp maybe_join(groups) do
    groups
    |> Enum.reject(&(&1 == []))
    |> Enum.with_index()
    |> Enum.flat_map(fn {group, idx} ->
      if idx == 0 do
        group
      else
        case group do
          [%Node{type: :divider} | _] -> group
          _ -> [divider() | group]
        end
      end
    end)
  end

  # Content types with filtered sub-views (like Sanity's documentTypeList with ordering)
  defp build_content_group(schemas) do
    items = []

    # Posts — with status filter sub-views
    items =
      if Map.has_key?(schemas, "post") do
        items ++ [doc_type_with_filters(schemas["post"])]
      else
        items
      end

    # Pages — simple list
    items =
      if Map.has_key?(schemas, "page") do
        items ++ [doc_type_list_item(schemas["page"])]
      else
        items
      end

    # Projects — with status filter sub-views
    items =
      if Map.has_key?(schemas, "project") do
        items ++ [doc_type_with_filters(schemas["project"])]
      else
        items
      end

    items
  end

  # Papers (convergence: papers are first-class type-"paper" documents).
  # Surfaced as its own desk group. The list opens each paper LIVE inside the
  # Studio editor pane at `/studio/:dataset/paper/:slug` — Studio-internal
  # navigation, NOT a link out to `/papers/:slug`. The structure + list panes
  # stay visible; the paper's blocks render (and stream) in the editor pane.
  # See PaneBuilder's special casing of the "paper" type.
  defp build_papers_group(schemas) do
    if Map.has_key?(schemas, "paper") do
      [doc_type_list_item(schemas["paper"])]
    else
      []
    end
  end

  # Sheets (M2): type-"sheet" documents open as the collaborative grid
  # editor inside the Studio editor pane at `/studio/:dataset/sheet/:slug` —
  # the same Studio-internal navigation shape as papers. See PaneBuilder's
  # special casing of the "sheet" type (`view: :sheet`).
  defp build_sheets_group(schemas) do
    if Map.has_key?(schemas, "sheet") do
      [doc_type_list_item(schemas["sheet"])]
    else
      []
    end
  end

  # Plugin-owned book schema (OnixEdit). Private visibility, but surfaced
  # in the top-level content nav rather than buried under Settings.
  defp build_books_group(schemas) do
    if Map.has_key?(schemas, "book") do
      [doc_type_list_item(schemas["book"])]
    else
      []
    end
  end

  # Plugin-owned media library schemas (Media plugin).
  defp build_media_group(schemas, dataset) do
    has_assets = Map.has_key?(schemas, "mediaAsset")
    has_collections = Map.has_key?(schemas, "mediaCollection")

    library_link = %Node{
      id: "media-library",
      title: "Media Library",
      icon: "image",
      type: :plugin_link,
      # Deliberately FLAT — Structure has no scope knowledge. The scoped
      # Studio rewrites this to the /d/ canonical at render time
      # (StudioLive.scoped_plugin_href/2).
      filter: "/studio/#{dataset}/media"
    }

    cond do
      has_assets and has_collections ->
        [
          %Node{
            # Must NOT use id "media" — that collides with the MediaLive route
            # at `/studio/:dataset/media` and breaks Structure navigation
            # (push_patch cannot cross LiveViews).
            id: "media-desk",
            title: "Media",
            icon: "🖼",
            type: :list,
            visibility: :private,
            items: [
              library_link,
              doc_type_list_item(schemas["mediaAsset"]),
              doc_type_list_item(schemas["mediaCollection"])
            ]
          }
        ]

      has_assets ->
        [library_link, doc_type_list_item(schemas["mediaAsset"])]

      has_collections ->
        [library_link, doc_type_list_item(schemas["mediaCollection"])]

      true ->
        []
    end
  end

  # Taxonomy types — supporting content (authors, categories)
  defp build_taxonomy_group(schemas) do
    items = []

    items =
      if Map.has_key?(schemas, "author") do
        items ++ [doc_type_list_item(schemas["author"])]
      else
        items
      end

    items =
      if Map.has_key?(schemas, "category") do
        items ++ [doc_type_list_item(schemas["category"])]
      else
        items
      end

    items
  end

  # Settings — singletons grouped under a sub-list
  defp build_settings_group(schemas) do
    # Plugin-owned schemas surfaced in their own nav group are excluded here
    # so they don't render twice (book lives in build_books_group/1).
    #
    # frt plugin: all 25 frt schemas are visibility:"private" but are rendered
    # via the plugin's own desk_items/1 groups (Frt.desk_items/1). Exclude them
    # by name so they don't ALSO appear under Settings (double-listing).
    frt_owned = frt_schema_names()

    private =
      schemas
      |> Map.values()
      |> Enum.filter(&(&1.visibility == "private"))
      |> Enum.reject(&(&1.name in ["book", "mediaAsset", "mediaCollection"]))
      |> Enum.reject(&(&1.name in frt_owned))

    if private == [] do
      []
    else
      [
        %Node{
          id: "settings",
          title: "Settings",
          icon: "⚙",
          type: :list,
          visibility: :private,
          items:
            Enum.map(private, fn s ->
              %Node{
                id: s.name,
                title: s.title,
                icon: s.icon,
                type: :document,
                type_name: s.name,
                visibility: :private
              }
            end)
        }
      ]
    end
  end

  # ── Node builders ──────────────────────────────────────────────────────────

  # A document type that has a status field → gets a sub-list with filtered views
  defp doc_type_with_filters(schema) do
    status_field =
      Enum.find(schema.fields, fn f ->
        f["name"] == "status" && is_list(f["options"])
      end)

    if status_field do
      %Node{
        id: schema.name,
        title: schema.title,
        icon: schema.icon,
        type: :list,
        type_name: schema.name,
        visibility: :public,
        items:
          [
            %Node{
              id: "#{schema.name}-all",
              title: "All #{schema.title}",
              icon: schema.icon,
              type: :document_type_list,
              type_name: schema.name
            },
            divider()
          ] ++
            Enum.map(status_field["options"], fn opt ->
              %Node{
                id: "#{schema.name}-#{opt}",
                title: String.capitalize(opt),
                icon: status_icon(opt),
                type: :document_type_list,
                type_name: schema.name,
                filter: "status=#{opt}"
              }
            end)
      }
    else
      doc_type_list_item(schema)
    end
  end

  defp doc_type_list_item(schema) do
    %Node{
      id: schema.name,
      title: schema.title,
      icon: schema.icon,
      type: :document_type_list,
      type_name: schema.name,
      visibility: :public
    }
  end

  defp divider do
    %Node{type: :divider, id: "div-#{System.unique_integer([:positive])}"}
  end

  # frt plugin: names of the schemas the frt plugin renders via its own
  # desk_items/1 groups. Pulled from the plugin module (single source of
  # truth) so adding/removing an frt type never needs a host edit here.
  # Guarded with ensure_loaded? so the host stays decoupled when the plugin
  # is absent (returns [] → no exclusion).
  defp frt_schema_names do
    mod = Barkpark.Plugins.Frt

    if Code.ensure_loaded?(mod) and function_exported?(mod, :schema_names, 0) do
      mod.schema_names()
    else
      []
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  @doc "Get sidebar items for the layout (flat list for rendering)."
  def sidebar_items(dataset \\ "production") do
    schemas = Content.list_schemas(dataset)
    public = Enum.filter(schemas, &(&1.visibility == "public"))
    private = Enum.filter(schemas, &(&1.visibility == "private"))

    %{
      content:
        Enum.map(public, fn s ->
          %{name: s.name, title: s.title, icon: s.icon, visibility: :public}
        end),
      settings:
        Enum.map(private, fn s ->
          %{name: s.name, title: s.title, icon: s.icon, visibility: :private}
        end)
    }
  end

  @doc """
  Parse a `field=value` filter string (used by `Structure.Node.filter`)
  into a map suitable for `Barkpark.Content.list_documents/3`'s
  `:filter_map` option. Returns `%{}` for nil / "" / malformed input.
  """
  @spec parse_filter(String.t() | nil) :: map()
  def parse_filter(nil), do: %{}
  def parse_filter(""), do: %{}

  def parse_filter(s) when is_binary(s) do
    case String.split(s, "=", parts: 2) do
      [field, value] -> %{field => value}
      _ -> %{}
    end
  end

  defp status_icon("published"), do: "●"
  defp status_icon("draft"), do: "○"
  defp status_icon("active"), do: "◆"
  defp status_icon("planning"), do: "◇"
  defp status_icon("completed"), do: "✓"
  defp status_icon("archived"), do: "▪"
  defp status_icon(_), do: "·"
end
