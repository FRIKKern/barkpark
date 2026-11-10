defmodule BarkparkWeb.Studio.DeskLive do
  @moduledoc """
  The desk slice: a read-only desk beside the Studio, built to prove the
  TanStack Studio's pane navigation in LiveView. Plan:
  `/papers/desk-vertical-slice`.

  The whole pane chain is one URL segment in the TanStack and Sanity format
  (`BarkparkWeb.Studio.Desk.Panes`), read against the same desk tree the
  Studio and `GET /v1/structure/:dataset` serve
  (`BarkparkWeb.Studio.Desk.Tree`):

      /w/:ws/p/:proj/d/:dataset/studio/_desk/post;post-01

  Every row is a real link that patches. This page reads the URL and the
  tree and nothing else; each pane reads its own data
  (`BarkparkWeb.Studio.Desk.PaneComponent`), so a click builds only the pane
  it opens. The tree is built once per dataset and kept for the visit.

  The last document of the chain is edited by the Studio's own editor
  (`StudioLive` loads it and takes its events); the other panes are
  read-only. Workspace admins only while it is a slice; anyone else lands on
  the Studio.

  This module is the page: the URL, the tree, the panes in order, and the
  reads kept from a hover. The rest lives beside it, and the callbacks here
  hand over to it:

    * `BarkparkWeb.Studio.Desk.EditorHost`  the active document's editor
    * `BarkparkWeb.Studio.Desk.LiveRefresh` someone else saved
    * `BarkparkWeb.Studio.Desk.Style`       the desk's CSS
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Structure
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.Desk.EditorHost
  alias BarkparkWeb.Studio.Desk.LiveRefresh
  alias BarkparkWeb.Studio.Desk.PaneComponent
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.Search
  alias BarkparkWeb.Studio.Desk.Style
  alias BarkparkWeb.Studio.Desk.Tree
  alias BarkparkWeb.Studio.StructureCopy
  alias BarkparkWeb.Studio.StudioLive.Paths

  @impl true
  def mount(%{"dataset" => dataset} = params, session, socket) do
    # The active document is edited by the Studio's own editor, so this page
    # mounts as the Studio does: the same state, capability gate and quota gate.
    {:ok, socket} = EditorHost.mount(params, session, socket)

    socket =
      socket
      |> assign_new(:scope_prefix, fn -> "" end)
      |> assign(dataset: dataset, page_title: gettext("Desk"), desk_panes: [], desk: nil)
      |> assign(warm: %{})
      |> LiveRefresh.init()

    if socket.assigns[:shares_admin?] do
      {:ok, socket}
    else
      {:ok,
       push_navigate(socket, to: Paths.studio_path(socket.assigns.scope_prefix, [], dataset))}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    dataset = params["dataset"] || socket.assigns.dataset
    # The router hands the splat over as decoded path segments; a param value
    # with a slash in it (`inspect=sanity/structure/history`) spans several.
    splat = params |> Map.get("panes", []) |> Enum.join("/")
    scope = ScopeHelpers.scope_opts(socket)
    desk = desk(socket.assigns.desk, dataset, scope)
    panes = Tree.parse(splat, desk.root)

    views =
      for {pane, index} <- Enum.with_index(panes) do
        node = node_of(pane, desk)

        %{
          id: "desk-pane-#{index}-#{Panes.pane_key(pane)}",
          pane: pane,
          index: index,
          node: node,
          key: PaneComponent.data_key(pane, dataset, node),
          title: PaneComponent.provisional_title(pane, node)
        }
      end

    base = Paths.studio_path(socket.assigns.scope_prefix, ["_desk"], dataset)
    # Following a hit (or any link) puts the search away.
    socket = assign(socket, desk_search: "", desk_search_hits: [])

    socket =
      socket
      |> LiveRefresh.subscribe(dataset)
      |> assign(
        dataset: dataset,
        desk: desk,
        scope: scope,
        chain: panes,
        desk_panes: views,
        base: base,
        # `Shared.studio_path/4` prints the Studio's own navigation as desk URLs.
        desk_base: base,
        desk_uri: uri,
        page_title: views |> List.last() |> Map.fetch!(:title)
      )

    socket = EditorHost.follow(socket, panes, dataset)

    # The pane's frame goes out with this patch; the editor follows in the
    # next message, so a click is answered before the document is loaded.
    if target = socket.assigns.pending, do: send(self(), {:desk_edit, target})

    {:noreply, socket}
  end

  # A row was hovered or focused (`bp-desk.js`): read the pane it opens now,
  # so the click that follows opens it with its data. Kept for a short while
  # and for a few panes only; a pane never shows a read older than that.
  @warm_ttl_ms 30_000
  @warm_cap 8

  @impl true
  def handle_event("warm", %{"href" => href}, socket) when is_binary(href) do
    %{base: base, desk: desk, dataset: dataset, scope: scope, warm: warm} = socket.assigns

    with true <- String.starts_with?(href, base <> "/"),
         chain = href |> String.replace_prefix(base <> "/", "") |> Tree.parse(desk.root),
         pane = PaneComponent.with_query(List.last(chain), chain, length(chain) - 1),
         true <- pane.kind in [:list, :doc],
         node = node_of(pane, desk),
         key = PaneComponent.data_key(pane, dataset, node),
         false <- Map.has_key?(warm, key) do
      socket =
        socket
        |> assign(:warm, Map.put(warm, key, :reading))
        |> start_async({:warm, key}, fn ->
          PaneComponent.read_pane(pane, node, dataset, scope, :warm)
        end)

      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("warm", _params, socket), do: {:noreply, socket}

  # Everything else is the editor's: the Studio's own handlers.
  def handle_event(event, params, socket), do: EditorHost.handle_event(event, params, socket)

  @impl true
  def handle_async({:warm, key}, {:ok, data}, socket) do
    now = System.monotonic_time(:millisecond)

    warm =
      socket.assigns.warm
      |> Map.put(key, {data, now})
      |> Enum.filter(fn {_key, entry} -> fresh?(entry, now) end)
      |> Enum.sort_by(
        fn {_key, entry} -> if entry == :reading, do: now, else: elem(entry, 1) end,
        :desc
      )
      |> Enum.take(@warm_cap)
      |> Map.new()

    {:noreply, assign(socket, :warm, warm)}
  end

  def handle_async({:warm, key}, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :warm, Map.delete(socket.assigns.warm, key))}

  defp fresh?(:reading, _now), do: true
  defp fresh?({_data, at}, now), do: now - at < @warm_ttl_ms

  defp warm(warm, key) do
    case warm[key] do
      {data, at} -> if fresh?({data, at}, System.monotonic_time(:millisecond)), do: data
      _ -> nil
    end
  end

  @impl true
  def handle_info({:desk_edit, target}, socket), do: EditorHost.edit(socket, target)

  def handle_info({:document_changed, %{type: _, doc_id: _} = msg}, socket),
    do: {:noreply, LiveRefresh.changed(socket, msg)}

  # A read kept from a hover may be older than the save: drop them all.
  def handle_info(:desk_refresh, socket),
    do: {:noreply, socket |> LiveRefresh.refresh() |> assign(:warm, %{})}

  # A pane's read landed: the tab title follows the last pane's real title.
  def handle_info({:desk_pane_title, index, title}, socket) do
    if index == length(socket.assigns.desk_panes) - 1 and is_binary(title),
      do: {:noreply, assign(socket, :page_title, title)},
      else: {:noreply, socket}
  end

  def handle_info(message, socket), do: EditorHost.handle_info(message, socket)

  @impl true
  def render(assigns) do
    ~H"""
    <Style.sheet />
    <div class="dk" style="flex: 1 1 auto; min-height: 0; display: flex; flex-direction: column">
    <Search.box query={@desk_search} hits={@desk_search_hits} root={@desk.root} base={@base} />
    <div
      class="pane-layout dk"
      id="desk-panes"
      data-testid="panes"
      role="main"
      style="flex: 1 1 auto; min-height: 0"
      phx-hook="Desk"
    >
      <%!-- One loop, so the panes are in the page in chain order: the layout
            and the keys read that order. --%>
      <%= for view <- @desk_panes do %>
      {if view.index == @active, do: EditorHost.pane(assigns, view)}
      <.live_component
        :if={view.index != @active}
        module={PaneComponent}
        id={view.id}
        pane={view.pane}
        index={view.index}
        node={view.node}
        hold={view.index == length(@desk_panes) - 1 and @pending != nil}
        warm={warm(@warm, view.key)}
        panes={@chain}
        base={@base}
        dataset={@dataset}
        scope={@scope}
      />
      <% end %>
    </div>
    </div>
    """
  end

  # The tree is the same for every click in a dataset: build it once.
  defp desk(%{dataset: dataset} = desk, dataset, _scope), do: desk

  defp desk(_stale, dataset, scope) do
    root =
      dataset
      |> Structure.build([defer_group_by: true] ++ scope)
      |> StructureCopy.localize()
      |> Tree.normalize()

    %{dataset: dataset, root: root, nodes: Tree.index(root)}
  end

  defp node_of(pane, desk), do: Tree.node_of(pane, desk.root, desk.nodes)
end
