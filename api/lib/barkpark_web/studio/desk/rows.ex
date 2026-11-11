defmodule BarkparkWeb.Studio.Desk.Rows do
  @moduledoc """
  A desk-slice list pane's rows, as the Studio's own desk draws them: the
  same filter, order, sort menu, page size and row preview (title, subtitle,
  draft mark).

  They come from `BarkparkWeb.Studio.PaneBuilder`, the one place that knows
  all of that. Nothing is copied from it, so the two desks cannot drift.

  The page already holds the desk tree, so a list it names by its node is
  read by PaneBuilder's own list branch (`PaneBuilder.walk_path/7` on that
  node alone): no tree is built for the read. A list with no node (a type
  name from an old link) asks `PaneBuilder.build/3` for the whole path and
  takes the last pane, which builds the tree again; the read runs in the
  pane's own task either way.
  """

  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.Content.TitleDerivation
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.Tree
  alias BarkparkWeb.Studio.PaneBuilder

  @page 100
  # The most rows a list holds, as the TanStack Studio's (and Sanity's) list:
  # past it the list says so and its search reaches the rest.
  @max_rows 2_000
  # The query layer reads at most this many rows at once (`Content.Query`).
  @chunk 1_000

  @doc "The first page size, and the step a scroll to the bottom grows it by."
  def page, do: @page

  @doc "The most rows a list holds."
  def max_rows, do: @max_rows

  @doc """
  What the list at `index` in `panes` is asked for: the desk path that
  leads to it, how many rows from which, and the sort the editor picked
  (nil = the declared order).
  """
  @spec query(
          [Panes.pane()],
          non_neg_integer(),
          pos_integer(),
          String.t() | nil,
          non_neg_integer()
        ) :: map()
  def query(panes, index, limit \\ @page, sort \\ nil, offset \\ 0) do
    %{path: Tree.studio_path(panes, index), limit: limit, sort: sort, offset: offset}
  end

  @doc """
  The rows of the `type` list a `query/4` names, or nil when the Studio's
  desk has no such list at that path. `node` is the list's desk node when
  the page holds it (`BarkparkWeb.Studio.Desk.Tree`); with it the read
  builds no tree.
  """
  @spec read(String.t(), map(), String.t(), keyword(), struct() | nil) :: map() | nil
  def read(type, query, dataset, scope, node \\ nil)

  # More rows than the query layer reads at once (a list scrolled past 1,000,
  # read again after a save): its pages one after the other.
  def read(type, %{limit: limit} = query, dataset, scope, node) when limit > @chunk do
    offset = Map.get(query, :offset, 0)
    first = read(type, %{query | limit: @chunk}, dataset, scope, node)

    with %{more?: true} <- first,
         %{} = rest <-
           read(
             type,
             Map.merge(query, %{limit: limit - @chunk, offset: offset + @chunk}),
             dataset,
             scope,
             node
           ) do
      %{first | entries: first.entries ++ rest.entries, more?: rest.more?}
    else
      _ -> first
    end
  end

  # Only when the path ends AT the node: a path that goes on past it (a level
  # inside the list) is not the node's own list, and is read by its path below.
  def read(
        type,
        %{path: path} = query,
        dataset,
        scope,
        %{type: :document_type_list, type_name: type, id: id} = node
      ) do
    if List.last(path) == id do
      opts = opts(type, query, scope)

      case PaneBuilder.walk_path([id], 0, %{items: [node]}, [], nil, dataset, opts) do
        {[list], _editor} -> rows(list, type)
        _ -> nil
      end
    else
      read(type, query, dataset, scope, nil)
    end
  end

  def read(type, %{path: path} = query, dataset, scope, _node) do
    with {[_ | _] = panes, _editor} <- PaneBuilder.build(dataset, path, opts(type, query, scope)),
         %{} = rows <- rows(List.last(panes), type) do
      rows
    else
      _ -> nil
    end
  end

  defp opts(type, %{limit: limit, sort: sort} = query, scope) do
    order = order(sort)

    [
      scope: scope,
      scope_prefix: "",
      list_limits: %{type => limit},
      list_offsets: %{type => Map.get(query, :offset, 0)},
      # A name is one of the type's `desk.sortOrderings`; anything else the
      # list menu picked is an order of its own.
      list_sorts: if(sort && is_nil(order), do: %{type => sort}, else: %{}),
      list_orders: if(order, do: %{type => order}, else: %{})
    ]
  end

  @doc """
  A list sort as the TanStack Studio keeps it (`app/src/lib/list-prefs.ts`),
  as a `Content.Query` order: `"title"`, `"updated"`, `"created"`, or an
  order expression such as `"rating:desc,title:asc"`. Nil for nil and for a
  name (a `desk.sortOrderings` entry, which PaneBuilder applies itself), and
  for anything it cannot read.
  """
  @spec order(String.t() | nil) :: term()
  def order("title"), do: [{:field, "title", :asc}]
  def order("updated"), do: :updated_at_desc
  def order("created"), do: :created_at_desc

  def order(expr) when is_binary(expr) do
    specs = expr |> String.split(",") |> Enum.map(&spec/1)
    if specs != [] and Enum.all?(specs), do: specs
  end

  def order(_sort), do: nil

  defp spec(part) do
    case String.split(part, ":") do
      [field, dir] when dir in ["asc", "desc"] ->
        if field =~ ~r/^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/,
          do: {:field, field, String.to_existing_atom(dir)}

      _ ->
        nil
    end
  end

  @doc """
  The "Sort by …" choices a type's list menu starts with, as the TanStack
  Studio offers them (`ListMenu` in its Structure.tsx): the schema's own
  `desk.orderings`, each as an order expression, or when it declares none
  its title field, as `"title"`.
  """
  @spec orderings(map() | nil) :: [%{title: String.t(), sort: String.t()}]
  def orderings(schema) do
    desk = (schema && (Map.get(schema, :desk) || Map.get(schema, "desk"))) || %{}
    declared = if is_map(desk), do: List.wrap(desk["orderings"] || desk[:orderings]), else: []

    case Enum.flat_map(declared, &ordering/1) do
      [] -> [%{title: title_field_title(schema), sort: "title"}]
      some -> some
    end
  end

  # `{name, title, field, direction}` or `{name, title, by: [{field, direction}]}`.
  defp ordering(%{} = o) do
    by = o["by"] || [%{"field" => o["field"], "direction" => o["direction"] || "asc"}]

    with [_ | _] <- by,
         parts = Enum.map(by, &"#{&1["field"]}:#{&1["direction"] || "asc"}"),
         sort = Enum.join(parts, ","),
         [_ | _] <- order(sort) do
      field = hd(by)["field"]
      [%{title: o["title"] || start_case(field), sort: sort}]
    else
      _ -> []
    end
  end

  defp ordering(_o), do: []

  defp start_case(field) do
    {first, rest} = field |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2") |> String.split_at(1)
    String.upcase(first) <> rest
  end

  # The field a row's title comes from, by its title ("Name" for authors).
  defp title_field_title(schema) do
    name = TitleDerivation.preview_title_field(schema) || "title"
    fields = (schema && (Map.get(schema, :fields) || Map.get(schema, "fields"))) || []
    field = Enum.find(fields, &(&1["name"] == name))
    (field && field["title"]) || gettext("Title")
  end

  defp rows(%{role: :list, type_name: type} = list, type) do
    %{
      title: list.title,
      # A tree level is its parent, a divider, then its children; it has
      # no more, no sorts.
      entries:
        for(%{type: t} = item when t in [:doc, :divider] <- list.items, do: entry(item, type)),
      more?: list[:has_more] == true,
      sorts: list[:sort_options],
      sort: list[:active_sort],
      refused: list[:filter_error]
    }
  end

  defp rows(_pane, _type), do: nil

  defp entry(%{type: :divider}, _type), do: :divider

  defp entry(item, type) do
    %{
      title: text(item.title) || item.id,
      sub: text(item[:meta]) || text(item[:updated]),
      draft: item[:is_draft] == true,
      next: %{kind: :doc, id: item.id, type: type}
    }
  end

  defp text(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp text(_value), do: nil
end
