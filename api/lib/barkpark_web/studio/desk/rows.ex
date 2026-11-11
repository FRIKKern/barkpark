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

  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.PaneBuilder

  @page 100

  @doc "The first page size, and the step \"Show more\" grows it by."
  def page, do: @page

  @doc """
  What the list at `index` in `panes` is asked for: the desk path that
  leads to it, how many rows, and the sort the editor picked (nil = the
  declared order).
  """
  @spec query([Panes.pane()], non_neg_integer(), pos_integer(), String.t() | nil) :: map()
  def query(panes, index, limit \\ @page, sort \\ nil) do
    path =
      panes
      |> Enum.slice(1..index//1)
      |> Enum.map(fn pane -> pane[:node] || pane[:type] end)

    %{path: path, limit: limit, sort: sort}
  end

  @doc """
  The rows of the `type` list a `query/4` names, or nil when the Studio's
  desk has no such list at that path. `node` is the list's desk node when
  the page holds it (`BarkparkWeb.Studio.Desk.Tree`); with it the read
  builds no tree.
  """
  @spec read(String.t(), map(), String.t(), keyword(), struct() | nil) :: map() | nil
  def read(type, query, dataset, scope, node \\ nil)

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

  defp opts(type, %{limit: limit, sort: sort}, scope) do
    [
      scope: scope,
      scope_prefix: "",
      list_limits: %{type => limit},
      list_sorts: if(sort, do: %{type => sort}, else: %{})
    ]
  end

  defp rows(%{role: :list, type_name: type} = list, type) do
    %{
      title: list.title,
      entries: for(%{type: :doc} = item <- list.items, do: entry(item, type)),
      more?: list.has_more == true,
      sorts: list.sort_options,
      sort: list.active_sort,
      refused: list.filter_error
    }
  end

  defp rows(_pane, _type), do: nil

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
