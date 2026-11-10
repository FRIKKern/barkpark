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
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Content
  alias Barkpark.Content.Broadcast
  alias Barkpark.Structure
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.Desk.PaneComponent
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.Refs
  alias BarkparkWeb.Studio.Desk.Tree
  alias BarkparkWeb.Studio.StructureCopy
  alias BarkparkWeb.Studio.StudioLive
  alias BarkparkWeb.Studio.StudioLive.Components
  alias BarkparkWeb.Studio.StudioLive.Paths
  alias BarkparkWeb.Studio.StudioLive.Shared

  @impl true
  def mount(%{"dataset" => dataset} = params, session, socket) do
    # The active document is edited by the Studio's own editor, so this page
    # mounts as the Studio does: the same state, capability gate and quota gate.
    {:ok, socket} = StudioLive.mount(params, session, socket)

    socket =
      socket
      |> assign_new(:scope_prefix, fn -> "" end)
      |> assign(dataset: dataset, page_title: gettext("Desk"), desk_panes: [], desk: nil)
      |> assign(warm: %{}, topics: [], stale: MapSet.new(), refresh_timer: nil)
      |> assign(active: nil, editing: nil, pending: nil, active_refs: [])

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
    target = target(panes, dataset)
    kept? = target != nil and target == socket.assigns.editing

    socket =
      socket
      |> subscribe(dataset)
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

    cond do
      # The same document is still the last pane (a pane closed to its left,
      # a param changed): its editor stays as it is, typing and all.
      kept? ->
        {:noreply, assign(socket, :active, length(panes) - 1)}

      # The pane's frame goes out with this patch; the editor follows in the
      # next message, so a click is answered before the document is loaded.
      target ->
        send(self(), {:desk_edit, target})
        {:noreply, assign(socket, active: nil, editing: nil, pending: target, active_refs: [])}

      true ->
        {:noreply, assign(socket, active: nil, editing: nil, pending: nil, active_refs: [])}
    end
  end

  # ── the active document: the Studio's own editor ───────────────────────────
  #
  # Decision in /papers/desk-vertical-slice (task 11): one real editor on the
  # page, for the last document of the chain. This page hands the Studio the
  # document's own Studio path; `StudioLive` loads it, subscribes to it and
  # tracks presence exactly as it does for its own desk, and every event and
  # message this page does not own goes to it. The other documents of the
  # chain stay read-only panes.

  # What the last pane edits, when it is a document whose type the URL states.
  defp target(panes, dataset) do
    case List.last(panes) do
      %{kind: :doc, id: id, type: type} = pane ->
        if pane[:untyped], do: nil, else: {dataset, type, id}

      _ ->
        nil
    end
  end

  defp edit(%{assigns: %{pending: target}} = socket, target) do
    %{chain: panes, desk: desk, dataset: dataset, desk_uri: uri, scope: scope} = socket.assigns
    %{id: id, type: type} = pane = List.last(panes)
    path = (pane[:node] && [pane.node]) || Tree.path_to_type(desk.root, type) ++ [id]

    {:noreply, socket} =
      %{"dataset" => dataset, "path" => path} |> StudioLive.handle_params(uri, socket) |> ours()

    # The document's references, as links that open the next pane: the
    # Studio's reference fields pick a target, they do not follow one.
    refs =
      case socket.assigns do
        %{editor_doc: %{} = doc, editor_schema: %{} = schema} ->
          for {field, targets} <- Refs.resolve(doc, schema, dataset, scope),
              %{type: ref_type} = ref when is_binary(ref_type) <- targets,
              do: Map.put(ref, :path, field)

        _ ->
          []
      end

    {:noreply,
     assign(socket, active: length(panes) - 1, editing: target, pending: nil, active_refs: refs)}
  end

  # The URL moved on before the editor was loaded.
  defp edit(socket, _stale_target), do: {:noreply, socket}

  # The Studio's panes are not drawn here; its editor is.
  defp ours({:noreply, socket}), do: {:noreply, assign(socket, :panes, [])}
  defp ours({:reply, reply, socket}), do: {:reply, reply, assign(socket, :panes, [])}

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
         false <- kept?(warm[key]) do
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
  def handle_event(event, params, socket),
    do: event |> StudioLive.handle_event(params, socket) |> ours()

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

  # A read still running, or one a pane may still show: no need to read again.
  defp kept?(nil), do: false
  defp kept?(entry), do: fresh?(entry, System.monotonic_time(:millisecond))

  defp fresh?(:reading, _now), do: true
  defp fresh?({_data, at}, now), do: now - at < @warm_ttl_ms

  defp warm(warm, key) do
    case warm[key] do
      {data, at} -> if fresh?({data, at}, System.monotonic_time(:millisecond)), do: data
      _ -> nil
    end
  end

  # ── live: someone else saved ───────────────────────────────────────────────
  #
  # Every document change in the dataset is announced on one of two topics
  # (`Content.Broadcast`: the workspace's own, or the shared layer's). The
  # panes that show the changed type read again, a moment later so a burst
  # of saves is one read.
  @refresh_after_ms 120

  defp subscribe(socket, dataset) do
    ws = socket.assigns[:current_workspace]

    topics =
      [Broadcast.global_list_topic(dataset)] ++
        if(is_map(ws) and is_binary(ws.id),
          do: [Broadcast.workspace_list_topic(dataset, ws.id)],
          else: []
        )

    if connected?(socket) and topics != socket.assigns.topics do
      Enum.each(socket.assigns.topics, &Phoenix.PubSub.unsubscribe(Barkpark.PubSub, &1))
      Enum.each(topics, &Phoenix.PubSub.subscribe(Barkpark.PubSub, &1))
      assign(socket, :topics, topics)
    else
      socket
    end
  end

  @impl true
  def handle_info({:desk_edit, target}, socket), do: edit(socket, target)

  def handle_info({:document_changed, %{type: type, doc_id: doc_id} = msg}, socket) do
    if ours?(msg, socket) do
      stale = MapSet.put(socket.assigns.stale, {type, Content.published_id(doc_id)})

      timer =
        socket.assigns.refresh_timer ||
          Process.send_after(self(), :desk_refresh, @refresh_after_ms)

      {:noreply, assign(socket, stale: stale, refresh_timer: timer)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:desk_refresh, socket) do
    stale = socket.assigns.stale
    types = MapSet.new(stale, &elem(&1, 0))

    for %{pane: pane, id: id, index: index} <- socket.assigns.desk_panes,
        index != socket.assigns.active,
        stale?(pane, stale, types) do
      send_update(PaneComponent, id: id, refresh: true)
    end

    # A read kept from a hover may be older than the save: drop them all.
    {:noreply, assign(socket, stale: MapSet.new(), refresh_timer: nil, warm: %{})}
  end

  # A pane's read landed: the tab title follows the last pane's real title.
  def handle_info({:desk_pane_title, index, title}, socket) do
    if index == length(socket.assigns.desk_panes) - 1 and is_binary(title),
      do: {:noreply, assign(socket, :page_title, title)},
      else: {:noreply, socket}
  end

  def handle_info(message, socket), do: message |> StudioLive.handle_info(socket) |> ours()

  defp stale?(%{kind: :list, type: type}, _stale, types), do: MapSet.member?(types, type)

  defp stale?(%{kind: :doc, type: type, id: id}, stale, _types),
    do: MapSet.member?(stale, {type, id})

  defp stale?(_pane, _stale, _types), do: false

  # Another workspace's frame on the shared topic, or a sibling project's
  # document with the same id, is not this desk's (as StudioLive refuses them).
  defp ours?(msg, socket) do
    ws = socket.assigns[:current_workspace]
    proj = socket.assigns[:current_project]

    Shared.own_tenant?(msg, is_map(ws) && ws.id) and
      not (is_binary(msg[:project_id]) and is_map(proj) and is_binary(proj.id) and
             msg.project_id != proj.id)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      .dk .dk-pane { width: 320px; min-width: 320px; flex-shrink: 0; }
      .dk .dk-doc { width: auto; flex: 1 0 600px; border-right: 0; }
      .dk a.pane-item { text-decoration: none; box-sizing: border-box; }
      .dk a.pane-item:hover { color: var(--fg); }
      .dk a.pane-item:focus-visible { outline: 2px solid var(--primary); outline-offset: -2px; }
      .dk .dk-note { padding: 16px; color: var(--fg-muted); font-size: var(--text-sm); }
      .dk .dk-fields { padding: 24px 32px; margin: 0; display: grid; gap: 20px; max-width: 72ch; }
      .dk .dk-fields dt { font-size: var(--text-xs); color: var(--fg-muted); margin-bottom: 4px; }
      .dk .dk-fields dd { margin: 0; font-size: var(--text-sm); white-space: pre-wrap; overflow-wrap: anywhere; }
      .dk .dk-close { color: var(--fg-muted); text-decoration: none; padding: 4px 8px; }
      .dk .dk-bone { display: block; height: 10px; width: 60%; border-radius: 5px; background: var(--border-subtle); }
      .dk .dk-skeleton .pane-item { cursor: default; }
      .dk .dk-skeleton .pane-item:nth-child(even) .dk-bone { width: 42%; }
      .dk [data-desk-leaving] { display: none; }
      .dk .dk-row-sub { display: block; font-weight: 400; font-size: var(--text-xs); color: var(--fg-muted); overflow: hidden; text-overflow: ellipsis; }
      .dk .dk-draft { color: var(--fg-muted); font-size: var(--text-xs); }
      .dk .dk-sort { display: flex; align-items: center; gap: 8px; padding: 8px 16px; border-bottom: 1px solid var(--border-subtle); font-size: var(--text-xs); color: var(--fg-muted); }
      .dk .dk-more { margin: 12px 16px; }
      .dk .sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }
      .dk .dk-edit { position: relative; display: flex; flex-direction: column; min-width: 600px; }
      .dk .dk-edit > .pane-layout { flex: 1 1 auto; min-height: 0; }
      .dk .dk-edit-refs { padding: 8px 48px 8px 16px; border-bottom: 1px solid var(--border-subtle); }
      .dk .dk-edit-close { position: absolute; top: 8px; right: 8px; z-index: 2; }
      .dk .dk-refs { display: flex; flex-wrap: wrap; gap: 6px; }
      .dk .dk-ref { padding: 2px 8px; border: 1px solid var(--border-subtle); border-radius: 6px; color: var(--fg); text-decoration: none; }
      .dk .dk-ref:hover, .dk .dk-ref[aria-current] { background: var(--bg-accent); border-color: var(--primary); }
      .dk .dk-ref-missing { color: var(--fg-muted); }
    </style>
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
      <section
        :if={view.index == @active}
        id={view.id}
        class="pane-column dk-pane dk-doc dk-edit"
        data-pane-index={view.index}
        data-pane-kind="doc"
        data-pane-editing
        aria-label={@page_title}
      >
        <a
          href={Panes.close_from(@chain, view.index, @base)}
          data-phx-link="patch"
          data-phx-link-state="push"
          class="dk-close dk-edit-close"
          aria-label={gettext("Close %{title}", title: @page_title)}
        >
          <span aria-hidden="true">×</span>
        </a>
        <nav :if={@active_refs != []} class="dk-edit-refs dk-refs" aria-label={gettext("References")}>
          <.link
            :for={ref <- @active_refs}
            patch={
              Panes.open_after(
                @chain,
                view.index,
                %{kind: :doc, id: ref.id, type: ref.type, parent_ref_path: ref.path},
                @base
              )
            }
            class="dk-ref"
            data-desk-ref
          >
            {ref.title}
          </.link>
        </nav>
        {Components.studio_live_shell(assigns)}
      </section>
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

  defp node_of(%{kind: :types}, desk), do: desk.root
  defp node_of(%{kind: :doc}, _desk), do: nil
  defp node_of(pane, desk), do: pane[:node] && desk.nodes[pane.node]
end
