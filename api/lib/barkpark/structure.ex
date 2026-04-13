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
      :type,        # :list, :document_type_list, :document, :divider
      :type_name,   # schema type name (for doc lists/singletons)
      :filter,      # "field=value" filter string
      :visibility,  # :public or :private
      items: [],    # child nodes
      child: nil    # what opens when selected
    ]
  end

  @doc "Build the full structure tree for a dataset."
  def build(dataset \\ "production") do
    schemas = Content.list_schemas(dataset)
    schema_map = Map.new(schemas, &{&1.name, &1})

    %Node{
      id: "root",
      title: "Structure",
      type: :list,
      items: build_desk_items(schema_map)
    }
  end

  # ── Desk structure definition ──────────────────────────────────────────────
  # This is the equivalent of Sanity's deskStructure export.
  # Edit this function to change the navigation tree.

  defp build_desk_items(schemas) do
    content_items = build_content_group(schemas)
    taxonomy_items = build_taxonomy_group(schemas)
    settings_items = build_settings_group(schemas)

    content_items ++
      [divider()] ++
      taxonomy_items ++
      [divider()] ++
      settings_items
  end

  # Content types with filtered sub-views (like Sanity's documentTypeList with ordering)
  defp build_content_group(schemas) do
    items = []

    # Posts — with status filter sub-views
    items = if Map.has_key?(schemas, "post") do
      items ++ [doc_type_with_filters(schemas["post"])]
    else
      items
    end

    # Pages — simple list
    items = if Map.has_key?(schemas, "page") do
      items ++ [doc_type_list_item(schemas["page"])]
    else
      items
    end

    # Projects — with status filter sub-views
    items = if Map.has_key?(schemas, "project") do
      items ++ [doc_type_with_filters(schemas["project"])]
    else
      items
    end

    items
  end

  # Taxonomy types — supporting content (authors, categories)
  defp build_taxonomy_group(schemas) do
    items = []

    items = if Map.has_key?(schemas, "author") do
      items ++ [doc_type_list_item(schemas["author"])]
    else
      items
    end

    items = if Map.has_key?(schemas, "category") do
      items ++ [doc_type_list_item(schemas["category"])]
    else
      items
    end

    items
  end

  # Settings — singletons grouped under a sub-list
  defp build_settings_group(schemas) do
    private = Enum.filter(Map.values(schemas), &(&1.visibility == "private"))

    if private == [] do
      []
    else
      [%Node{
        id: "settings",
        title: "Settings",
        icon: "⚙",
        type: :list,
        visibility: :private,
        items: Enum.map(private, fn s ->
          %Node{
            id: s.name,
            title: s.title,
            icon: s.icon,
            type: :document,
            type_name: s.name,
            visibility: :private
          }
        end)
      }]
    end
  end

  # ── Node builders ──────────────────────────────────────────────────────────

  # A document type that has a status field → gets a sub-list with filtered views
  defp doc_type_with_filters(schema) do
    status_field = Enum.find(schema.fields, fn f ->
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
        items: [
          %Node{
            id: "#{schema.name}-all",
            title: "All #{schema.title}",
            icon: schema.icon,
            type: :document_type_list,
            type_name: schema.name
          },
          divider()
        ] ++ Enum.map(status_field["options"], fn opt ->
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

  # ── Helpers ────────────────────────────────────────────────────────────────

  @doc "Get sidebar items for the layout (flat list for rendering)."
  def sidebar_items(dataset \\ "production") do
    schemas = Content.list_schemas(dataset)
    public = Enum.filter(schemas, &(&1.visibility == "public"))
    private = Enum.filter(schemas, &(&1.visibility == "private"))

    %{
      content: Enum.map(public, fn s ->
        %{name: s.name, title: s.title, icon: s.icon, visibility: :public}
      end),
      settings: Enum.map(private, fn s ->
        %{name: s.name, title: s.title, icon: s.icon, visibility: :private}
      end)
    }
  end

  defp status_icon("published"), do: "●"
  defp status_icon("draft"), do: "○"
  defp status_icon("active"), do: "◆"
  defp status_icon("planning"), do: "◇"
  defp status_icon("completed"), do: "✓"
  defp status_icon("archived"), do: "▪"
  defp status_icon(_), do: "·"
end
