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

  Nothing here writes. Workspace admins only while it is a slice; anyone
  else lands on the Studio.
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Structure
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.Desk.PaneComponent
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.Tree
  alias BarkparkWeb.Studio.StructureCopy
  alias BarkparkWeb.Studio.StudioLive.Paths

  @impl true
  def mount(%{"dataset" => dataset}, _session, socket) do
    socket =
      socket
      |> assign_new(:scope_prefix, fn -> "" end)
      |> assign(dataset: dataset, page_title: gettext("Desk"), panes: [], desk: nil, warm: %{})

    if socket.assigns[:shares_admin?] do
      {:ok, socket}
    else
      {:ok,
       push_navigate(socket, to: Paths.studio_path(socket.assigns.scope_prefix, [], dataset))}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
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

    {:noreply,
     assign(socket,
       dataset: dataset,
       desk: desk,
       scope: scope,
       chain: panes,
       panes: views,
       base: Paths.studio_path(socket.assigns.scope_prefix, ["_desk"], dataset),
       page_title: views |> List.last() |> Map.fetch!(:title)
     )}
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

  # A pane's read landed: the tab title follows the last pane's real title.
  @impl true
  def handle_info({:desk_pane_title, index, title}, socket) do
    if index == length(socket.assigns.panes) - 1 and is_binary(title),
      do: {:noreply, assign(socket, :page_title, title)},
      else: {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

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
      <.live_component
        :for={view <- @panes}
        module={PaneComponent}
        id={view.id}
        pane={view.pane}
        index={view.index}
        node={view.node}
        warm={warm(@warm, view.key)}
        panes={@chain}
        base={@base}
        dataset={@dataset}
        scope={@scope}
      />
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
