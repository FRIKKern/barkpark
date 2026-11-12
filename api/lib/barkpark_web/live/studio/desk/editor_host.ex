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
  the `active`, `editing`, `pending`, `active_refs`, `desk_ref_ids` and
  `desk_nav` assigns.

  When a Studio handler navigates (delete, duplicate, discard, open a
  backlink, new document), it prints a Studio path under the desk's base
  (`Shared.studio_path/4`). `desk_nav` is the Studio path this module handed
  over; the asked path is read against it and the desk's own chain, so the
  panes the document was opened from stay (`steer/2`).
  """

  use BarkparkWeb, :html

  import Phoenix.LiveView, only: [push_navigate: 2, push_patch: 2]

  require Logger

  alias BarkparkWeb.Studio.Desk.Discarded
  alias BarkparkWeb.Studio.Desk.DocMenu
  alias BarkparkWeb.Studio.Desk.InspectDialog
  alias BarkparkWeb.Studio.Desk.LiveRefresh
  alias BarkparkWeb.Studio.Desk.PaneComponent
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.Refs
  alias BarkparkWeb.Studio.Desk.ShareMenu
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
    {:ok, socket |> assign(active: nil, editing: nil, pending: nil) |> put_away()}
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
        socket |> assign(active: nil, editing: nil, pending: target) |> put_away()

      true ->
        socket |> assign(active: nil, editing: nil, pending: nil) |> put_away()
    end
  end

  # No document is handed to the Studio: no path, no reference links.
  defp put_away(socket),
    do: assign(socket, active_refs: [], desk_ref_ids: nil, desk_nav: nil, edit_failed: false)

  @doc """
  Loads the pending document into the Studio's editor.

  The Studio reads it in the page process. When the database is out that read
  raises, and an error there would take the whole page down, every pane with
  it (J50). So a database error keeps the socket from before the read and the
  pane says the document could not be read; the target stays `pending`, so
  its Retry loads it again.
  """
  def edit(%{assigns: %{pending: target}} = socket, target) do
    %{chain: panes, desk: desk, dataset: dataset, desk_uri: uri} = socket.assigns
    path = Tree.edit_path(panes, desk.root)

    try do
      {:noreply, loaded} =
        %{"dataset" => dataset, "path" => path}
        |> StudioLive.handle_params(uri, assign(socket, :desk_nav, path))
        |> ours(:settled)

      {:noreply,
       assign(loaded,
         active: length(panes) - 1,
         editing: target,
         pending: nil,
         edit_failed: false
       )}
    rescue
      error in [DBConnection.ConnectionError, Postgrex.Error] ->
        Logger.warning(
          "desk: the editor could not read #{inspect(target)}: #{Exception.message(error)}"
        )

        {:noreply, assign(socket, active: length(panes) - 1, editing: nil, edit_failed: true)}
    end
  end

  # The URL moved on before the editor was loaded.
  def edit(socket, _stale_target), do: {:noreply, socket}

  # The document's references, as links that open the next pane: the
  # Studio's reference fields pick a target, they do not follow one. The
  # links follow what the editor holds: a pick or a clear it saved shows at
  # once. The targets are read again (one query) only when the ids changed,
  # so a save of any other field reads nothing.
  defp strip(%{assigns: %{desk_nav: [_ | _], editor_doc: %{} = doc} = assigns} = socket) do
    with %{editor_schema: %{} = schema, dataset: dataset, scope: scope} <- assigns,
         ids = Refs.ids(doc, schema),
         true <- ids != assigns.desk_ref_ids do
      refs =
        for {field, targets} <- Refs.resolve(doc, schema, dataset, scope),
            %{type: ref_type} = ref when is_binary(ref_type) <- targets,
            do: Map.put(ref, :path, field)

      assign(socket, active_refs: refs, desk_ref_ids: ids)
    else
      _ -> socket
    end
  end

  defp strip(socket), do: socket

  @doc "An event the page does not own is the editor's: the Studio's own handlers."
  # The card's Retry, when the document could not be read: read it again.
  def handle_event("desk-edit-retry", _params, %{assigns: %{edit_failed: true}} = socket),
    do: edit(socket, socket.assigns.pending)

  def handle_event("desk-edit-retry", _params, socket), do: {:noreply, socket}

  # The Studio's `nav_path` says nothing about the pane a "+" was pressed in,
  # so a new document is placed by the event (and an optional `desk-pane`).
  def handle_event("new-document", %{"type" => type} = params, socket) when is_binary(type),
    do: "new-document" |> StudioLive.handle_event(params, socket) |> ours({:new, type, params})

  # The Studio's events that write the open document from its form.
  @form_writes ~w(save autosave paper-block-autosave paper-save-master object-dialog-save)

  # The browser has the form that replaced a draft discarded elsewhere
  # (`Discarded`): its saves are the editor's again.
  def handle_event("desk-discard-seen", _params, socket),
    do: {:noreply, Discarded.seen(socket)}

  # The open document was deleted by someone else (J32): a save of the form
  # would write it back as a draft. The pane drops the form (`pane/2`); a
  # save still in flight from it is dropped here. So is a save from the form
  # a draft discarded elsewhere had (live.spec:48), until the browser has the
  # new one.
  def handle_event(event, params, socket) do
    cond do
      event in @form_writes and gone?(socket.assigns) ->
        {:noreply, socket}

      event in @form_writes and Discarded.drop?(socket.assigns) ->
        {:noreply, Discarded.drop(socket)}

      true ->
        event |> StudioLive.handle_event(params, written(socket, event)) |> ours()
    end
  end

  # A save from the new form: the line that said the draft was discarded goes.
  defp written(socket, event) when event in @form_writes, do: Discarded.clear(socket)
  defp written(socket, _event), do: socket

  # Whether the document in the editor was deleted while it was on the desk.
  defp gone?(%{editing: {_dataset, type, id}} = assigns), do: LiveRefresh.gone?(assigns, type, id)
  defp gone?(_assigns), do: false

  @doc "A message the page does not own is the editor's."
  # Someone else discarded the open draft: the frame carries the dead draft,
  # which the Studio would put in the form (`Discarded`).
  def handle_info({:doc_updated, msg} = message, socket) do
    if Discarded.frame?(msg, socket.assigns),
      do: ours({:noreply, Discarded.reload(socket)}),
      else: message |> StudioLive.handle_info(socket) |> ours()
  end

  def handle_info(message, socket), do: message |> StudioLive.handle_info(socket) |> ours()

  # The Studio's panes are not drawn here; its editor is.
  defp ours(result, how \\ :reload)
  defp ours({:noreply, socket}, how), do: {:noreply, settle(socket, how)}
  defp ours({:reply, reply, socket}, how), do: {:reply, reply, settle(socket, how)}

  defp settle(socket, how), do: socket |> steer(how) |> strip() |> assign(:panes, [])

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
    %{dataset: dataset, desk_uri: uri, desk_nav: nav} = socket.assigns

    {:noreply, socket} =
      StudioLive.handle_params(%{"dataset" => dataset, "path" => nav}, uri, socket)

    steer(socket, :settled)
  end

  defp desk_pane(%{"desk-pane" => index}, chain) do
    case Integer.parse(to_string(index)) do
      {i, ""} when i >= 0 and i < length(chain) -> i
      _ -> nil
    end
  end

  defp desk_pane(_params, _chain), do: nil

  @doc """
  The pane that edits: a header row with the close link, the document's
  references, and the Studio's editor. Takes the page's own assigns, because the Studio's shell
  reads them.
  """
  def pane(assigns, view) do
    assigns = assign(assigns, :view, view)

    ~H"""
    <section
      id={@view.id}
      class="pane-column dk-pane pane doc dk-doc dk-edit"
      data-pane-index={@view.index}
      data-pane-kind="doc"
      data-pane-editing
      aria-label={@page_title}
    >
      <%!-- The same header row the read-only panes have, so the close link
            covers none of the Studio's toolbar and the narrow layout's Back
            (`bp-desk.js`) finds it. --%>
      <div class="pane-header">
        <span class="pane-header-title">{@page_title}</span>
        <%!-- Sanity's "Split pane right": the same document again, beside
              this pane in its group (`Panes.split_right/3`). The desk edits
              the last pane, so the editor moves to the new one and this pane
              shows the document read-only. --%>
        <.link
          :if={!@edit_failed and !gone?(assigns)}
          patch={Panes.split_right(@chain, @view.index, @base)}
          class="dk-split icon-btn"
          aria-label={gettext("Split pane right")}
          data-tip={gettext("Split pane right")}
        >
          <BarkparkWeb.Icons.icon name="columns" size={14} />
        </.link>
        <%!-- In a split, "Close split pane" drops just this pane
              (`Panes.close_split/3`); the close link drops it and the panes
              to its right. --%>
        <.link
          :if={Panes.split?(@chain, @view.index)}
          patch={Panes.close_split(@chain, @view.index, @base)}
          class="dk-split icon-btn"
          aria-label={gettext("Close split pane")}
          data-tip={gettext("Close split pane")}
          data-desk-close-split
        >
          <BarkparkWeb.Icons.icon name="x" size={14} />
        </.link>
        <%!-- Sanity's "Share document": copy its ID or its URL. --%>
        <ShareMenu.menu
          :if={!@edit_failed and !gone?(assigns) and is_map(assigns[:editor_doc])}
          id={"#{@view.id}-share"}
          doc={@editor_doc}
          chain={@chain}
          index={@view.index}
          base={@base}
        />
        <%!-- The document's actions, none over a document that could not be
              read or was deleted. --%>
        <DocMenu.menu
          id={"#{@view.id}-actions"}
          items={if @edit_failed or gone?(assigns), do: [], else: DocMenu.items(assigns)}
        />
        <a
          href={Panes.close_from(@chain, @view.index, @base)}
          data-phx-link="patch"
          data-phx-link-state="push"
          class="dk-close icon-btn"
          aria-label={gettext("Close %{title}", title: @page_title)}
          data-tip={gettext("Close %{title}", title: @page_title)}
        >
          <span aria-hidden="true">×</span>
        </a>
      </div>
      <%!-- Sanity's Inspect dialog (Ctrl+Alt+I), in a holder that is always
            here, as the notes' is. --%>
      <div id={"#{@view.id}-inspect"}>
        <InspectDialog.dialog
          :if={assigns[:desk_inspect] == true and !@edit_failed and !gone?(assigns) and is_map(assigns[:editor_doc])}
          id={"#{@view.id}-inspect-dialog"}
          title={@page_title}
          doc={@editor_doc}
          schema={assigns[:editor_schema]}
          caller={assigns[:caller_context]}
        />
      </div>
      <%!-- The editor opens the current document, whatever the URL asked for.
            The holder is always in the page: a note that came and went
            between the rows with ids would make the patch move the
            references and the editor below it. --%>
      <div id={"#{@view.id}-notes"}>
        <%!-- Not over a document the editor did not open: it has no current one. --%>
        <p
          :for={note <- (assigns[:editor_doc] && PaneComponent.left_out(@view.pane)) || []}
          class="dk-note"
          data-desk-left-out
        >
          {note}
        </p>
        <Discarded.note
          :if={!@edit_failed and !gone?(assigns) and Discarded.note?(assigns)}
          dropped={Discarded.dropped?(assigns)}
        />
      </div>
      <%!-- Always in the page, shown when there is a link: a pick adds the
            first link while the editor has the focus, and a row that came and
            went would make the patch rebuild the editor below it. --%>
      <nav
        id={"#{@view.id}-refs"}
        class="dk-edit-refs dk-refs"
        aria-label={gettext("References")}
        style={@active_refs == [] && "display: none"}
      >
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
      <%!-- `pane-body` and `doc-form` are the names the TanStack specs know
            the document's form region by. --%>
      <div id={"#{@view.id}-body"} class="pane-body doc-form dk-edit-body" style="flex: 1 1 auto; min-height: 0; display: flex; flex-direction: column; padding: 0; overflow: hidden">
        <%!-- The Studio's shell brings the page's main landmark; the card,
              drawn in its place, is it while the shell is away. --%>
        <div :if={@edit_failed} class="dk-note" role="main" data-desk-edit-failed>
          <p role="alert">{gettext("This document could not be read.")}</p>
          <button type="button" class="btn" phx-click="desk-edit-retry">
            {gettext("Retry")}
          </button>
        </div>
        <%!-- Deleted by someone else: no form is left to write it back. The
              page's notice (`LiveRefresh.gone_notice/1`) says it too. --%>
        <div :if={!@edit_failed and gone?(assigns)} class="dk-note" role="main" data-desk-edit-gone>
          <p>{gettext("This document has been deleted.")}</p>
        </div>
        <%= if !@edit_failed and !gone?(assigns) do %>
          {Components.studio_live_shell(assigns)}
        <% end %>
      </div>
      <%!-- Sanity's pane footer has the same actions behind its own "…"
            ("Open document actions"); the desk draws only that button there.
            It is the pane's last child, so its coming and going moves nothing. --%>
      <div :if={!@edit_failed and !gone?(assigns) and DocMenu.items(assigns) != []}
        id={"#{@view.id}-footer"}
        class="dk-edit-footer"
      >
        <DocMenu.menu id={"#{@view.id}-footer-actions"} items={DocMenu.items(assigns)} place={:footer} />
      </div>
    </section>
    """
  end
end
