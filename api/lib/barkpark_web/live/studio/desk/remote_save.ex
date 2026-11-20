defmodule BarkparkWeb.Studio.Desk.RemoteSave do
  @moduledoc """
  Another editor's save, as the desk footer reads it (`DocFooter.status/2`).

  WHETHER IT IS NAMED. The Studio names every save from another editor
  "Updated by another user". The footer hides that only when the save kept
  every value this tab saved intact: another field, or J06's two ends of
  one title. When it replaced or dropped one, the footer keeps the warning:
  two splices that overlap, a post with no base text, a date both picked, a
  text over the merge's size cap (`TextRebase.merge3/3` falls back to the
  last post in each). Typing this tab still holds is the Studio's own
  clash (`doc_conflict`), named too.

  - This tab's own change is read from the write itself (`after_write/4`):
    every user field whose stored value moved from the last stored value
    this tab knew (its own last write or the last frame it took, `@seen`)
    is this tab's, kept per field as `{before, after}` in form shape, every
    save of it (`push/3`), not only the last. A field only another editor
    changed is in the last frame already, so it is not counted as this
    tab's. That holds for any write that moves the
    document's revision: a typed save, the form's submit (Enter, no
    `_target`), a pick, a paste, an undo, a Restore from History.
  - Free text typed into one field (`_target`) keeps the text the post was
    typed from and the text it posted, this tab's words alone, not the
    merged text that can hold another editor's words.
  - Publish, Unpublish, Discard, Delete and "reload" move the revision but
    write no value of this tab's: the last stored values are taken in, and
    a discard or reload forgets this tab's changes.
  - Only the user's values: the title and the schema's fields. Never the
    document's status (a first edit opens the draft, a Publish elsewhere
    closes it: nothing of this tab's is lost) or any `_` key.
  - Every desk write records it (`EditorHost`): the form's events, the
    desk's own built writes (paste, undo, revert), and the writes the page
    sends itself (a tree codelist's pick, a reference or image pick). It
    does not rest on the save state: a Restore writes through `Content` and
    leaves it as it was.
  - A frame keeps a change intact when the field still holds this tab's
    value, or, for text, when this tab's words still come back out of it
    (`TextUndo.revert/3`). The change is then kept on the new text. A change
    not intact is dropped, and the document is marked until this tab's
    next save lands.

  THE DRAFT. A remote frame does not change `editor_doc`: it stays this
  tab's base for the merge. What the footer and the Publish button read of
  it is refreshed here: a remote save of the draft opens it in this tab too
  (`editor_is_draft`, Publish offered, "Edited N ago" from the frame's time),
  and a Publish elsewhere closes it ("Last published N ago").

  Both are keyed by the document's published id, so another document
  opened in the pane does not inherit them, and both start again when the
  editor loads a document (`reset/1`): opening it again, or the reload
  after a discard elsewhere.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias Barkpark.Content
  alias Barkpark.Content.TextUndo
  alias BarkparkWeb.Studio.StudioLive.Handlers.RemoteValues

  @own :desk_own_values
  @overwritten :desk_overwritten
  @meta :desk_remote_meta
  @seen :desk_remote_seen

  @doc "Forget it all: the editor loaded a document afresh."
  def reset(socket),
    do: assign(socket, [{@own, nil}, {@overwritten, nil}, {@meta, nil}, {@seen, nil}])

  # ── This tab's writes ───────────────────────────────────────────────────

  # Events that move the revision but write none of this tab's values: the
  # stored values are taken in. A discard or a reload also forgets this
  # tab's changes, which are no longer in the document.
  @takes_in ~w(publish paper-publish unpublish confirm-unpublish)
  @forgets ~w(reload-remote-doc discard-draft confirm-discard delete-doc confirm-delete)

  @doc """
  The result of `event` (nil: a write the desk built, or one the page sent
  itself) answered from `before` (the socket before it), with its `params`:
  a write that landed keeps what it changed, and the document is no longer
  marked.
  """
  def after_write(result, before, params, event \\ nil)

  def after_write({:noreply, socket}, before, params, event),
    do: {:noreply, own(socket, before, params, event)}

  def after_write({:reply, reply, socket}, before, params, event),
    do: {:reply, reply, own(socket, before, params, event)}

  def after_write(other, _before, _params, _event), do: other

  defp own(socket, before, params, event) do
    doc = socket.assigns[:editor_doc]

    with %{doc_id: id, rev: rev} <- doc,
         %{doc_id: was, rev: was_rev} when was_rev != rev <- before.assigns[:editor_doc],
         pub = Content.published_id(id),
         true <- pub == Content.published_id(was) do
      stored = Content.doc_to_form(doc, socket.assigns[:editor_schema])

      cond do
        event in @takes_in -> assign(socket, @seen, {pub, stored})
        event in @forgets -> assign(socket, [{@own, nil}, {@seen, {pub, stored}}])
        true -> wrote(socket, before, params, pub, stored)
      end
    else
      _ -> socket
    end
  end

  # What the write changed: every user field moved from the last stored
  # value this tab knew. Free text typed into one field keeps this tab's
  # own words (`typed/4`).
  defp wrote(socket, before, params, pub, stored) do
    schema = socket.assigns[:editor_schema]
    seen = seen(before.assigns, pub, schema)
    user = user_keys(schema)

    moved =
      for {key, value} <- stored,
          MapSet.member?(user, key),
          Map.get(seen, key) != value,
          into: %{},
          do: {key, {Map.get(seen, key), value}}

    shown = before.assigns[:editor_form] || %{}
    mine = typed(moved, before, params, shown)

    own =
      Enum.reduce(mine, kept(socket.assigns, pub), fn {key, step}, own ->
        Map.put(own, key, push(Map.get(own, key, []), step, RemoteValues.free_text?(schema, key)))
      end)

    socket = assign(socket, [{@own, {pub, own}}, {@seen, {pub, stored}}])

    if mine == %{}, do: socket, else: assign(socket, @overwritten, nil)
  end

  # Every save of this tab is kept per field, newest first, until the field
  # holds none of its words: a second save does not stand for the first,
  # whose words another editor can still drop. Any value but free text is
  # whole, written by the last post: its last save alone. A free text save
  # that continues the newest (typing on in one place) joins it as one
  # change; one apart from a kept save leaves it, moved onto the new text.
  # A kept save this tab's own text no longer holds is gone, not lost.
  # Bounded: past `@steps` saves the oldest is forgotten.
  @steps 8

  defp push(_steps, step, false), do: [step]

  defp push(steps, {from, posted} = step, true) when is_binary(from) and is_binary(posted) do
    {step, kept} =
      Enum.reduce(steps, {step, []}, fn kept_step, {step, kept} ->
        case onto(kept_step, step) do
          {:joined, joined} -> {joined, kept}
          {:ok, moved} -> {step, [moved | kept]}
          :gone -> {step, kept}
        end
      end)

    [step | Enum.reverse(kept)]
    |> Enum.reject(fn {before, value} -> before == value end)
    |> Enum.take(@steps)
  end

  defp push(_steps, step, _text?), do: [step]

  # A kept save `{before, value}` on this tab's new one `{from, posted}`.
  # Continued: its words and the new ones are one change unless the two lie
  # apart. A field empty before it holds no one else's words to keep apart.
  # A save that takes the kept one back (a Restore of what was there) is
  # still a value this tab saved: it stays, alone.
  defp onto({nil, from}, {from, posted}), do: {:joined, {nil, posted}}

  defp onto({before, from}, {from, posted} = step) when is_binary(before) do
    case apart(before, from, posted) do
      {:ok, without} -> {:ok, {without, posted}}
      :near when before == posted -> {:joined, step}
      :near -> {:joined, {before, posted}}
    end
  end

  defp onto(kept, {_from, posted}) do
    case intact(kept, posted, true) do
      {:ok, moved} -> {:ok, moved}
      :lost -> :gone
    end
  end

  # Free text: the text the post was typed from (the base the save merged it
  # from, as `DocUndo` reads it) and the text it posted. Not the stored
  # text, which can hold another editor's words the save merged in.
  defp typed(changes, before, %{"_target" => ["doc", key], "doc" => %{} = doc} = params, shown)
       when is_binary(key) do
    with posted when is_binary(posted) <- doc[key],
         true <- RemoteValues.free_text?(before.assigns[:editor_schema], key),
         from when is_binary(from) <- text_base(before, key, params, shown),
         true <- from != posted do
      Map.put(changes, key, {from, posted})
    else
      _ -> changes
    end
  end

  defp typed(changes, _before, _params, _shown), do: changes

  defp text_base(before, key, params, shown) do
    given = params[:bases] || params["bases"] || %{}

    seen =
      RemoteValues.put_bases(before, [key], params["_bp_seen"]).assigns[:editor_field_bases] ||
        %{}

    Map.get(given, key) || Map.get(seen, key) || Map.get(shown, key)
  end

  # The last stored values this tab knew: its last write or the last frame
  # it took, else the document it holds.
  defp seen(assigns, pub, schema) do
    case assigns[@seen] do
      {^pub, form} -> form
      _ -> Content.doc_to_form(assigns[:editor_doc], schema)
    end
  end

  # The user's values: the title and the schema's own fields, never the
  # status or a system key.
  defp user_keys(schema) do
    names = for %{"name" => name} <- fields(schema), is_binary(name), do: name

    ["title" | names]
    |> Enum.reject(&(&1 == "status" or String.starts_with?(&1, "_")))
    |> MapSet.new()
  end

  defp fields(%{fields: fields}) when is_list(fields), do: fields
  defp fields(_schema), do: []

  defp kept(assigns, pub) do
    case assigns[@own] do
      {^pub, changes} -> changes
      _ -> %{}
    end
  end

  # ── Another editor's frame ──────────────────────────────────────────────

  @doc """
  After the Studio took another editor's frame `msg` into `result`: whether
  it kept this tab's values, and the draft state it carries.
  """
  def frame({:noreply, socket}, msg), do: {:noreply, frame_into(socket, msg)}
  def frame(other, _msg), do: other

  defp frame_into(socket, %{doc: %{doc_id: frame_id} = frame} = msg) do
    with true <- msg[:sender] != self(),
         %{doc_id: id} = doc <- socket.assigns[:editor_doc],
         pub = Content.published_id(id),
         true <- pub == Content.published_id(frame_id),
         true <- newer?(frame, doc) do
      schema = socket.assigns[:editor_schema]
      stored = Content.doc_to_form(frame, schema)
      was = seen(socket.assigns, pub, schema)

      socket
      |> judge(pub, moved(stored, was))
      |> draft_state(pub, msg, frame)
      |> assign(@seen, {pub, stored})
    else
      _ -> socket
    end
  end

  defp frame_into(socket, _msg), do: socket

  # The fields whose stored value the frame moved from the last one this
  # tab knew. Only those can have lost this tab's value.
  defp moved(stored, was) do
    for {key, value} <- stored, Map.get(was, key) != value, into: MapSet.new(), do: key
  end

  # The form now holds the frame (the Studio's clean path); a clash with
  # typing here is the Studio's own warning. A field the frame did not move
  # keeps its step as it is, unread.
  defp judge(socket, pub, moved) do
    if socket.assigns[:doc_conflict] == true do
      socket
    else
      now = socket.assigns[:editor_form] || %{}
      schema = socket.assigns[:editor_schema]

      {intact, lost} =
        socket.assigns
        |> kept(pub)
        |> Enum.reduce({%{}, []}, fn {key, steps}, {intact, lost} ->
          {held, dropped} =
            if MapSet.member?(moved, key),
              do: hold(steps, Map.get(now, key), RemoteValues.free_text?(schema, key)),
              else: {steps, false}

          intact = if held == [], do: intact, else: Map.put(intact, key, held)
          {intact, if(dropped, do: [key | lost], else: lost)}
        end)

      socket = assign(socket, @own, {pub, intact})
      if lost == [], do: socket, else: assign(socket, @overwritten, pub)
    end
  end

  # Every kept save of one field on the value it holds now: the saves still
  # intact, and whether any was replaced or dropped.
  defp hold(steps, now, text?) do
    Enum.reduce(steps, {[], false}, fn step, {held, dropped} ->
      case intact(step, now, text?) do
        {:ok, step} -> {held ++ [step], dropped}
        :lost -> {held, true}
      end
    end)
  end

  # Cheap first: the field still holds this tab's value (intact), or holds
  # again what it held before this tab's change (dropped). Any value but free
  # text is written by the last post, with no merge: another value replaced
  # this tab's. Only free text can still hold this tab's words among another
  # editor's: they must come back out of it (`TextUndo.revert/3`), and the
  # step is then kept on the text it holds now.
  defp intact({_before, value} = step, value, _text?), do: {:ok, step}
  defp intact({before, _value}, before, _text?), do: :lost

  defp intact({before, value}, now, true)
       when is_binary(before) and is_binary(value) and is_binary(now) do
    case apart(before, value, now) do
      {:ok, without} ->
        {:ok, {without, now}}

      :near ->
        :telemetry.execute(
          [:barkpark, :desk, :remote_save, :revert],
          %{bytes: byte_size(now)},
          %{}
        )

        case TextUndo.revert(value, before, now) do
          ^now -> :lost
          without -> {:ok, {without, now}}
        end
    end
  end

  defp intact(_step, _now, _text?), do: :lost

  # Bytes of untouched text the two changes must have between them: closer
  # than that, which editor's words are which is a judgement for the merge.
  @gap 8

  # The common case, in bytes and without a merge: the other editor's change
  # (`value` -> `now`) lies wholly before or wholly after this tab's own
  # (`before` -> `value`), not touching it. This tab's words are then intact,
  # and the text without them is `now` with this tab's splice undone. Any
  # other shape (the two touch or overlap) is `:near`, for the full merge.
  defp apart(before, value, now) do
    {p, e_v, e_b} = splice(before, value)
    {q, _f_now, f_v} = splice(value, now)
    d = byte_size(now) - byte_size(value)

    cond do
      q > e_v + @gap and starts?(now, e_v) ->
        {:ok, binary_part(now, 0, p) <> part(before, p, e_b) <> rest(now, e_v)}

      f_v + @gap < p and starts?(now, p + d) ->
        {:ok, binary_part(now, 0, p + d) <> part(before, p, e_b) <> rest(now, e_v + d)}

      true ->
        :near
    end
  end

  # Whether byte `at` of `bin` starts a character (or is its end).
  defp starts?(bin, at), do: at >= byte_size(bin) or :binary.at(bin, at) not in 0x80..0xBF

  # Where `to` differs from `from`: the common prefix's length, and where the
  # common suffix starts in `to` and in `from` (the two never cross).
  defp splice(from, to) do
    p = :binary.longest_common_prefix([from, to])
    s = min(:binary.longest_common_suffix([from, to]), min(byte_size(from), byte_size(to)) - p)
    {p, byte_size(to) - s, byte_size(from) - s}
  end

  defp part(bin, from, to), do: binary_part(bin, from, to - from)
  defp rest(bin, from), do: binary_part(bin, from, byte_size(bin) - from)

  defp draft_state(socket, pub, msg, frame) do
    meta = %{id: pub, at: frame[:updated_at]}

    case {msg[:mutation], Content.draft?(frame.doc_id)} do
      {"publish", _} ->
        assign(socket,
          editor_is_draft: false,
          editor_has_published: true,
          desk_remote_meta: Map.put(meta, :status, "published")
        )

      {"unpublish", true} ->
        assign(socket,
          editor_is_draft: true,
          editor_has_published: false,
          desk_remote_meta: Map.put(meta, :status, "draft")
        )

      {mutation, true} when mutation not in ["discardDraft", "delete"] ->
        assign(socket, editor_is_draft: true, desk_remote_meta: Map.put(meta, :status, "draft"))

      _ ->
        socket
    end
  end

  defp newer?(%{updated_at: %DateTime{} = sent}, %{updated_at: %DateTime{} = own}),
    do: DateTime.compare(sent, own) != :lt

  defp newer?(_frame, _doc), do: true

  # ── What the footer reads ───────────────────────────────────────────────

  @doc "Whether another editor's save replaced or dropped a value this tab saved."
  def overwritten?(assigns),
    do: open_id(assigns) != nil and assigns[@overwritten] == open_id(assigns)

  @doc """
  The open document's last change, `{at, status}`: this tab's copy, or
  another editor's frame when that is newer and agrees with the draft state
  the editor holds (a discard elsewhere reloads a published document over a
  draft frame).
  """
  def latest(assigns) do
    doc = assigns[:editor_doc] || %{}
    own = {Map.get(doc, :updated_at), Map.get(doc, :status)}
    draft? = assigns[:editor_is_draft] == true
    agrees? = fn status -> if draft?, do: status == "draft", else: status != "draft" end

    case assigns[@meta] do
      %{id: id, at: %DateTime{} = at, status: status} ->
        if id == open_id(assigns) and newer?(%{updated_at: at}, doc) and agrees?.(status),
          do: {at, status},
          else: own

      _ ->
        own
    end
  end

  defp open_id(assigns) do
    case assigns[:editor_doc] do
      %{doc_id: id} when is_binary(id) -> Content.published_id(id)
      _ -> nil
    end
  end
end
