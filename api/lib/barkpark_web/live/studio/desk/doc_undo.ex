defmodule BarkparkWeb.Studio.Desk.DocUndo do
  @moduledoc """
  The desk document's undo and redo (F7, task-c25c112913859b11), as the
  TanStack Studio's (`app/src/lib/edits.ts` `undo`, `DocumentPane.tsx`):
  Mod+Z takes back this editor's last own change, Shift+Mod+Z or Mod+Y puts
  it back, and another editor's words stay.

  The browser's own undo cannot do it. A text input's undo history is gone
  once a script sets its value, which `bp-array-focus.js` does when another
  editor's save reaches the focused field, and it knows nothing of the other
  fields or of what others wrote since.

  ## What is kept

  For each typed edit of a free-text field that landed (`record/3`), a step:
  the text the page wrote it from and the text it posted. The page's base
  is the one the save merged the post from (`RemoteValues.put_bases/3`), so
  a step holds this editor's keys and none of the words another editor's
  save brought in between. Steps of one field closer than 600 ms make one
  change, one Mod+Z. The changes belong to the document the editor holds:
  another document's start empty. Only top-level free-text fields are kept;
  a select, a list or a widget is not undone here.

  ## Undo

  `desk-undo` (from `bp-desk-undo.js`) names its document (`PostIdentity`).
  The last change's steps are taken back out of the text the store holds
  now (`TextUndo`). A change someone else wrote into is left as it is and
  dropped, as the TanStack Studio's. What comes out is saved as a typed edit
  of the field is (`EditorHost.write_built/2`, with the desk's guards), and
  merged by the save onto what the store holds by then. The page is told the
  field, its new value and the value it showed (`desk:undone`): the script
  sets the field when it still shows that value, and puts the focus in it.

  Nothing is undone over an old revision (`RevisionView`) or in the
  published perspective: both are read-only, as the TanStack Studio's
  locked document is.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Barkpark.Content
  alias Barkpark.Content.TextRebase
  alias Barkpark.Content.TextUndo
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.Desk.EditorHost
  alias BarkparkWeb.Studio.Desk.FieldActions
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.PublishedView
  alias BarkparkWeb.Studio.Desk.RevisionView
  alias BarkparkWeb.Studio.StudioLive.Handlers.RemoteValues
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @event "desk:undone"

  # Typing in one field within this long of the last step is one change.
  @group_ms 600

  # Changes kept, and the bytes their texts may hold together: the oldest go
  # first.
  @max_changes 100
  @max_bytes 1_000_000

  @doc """
  The form names of the fields an undo is kept for (`record/3`), space
  separated, for the form's `data-desk-undo-keys`. `bp-desk-undo.js` takes
  Mod+Z in these inputs only; in every other input (a slug, a url, a number,
  a nested or list string) the browser keeps its own undo.
  """
  @spec names(map() | nil) :: String.t()
  def names(schema) do
    fields =
      case schema do
        %{fields: fields} when is_list(fields) -> fields
        _ -> []
      end

    ["title" | for(%{"name" => key} <- fields, is_binary(key), do: key)]
    |> Enum.uniq()
    |> Enum.filter(&RemoteValues.free_text?(schema, &1))
    |> Enum.map_join(" ", &"doc[#{&1}]")
  end

  @doc """
  After the form's `autosave` post `params` (the result of handling it on
  `before`): the step it made, when it landed.
  """
  def record({:noreply, socket}, params, before), do: {:noreply, record(socket, params, before)}

  def record({:reply, reply, socket}, params, before),
    do: {:reply, reply, record(socket, params, before)}

  def record(%Phoenix.LiveView.Socket{} = socket, params, before) do
    with %{"_target" => ["doc", key]} when is_binary(key) <- params,
         %{"doc" => %{^key => posted}} when is_binary(posted) <- params,
         true <- RemoteValues.free_text?(socket.assigns[:editor_schema], key),
         mark when is_binary(mark) <- PostIdentity.of(socket),
         ^mark <- PostIdentity.of(before),
         true <- landed?(socket, before),
         from when is_binary(from) <- base(before, key, params),
         true <- from != posted,
         true <-
           byte_size(from) <= TextRebase.max_bytes() and
             byte_size(posted) <= TextRebase.max_bytes() do
      add(socket, mark, key, {from, posted})
    else
      _ -> socket
    end
  end

  @doc "`desk-undo`: undo, or with `redo` true, redo, in the document it names."
  def handle_event(params, socket) do
    PostIdentity.pressed(params, socket, fn params, socket ->
      step(socket, params["redo"] in [true, "true"])
    end)
  end

  # ── Recording ───────────────────────────────────────────────────────────

  # The post was written: the store holds another document than before it.
  defp landed?(socket, before) do
    socket.assigns[:save_status] == "Saved" and is_map(socket.assigns[:editor_doc]) and
      socket.assigns[:editor_doc] != before.assigns[:editor_doc]
  end

  # The text the page typed the post from: the base the save merged it from,
  # else what the store held.
  defp base(before, key, params) do
    bases = RemoteValues.put_bases(before, [key], params["_bp_seen"]).assigns[:editor_field_bases]
    Map.get(bases || %{}, key) || stored(before, key)
  end

  defp add(socket, mark, key, step) do
    state = state(socket, mark)
    now = System.monotonic_time(:millisecond)

    undo =
      case state.undo do
        [%{field: ^key, at: at} = last | rest] when is_integer(at) and now - at < @group_ms ->
          [%{last | steps: last.steps ++ [step], at: now} | rest]

        changes ->
          [%{field: key, steps: [step], at: now} | changes]
      end

    put_state(socket, mark, trim(undo), [])
  end

  # The newest changes that fit both bounds.
  defp trim(changes) do
    changes
    |> Enum.take(@max_changes)
    |> Enum.reduce_while({[], 0}, fn change, {kept, bytes} ->
      bytes =
        bytes + Enum.reduce(change.steps, 0, fn {a, b}, n -> n + byte_size(a) + byte_size(b) end)

      if bytes > @max_bytes, do: {:halt, {kept, bytes}}, else: {:cont, {[change | kept], bytes}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # ── Undo and redo ───────────────────────────────────────────────────────

  defp step(socket, redo?) do
    mark = PostIdentity.of(socket)

    if read_only?(socket.assigns) or not is_binary(mark) do
      {:noreply, socket}
    else
      state = state(socket, mark)
      {from, onto} = if redo?, do: {state.redo, state.undo}, else: {state.undo, state.redo}

      case from do
        [] -> {:noreply, socket}
        [change | rest] -> apply_change(socket, mark, state, change, rest, onto, redo?)
      end
    end
  end

  defp apply_change(socket, mark, state, change, rest, onto, redo?) do
    steps =
      if redo?,
        do: change.steps,
        else: change.steps |> Enum.reverse() |> Enum.map(fn {a, b} -> {b, a} end)

    field = change.field
    now = current(socket, field)
    next = if is_binary(now), do: TextUndo.revert_steps(steps, now), else: now
    popped = if redo?, do: {state.undo, rest}, else: {rest, state.redo}
    socket = put_state(socket, mark, elem(popped, 0), elem(popped, 1))

    # Someone else wrote into it since, or the field is no longer this
    # editor's to change: theirs stays, and the change is gone.
    if next == now or FieldActions.target(socket.assigns, field) == nil do
      {:noreply, socket}
    else
      params = %{"doc" => %{field => next}, "_target" => ["doc", field], bases: %{field => now}}
      {:noreply, saved} = EditorHost.write_built(params, socket)

      if landed?(saved, socket) do
        # Undone or redone, it is a step of its own: typing next is not part of it.
        change = %{change | at: nil}

        {undo, redo} =
          if redo?, do: {[change | onto], rest}, else: {rest, [change | onto]}

        {:noreply,
         saved
         |> put_state(mark, undo, redo)
         |> push_event(@event, %{field: "doc[#{field}]", value: stored(saved, field), was: now})}
      else
        {:noreply, put_state(saved, mark, state.undo, state.redo)}
      end
    end
  end

  # An old revision or the published version is shown: nothing is written.
  defp read_only?(assigns),
    do:
      RevisionView.shown?(assigns) or PublishedView.active?(assigns) or
        Panes.perspective(assigns[:desk_uri]) == :published

  # ── State ───────────────────────────────────────────────────────────────

  defp state(socket, mark) do
    case socket.assigns[:desk_undo] do
      %{doc: ^mark} = state -> state
      _ -> %{doc: mark, undo: [], redo: []}
    end
  end

  defp put_state(socket, mark, undo, redo),
    do: assign(socket, :desk_undo, %{doc: mark, undo: undo, redo: redo})

  # The field as the store holds it now, read fresh: the editor's own copy
  # can be a frame behind another editor's save, and an undo computed from
  # it would take their words with ours. The editor's copy when the read
  # finds nothing.
  defp current(%{assigns: assigns} = socket, key) do
    with %{doc_id: id} when is_binary(id) <- assigns[:editor_doc],
         type when is_binary(type) <- assigns[:editor_type],
         {%{} = doc, _, _} <-
           Content.fetch_doc_with_draft(
             type,
             Content.published_id(id),
             assigns.dataset,
             ScopeHelpers.scope_opts(socket)
           ) do
      text(FieldActions.stored(doc, key))
    else
      _ -> stored(socket, key)
    end
  end

  defp stored(socket, key) do
    case socket.assigns[:editor_doc] do
      %{} = doc -> text(FieldActions.stored(doc, key))
      _ -> ""
    end
  end

  defp text(value) when is_binary(value), do: value
  defp text(nil), do: ""
  defp text(_value), do: nil
end
