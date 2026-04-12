defmodule SanityApi.Structure do
  @moduledoc """
  Builds the navigation structure tree from schema definitions.
  Mirrors the Go TUI's structure.go — auto-generates the tree from schemas,
  grouping public types as content and private types under settings.
  """

  alias SanityApi.Content

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
    public = Enum.filter(schemas, &(&1.visibility == "public"))
    private = Enum.filter(schemas, &(&1.visibility == "private"))

    items =
      Enum.map(public, &doc_type_list_item/1) ++
      [%Node{type: :divider, id: "div-settings"}] ++
      [settings_group(private)]

    %Node{
      id: "root",
      title: "Structure",
      type: :list,
      items: items
    }
  end

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

  @doc "Get the structure node for a specific type (with sub-navigation if applicable)."
  def type_node(type_name, dataset \\ "production") do
    case Content.get_schema(type_name, dataset) do
      {:ok, schema} ->
        # Build sub-navigation for this type
        items = build_type_subnav(schema, dataset)
        %Node{
          id: type_name,
          title: schema.title,
          icon: schema.icon,
          type: :list,
          type_name: type_name,
          visibility: String.to_atom(schema.visibility),
          items: items
        }

      _ ->
        nil
    end
  end

  # Build sub-navigation for a document type (all, by status, etc.)
  defp build_type_subnav(schema, _dataset) do
    base = [
      %Node{
        id: "#{schema.name}-all",
        title: "All #{schema.title}",
        icon: schema.icon,
        type: :document_type_list,
        type_name: schema.name
      }
    ]

    # If the schema has a "status" field with options, add filtered views
    status_field = Enum.find(schema.fields, fn f ->
      f["name"] == "status" && is_list(f["options"])
    end)

    status_items =
      if status_field do
        [%Node{type: :divider, id: "div-#{schema.name}-status"}] ++
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
      else
        []
      end

    base ++ status_items
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

  defp settings_group(private_schemas) do
    %Node{
      id: "settings",
      title: "Settings",
      icon: "⚙",
      type: :list,
      visibility: :private,
      items: Enum.map(private_schemas, fn s ->
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
  end

  defp status_icon("published"), do: "●"
  defp status_icon("draft"), do: "○"
  defp status_icon("active"), do: "◆"
  defp status_icon("planning"), do: "◇"
  defp status_icon("completed"), do: "✓"
  defp status_icon("archived"), do: "▪"
  defp status_icon(_), do: "·"
end
