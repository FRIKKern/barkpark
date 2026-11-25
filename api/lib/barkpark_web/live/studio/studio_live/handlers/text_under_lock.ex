defmodule BarkparkWeb.Studio.StudioLive.Handlers.TextUnderLock do
  @moduledoc """
  A free-text post read under the document's lock (task-5b8f13c40a052514),
  as a rich text one is (`RichTextRemote.UnderLock`, task-00c56c6a88ed0b8f).

  Another tab's save can land after this socket read the post and before
  its write, its broadcast waiting behind the post. Two tabs typing in one
  word of a string field then lost the first save's words, with no banner:
  the page reported no base for the field (this socket had not heard of the
  save), so the post was written as sent.

  So the save is told, per free-text field of the post, what this socket
  believed the store held (`values/4`: the newest stored version it has
  seen, `Lifecycle.base_doc/1`), for a page that numbers its values (v2 of
  `_bp_seen`). `TextRebase.rebase/4` reads it under the lock: the store
  moved from it, and the post is merged onto the store, an overlap keeping
  the store. `held/3` reads the write's outcome (`:saved_over`, the value
  the write landed over): a store kept over a post that changed the field
  is held (`hold/3`), A's words in the form, unsaved, with the banner, as
  `Lifecycle.doc_updated/2` holds a clash it was told of. Typing on saves
  A's words over theirs, as there.
  """

  import Phoenix.Component, only: [assign: 2]

  alias BarkparkWeb.Studio.StudioLive.Handlers.Lifecycle
  alias BarkparkWeb.Studio.StudioLive.Handlers.RemoteValues

  @doc "Each free-text field of the post (a key or a path) => the value this socket believed stored."
  def values(socket, keys, seen, path) do
    schema = socket.assigns[:editor_schema]

    with true <- RemoteValues.crossing?(seen),
         %{} = doc <- Lifecycle.base_doc(socket) do
      text = Map.put(if(is_map(doc.content), do: doc.content, else: %{}), "title", doc.title)

      for key <- RemoteValues.units(keys, RemoteValues.text_path(schema, keys, path)),
          RemoteValues.free_text_at?(schema, key),
          value = RemoteValues.value_at(text, key),
          is_binary(value),
          into: %{},
          do: {key, value}
    else
      _ -> %{}
    end
  end

  @doc "The save's options: each value by its key, and the fields to report."
  def write_opts(values) when map_size(values) == 0, do: []

  def write_opts(values),
    do: [text_seen: values, saved_over: values |> Map.keys() |> Enum.map(&top/1) |> Enum.uniq()]

  @doc """
  The fields of `values` whose store moved under the post and was kept over
  it (`saved` is the socket after the write, `posted` the post's doc).
  """
  def held(saved, values, posted) when map_size(values) > 0 do
    written = saved.assigns[:editor_doc]
    over = (is_map(written) && Map.get(written, :saved_over)) || %{}

    now =
      if is_map(written),
        do: Map.put(written.content || %{}, "title", Map.get(written, :title)),
        else: %{}

    for {key, was} <- values,
        is_map_key(over, top(key)),
        before = RemoteValues.value_at(over, key),
        mine = RemoteValues.value_at(posted, key),
        is_binary(before) and is_binary(mine),
        before != was and mine != before and RemoteValues.value_at(now, key) == before,
        do: key
  end

  def held(_saved, _values, _posted), do: []

  @doc "A's words for each held field in the form, unsaved, with the banner."
  def hold(socket, [], _posted), do: socket

  def hold(socket, keys, posted) do
    form =
      Enum.reduce(keys, socket.assigns[:editor_form] || %{}, fn key, form ->
        RemoteValues.put_at({key, RemoteValues.value_at(posted, key)}, form)
      end)

    tops = Enum.map(keys, &top/1)

    assign(socket,
      editor_form: form,
      editor_dirty: true,
      editor_unsaved_keys:
        MapSet.union(socket.assigns[:editor_unsaved_keys] || MapSet.new(), MapSet.new(tops)),
      doc_conflict: true,
      save_status: "Updated by another user",
      editor_clash_fields: Enum.uniq((socket.assigns[:editor_clash_fields] || []) ++ tops)
    )
  end

  defp top([key | _]), do: key
  defp top(key), do: key
end
