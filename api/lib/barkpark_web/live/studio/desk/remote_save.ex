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

  - This tab's own change is kept per field as `{before, after}` in form
    shape (`after_write/3`). Free text: the text the post was typed from
    and the text it posted, this tab's words alone. Any other field: the
    last stored value this tab knew (its own last write or the last frame
    it took, `@seen`) and the stored value after the write, when that
    moved. A field only another editor changed is in the last frame
    already, so it is not counted as this tab's.
  - Only the user's values: the title and the schema's fields. Never the
    document's status (a first edit opens the draft, a Publish elsewhere
    closes it: nothing of this tab's is lost) or any `_` key.
  - Every desk write records it (`EditorHost`): the form's events, the
    desk's own built writes (paste, undo, revert), and the writes the page
    sends itself (a tree codelist's pick, a reference or image pick).
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

  @doc """
  The result of an event answered from `before` (the socket before it), with
  the event's `params`: a write that landed keeps its change, and the
  document is no longer marked.
  """
  def after_write({:noreply, socket}, before, params),
    do: {:noreply, own(socket, before, params)}

  def after_write({:reply, reply, socket}, before, params),
    do: {:reply, reply, own(socket, before, params)}

  def after_write(other, _before, _params), do: other

  defp own(socket, before, params) do
    doc = socket.assigns[:editor_doc]

    with "Saved" <- socket.assigns[:save_status],
         %{doc_id: id, rev: rev} <- doc,
         %{doc_id: was, rev: was_rev} when was_rev != rev <- before.assigns[:editor_doc],
         pub = Content.published_id(id),
         true <- pub == Content.published_id(was) do
      schema = socket.assigns[:editor_schema]
      stored = Content.doc_to_form(doc, schema)
      shown = before.assigns[:editor_form] || %{}
      seen = seen(before.assigns, pub, schema)
      user = user_keys(schema)

      # Any other field: the value the store kept, moved from the last
      # stored value this tab knew (a field only another editor moved is in
      # the last frame already). A pick the form showed before it was
      # written (a reference, an image) counts too.
      changes =
        for {key, value} <- stored,
            MapSet.member?(user, key),
            not RemoteValues.free_text?(schema, key),
            Map.get(seen, key) != value,
            into: kept(socket.assigns, pub),
            do: {key, {Map.get(seen, key), value}}

      assign(socket, [
        {@own, {pub, typed(changes, before, params, shown)}},
        {@overwritten, nil},
        {@seen, {pub, stored}}
      ])
    else
      _ -> socket
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
      seen = Content.doc_to_form(frame, socket.assigns[:editor_schema])

      socket
      |> judge(pub)
      |> draft_state(pub, msg, frame)
      |> assign(@seen, {pub, seen})
    else
      _ -> socket
    end
  end

  defp frame_into(socket, _msg), do: socket

  # The form now holds the frame (the Studio's clean path); a clash with
  # typing here is the Studio's own warning.
  defp judge(socket, pub) do
    if socket.assigns[:doc_conflict] == true do
      socket
    else
      now = socket.assigns[:editor_form] || %{}

      {intact, lost} =
        socket.assigns
        |> kept(pub)
        |> Enum.reduce({%{}, []}, fn {key, step}, {intact, lost} ->
          case intact(step, Map.get(now, key)) do
            {:ok, step} -> {Map.put(intact, key, step), lost}
            :lost -> {intact, [key | lost]}
          end
        end)

      socket = assign(socket, @own, {pub, intact})
      if lost == [], do: socket, else: assign(socket, @overwritten, pub)
    end
  end

  # The field still holds this tab's value, or this tab's words still come
  # back out of the text: kept on the text it holds now.
  defp intact({_before, value} = step, value), do: {:ok, step}

  defp intact({before, value}, now)
       when is_binary(before) and is_binary(value) and is_binary(now) do
    case TextUndo.revert(value, before, now) do
      ^now -> :lost
      without -> {:ok, {without, now}}
    end
  end

  defp intact(_step, _now), do: :lost

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
