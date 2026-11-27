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
  another document's start empty.

  Every other field the form writes (a slug, a select, a list, an object's
  nested fields) is kept as whole-value steps (`DocUndoValues`): the value
  the write landed over and the value it left, taken back with `ValueUndo`.
  A rich-text body, a reference or an asset is not undone here.

  ## Undo

  `desk-undo` (from `bp-desk-undo.js`) names its document (`PostIdentity`).
  The last change's steps are taken back out of the value the store holds
  now (`TextUndo` for free text, `ValueUndo` for the rest). A change someone else wrote into is left as it is and
  dropped, as the TanStack Studio's. What comes out is saved as a typed edit
  of the field is (`EditorHost.write_built/2`, with the desk's guards), and
  merged by the save onto what the store holds by then. A value is written
  only while the store still holds the value the undo read (`:field_expect`,
  checked by the save under its lock): another editor's save that lands
  between the read and the write stays, and the change is dropped. The page is told the
  field, its new value and the value it showed (`desk:undone`): the script
  sets the field when it still shows that value, and puts the focus in it.
  A field on a group tab that is not shown switches the editor to a tab that
  draws it first: nothing changes where the user cannot see it.

  Nothing is undone over an old revision (`RevisionView`) or in the
  published perspective: both are read-only, as the TanStack Studio's
  locked document is.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Barkpark.Content
  alias Barkpark.Content.TextRebase
  alias Barkpark.Content.TextUndo
  alias Barkpark.Content.ValueUndo
  alias Barkpark.Content.TitleDerivation
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.Desk.DocUndoValues
  alias BarkparkWeb.Studio.Desk.EditorHost
  alias BarkparkWeb.Studio.Desk.FieldActions
  alias BarkparkWeb.Studio.Desk.FieldGroups
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.PublishedView
  alias BarkparkWeb.Studio.Desk.RevisionView
  alias BarkparkWeb.Studio.StudioLive.Handlers.RemoteValues
  alias BarkparkWeb.Studio.StudioLive.PostIdentity
  alias BarkparkWeb.StudioComponents.Editor

  @event "desk:undone"

  # Typing in one field within this long of the last step is one change.
  @group_ms 600

  # Changes kept, and the bytes their texts may hold together: the oldest go
  # first.
  @max_changes 100
  @max_bytes 1_000_000

  @doc """
  The form names of the top-level fields an undo is kept for (`record/3`,
  `DocUndoValues`), space separated, for the form's `data-desk-undo-keys`.
  `bp-desk-undo.js` takes Mod+Z in these fields' inputs (theirs nested
  inside too); in every other input (a url, a number, a widget's own box)
  the browser keeps its own undo.
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
    |> Enum.filter(&(RemoteValues.free_text?(schema, &1) or DocUndoValues.recorded?(schema, &1)))
    |> Enum.map_join(" ", &"doc[#{&1}]")
  end

  @doc """
  `event` of the form, handled by `fun` (given the socket), with the step it
  made kept when it landed: a free-text field's typed edit (`record/3`), or
  a write of any other field kept (`DocUndoValues`), from the value the
  write landed over. The save reports that value (`:saved_over`), read
  under its lock: a read ahead of the save would miss another editor's save
  landed in between, and the undo would put back a value older than theirs
  (task-2f3af2d2f7f56811).
  """
  def around(event, params, socket, fun) do
    case DocUndoValues.target(event, params, socket.assigns) do
      nil ->
        if event == "autosave", do: record(fun.(socket), params, socket), else: fun.(socket)

      {key, input} ->
        socket
        |> assign(:editor_saved_over, [key])
        |> fun.()
        |> record_value(socket, key, input)
    end
  end

  defp record_value({:noreply, saved}, before, key, input),
    do: {:noreply, value_step(reported(saved), before, key, input)}

  defp record_value({:reply, reply, saved}, before, key, input),
    do: {:reply, reply, value_step(reported(saved), before, key, input)}

  defp record_value(other, _before, _key, _input), do: other

  defp reported(saved), do: assign(saved, :editor_saved_over, nil)

  defp value_step(saved, before, key, input) do
    with mark when is_binary(mark) <- PostIdentity.of(saved),
         ^mark <- PostIdentity.of(before),
         true <- landed?(saved, before),
         %{saved_over: %{^key => was}} <- saved.assigns[:editor_doc],
         left = DocUndoValues.stored(saved, key),
         true <- left != was,
         true <- size(was) + size(left) <= @max_bytes do
      add(saved, mark, key, {was, left}, :value, input)
    else
      _ -> saved
    end
  end

  # The values a paste keeps a whole-value step for besides `DocUndoValues`'
  # own: those whose typing is the browser's (a number, a url), and a
  # widget's pick.
  @pasted_types ~w(number boolean url email date datetime codelist)

  @doc """
  A paste's write of one top-level field (Paste field, Paste document), the
  params the server built for it (`EditorHost.write_built/2`), and a step of
  the undo when it landed, as the TanStack Studio records every write:
  free text a text step, as typing is (`record/3`); any other value a
  whole-value step. A rich-text body, a reference or an asset is written
  and not kept.
  """
  def write_built(%{"_target" => ["doc", key]} = params, socket) when is_binary(key) do
    schema = socket.assigns[:editor_schema]
    write = &EditorHost.write_built(params, &1)

    cond do
      RemoteValues.free_text?(schema, key) ->
        record(write.(socket), params, socket)

      DocUndoValues.recorded?(schema, key) or
          match?(%{"type" => t} when t in @pasted_types, DocUndoValues.field(schema, key)) ->
        socket
        |> assign(:editor_saved_over, [key])
        |> write.()
        |> record_value(socket, key, "doc[#{key}]")

      true ->
        write.(socket)
    end
  end

  def write_built(params, socket), do: EditorHost.write_built(params, socket)

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
      add(socket, mark, key, {from, posted}, :text, nil)
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
  # A built write over a held field says so on its own: the hold kept the
  # banner's status in place of "Saved" (`Fields.autosave_built/2`).
  defp landed?(socket, before) do
    (socket.assigns[:save_status] == "Saved" or socket.assigns[:editor_built_landed] == true) and
      is_map(socket.assigns[:editor_doc]) and
      socket.assigns[:editor_doc] != before.assigns[:editor_doc]
  end

  # The text the page typed the post from: the base the save merged it from,
  # else what the store held.
  defp base(before, key, params) do
    bases = RemoteValues.put_bases(before, [key], params["_bp_seen"]).assigns[:editor_field_bases]
    Map.get(bases || %{}, key) || stored(before, key)
  end

  defp add(socket, mark, key, step, kind, input) do
    state = state(socket, mark)
    now = System.monotonic_time(:millisecond)

    undo =
      case state.undo do
        [%{field: ^key, kind: ^kind, at: at} = last | rest]
        when is_integer(at) and now - at < @group_ms ->
          [%{last | steps: last.steps ++ [step], at: now, input: input || last.input} | rest]

        changes ->
          [%{field: key, kind: kind, input: input, steps: [step], at: now} | changes]
      end

    put_state(socket, mark, trim(undo), [])
  end

  # The newest changes that fit both bounds.
  defp trim(changes) do
    changes
    |> Enum.take(@max_changes)
    |> Enum.reduce_while({[], 0}, fn change, {kept, bytes} ->
      bytes = bytes + Enum.reduce(change.steps, 0, fn {a, b}, n -> n + size(a) + size(b) end)

      if bytes > @max_bytes, do: {:halt, {kept, bytes}}, else: {:cont, {[change | kept], bytes}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp size(text) when is_binary(text), do: byte_size(text)
  defp size(value), do: :erlang.external_size(value)

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
    {now, next} = reverted(socket, change, steps)
    popped = if redo?, do: {state.undo, rest}, else: {rest, state.redo}
    socket = put_state(socket, mark, elem(popped, 0), elem(popped, 1))

    # Someone else wrote into it since, or the field is no longer this
    # editor's to change: theirs stays, and the change is gone.
    if next == now or FieldActions.target(socket.assigns, field) == nil do
      {:noreply, socket}
    else
      {:noreply, saved} =
        EditorHost.write_built(written(change, field, next, now), expecting(socket, change, now))

      saved = assign(saved, :editor_field_expect, nil)

      cond do
        landed?(saved, socket) ->
          # Undone or redone, it is a step of its own: typing next is not part of it.
          change = %{change | at: nil}

          {undo, redo} =
            if redo?, do: {[change | onto], rest}, else: {rest, [change | onto]}

          {:noreply,
           saved
           |> put_state(mark, undo, redo)
           |> show_field(field)
           |> push_event(@event, told(change, saved, field, now))}

        # Another editor saved the field after it was read: the save refused
        # (`:field_expect`), nothing was written, theirs stays and the change
        # is gone.
        moved?(socket, change, now) ->
          {:noreply, socket}

        true ->
          {:noreply, put_state(saved, mark, state.undo, state.redo)}
      end
    end
  end

  # A value is written only over the value it was computed from.
  defp expecting(socket, %{kind: :value, field: field}, now),
    do: assign(socket, :editor_field_expect, %{field => now})

  defp expecting(socket, _change, _now), do: socket

  defp moved?(socket, %{kind: :value, field: field}, now),
    do: DocUndoValues.stored_now(socket, field) != now

  defp moved?(_socket, _change, _now), do: false

  # The value the store holds now, and that value with the steps taken back.
  defp reverted(socket, %{kind: :value} = change, steps) do
    now = DocUndoValues.stored_now(socket, change.field)
    field = DocUndoValues.field(socket.assigns[:editor_schema], change.field)
    {now, ValueUndo.revert_steps(steps, now, field)}
  end

  defp reverted(socket, change, steps) do
    now = current(socket, change.field)
    {now, if(is_binary(now), do: TextUndo.revert_steps(steps, now), else: now)}
  end

  # The write of an undo: free text merged by the save from the text it was
  # computed from, any other value set whole.
  defp written(%{kind: :value}, field, next, now),
    do: %{
      "doc" => %{field => DocUndoValues.post(now, next)},
      "_target" => ["doc", field],
      bases: %{field => :whole}
    }

  defp written(_change, field, next, now),
    do: %{"doc" => %{field => next}, "_target" => ["doc", field], bases: %{field => now}}

  # What the page is told: the input to bring into sight and focus, and its
  # text when it has one (`bp-desk-undo.js`).
  defp told(%{kind: :value} = change, saved, field, now) do
    input = change.input || "doc[#{field}]"

    {value, was} =
      DocUndoValues.told(change.input, field, DocUndoValues.stored(saved, field), now)

    # `path` names the field itself: a list the undo left empty has no input
    # to find it by.
    %{field: input, value: value, was: was, path: field}
  end

  defp told(_change, saved, field, now),
    do: %{field: "doc[#{field}]", value: stored(saved, field), was: now}

  # The desk draws the chosen group tab's fields only: a change undone in a
  # field on another tab switches to a tab that draws it, so the user sees
  # what changed and the focus can go there (`desk:undone`).
  defp show_field(%{assigns: assigns} = socket, field) do
    schema = assigns[:editor_schema]
    form = assigns[:editor_form]

    case FieldGroups.current(schema, assigns[:nav_group], form) do
      nil ->
        socket

      group ->
        if on_tab?(schema, field, group),
          do: socket,
          else: assign(socket, :nav_group, tab_for(schema, field, form))
    end
  end

  defp on_tab?(schema, "title", group), do: Editor.title_on_tab?(schema, group)

  defp on_tab?(schema, field, group),
    do:
      Enum.any?(
        schema_fields(schema),
        &(&1["name"] == field and FieldGroups.in_group?(&1, group))
      )

  # The first of the field's groups that has a tab; with none, All fields.
  defp tab_for(schema, field, form) do
    tabs = schema |> FieldGroups.shown(form) |> Enum.map(& &1["name"])

    spec =
      if field == "title",
        do: TitleDerivation.title_field(schema),
        else: Enum.find(schema_fields(schema), &(&1["name"] == field))

    Enum.find(tabs, &(is_map(spec) and FieldGroups.in_group?(spec, &1)))
  end

  defp schema_fields(%{fields: fields}) when is_list(fields), do: Enum.filter(fields, &is_map/1)
  defp schema_fields(_schema), do: []

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
