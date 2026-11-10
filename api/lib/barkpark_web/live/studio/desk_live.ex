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
      |> assign(dataset: dataset, page_title: gettext("Desk"), panes: [], desk: nil)

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
    </style>
    <div
      class="pane-layout dk"
      id="desk-panes"
      data-testid="panes"
      role="main"
      style="flex: 1 1 auto; min-height: 0"
    >
      <.live_component
        :for={view <- @panes}
        module={PaneComponent}
        id={view.id}
        pane={view.pane}
        index={view.index}
        node={view.node}
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
