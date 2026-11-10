defmodule BarkparkWeb.Studio.Desk.Rows do
  @moduledoc """
  A desk-slice list pane's rows, as the Studio's own desk draws them: the
  same filter, order, sort menu, page size and row preview (title, subtitle,
  draft mark).

  They come from `BarkparkWeb.Studio.PaneBuilder.build/3`, the one place
  that knows all of that, asked for the list alone. Nothing is copied from
  it, so the two desks cannot drift. The cost is that it builds its tree
  again for this read; the read runs in the pane's own task.
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
  desk has no such list at that path.
  """
  @spec read(String.t(), map(), String.t(), keyword()) :: map() | nil
  def read(type, %{path: path, limit: limit, sort: sort}, dataset, scope) do
    opts = [
      scope: scope,
      scope_prefix: "",
      list_limits: %{type => limit},
      list_sorts: if(sort, do: %{type => sort}, else: %{})
    ]

    with {[_ | _] = panes, _editor} <- PaneBuilder.build(dataset, path, opts),
         %{role: :list, type_name: ^type} = list <- List.last(panes) do
      %{
        title: list.title,
        entries: for(%{type: :doc} = item <- list.items, do: entry(item, type)),
        more?: list.has_more == true,
        sorts: list.sort_options,
        sort: list.active_sort,
        refused: list.filter_error
      }
    else
      _ -> nil
    end
  end

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
