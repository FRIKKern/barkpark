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
  the `active`, `editing`, `pending`, `active_refs`, `desk_ref_ids`,
  `desk_nav`, `desk_incoming` (`IncomingRefs`) and `desk_used_in`
  (`DocDialog`) assigns.

  When a Studio handler navigates (delete, duplicate, discard, open a
  backlink, new document), it prints a Studio path under the desk's base
  (`Shared.studio_path/4`). `desk_nav` is the Studio path this module handed
  over; the asked path is read against it and the desk's own chain, so the
  panes the document was opened from stay (`steer/2`).
  """

  use BarkparkWeb, :html

  import Phoenix.LiveView, only: [attach_hook: 4, push_navigate: 2, push_patch: 2]

  require Logger

  alias BarkparkWeb.Studio.Desk.DeleteDialog
  alias BarkparkWeb.Studio.Desk.Discarded
  alias BarkparkWeb.Studio.Desk.DocDialog
  alias BarkparkWeb.Studio.Desk.DocClip
  alias BarkparkWeb.Studio.Desk.DocMenu
  alias BarkparkWeb.Studio.Desk.DocStatus
  alias BarkparkWeb.Studio.Desk.FocusMode
  alias BarkparkWeb.Studio.Desk.HistoryPanel
  alias BarkparkWeb.Studio.Desk.IncomingRefs
  alias BarkparkWeb.Studio.Desk.InspectDialog
  alias BarkparkWeb.Studio.Desk.ItemRefs
  alias BarkparkWeb.Studio.Desk.LeaveGuard
  alias BarkparkWeb.Studio.Desk.LiveRefresh
  alias BarkparkWeb.Studio.Desk.NewDoc
  alias BarkparkWeb.Studio.Desk.PaneComponent
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.PublishedView
  alias BarkparkWeb.Studio.Desk.Refs
  alias BarkparkWeb.Studio.Desk.ReviewChanges
  alias BarkparkWeb.Studio.Desk.RevisionView
  alias BarkparkWeb.Studio.Desk.ShareMenu
  alias BarkparkWeb.Studio.Desk.SlugInUse
  alias BarkparkWeb.Studio.Desk.Tree
  alias BarkparkWeb.Studio.Desk.UnpublishDialog
  alias BarkparkWeb.Studio.Desk.ValidationPanel
  alias BarkparkWeb.Studio.StudioLive
  alias BarkparkWeb.Studio.StudioLive.Components
  alias BarkparkWeb.Studio.StudioLive.DocActions
  alias BarkparkWeb.Studio.StudioLive.Handlers.Fields
  alias BarkparkWeb.Studio.StudioLive.Handlers.Scope
  alias BarkparkWeb.Studio.StudioLive.Paths
  alias BarkparkWeb.Studio.StudioLive.PostIdentity
  alias Phoenix.LiveView.JS

  @doc """
  Mounts as the Studio does (the same state, capability gate and quota
  gate), with no document open.
  """
  def mount(params, session, socket) do
    {:ok, socket} = StudioLive.mount(params, session, socket)

    {:ok,
     socket
     |> assign(
       active: nil,
       editing: nil,
       pending: nil,
       desk_incoming: nil,
       desk_used_in: nil,
       desk_history: nil,
       desk_revision: nil,
       desk_gone_latest: nil,
       desk_new: nil,
       desk_published: nil,
       desk_published_view: nil,
       desk_changes: nil,
       desk_review: nil
     )
     # The open Incoming references panel reads again when someone saves.
     |> attach_hook(:desk_incoming_refs, :handle_info, &on_info/2)
     |> put_away()}
  end

  # The hook's function is this module's own, so the page's hooks can be read
  # from where they are attached; the panel decides what a message means.
  # The deleted document's restore reads its newest revision on the same tick.
  defp on_info(message, socket) do
    {:cont, socket} = IncomingRefs.on_info(message, socket)
    {:cont, message |> RevisionView.on_info(socket) |> then(&PublishedView.on_info(message, &1))}
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
  `pending` (the page then loads it with `edit/2`, in the same patch once
  connected), or put the editor away.
  """
  def follow(socket, panes, dataset) do
    target = target(panes, dataset)

    cond do
      # The same document is still the last pane (a pane closed to its left,
      # a param changed): its editor stays as it is, typing and all.
      # Its inspector may have opened or closed with the URL (`IncomingRefs`).
      target != nil and target == socket.assigns.editing ->
        socket |> assign(:active, length(panes) - 1) |> load_inspectors()

      # A new document: the page loads it next (`edit/2`).
      target ->
        socket |> assign(active: nil, editing: nil, pending: target) |> put_away()

      true ->
        socket |> assign(active: nil, editing: nil, pending: nil) |> put_away()
    end
  end

  # No document is handed to the Studio: no path, no reference links. A
  # dialog one of the document's actions opened goes with the document: the
  # Studio still holds it, and would show the dialog again over the next.
  defp put_away(socket) do
    socket
    |> assign(
      active_refs: [],
      desk_ref_ids: nil,
      desk_nav: nil,
      edit_failed: false,
      desk_incoming: nil,
      desk_history: nil,
      desk_revision: nil,
      desk_gone_latest: nil,
      desk_new: nil,
      desk_published: nil,
      desk_published_view: nil,
      desk_changes: nil,
      desk_review: nil
    )
    |> PostIdentity.close_dialogs()
    |> DocDialog.follow()
  end

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
        |> StudioLive.handle_params(uri, socket |> assign(:desk_nav, path) |> NewDoc.prepare())
        |> ours(:settled)

      {:noreply,
       loaded
       |> assign(
         active: length(panes) - 1,
         editing: target,
         pending: nil,
         edit_failed: false
       )
       |> load_inspectors()}
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

  # What the URL opens beside the form or in its place: the Incoming
  # references and History inspectors, an old revision (`rev`), and what
  # the draft changed (`ReviewChanges`: its change bars and its tab).
  defp load_inspectors(socket),
    do:
      socket
      |> IncomingRefs.load()
      |> HistoryPanel.load()
      |> RevisionView.load()
      |> ReviewChanges.follow()
      |> PublishedView.follow()

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

      # The reference cards in the form are drawn in the browser
      # (`bp-reference-picker.js`): they follow these same targets.
      socket
      |> assign(active_refs: refs, desk_ref_ids: ids)
      |> Phoenix.LiveView.push_event("desk:ref-targets", %{
        refs: Enum.map(refs, &Map.take(&1, [:path, :id, :title, :type]))
      })
    else
      _ -> socket
    end
  end

  defp strip(socket), do: socket

  # The references as menu items, "Open reference: <title>", each a patch to
  # the next pane, as the strip's links were. Not a single reference field's:
  # its card in the form is that link (TanStack's RefInput), and a hidden
  # twin here would answer for it first. An array's rows are not links yet.
  defp ref_items(%{active_refs: refs, chain: chain, view: view, base: base} = assigns) do
    carded = for {name, :one} <- Refs.fields(assigns[:editor_schema] || %{}), do: name

    for ref <- refs, ref.path not in carded do
      %{
        label: gettext("Open reference: %{title}", title: ref.title),
        name: "open-reference",
        event: nil,
        patch: true,
        href:
          Panes.open_after(
            chain,
            view.index,
            %{kind: :doc, id: ref.id, type: ref.type, parent_ref_path: ref.path},
            base
          )
      }
    end
  end

  defp ref_items(_assigns), do: []

  @doc """
  A document the editor's references can point at changed (`LiveRefresh`):
  the strip reads its targets again, though its ids are the same.
  """
  def refs_changed(socket), do: socket |> assign(:desk_ref_ids, nil) |> strip()

  @doc "An event the page does not own is the editor's: the Studio's own handlers."
  # The card's Retry, when the document could not be read: read it again.
  def handle_event("desk-edit-retry", _params, %{assigns: %{edit_failed: true}} = socket),
    do: edit(socket, socket.assigns.pending)

  def handle_event("desk-edit-retry", _params, socket), do: {:noreply, socket}

  # The Studio's `nav_path` says nothing about the pane a "+" was pressed in,
  # so a new document is placed by the event (and an optional `desk-pane`).
  # One that waits for its first edit (`NewDoc`) is only opened: its URL
  # names the way it was started; a type built at once is the Studio's.
  def handle_event("new-document", %{"type" => type} = params, socket) when is_binary(type) do
    case NewDoc.start(type, params, socket) do
      %{} = next ->
        {:noreply,
         socket
         |> repatch(place(socket.assigns, next, params))
         |> Phoenix.LiveView.push_event("bp:focus-new-doc", %{id: next.id})}

      nil ->
        "new-document" |> StudioLive.handle_event(params, socket) |> ours({:new, type, params})
    end
  end

  # Sent by hand with no type: nothing to create.
  def handle_event("new-document", _params, socket), do: {:noreply, socket}

  # The Studio's events that write the open document from its form.
  @form_writes ~w(save autosave paper-block-autosave paper-save-master object-dialog-save)

  # The browser has the form that replaced a draft discarded elsewhere
  # (`Discarded`): its saves are the editor's again. `lost`: keys typed in
  # the old form that were never sent went with it.
  def handle_event("desk-discard-seen", params, socket) do
    socket = if params["lost"] == true, do: Discarded.drop(socket, params["text"]), else: socket
    {:noreply, Discarded.seen(socket)}
  end

  # The open document was deleted by someone else (J32): a save of the form
  # would write it back as a draft. The pane drops the form (`pane/2`); a
  # save still in flight from it is dropped here. So is a save from the form
  # a draft discarded elsewhere had (live.spec:48), until the browser has the
  # new one.
  # While an old revision is shown in the form's place (`RevisionView`), the
  # page takes only the events that cannot write the open document.
  def handle_event(event, params, socket) do
    cond do
      event in @form_writes and gone?(socket.assigns) ->
        {:noreply, socket}

      RevisionView.refuses?(event, socket.assigns) ->
        {:noreply, socket}

      # The published version is read-only: Unpublish is its one write.
      PublishedView.refuses?(event, socket.assigns) ->
        {:noreply, socket}

      event in @form_writes and Discarded.drop?(socket.assigns) ->
        {:noreply, Discarded.drop(socket)}

      true ->
        with :cont <- NewDoc.guard(event, params, socket),
             :cont <- SlugInUse.guard(event, socket) do
          before = socket.assigns[:editor_doc]

          event
          |> StudioLive.handle_event(params, written(socket, event))
          |> ours()
          |> after_restore(event, before)
          |> LeaveGuard.done(event)
        else
          {:halt, socket} -> {:noreply, socket}
        end
    end
  end

  @doc """
  A change the desk built itself for the open document (Paste field), with
  the guards a typed change gets above. It is no browser post and names no
  document (`Fields.autosave_built/2`).
  """
  def write_built(params, socket) do
    cond do
      gone?(socket.assigns) or RevisionView.shown?(socket.assigns) or
          PublishedView.active?(socket.assigns) ->
        {:noreply, socket}

      Discarded.drop?(socket.assigns) ->
        {:noreply, Discarded.drop(socket)}

      true ->
        case NewDoc.room(socket) do
          :cont ->
            params
            |> Fields.autosave_built(written(socket, "autosave"))
            |> Scope.settle_group()
            |> ours()

          {:halt, socket} ->
            {:noreply, socket}
        end
    end
  end

  defp after_restore({:noreply, socket}, event, before),
    do: {:noreply, RevisionView.restored(socket, event, before)}

  defp after_restore({:reply, reply, socket}, event, before),
    do: {:reply, reply, RevisionView.restored(socket, event, before)}

  # A save from the new form: the line that said the draft was discarded goes.
  defp written(socket, event) when event in @form_writes, do: Discarded.clear(socket)
  defp written(socket, _event), do: socket

  # Whether the document in the editor was deleted while it was on the desk.
  defp gone?(%{editing: {_dataset, type, id}} = assigns), do: LiveRefresh.gone?(assigns, type, id)
  defp gone?(_assigns), do: false

  # The Studio's shell, without its profile dialog: the desk draws that one
  # itself, outside the panes (`DeskLive`), so the navbar's pill and the
  # drawer open it with no document open too. Inside a shown revision its
  # form would sit in the revision's disabled fieldset.
  defp shell(assigns), do: Components.studio_live_shell(assign(assigns, :show_profile, false))

  # Whether nothing may be written from the form: its document is gone, or an
  # old revision or the published version is shown in its place.
  defp shut?(assigns),
    do: gone?(assigns) or RevisionView.shown?(assigns) or PublishedView.active?(assigns)

  @doc "A message the page does not own is the editor's."
  # Someone else discarded the open draft: the frame carries the dead draft,
  # which the Studio would put in the form (`Discarded`).
  def handle_info({:doc_updated, msg} = message, socket) do
    if Discarded.frame?(msg, socket.assigns),
      do: ours({:noreply, Discarded.reload(socket)}),
      else: message |> StudioLive.handle_info(socket) |> quiet_remote() |> ours()
  end

  # A tree codelist's pick: the press went to its component
  # (`TreeCodelistField`), past `handle_event/3`'s guards, and comes here as a
  # message. It meets the same ones: nothing is written while an old revision
  # or the published version is shown, into a document deleted elsewhere, or
  # from the form of a draft discarded elsewhere.
  def handle_info({:tree_codelist_pick, _msg} = message, socket) do
    cond do
      shut?(socket.assigns) -> {:noreply, socket}
      Discarded.drop?(socket.assigns) -> {:noreply, Discarded.drop(socket)}
      true -> message |> StudioLive.handle_info(socket) |> ours()
    end
  end

  def handle_info(message, socket), do: message |> StudioLive.handle_info(socket) |> ours()

  # The Studio's panes are not drawn here; its editor is.
  defp ours(result, how \\ :reload)
  defp ours({:noreply, socket}, how), do: {:noreply, settle(socket, how)}
  defp ours({:reply, reply, socket}, how), do: {:reply, reply, settle(socket, how)}

  defp settle(socket, how),
    do:
      socket
      |> steer(how)
      |> strip()
      |> ItemRefs.follow()
      |> form_only()
      |> DocDialog.follow()
      |> HistoryPanel.follow()
      |> ReviewChanges.follow()
      |> PublishedView.follow()
      |> NewDoc.settle()
      |> SlugInUse.refresh()
      |> assign(:panes, [])

  # A document the desk opens from a document node of its own (an
  # `S.document()` child: a singleton) shows the form only, as Sanity's
  # (singleton.spec:64): no view tabs, so no "Split pane right" (`pane/2`),
  # and no type line over the title (`Desk.Style`). The Studio sets the tabs
  # again on every rebuild, so they are cleared after each call it answers.
  defp form_only(socket) do
    if document_node?(List.last(socket.assigns[:chain] || [])),
      do: assign(socket, :editor_views, []),
      else: socket
  end

  # A doc pane that carries its desk node (`Tree.opens/1`, `Panes.parse_singleton/2`).
  defp document_node?(%{kind: :doc, node: node}) when is_binary(node), do: true
  defp document_node?(_pane), do: false

  # ── the Studio's navigation, read against the desk's chain ────────────────

  # A live patch the Studio printed under the desk's base (`Shared.studio_path/4`
  # joins its path with ";") is read back as that Studio path and answered with
  # the desk's own URL. Anything else (a navigate, a URL with a query, a patch
  # with no document handed over) goes out as the Studio printed it.
  #
  # A patch to a path outside the desk (the Studio opens another dataset when
  # the URL's does not exist) is no patch of this page: it leaves for it.
  defp steer(%{redirected: {:live, :patch, %{to: to}}} = socket, how) do
    with %{desk_base: base} when is_binary(base) <- socket.assigns,
         {:in, true} <- {:in, to == base or String.starts_with?(to, [base <> "/", base <> "?"])},
         {:ok, asked} <- asked(to, base) do
      route(socket, asked, how)
    else
      {:in, false} -> push_navigate(%{socket | redirected: nil}, to: to)
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
  defp route(socket, [_ | _] = asked, {:new, type, params}),
    do:
      repatch(
        socket,
        place(socket.assigns, %{kind: :doc, id: List.last(asked), type: type}, params)
      )

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

  # Where a new document opens. From the navbar (`at=root`): its type's list
  # and it, as the TanStack Studio's navbar "+".
  defp place(%{base: base}, %{type: type} = next, %{"at" => "root"}),
    do: Panes.to_path([%{kind: :types}, %{kind: :list, type: type}, next], base)

  defp place(%{chain: chain, base: base}, next, params) do
    last = length(chain) - 1

    case {desk_pane(params, chain), List.last(chain)} do
      {index, _} when is_integer(index) -> Panes.open_after(chain, index, next, base)
      {nil, %{kind: :doc}} -> Panes.to_path(Enum.take(chain, last) ++ [next], base)
      {nil, _} -> Panes.open_after(chain, last, next, base)
    end
  end

  # Another user's save over a form with nothing unsaved is taken in and
  # says nothing: TanStack's footer keeps its "Edited …" and has no words
  # for it (DocumentPane `DocFooter`, task-22f40460dbb71b27). Over unsaved
  # edits it is a conflict (`doc_conflict`) and keeps its words.
  defp quiet_remote({:noreply, socket}) do
    if socket.assigns[:save_status] == "Updated by another user" and
         socket.assigns[:doc_conflict] != true,
       do: {:noreply, assign(socket, :save_status, "")},
       else: {:noreply, socket}
  end

  defp quiet_remote(reply), do: reply

  defp repatch(socket, to), do: push_patch(%{socket | redirected: nil}, to: to)

  @doc """
  The open document was written by this page's own bulk action (`Bulk`): the
  editor reads what is stored now, as after its own Publish. The writes came
  from the action's task, so the Studio took their frames for another
  user's save; they were this tab's, and the footer stops saying so. With no
  document in the editor, nothing.
  """
  def reread(%{assigns: %{editing: {_dataset, _type, _id}, desk_nav: [_ | _]}} = socket) do
    socket = socket |> reload(:reload) |> settle(:settled)

    if socket.assigns[:save_status] == "Updated by another user",
      do: assign(socket, :save_status, ""),
      else: socket
  end

  def reread(socket), do: socket

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

  # What the URL asks for that the pane does not draw (`PaneComponent`). The
  # Incoming references and Validation inspectors are drawn, so their
  # `inspect` is not left out.
  # So are History and the revision it shows (`HistoryPanel`, `RevisionView`).
  defp left_out(pane, assigns) do
    pane =
      if IncomingRefs.open?(pane) or ValidationPanel.open?(pane) or HistoryPanel.open?(pane),
        do: Map.delete(pane, :inspect),
        else: pane

    pane =
      if RevisionView.shown?(assigns) or RevisionView.missing?(assigns),
        do: Map.delete(pane, :rev),
        else: pane

    PaneComponent.left_out(pane)
  end

  # The footer follows the page's perspective (`Panes.perspective/1`):
  # Unpublish in Publish's place at `?perspective=published`. A singleton is
  # never unpublished (the Studio withholds the action): no Unpublish. Over a
  # form the published version is shown read-only (`PublishedView`); a sheet
  # or a paper keeps its own editor and this footer.
  defp footer_perspective(assigns) do
    if "unpublish" in DocActions.withheld_action_names(assigns[:editor_schema]),
      do: :drafts,
      else: Panes.perspective(assigns[:desk_uri])
  end

  # The form's box is keyed by what it draws: a locked version (an old
  # revision, the published version) or the live form. Going back to the live
  # form, the box is a new element, so the form is drawn as on a first load.
  # Morphed back into the same box, Chrome gave the live form's new body no
  # layout box: the pane read blank until reloaded. The fieldset around it
  # keeps its id, so the holders after it, and a History row's focus, stay.
  defp form_key(assigns) do
    cond do
      RevisionView.shown?(assigns) -> "-revision"
      PublishedView.shown?(assigns) -> "-published"
      true -> ""
    end
  end

  # `inspect=on` is the Inspect dialog, drawn over the form, not an inspector.
  defp inspector(pane), do: if(pane[:inspect] == "on", do: nil, else: pane[:inspect])

  @doc """
  The pane that edits: a header row with the close link, the document's
  references, and the Studio's editor. Takes the page's own assigns, because the Studio's shell
  reads them.
  """
  def pane(assigns, view) do
    assigns = assign(assigns, :view, view)

    # The document's problems (`ValidationPanel`): the header's button, the
    # panel and the footer's Publish read the one list. None over a document
    # that could not be read or was deleted.
    problems =
      if assigns.edit_failed or gone?(assigns), do: [], else: ValidationPanel.problems(assigns)

    assigns = assign(assigns, :desk_problems, problems)

    ~H"""
    <section
      id={@view.id}
      class="pane-column dk-pane pane doc dk-doc dk-edit"
      data-pane-index={@view.index}
      data-pane-kind="doc"
      data-testid="document-pane"
      data-pane={"doc:#{@view.pane.id}"}
      data-pane-editing
      data-desk-focused={assigns[:desk_focus] == @view.index}
      data-desk-document={document_node?(@view.pane)}
      data-desk-save={BarkparkWeb.Studio.StudioLive.RefusedSave.token(assigns)}
      data-desk-conflict={
        assigns[:doc_conflict] == true and
          BarkparkWeb.Studio.StudioLive.RefusedSave.token(assigns) == "Updated by another user"
      }
      data-desk-inspecting={inspector(@view.pane) != nil}
      data-desk-held={BarkparkWeb.Studio.Desk.LeaveGuard.message(assigns)}
      data-desk-held-doc={BarkparkWeb.Studio.Desk.LeaveGuard.doc(assigns)}
      aria-label={@page_title}
    >
      <%!-- `data-desk-save`: the save token (`SaveStatus`), not its words;
            `bp-desk.js` asks before the tab closes over "Save failed".
            `data-desk-conflict`: another user saved over edits not saved
            here, and the status still says so. Both, as a guard: a save
            that said "Saved" with `doc_conflict` still set (the removed
            legacy pick's `{:autosave_form, …}` did) is no conflict.
            `Desk.DocStyle` tones the form's status by both marks.
            `data-desk-held`: what `bp-desk.js` asks before leaving this
            document while a field is held (`Desk.LeaveGuard`). --%>
      <%!-- The same header row the read-only panes have, so the close link
            covers none of the Studio's toolbar and the narrow layout's Back
            (`bp-desk.js`) finds it. --%>
      <div class="pane-header">
        <%!-- The TanStack Studio's Published / Draft pills (`DocStatus`). With
              the form's big title drawn (`Desk.DocStyle`), the title below is
              for screen readers only, unless it holds focus mode's way back. --%>
        <%!-- They switch the perspective, as TanStack's (`PublishedView`). --%>
        <DocStatus.chips
          :if={!@edit_failed and !gone?(assigns) and is_map(assigns[:editor_doc])}
          {DocStatus.state(assigns)}
          perspective={Panes.perspective(assigns[:desk_uri])}
          published_href={HistoryPanel.path(@chain, @view.index, @base, :published, %{})}
          drafts_href={HistoryPanel.path(@chain, @view.index, @base, :drafts, %{})}
        />
        <%!-- In focus mode the title line is the panes it hides, each a way
              back (`FocusMode`). One title element, the same tag, either way:
              an element that changed (a span or h2 swapped for a div) makes the
              patch re-insert the focus mode button after it, and a re-inserted
              button loses the focus. A div with the heading role, because the
              breadcrumb is a nav and a nav cannot sit in an h2. --%>
        <div class="pane-header-title" role="heading" aria-level="2">
          <%= if assigns[:desk_focus] == @view.index do %>
            <FocusMode.crumbs
              views={@desk_panes}
              titles={@titles}
              index={@view.index}
              chain={@chain}
              base={@base}
              title={@page_title}
            />
          <% else %>
            {@page_title}
          <% end %>
        </div>
        <%!-- TanStack's order: Share, the "…", Split, Focus, close. --%>
        <%!-- Sanity's "Share document": copy its ID or its URL. --%>
        <ShareMenu.menu
          :if={!@edit_failed and !gone?(assigns) and is_map(assigns[:editor_doc])}
          id={"#{@view.id}-share"}
          doc={@editor_doc}
          chain={@chain}
          index={@view.index}
          base={@base}
        />
        <%!-- Sanity's Validation button, where TanStack has it: after Share,
              and only while there is a problem to show or its panel is open. --%>
        <ValidationPanel.button_sheet />
        <ValidationPanel.status
          :if={!@edit_failed and !gone?(assigns) and is_map(assigns[:editor_doc])}
          id={"#{@view.id}-validation-status"}
          problems={@desk_problems}
        />
        <ValidationPanel.button
          id={"#{@view.id}-validation-button"}
          problems={@desk_problems}
          pane={@view.pane}
          chain={@chain}
          index={@view.index}
          base={@base}
          perspective={Panes.perspective(assigns[:desk_uri])}
        />
        <%!-- The document's actions, none over a document that could not be
              read or was deleted. --%>
        <%!-- The document's references are in it too, each a link that opens
              the next pane: the TanStack Studio has no row of them. --%>
        <DocMenu.menu
          id={"#{@view.id}-actions"}
          items={
            if @edit_failed or gone?(assigns),
              do: [],
              else:
                assigns
                |> DocMenu.items()
                |> NewDoc.offered(assigns)
                |> DocMenu.with_incoming(
                  IncomingRefs.menu_item(
                    @chain,
                    @view.index,
                    @base,
                    Panes.perspective(assigns[:desk_uri])
                  )
                )
                |> DocMenu.with_refs(ref_items(assigns))
                |> DocClip.with_items()
                |> HistoryPanel.with_item(
                  @chain,
                  @view.index,
                  @base,
                  Panes.perspective(assigns[:desk_uri])
                )
                |> RevisionView.menu(assigns)
                |> PublishedView.menu(assigns)
          }
        />
        <%!-- Sanity's "Split pane right": the same document again, beside
              this pane in its group (`Panes.split_right/3`). The desk edits
              the last pane, so the editor moves to the new one and this pane
              shows the document read-only. --%>
        <.link
          :if={!@edit_failed and !gone?(assigns) and !document_node?(@view.pane)}
          patch={Panes.split_right(@chain, @view.index, @base)}
          class="dk-split icon-btn"
          data-desk-split-right
          aria-label={gettext("Split pane right")}
          data-tip={gettext("Split pane right")}
        >
          <BarkparkWeb.Icons.icon name="columns" size={14} />
        </.link>
        <FocusMode.button
          id={"#{@view.id}-focus"}
          index={@view.index}
          on={assigns[:desk_focus] == @view.index}
        />
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
      <%!-- The editor opens the current document, whatever the URL asked for.
            The holder is always in the page: a note that came and went
            between the rows with ids would make the patch move the
            references and the editor below it. --%>
      <div id={"#{@view.id}-notes"}>
        <%!-- Not over a document the editor did not open: it has no current
              one, still holds the one before (the read failed), or the one
              it held was deleted. --%>
        <p
          :for={
            note <-
              (assigns[:editor_doc] && !@edit_failed && !gone?(assigns) &&
                 left_out(@view.pane, assigns)) || []
          }
          class="dk-note"
          data-desk-left-out
        >
          {note}
        </p>
        <%!-- Why Beta is not offered (duplicate block ids, blocks it cannot
              edit safely). The Studio says it in its toolbar row, which the
              desk hides (`Desk.Style`). --%>
        <p
          :if={!@edit_failed and !gone?(assigns) and assigns[:editor_blocks_identity_error]}
          class="dk-note"
          role="alert"
          data-desk-identity-error
        >
          {Components.beta_identity_error_message(@editor_blocks_identity_error)}
        </p>
        <Discarded.note
          :if={!@edit_failed and !gone?(assigns) and Discarded.note?(assigns)}
          dropped={Discarded.dropped?(assigns)}
          lost_text={Discarded.lost_text(assigns)}
          cleared={Discarded.cleared?(assigns)}
        />
      </div>
      <%!-- The TanStack Studio's title bar (`.doc-title-bar`): the title, and
            under it the views, Editor and JSON (Sanity's). JSON is the
            desk's Inspect dialog, so the tab opens it (`inspect=on`, as
            Ctrl+Alt+I). A singleton has one view, so no tabs, as Sanity's.
            The bar is always in the page (with an id): a row that came and
            went would make the patch rebuild the editor below it. --%>
      <div id={"#{@view.id}-title-bar"} class="doc-title-bar dk-title-bar">
        <%= if !@edit_failed and !gone?(assigns) and is_map(assigns[:editor_doc]) do %>
          <div class="title-row">
            <span class="title">
              {if PublishedView.shown?(assigns), do: PublishedView.title(assigns), else: @page_title}
            </span>
          </div>
          <div :if={!document_node?(@view.pane)} class="view-tabs" role="tablist" aria-label={gettext("Views")}>
            <button type="button" role="tab" aria-selected="true" tabindex="0">{gettext("Editor")}</button>
            <button
              type="button"
              role="tab"
              aria-selected="false"
              tabindex="-1"
              phx-click={JS.push("desk-inspect", value: %{open: true})}
              data-desk-json-tab
            >
              {gettext("JSON")}
            </button>
          </div>
        <% end %>
      </div>
      <%!-- `pane-body` and `doc-form` are the names the TanStack specs know
            the document's form region by. --%>
      <div id={"#{@view.id}-body"} class="pane-body doc-form dk-edit-body" style="flex: 1 1 auto; min-height: 0; display: flex; flex-direction: column; padding: 0; overflow: hidden">
        <%!-- Sanity's Inspect (Ctrl+Alt+I), TanStack's place for it: a layer
              over this pane's form only, under its header and over its
              footer (`InspectDialog`). The holder is always here, as the
              notes' is. --%>
        <div id={"#{@view.id}-inspect"} class="dk-inspect-layer" data-desk-inspect-layer>
          <InspectDialog.dialog
            :if={assigns[:desk_inspect] == true and !@edit_failed and !gone?(assigns) and is_map(assigns[:editor_doc])}
            id={"#{@view.id}-inspect-dialog"}
            title={@page_title}
            doc={@editor_doc}
            schema={assigns[:editor_schema]}
            caller={assigns[:caller_context]}
          />
        </div>
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
          <RevisionView.restore_latest
            doc={PostIdentity.of(%{assigns: assigns})}
            revision={assigns[:desk_gone_latest]}
          />
        </div>
        <%!-- The Studio's own delete and unpublish modals are kept out of the
              desk: the desk draws its dialogs below, from the same assigns. --%>
        <%!-- An old revision (`rev`) is the Studio's form over its values
              (`RevisionView`); one that is not shown says so. So is the
              published version in the published perspective
              (`PublishedView`). Their fields sit in a disabled fieldset inside
              the shell (`ReadonlyFields`), under group tabs that still switch.
              The live form sits in the same holder: the holders after it keep
              their place when a History row is picked, so the row keeps the
              focus. Inside it, the form's box is keyed by what it draws
              (`form_key/1`). --%>
        <fieldset
          id={"#{@view.id}-form-holder"}
          class="dk-revision-form"
          data-desk-revision-form={RevisionView.shown?(assigns)}
          data-desk-published-form={PublishedView.shown?(assigns)}
        >
          <div id={"#{@view.id}-form-box#{form_key(assigns)}"} class="dk-form-box" data-desk-form-box>
          <%= cond do %>
            <% @edit_failed or gone?(assigns) -> %>
            <% RevisionView.shown?(assigns) -> %>
              {shell(RevisionView.shell_assigns(assigns))}
            <% PublishedView.shown?(assigns) -> %>
              {shell(PublishedView.shell_assigns(assigns))}
            <% RevisionView.missing?(assigns) -> %>
              <p class="dk-note" role="alert" data-desk-revision-missing>
                {gettext("This revision can't be found. Pick another entry in the history.")}
              </p>
            <% true -> %>
              {shell(
                assigns
                |> assign(show_delete: false, show_unpublish_guard: false)
                |> HistoryPanel.waiting()
              )}
          <% end %>
          </div>
        </fieldset>
        <%!-- The inspector's holder (TanStack's `aside` beside the form:
              validation, history, incoming references). Hidden until an
              inspector fills it; `data-inspect` is the pane's `inspect` from
              the URL, which says which one. Incoming references is the first
              (`IncomingRefs`), and never over a document that could not be
              read or was deleted. --%>
        <IncomingRefs.holder
          id={"#{@view.id}-inspector"}
          panel={if(@edit_failed or gone?(assigns), do: nil, else: assigns[:desk_incoming])}
          inspect={inspector(@view.pane)}
          chain={@chain}
          index={@view.index}
          base={@base}
          menu_button={"#{@view.id}-actions-button"}
          perspective={Panes.perspective(assigns[:desk_uri])}
        />
        <%!-- The History inspector, in the same place (`HistoryPanel`). --%>
        <HistoryPanel.holder
          id={"#{@view.id}-history"}
          panel={if(@edit_failed or gone?(assigns), do: nil, else: assigns[:desk_history])}
          pane={@view.pane}
          chain={@chain}
          index={@view.index}
          base={@base}
          menu_button={"#{@view.id}-actions-button"}
          perspective={Panes.perspective(assigns[:desk_uri])}
          review={assigns[:desk_review]}
        />
        <%!-- The Validation inspector, in the same place beside the form
              (`ValidationPanel`): one `inspect` in the URL, so one of the
              two at a time. --%>
        <ValidationPanel.holder
          :if={!@edit_failed and !gone?(assigns) and is_map(assigns[:editor_doc])}
          id={"#{@view.id}-validation"}
          button={"#{@view.id}-validation-button"}
          problems={@desk_problems}
          pane={@view.pane}
          chain={@chain}
          index={@view.index}
          base={@base}
          perspective={Panes.perspective(assigns[:desk_uri])}
          schema={assigns[:editor_schema]}
          nav_group={assigns[:nav_group]}
          form={assigns[:editor_form]}
        />
        <%!-- The desk's own dialogs for the Studio's document actions
              (`DocDialog`): the Studio's handlers open and close them. The
              holder is always here, as the notes' is. --%>
        <div id={"#{@view.id}-dialogs"}>
          <DeleteDialog.dialog
            :if={assigns[:show_delete] == true and !@edit_failed and !gone?(assigns) and is_map(assigns[:editor_doc])}
            id={"#{@view.id}-delete-dialog"}
            title={@page_title}
            published?={DocStatus.state(assigns).published?}
            rows={DocDialog.rows(assigns[:desk_used_in])}
            base={@base}
          />
          <UnpublishDialog.dialog
            :if={assigns[:show_unpublish_guard] == true and !@edit_failed and !gone?(assigns) and is_map(assigns[:editor_doc])}
            id={"#{@view.id}-unpublish-dialog"}
            title={@page_title}
            rows={DocDialog.rows(assigns[:desk_used_in])}
            base={@base}
            return_to={"#{@view.id}-actions-button"}
          />
        </div>
      </div>
      <%!-- Sanity's pane footer: what happened last, Publish, and the same
            actions behind its own "…" ("Open document actions"),
            `Desk.DocFooter`. It is the pane's last child, so its coming and
            going moves nothing. --%>
      <%!-- While an old revision is shown, its own footer: when it is from,
            and Revert to revision (`RevisionView`). --%>
      <RevisionView.footer
        :if={RevisionView.shown?(assigns) and !@edit_failed and !gone?(assigns)}
        id={"#{@view.id}-revision-footer"}
        revision={@desk_revision}
        menu_button={"#{@view.id}-actions-button"}
        seen_rev={BarkparkWeb.Studio.StudioLive.Handlers.History.seen_rev(assigns)}
      />
      <%!-- The published version's footer (`PublishedView`): its words and
            Unpublish, no "…", as TanStack's `PublishedFooter`. --%>
      <div
        :if={PublishedView.shown?(assigns) and !@edit_failed and !gone?(assigns)}
        id={"#{@view.id}-footer"}
        class="dk-edit-footer doc-footer"
      >
        <BarkparkWeb.Studio.Desk.DocFooter.bar
          id={"#{@view.id}-footer"}
          status={PublishedView.status(assigns)}
          menu_button={"#{@view.id}-actions-button"}
          perspective={:published}
          published?={PublishedView.published?(assigns)}
          unpublish?={footer_perspective(assigns) == :published}
        />
      </div>
      <% items =
        if @edit_failed or gone?(assigns) or RevisionView.shown?(assigns) or
             PublishedView.shown?(assigns),
           do: [],
           else: NewDoc.offered(DocMenu.items(assigns), assigns) %>
      <div :if={items != []} id={"#{@view.id}-footer"} class="dk-edit-footer doc-footer">
        <BarkparkWeb.Studio.Desk.DocFooter.bar
          id={"#{@view.id}-footer"}
          status={BarkparkWeb.Studio.Desk.DocFooter.status(assigns)}
          publish={Enum.find(items, &(&1.event == "publish"))}
          menu_button={"#{@view.id}-footer-actions-button"}
          perspective={footer_perspective(assigns)}
          published?={DocStatus.state(assigns).published?}
          blocked={ValidationPanel.blocking(@desk_problems)}
          review={
            HistoryPanel.path(@chain, @view.index, @base, Panes.perspective(assigns[:desk_uri]), %{
              inspect: "review",
              rev: nil
            })
          }
        />
        <DocMenu.menu
          id={"#{@view.id}-footer-actions"}
          items={
            HistoryPanel.with_item(
              items,
              @chain,
              @view.index,
              @base,
              Panes.perspective(assigns[:desk_uri])
            )
          }
          place={:footer}
        />
      </div>
    </section>
    """
  end
end
