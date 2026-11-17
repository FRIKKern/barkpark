defmodule BarkparkWeb.Studio.Desk.Bulk do
  @moduledoc """
  A desk list's selection and its bulk publish and unpublish (B03, B07), the
  TanStack Studio's (`Structure.tsx` `ListPane`, `BulkBar.tsx`, `lib/bulk.ts`,
  `UnpublishDialog.tsx`). `BulkBar` draws it; this module holds the state and
  does the work.

  ## State

  The page (`DeskLive`) holds every list's selection in `desk_bulk`, by the
  pane's id: `%{type, scope, selecting, ids, set, last, running}`. `scope` is
  the dataset, workspace and project it was ticked in: a selection is drawn
  and acted on there only, and a patch to another dataset ends it. `ids` are the
  ticked documents in the order they were ticked, never more than
  `max_selected/0`. A pane gets its own entry as its `bulk` assign. A pane
  that leaves the page takes its selection with it (`follow/2`).

  ## Events

  A tick and a Shift-click go to the list's own pane (`pick/2`), which knows
  the rows and their order; it tells the page which documents
  (`{:desk_bulk_pick, pane, mode, ids}`, `picked/4`). Only ids of rows the
  pane holds are passed on. Nothing is written by either.

  Everything else is the page's own event, so it passes the Studio's
  capability gate (`Caps`) like any other event of the page:

    * `bulk-select` starts or stops selecting; `bulk-clear` stops it.
    * `bulk-publish` publishes the ticked documents.
    * `bulk-unpublish` opens the dialog. Sent again with `confirm` while that
      dialog is open and has read who refers, it unpublishes; with `disconnect` too, it first takes
      the references out of the documents that hold them.
    * `bulk-unpublish-close` puts the dialog away.

  ## What is written

  Only the documents ticked in that pane, of the pane's own type (from the
  URL the page parsed, never from the event), in the dataset the socket
  holds, with the socket's own caller and scope (`Shared.hook_opts/1`,
  `Shared.disconnect_opts/1`). Each document goes through
  `Content.publish_document/4` or `Content.unpublish_document/4` on its own,
  so one refusal never stops the rest. An unpublish writes only the
  documents the dialog named: the ones that were published when it opened.
  When an action starts, what is stored of each ticked document is read
  again (`stored/2`): one with nothing to do is left alone, one that is gone
  is said to have failed.

  The work runs in a task (`start_async`), so the page stays live; the task
  tells the pane how far it is. One summary says what happened
  (`summary/2`), and the selection ends.
  """

  use Gettext, backend: BarkparkWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, start_async: 3]

  alias BarkparkWeb.Studio.Desk.BulkRun
  alias BarkparkWeb.Studio.Desk.DocDialog
  alias BarkparkWeb.Studio.Desk.EditorHost

  # The Studio's cap (`Handlers.Bulk`), and the TanStack Studio's MAX_SELECTED.
  @max 500

  @doc "The most documents one selection holds."
  def max_selected, do: @max

  @doc "The page's assigns, with nothing selected."
  def init(socket) do
    socket
    |> assign(:desk_bulk, %{})
    |> assign(:desk_bulk_confirm, nil)
    |> assign(:desk_bulk_scope, nil)
  end

  @doc """
  The URL changed. A selection lives as long as its pane is on the page, and
  only in the dataset and scope it was ticked in: a patch to another dataset
  (the same pane id, the same document ids) ends every selection, so
  nothing ticked in one dataset is ever written in another. Called once the
  page holds the new dataset and scope.
  """
  def follow(socket, views) do
    scope = scope_key(socket)

    if socket.assigns.desk_bulk_scope == scope do
      ids = MapSet.new(views, & &1.id)
      bulk = Map.filter(socket.assigns.desk_bulk, fn {pane, _} -> MapSet.member?(ids, pane) end)
      confirm = socket.assigns.desk_bulk_confirm
      confirm = if confirm && MapSet.member?(ids, confirm.pane), do: confirm

      socket |> assign(:desk_bulk, bulk) |> assign(:desk_bulk_confirm, confirm)
    else
      socket
      |> assign(:desk_bulk, %{})
      |> assign(:desk_bulk_confirm, nil)
      |> assign(:desk_bulk_scope, scope)
    end
  end

  # Where a selection belongs: the dataset, and the workspace and project.
  defp scope_key(%{assigns: assigns}),
    do: {assigns[:dataset], Keyword.take(assigns[:scope] || [], [:workspace_id, :project_id])}

  @doc "A pane's selection, for its `bulk` assign: only one ticked in the page's dataset and scope."
  def of(%{desk_bulk: bulk, desk_bulk_scope: scope}, pane) do
    case bulk[pane] do
      %{scope: ^scope} = state -> state
      _ -> nil
    end
  end

  @doc """
  Whether a pane's rows can be ticked: a plain document list. Not a tree
  level (its rows open the next level) and not a menu.
  """
  def selectable?(%{kind: :list} = pane, node),
    do: is_nil(pane[:tree_parent]) and not match?(%{tree: %{}}, node)

  def selectable?(_pane, _node), do: false

  @doc "Whether the list shows its ticks: selecting was started, or a row is ticked."
  def active?(%{selecting: selecting, ids: ids}), do: selecting or ids != []
  def active?(_none), do: false

  @doc "Whether `id` is ticked."
  def picked?(%{set: set}, id), do: MapSet.member?(set, id)
  def picked?(_none, _id), do: false

  # ── the pane's side ────────────────────────────────────────────────────────

  @doc """
  A tick, or a Shift-click (`range`), in the pane `socket` is. The pane knows
  its rows: a tick toggles one document; a range adds every row from the
  last tick to this one, as the list shows them. Ids the pane does not hold
  are dropped.
  """
  def pick(%{assigns: assigns} = socket, %{"id" => id} = params) when is_binary(id) do
    held = for %{next: %{kind: :doc, id: doc}} <- entries(assigns), do: doc
    last = assigns[:bulk] && assigns.bulk.last

    picks =
      cond do
        not selectable?(assigns.pane, assigns.node) or id not in held ->
          nil

        params["range"] == "true" and is_binary(last) and last in held ->
          [from, to] = Enum.sort([index(held, last), index(held, id)])
          {:add, Enum.slice(held, from..to//1)}

        true ->
          {:toggle, [id]}
      end

    with {mode, ids} <- picks, do: send(self(), {:desk_bulk_pick, assigns.id, mode, ids, id})

    {:noreply, socket}
  end

  def pick(socket, _params), do: {:noreply, socket}

  defp entries(%{data: %{ok?: true, result: %{entries: entries}}}) when is_list(entries),
    do: entries

  defp entries(_assigns), do: []

  defp index(held, id), do: Enum.find_index(held, &(&1 == id))

  # ── the page's side ────────────────────────────────────────────────────────

  @doc "The pane's answer to a tick: the documents to toggle or add, and the row ticked last."
  def picked(socket, pane, mode, ids, last) when is_list(ids) do
    with %{} = view <- view(socket, pane),
         state = state(socket, view),
         nil <- state.running do
      case mode do
        :toggle -> toggle(socket, pane, state, hd(ids))
        :add -> put(socket, pane, add(state, ids, last))
      end
    else
      _ -> socket
    end
  end

  defp toggle(socket, pane, state, id) do
    cond do
      MapSet.member?(state.set, id) ->
        ids = List.delete(state.ids, id)
        put(socket, pane, %{state | ids: ids, set: MapSet.delete(state.set, id), last: id})

      length(state.ids) >= @max ->
        socket
        |> toast(
          "caution",
          gettext("Selection limit reached (%{max_selected})", max_selected: @max)
        )
        |> put(pane, %{state | last: id})

      true ->
        put(socket, pane, add(state, [id], id))
    end
  end

  # A range stops at the cap, without a word, as the TanStack Studio's.
  defp add(state, ids, last) do
    fresh = Enum.reject(ids, &MapSet.member?(state.set, &1))
    fresh = Enum.take(fresh, @max - length(state.ids))

    %{
      state
      | ids: state.ids ++ fresh,
        set: MapSet.union(state.set, MapSet.new(fresh)),
        last: last
    }
  end

  @doc "The page's bulk events (the moduledoc lists them)."
  def handle_event("bulk-select", %{"pane" => pane} = params, socket) do
    case view(socket, pane) do
      nil ->
        {:noreply, socket}

      view ->
        if params["on"] == "true",
          do: {:noreply, put(socket, pane, %{state(socket, view) | selecting: true})},
          else: {:noreply, stop(socket, pane)}
    end
  end

  def handle_event("bulk-clear", %{"pane" => pane}, socket) when is_binary(pane),
    do: {:noreply, stop(socket, pane)}

  def handle_event("bulk-publish", %{"pane" => pane}, socket) do
    case ready(socket, pane) do
      nil ->
        {:noreply, socket}

      state ->
        stored = BulkRun.stored(socket, state)

        plan =
          for id <- state.ids do
            case stored[id] do
              {true, _published?} -> {id, :write}
              {false, true} -> {id, :skipped}
              _gone -> {id, :gone}
            end
          end

        {:noreply, run(socket, pane, state, :publish, plan, [])}
    end
  end

  # The dialog's own button, while the dialog is open for this pane.
  def handle_event(
        "bulk-unpublish",
        %{"pane" => pane, "confirm" => "true"} = params,
        %{assigns: %{desk_bulk_confirm: %{pane: pane, checking: false} = confirm}} = socket
      ) do
    case ready(socket, pane) do
      nil ->
        {:noreply, assign(socket, :desk_bulk_confirm, nil)}

      state ->
        named = MapSet.new(confirm.docs, & &1.id)
        stored = BulkRun.stored(socket, state)

        # Only what the dialog named, and only what is still published.
        plan =
          for id <- state.ids do
            case stored[id] do
              {_draft?, true} -> {id, if(MapSet.member?(named, id), do: :write, else: :skipped)}
              {true, false} -> {id, :skipped}
              _gone -> {id, :gone}
            end
          end

        live = for {id, :write} <- plan, do: id

        cut =
          if params["disconnect"] == "true",
            do: for(%{id: id, rows: [_ | _]} <- confirm.docs, id in live, do: id),
            else: []

        socket = assign(socket, :desk_bulk_confirm, nil)
        {:noreply, run(socket, pane, state, :unpublish, plan, cut)}
    end
  end

  def handle_event("bulk-unpublish", %{"pane" => pane}, socket) do
    case ready(socket, pane) do
      nil -> {:noreply, socket}
      state -> {:noreply, ask(socket, pane, state)}
    end
  end

  def handle_event("bulk-unpublish-close", _params, socket),
    do: {:noreply, assign(socket, :desk_bulk_confirm, nil)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The dialog: which of the ticked documents are published (one read), then
  # who refers to each, read in a task while the dialog says it is looking
  # (its buttons wait). None published: nothing to ask and nothing to write.
  defp ask(socket, pane, state) do
    %{dataset: dataset, scope: scope} = socket.assigns
    stored = BulkRun.stored(socket, state)
    ids = for id <- state.ids, match?({_draft?, true}, stored[id]), do: id

    if ids == [] do
      left =
        for id <- state.ids,
            do: if(stored[id] == {true, false}, do: :skipped, else: BulkRun.gone())

      socket |> toast(BulkRun.summary(:unpublish, left)) |> stop(pane)
    else
      titles = socket.assigns.doc_titles
      docs = for id <- ids, do: %{id: id, title: titles[id] || id, rows: []}
      reader = %{dataset: dataset, scope: scope}

      socket
      |> assign(:desk_bulk_confirm, %{pane: pane, docs: docs, checking: true})
      |> start_async({:desk_bulk, {:refs, pane}}, fn -> DocDialog.rows_for(ids, reader) end)
    end
  end

  # The run is a task, so the page stays live; the bar says it is running.
  defp run(socket, pane, state, action, plan, cut) do
    work = BulkRun.work(socket, pane, state, action, plan, cut)

    socket
    |> put(pane, %{state | running: %{action: action, n: length(plan)}})
    |> start_async({:desk_bulk, {:run, pane}}, work)
  end

  @doc "The summary of an action (`BulkRun.summary/2`)."
  defdelegate summary(action, outcomes), to: BulkRun

  @doc "A task is back: who refers to the dialog's documents, or what an action did."
  def handle_async({:refs, pane}, {:ok, %{} = used}, socket) do
    case socket.assigns.desk_bulk_confirm do
      %{pane: ^pane, checking: true} = confirm ->
        docs = Enum.map(confirm.docs, &%{&1 | rows: Map.get(used, &1.id, [])})
        {:noreply, assign(socket, :desk_bulk_confirm, %{confirm | docs: docs, checking: false})}

      _ ->
        {:noreply, socket}
    end
  end

  # Who refers could not be read: nothing is unpublished unseen.
  def handle_async({:refs, pane}, _failed, socket) do
    case socket.assigns.desk_bulk_confirm do
      %{pane: ^pane} ->
        {:noreply,
         socket
         |> assign(:desk_bulk_confirm, nil)
         |> toast(
           "critical",
           gettext("Could not check which documents refer to them. Retry before unpublishing.")
         )}

      _ ->
        {:noreply, socket}
    end
  end

  # One summary, and the selection ends.
  def handle_async({:run, pane}, {:ok, {action, outcomes, written}}, socket)
      when is_list(outcomes) do
    {:noreply,
     socket |> toast(BulkRun.summary(action, outcomes)) |> stop(pane) |> reread(written)}
  end

  # Refused before anything was unpublished: the ticks stay.
  def handle_async({:run, pane}, {:ok, {:refused, why}}, socket),
    do: {:noreply, socket |> toast("critical", why) |> idle(pane)}

  def handle_async({:run, pane}, _crashed, socket) do
    {:noreply,
     socket
     |> toast("critical", gettext("The bulk action stopped before it finished"))
     |> idle(pane)}
  end

  # The document open in the editor was one of them: the editor reads it
  # again, as after its own Publish. Its frames came from the task, so the
  # Studio took them for someone else's save. Unsaved typing is left alone.
  defp reread(%{assigns: %{editing: {_dataset, _type, id}} = assigns} = socket, written) do
    if id in written and assigns[:editor_dirty] != true,
      do: EditorHost.reread(socket),
      else: socket
  end

  defp reread(socket, _written), do: socket

  defp idle(socket, pane) do
    case of(socket.assigns, pane) do
      %{} = state -> put(socket, pane, %{state | running: nil})
      nil -> socket
    end
  end

  # ── state ──────────────────────────────────────────────────────────────────

  # The open list pane with this id, if its rows can be ticked.
  defp view(socket, pane) when is_binary(pane) do
    Enum.find(socket.assigns.desk_panes, fn view ->
      view.id == pane and selectable?(view.pane, view.node)
    end)
  end

  defp view(_socket, _pane), do: nil

  defp state(socket, view) do
    of(socket.assigns, view.id) ||
      %{
        type: view.pane.type,
        scope: scope_key(socket),
        selecting: false,
        ids: [],
        set: MapSet.new(),
        last: nil,
        running: nil
      }
  end

  # A pane's selection that an action may start on: ticked, and none running.
  defp ready(socket, pane) do
    with %{} <- view(socket, pane),
         %{ids: [_ | _], running: nil} = state <- of(socket.assigns, pane) do
      state
    else
      _ -> nil
    end
  end

  defp put(socket, pane, state) do
    socket
    |> assign(:desk_bulk, Map.put(socket.assigns.desk_bulk, pane, state))
    |> push_event("desk:bulk", %{
      pane: pane,
      active: active?(state),
      running: state.running != nil
    })
  end

  # Selecting ends: no ticks, no bar, no dialog.
  defp stop(socket, pane) do
    confirm = socket.assigns.desk_bulk_confirm
    confirm = if confirm && confirm.pane != pane, do: confirm

    socket
    |> assign(:desk_bulk, Map.delete(socket.assigns.desk_bulk, pane))
    |> assign(:desk_bulk_confirm, confirm)
    |> push_event("desk:bulk", %{pane: pane, active: false, running: false})
  end

  defp toast(socket, %{tone: tone, title: title, description: description}),
    do:
      push_event(socket, "desk:bulk-toast", %{tone: tone, title: title, description: description})

  defp toast(socket, tone, title),
    do: push_event(socket, "desk:bulk-toast", %{tone: tone, title: title, description: nil})
end
