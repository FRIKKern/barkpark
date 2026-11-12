defmodule BarkparkWeb.Studio.Desk.ListFirst do
  @moduledoc """
  A desk list's first page in the first render of the page (ruling R12).

  A pane reads in `start_async`, which runs only once the page is
  connected: on a slow network the list was a skeleton for 0.75 to 2.2 s
  after the page had arrived. The first (dead) render now reads each list
  pane's first page itself, and the page arrives with its rows.

  The connected mount does not read them again. The dead render's reads are
  handed to it through `BarkparkWeb.Studio.ConnectHandoff`, the Studio's own
  handoff, which gives them only to the connected mount of that same page,
  for the same editor and the same lists, and only while no document of the
  workspace has been announced since. Anything else is a miss, and a miss
  leaves the panes to read as before.

  The reads go to the panes as a hover's reads do (`warm`): a pane that has
  its data when it is drawn reads nothing.
  """

  alias BarkparkWeb.Studio.ConnectHandoff
  alias BarkparkWeb.Studio.Desk.ListMenu
  alias BarkparkWeb.Studio.Desk.PaneComponent
  alias BarkparkWeb.Studio.Desk.Rows

  @doc """
  Puts the first page of each list pane in `views` into the page's `warm`
  reads: read now in the dead render, taken from it in the connected mount.
  """
  @spec warm(Phoenix.LiveView.Socket.t(), [map()]) :: Phoenix.LiveView.Socket.t()
  def warm(socket, views) do
    %{chain: chain, dataset: dataset, scope: scope} = socket.assigns
    lists = for %{pane: %{kind: :list}, follows: nil} = view <- views, do: view

    # With no handoff (off in `:test`), the connected mount would read the
    # lists again: the first render leaves them to it.
    if lists == [] or not ConnectHandoff.enabled?() do
      socket
    else
      reads = handoff(socket, chain, dataset, scope, lists)
      now = System.monotonic_time(:millisecond)
      kept = Map.new(reads, fn {key, data} -> {key, {data, now}} end)
      Phoenix.Component.assign(socket, :warm, Map.merge(socket.assigns.warm, kept))
    end
  end

  defp handoff(socket, chain, dataset, scope, lists) do
    sorts = socket.assigns[:list_sorts] || %{}
    menus = socket.assigns.desk.menus

    lists =
      for view <- lists, do: Map.put(view, :sort, ListMenu.kept(sorts, menus, view.pane[:type]))

    queries = for view <- lists, do: {view.key, with_query(view, chain).query}
    args = {:desk_first, dataset, queries, Gettext.get_locale(BarkparkWeb.Gettext)}

    ConnectHandoff.build(socket, scope, args, fn ->
      # Connected and nothing handed over: the panes read, as before.
      if Phoenix.LiveView.connected?(socket), do: %{}, else: read(lists, chain, dataset, scope)
    end)
  end

  # As the pane itself asks: its first page, in the sort the editor keeps
  # for the type when the type offers it (`ListMenu.kept/3`), else the
  # declared order.
  defp with_query(view, chain),
    do: PaneComponent.with_query(view.pane, chain, view.index, Rows.page(), view.sort)

  # A list that fails to read is left to its pane, which says so.
  defp read(lists, chain, dataset, scope) do
    for view <- lists,
        pane = with_query(view, chain),
        %{} = data <- [safe_read(pane, view.node, dataset, scope)],
        into: %{},
        do: {view.key, data}
  end

  defp safe_read(pane, node, dataset, scope) do
    PaneComponent.read_pane(pane, node, dataset, scope, :first)
  rescue
    _ -> nil
  end
end
