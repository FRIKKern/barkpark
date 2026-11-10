defmodule BarkparkWeb.Studio.Desk.EditorHost do
  @moduledoc """
  The desk slice's active document: the Studio's own editor, hosted in the
  last pane (`BarkparkWeb.Studio.DeskLive`).

  Decision in /papers/desk-vertical-slice (task 11): one real editor on the
  page, for the last document of the chain. The page hands the Studio the
  document's own Studio path; `StudioLive` loads it, subscribes to it and
  tracks presence exactly as it does for its own desk, and every event and
  message the page does not own goes to it. The other documents of the chain
  stay read-only panes.

  `DeskLive` keeps the callbacks and hands each one here; this module owns
  the `active`, `editing`, `pending` and `active_refs` assigns.
  """

  use BarkparkWeb, :html

  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.Refs
  alias BarkparkWeb.Studio.Desk.Tree
  alias BarkparkWeb.Studio.StudioLive
  alias BarkparkWeb.Studio.StudioLive.Components

  @doc """
  Mounts as the Studio does (the same state, capability gate and quota
  gate), with no document open.
  """
  def mount(params, session, socket) do
    {:ok, socket} = StudioLive.mount(params, session, socket)
    {:ok, assign(socket, active: nil, editing: nil, pending: nil, active_refs: [])}
  end

  @doc "What the last pane edits, when it is a document whose type the URL states."
  def target(panes, dataset) do
    case List.last(panes) do
      %{kind: :doc, id: id, type: type} = pane ->
        if pane[:untyped], do: nil, else: {dataset, type, id}

      _ ->
        nil
    end
  end

  @doc """
  The URL changed to `panes`: keep the editor, leave the new document
  `pending` (the page then sends itself `{:desk_edit, target}`, answered by
  `edit/2`), or put the editor away.
  """
  def follow(socket, panes, dataset) do
    target = target(panes, dataset)

    cond do
      # The same document is still the last pane (a pane closed to its left,
      # a param changed): its editor stays as it is, typing and all.
      target != nil and target == socket.assigns.editing ->
        assign(socket, :active, length(panes) - 1)

      # A new document: the page sends itself `{:desk_edit, target}` for it.
      target ->
        assign(socket, active: nil, editing: nil, pending: target, active_refs: [])

      true ->
        assign(socket, active: nil, editing: nil, pending: nil, active_refs: [])
    end
  end

  @doc "Loads the pending document into the Studio's editor."
  def edit(%{assigns: %{pending: target}} = socket, target) do
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
  def edit(socket, _stale_target), do: {:noreply, socket}

  @doc "An event the page does not own is the editor's: the Studio's own handlers."
  def handle_event(event, params, socket),
    do: event |> StudioLive.handle_event(params, socket) |> ours()

  @doc "A message the page does not own is the editor's."
  def handle_info(message, socket), do: message |> StudioLive.handle_info(socket) |> ours()

  # The Studio's panes are not drawn here; its editor is.
  defp ours({:noreply, socket}), do: {:noreply, assign(socket, :panes, [])}
  defp ours({:reply, reply, socket}), do: {:reply, reply, assign(socket, :panes, [])}

  @doc """
  The pane that edits: a close link, the document's references, and the
  Studio's editor. Takes the page's own assigns, because the Studio's shell
  reads them.
  """
  def pane(assigns, view) do
    assigns = assign(assigns, :view, view)

    ~H"""
    <section
      id={@view.id}
      class="pane-column dk-pane dk-doc dk-edit"
      data-pane-index={@view.index}
      data-pane-kind="doc"
      data-pane-editing
      aria-label={@page_title}
    >
      <a
        href={Panes.close_from(@chain, @view.index, @base)}
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
              @view.index,
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
    """
  end
end
