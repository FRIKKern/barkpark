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
  alias BarkparkWeb.Studio.Desk.ListMenu
  alias BarkparkWeb.Studio.Desk.LiveRefresh
  alias BarkparkWeb.Studio.Desk.PaneComponent
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.Search
  alias BarkparkWeb.Studio.Desk.Style
  alias BarkparkWeb.Studio.Desk.Text
  alias BarkparkWeb.Studio.Desk.Tree
  alias BarkparkWeb.Studio.StructureCopy
  alias BarkparkWeb.Studio.StudioLive.Paths

  defmodule NotFound do
    @moduledoc "Raised for a desk URL that names nothing: its dataset segment is not text."
    defexception message: "no such dataset", plug_status: 404
  end

  @impl true
  def mount(%{"dataset" => dataset} = params, session, socket) do
    # A dataset segment with a byte the database refuses as text names no
    # dataset. Refused here, before the first read and before any redirect
    # that would carry it.
    Text.text?(dataset) || raise NotFound

    # The active document is edited by the Studio's own editor, so this page
    # mounts as the Studio does: the same state, capability gate and quota gate.
    {:ok, socket} = EditorHost.mount(params, session, socket)

    socket =
      socket
      |> assign_new(:scope_prefix, fn -> "" end)
      |> assign(dataset: dataset, page_title: gettext("Desk"), desk_panes: [], desk: nil)
      |> assign(warm: %{})
      |> assign(:titles, %{})
      # Each list type's sort as this editor keeps it (`ListMenu`).
      |> then(&assign(&1, :list_sorts, ListMenu.prefs(&1, dataset)))
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
    # A live patch to such a dataset segment goes back to the desk it left.
    if Text.text?(params["dataset"] || socket.assigns.dataset),
      do: follow(params, uri, socket),
      else: {:noreply, redirect(socket, to: socket.assigns.base)}
  end

  defp follow(params, uri, socket) do
    dataset = params["dataset"] || socket.assigns.dataset
    # The router hands the splat over as decoded path segments; a param value
    # with a slash in it (`inspect=sanity/structure/history`) spans several.
    splat = params |> Map.get("panes", []) |> Enum.join("/") |> Text.text_only()
    scope = ScopeHelpers.scope_opts(socket)
    desk = desk(socket.assigns.desk, dataset, scope)
    panes = Tree.parse(splat, desk.root)
    desk = expand_open(desk, panes, dataset, scope)

    nodes = Tree.nodes_of(panes, desk.root, desk.nodes)

    views =
      for {{pane, node}, index} <- panes |> Enum.zip(nodes) |> Enum.with_index() do
        %{
          id: "desk-pane-#{index}-#{Panes.pane_key(pane)}",
          pane: pane,
          index: index,
          node: node,
          key: PaneComponent.data_key(pane, dataset, node),
          title: PaneComponent.provisional_title(pane, node)
        }
      end

    views = Enum.map(views, &Map.put(&1, :follows, leader(&1, views)))
    base = Paths.studio_path(socket.assigns.scope_prefix, ["_desk"], dataset)
    # A pane that stays does not read again, so the title it read is kept here.
    titles = Map.take(socket.assigns.titles, Enum.map(views, & &1.id))
    last = List.last(views)
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
        titles: titles,
        page_title: titles[last.id] || last.title
      )

    socket = EditorHost.follow(socket, panes, dataset)

    # The pane's frame goes out with this patch; the editor follows in the
    # next message, so a click is answered before the document is loaded.
    if target = socket.assigns.pending, do: send(self(), {:desk_edit, target})

    {:noreply, socket}
  end

  # A row was hovered or focused (`bp-desk.js`): read the pane it opens now,
  # so the click that follows opens it with its data. Kept for a short while
  # and for a few panes only; a pane never shows a read older than that. The
  # while is counted from the hover, as `bp-desk.js` counts when it forgets
  # the row: counted from the landing, a slow read would refuse the next hover.
  @warm_ttl_ms 30_000
  @warm_cap 8

  @impl true
  def handle_event("warm", %{"href" => href}, socket) when is_binary(href) do
    %{base: base, desk: desk, dataset: dataset, scope: scope, warm: warm} = socket.assigns

    with true <- String.starts_with?(href, base <> "/"),
         splat = href |> String.replace_prefix(base <> "/", "") |> Text.text_only(),
         chain = Tree.parse(splat, desk.root),
         pane = PaneComponent.with_query(List.last(chain), chain, length(chain) - 1),
         true <- pane.kind in [:list, :doc],
         node = chain |> Tree.nodes_of(desk.root, desk.nodes) |> List.last(),
         key = PaneComponent.data_key(pane, dataset, node) do
      now = System.monotonic_time(:millisecond)
      hovered = assign(socket, :warm, Map.put(warm, key, {:reading, now}))

      cond do
        # Still out: nothing to read, but the row was hovered again just now.
        reading?(warm[key]) ->
          {:noreply, hovered}

        # A read a pane may still show: no need to read again.
        warm[key] && fresh?(warm[key], now) ->
          {:noreply, socket}

        true ->
          read = fn -> PaneComponent.read_pane(pane, node, dataset, scope, :warm) end
          {:noreply, start_async(hovered, {:warm, key}, read)}
      end
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

    case socket.assigns.warm[key] do
      {:reading, hovered} ->
        warm =
          socket.assigns.warm
          |> Map.put(key, {data, hovered})
          |> Enum.filter(fn {_key, entry} -> fresh?(entry, now) end)
          |> Enum.sort_by(
            fn {_key, entry} -> if reading?(entry), do: now, else: elem(entry, 1) end,
            :desc
          )
          |> Enum.take(@warm_cap)
          |> Map.new()

        {:noreply, assign(socket, :warm, warm)}

      # Dropped while it was out (someone saved): it may be older than the save.
      _ ->
        {:noreply, socket}
    end
  end

  def handle_async({:warm, key}, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :warm, Map.delete(socket.assigns.warm, key))}

  defp fresh?({:reading, _hovered}, _now), do: true
  defp fresh?({_data, at}, now), do: now - at < @warm_ttl_ms

  defp reading?(entry), do: match?({:reading, _hovered}, entry)

  defp warm(warm, key) do
    case warm[key] do
      {%{} = data, at} -> if fresh?({data, at}, System.monotonic_time(:millisecond)), do: data
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
  # The pane is named by its id, not its place: a title that lands after a
  # click replaced its pane is no longer anyone's.
  def handle_info({:desk_pane_title, id, title}, socket) when is_binary(title) do
    panes = socket.assigns.desk_panes

    case Enum.find(panes, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      view ->
        socket = assign(socket, :titles, Map.put(socket.assigns.titles, id, title))

        if view.index == length(panes) - 1,
          do: {:noreply, assign(socket, :page_title, title)},
          else: {:noreply, socket}
    end
  end

  # A list's menu picked a sort: it sticks for the type, here and for this editor.
  def handle_info({:desk_list_sort, type, sort}, socket) when is_binary(type) do
    # Only a sort the type offers is kept (the pane checked it too).
    sort = ListMenu.pick(sort, (socket.assigns.desk.menus[type] || %{sorts: []}).sorts)
    :ok = ListMenu.remember(socket, socket.assigns.dataset, type, sort)

    sorts =
      if sort,
        do: Map.put(socket.assigns.list_sorts, type, sort),
        else: Map.delete(socket.assigns.list_sorts, type)

    {:noreply, assign(socket, :list_sorts, sorts)}
  end

  def handle_info(message, socket), do: EditorHost.handle_info(message, socket)

  @impl true
  def render(assigns) do
    ~H"""
    <Style.sheet />
    <div class="dk" style="flex: 1 1 auto; min-height: 0; display: flex; flex-direction: column">
    <Search.box query={@desk_search} hits={@desk_search_hits} root={@desk.root} base={@base} />
    <%!-- `panes` is the TanStack Studio's name for this element. It is the
          page's main landmark until the Studio's editor, which brings its
          own, is hosted in it. The two labels are `bp-desk.js`'s: it names
          the strips and the dividers it draws, and fills in the title. --%>
    <div
      class="pane-layout panes dk"
      id="desk-panes"
      data-testid="panes"
      role={if is_nil(@active), do: "main"}
      data-desk-expand={gettext("Expand %{title}", title: "%{title}")}
      data-desk-resize={gettext("Resize pane")}
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
        follows={view.follows}
        hold={view.index == length(@desk_panes) - 1 and @pending != nil}
        warm={warm(@warm, view.key)}
        panes={@chain}
        base={@base}
        dataset={@dataset}
        scope={@scope}
        list_sort={ListMenu.pick(@list_sorts[view.pane[:type]], menu(@desk, view).sorts)}
        orderings={menu(@desk, view).orderings}
        sorts={menu(@desk, view).sorts}
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

    # The list menus' sorts per type (`ListMenu`), read with the tree: once.
    %{
      dataset: dataset,
      root: root,
      nodes: Tree.index(root),
      menus: ListMenu.menus(dataset, scope)
    }
  end

  defp menu(desk, view), do: desk.menus[view.pane[:type]] || %{orderings: [], sorts: []}

  # A groupBy is built deferred, with no groups: the menu that opens it builds
  # them, as the Studio's own walk does (`Structure.expand/3`), and keeps them
  # for the visit, so its groups' lists find their nodes too.
  defp expand_open(desk, panes, dataset, scope) do
    Enum.reduce(panes, desk, fn
      %{missing: true}, desk ->
        desk

      %{kind: :menu, node: id}, desk ->
        case desk.nodes[id] do
          %{deferred: {:group_by, _item, _idx}} = node ->
            open =
              node
              |> Structure.expand(dataset, scope)
              |> StructureCopy.localize()
              |> Tree.normalize()

            %{desk | nodes: Map.merge(desk.nodes, Tree.index(open))}

          _ ->
            desk
        end

      _pane, desk ->
        desk
    end)
  end

  # The earlier pane that reads the same document (a split sibling's first):
  # the later one shows that read instead of making its own.
  defp leader(%{pane: %{kind: :doc}, key: key, index: index}, views),
    do: Enum.find_value(views, &((&1.key == key and &1.index < index) && &1.id))

  defp leader(_view, _views), do: nil
end
