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
  the `active`, `editing`, `pending`, `active_refs` and `desk_nav` assigns.

  When a Studio handler navigates (delete, duplicate, discard, open a
  backlink, new document), it prints a Studio path under the desk's base
  (`Shared.studio_path/4`). `desk_nav` is the Studio path this module handed
  over; the asked path is read against it and the desk's own chain, so the
  panes the document was opened from stay (`steer/2`).
  """

  use BarkparkWeb, :html

  import Phoenix.LiveView, only: [push_navigate: 2, push_patch: 2]

  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.Refs
  alias BarkparkWeb.Studio.Desk.Tree
  alias BarkparkWeb.Studio.StudioLive
  alias BarkparkWeb.Studio.StudioLive.Components
  alias BarkparkWeb.Studio.StudioLive.Paths

  @doc """
  Mounts as the Studio does (the same state, capability gate and quota
  gate), with no document open.
  """
  def mount(params, session, socket) do
    {:ok, socket} = StudioLive.mount(params, session, socket)
    {:ok, assign(socket, active: nil, editing: nil, pending: nil, active_refs: [], desk_nav: nil)}
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
        assign(socket, active: nil, editing: nil, pending: target, active_refs: [], desk_nav: nil)

      true ->
        assign(socket, active: nil, editing: nil, pending: nil, active_refs: [], desk_nav: nil)
    end
  end

  @doc "Loads the pending document into the Studio's editor."
  def edit(%{assigns: %{pending: target}} = socket, target) do
    %{chain: panes, desk: desk, dataset: dataset, desk_uri: uri, scope: scope} = socket.assigns
    path = Tree.edit_path(panes, desk.root)

    {:noreply, socket} =
      %{"dataset" => dataset, "path" => path}
      |> StudioLive.handle_params(uri, assign(socket, :desk_nav, path))
      |> ours(:settled)

    {:noreply,
     assign(socket,
       active: length(panes) - 1,
       editing: target,
       pending: nil,
       active_refs: refs(socket.assigns, dataset, scope)
     )}
  end

  # The URL moved on before the editor was loaded.
  def edit(socket, _stale_target), do: {:noreply, socket}

  # The document's references, as links that open the next pane: the
  # Studio's reference fields pick a target, they do not follow one.
  defp refs(%{editor_doc: %{} = doc, editor_schema: %{} = schema}, dataset, scope) do
    for {field, targets} <- Refs.resolve(doc, schema, dataset, scope),
        %{type: ref_type} = ref when is_binary(ref_type) <- targets,
        do: Map.put(ref, :path, field)
  end

  defp refs(_assigns, _dataset, _scope), do: []

  @doc "An event the page does not own is the editor's: the Studio's own handlers."
  # The Studio's `nav_path` says nothing about the pane a "+" was pressed in,
  # so a new document is placed by the event (and an optional `desk-pane`).
  def handle_event("new-document", %{"type" => type} = params, socket) when is_binary(type),
    do: "new-document" |> StudioLive.handle_event(params, socket) |> ours({:new, type, params})

  def handle_event(event, params, socket),
    do: event |> StudioLive.handle_event(params, socket) |> ours()

  @doc "A message the page does not own is the editor's."
  def handle_info(message, socket), do: message |> StudioLive.handle_info(socket) |> ours()

  # The Studio's panes are not drawn here; its editor is.
  defp ours(result, how \\ :reload)
  defp ours({:noreply, socket}, how), do: {:noreply, socket |> steer(how) |> assign(:panes, [])}

  defp ours({:reply, reply, socket}, how),
    do: {:reply, reply, socket |> steer(how) |> assign(:panes, [])}

  # ── the Studio's navigation, read against the desk's chain ────────────────

  # A live patch the Studio printed under the desk's base (`Shared.studio_path/4`
  # joins its path with ";") is read back as that Studio path and answered with
  # the desk's own URL. Anything else (a navigate, a URL with a query, a patch
  # with no document handed over) goes out as the Studio printed it.
  defp steer(%{redirected: {:live, :patch, %{to: to}}} = socket, how) do
    with %{desk_base: base} when is_binary(base) <- socket.assigns,
         {:ok, asked} <- asked(to, base) do
      route(socket, asked, how)
    else
      _ -> socket
    end
  end

  defp steer(socket, _how), do: socket

  defp asked(base, base), do: {:ok, []}

  defp asked(to, base) do
    case String.split_at(to, byte_size(base) + 1) do
      {prefix, rest} when prefix == base <> "/" and rest != "" ->
        if String.contains?(rest, "?"), do: :error, else: {:ok, String.split(rest, ";")}

      _ ->
        :error
    end
  end

  # A new document opens as a typed pane after the list it belongs to: in the
  # last pane's place when that is a document, after it when it is a list, or
  # after the pane the "+" names (`desk-pane`). Its id is the Studio's last
  # segment.
  defp route(socket, [_ | _] = asked, {:new, type, params}) do
    %{chain: chain, base: base} = socket.assigns
    next = %{kind: :doc, id: List.last(asked), type: type}
    last = length(chain) - 1

    to =
      case {desk_pane(params, chain), List.last(chain)} do
        {index, _} when is_integer(index) -> Panes.open_after(chain, index, next, base)
        {nil, %{kind: :doc}} -> Panes.to_path(Enum.take(chain, last) ++ [next], base)
        {nil, _} -> Panes.open_after(chain, last, next, base)
      end

    repatch(socket, to)
  end

  defp route(socket, _asked, {:new, _type, _params}), do: socket

  defp route(%{assigns: %{desk_nav: [_ | _] = nav, chain: chain}} = socket, asked, how) do
    %{id: id, type: type} = List.last(chain)
    parent = Enum.drop(nav, -1)
    last = length(chain) - 1
    base = socket.assigns.base

    cond do
      # Its parent (delete, a crumb to the list): the chain without it.
      asked == parent ->
        repatch(socket, Panes.close_from(chain, last, base))

      # The same document (discard, publish's re-open by type and id): the
      # URL stays; the editor reads what is stored now.
      asked == nav or match?(["open", _, ^id], asked) ->
        reload(%{socket | redirected: nil}, how)

      # A document by type and id (a backlink, a wikilink, a graph node): the
      # next pane, the document stays.
      match?(["open", _, _], asked) ->
        ["open", next_type, next_id] = asked
        next = %{kind: :doc, id: next_id, type: next_type}
        repatch(socket, Panes.open_after(chain, last, next, base))

      # A Studio page the desk has no pane for (blast radius, which ends in
      # this document's id): leave for it; Back returns to the chain.
      List.first(asked) in ["graph", "open"] ->
        %{scope_prefix: prefix, dataset: dataset} = socket.assigns
        push_navigate(%{socket | redirected: nil}, to: Paths.studio_path(prefix, asked, dataset))

      # Another path to the same document (a canonical rewrite).
      List.last(asked) == id ->
        reload(%{socket | redirected: nil}, how)

      # A sibling (duplicate): the other document in the last pane's place.
      Enum.drop(asked, -1) == parent and length(asked) == length(nav) ->
        sibling = %{kind: :doc, id: List.last(asked), type: type}
        repatch(socket, Panes.to_path(List.replace_at(chain, last, sibling), base))

      true ->
        socket
    end
  end

  defp route(socket, _asked, _how), do: socket

  defp repatch(socket, to), do: push_patch(%{socket | redirected: nil}, to: to)

  # The Studio loads the document again, as its own patch would have; the
  # flash its handler put stays. From the path the desk handed over, not the
  # one asked for, so the Studio's `nav_path` stays `desk_nav` and the next
  # navigation reads against it (after publish's `["open", type, id]`, a
  # duplicate would print like a backlink). Once per redirect: a second ask
  # for the same document is dropped.
  defp reload(socket, :settled), do: socket

  defp reload(socket, :reload) do
    %{dataset: dataset, desk_uri: uri, scope: scope, desk_nav: nav} = socket.assigns

    {:noreply, socket} =
      StudioLive.handle_params(%{"dataset" => dataset, "path" => nav}, uri, socket)

    socket |> steer(:settled) |> assign(:active_refs, refs(socket.assigns, dataset, scope))
  end

  defp desk_pane(%{"desk-pane" => index}, chain) do
    case Integer.parse(to_string(index)) do
      {i, ""} when i >= 0 and i < length(chain) -> i
      _ -> nil
    end
  end

  defp desk_pane(_params, _chain), do: nil

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
