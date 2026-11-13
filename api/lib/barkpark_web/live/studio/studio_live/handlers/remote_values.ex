defmodule BarkparkWeb.Studio.StudioLive.Handlers.RemoteValues do
  @moduledoc """
  Another editor's save, told to the field this tab is resting in
  (task-e6ef964ac2e41d5a), and the base this tab's next post of a free-text
  field was written from (task-35956a566dd2c862).

  A LiveView patch never sets the value of the focused input. So when another
  editor saved the field this tab had focused, the tab kept showing the old
  text, and its next keystroke posted that text back over the other's words.

  `push/3` sends the page each changed text field: its new value and the value
  the page showed before (`bp:form-remote-values`). bp-array-focus.js sets the
  focused input only while it still shows exactly the old value: anything else
  is typing the page has not sent yet, and stays. It writes nothing.

  ## The base of a post

  When the page could not take the new value (the person was typing), its
  next post is written from an older value than the store holds. For a
  free-text field (`free_text?/2`) the server keeps what it told the page,
  each value with a sequence number (`editor_remote_history`), and the push
  carries the numbers (`seqs`: `[seq of was, seq of value]`). The page reports
  in the hidden `_bp_seen` input, per field, the number of the last value it
  showed: the new one when the field shows it after the event, else the old
  one. `bases/3` maps that number back to the value the server sent, so a
  forged number can only pick a value the server already sent to this tab.

  The page's own landed post (`:own`) is its base until it shows a later
  value: it is what the field shows after the save. Every older entry is
  dropped then, so an older remote value can never be picked again.

  Any other path that loads the form from the store (Reload, an explicit
  save, navigation: `Shared.rebuild_panes/1`) sends the page no numbers, so
  it drops the history (#25994 review): the page's last number then maps to
  nothing. Only a rebuild that then pushes keeps it (`keep_history/2`). The
  numbers start from the clock at the first one, so a page that rejoins a new
  socket and still reports the old socket's numbers matches nothing either.

  A field the page reports nothing for is not merged: the post stands, as
  before this module. So is any field that is not free text: a date or a
  select is a choice, not text two people type into.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Barkpark.Content

  @event "bp:form-remote-values"

  # Entries kept per field. A page that reports a number older than these is
  # not merged.
  @cap 16

  @doc """
  Tells the page of each top-level text field that differs between `old_form`
  and `new_form`, with the value it showed before. A free-text field is
  remembered, and its numbers ride along in `seqs`.
  """
  def push(socket, old_form, new_form) do
    changed =
      for {key, new} <- new_form,
          is_binary(key) and is_binary(new),
          old = Map.get(old_form, key),
          is_binary(old) and old != new,
          do: {key, old, new}

    if changed == [] do
      socket
    else
      {socket, values, seqs} =
        Enum.reduce(changed, {socket, %{}, %{}}, fn {key, old, new}, {s, values, seqs} ->
          name = "doc[#{key}]"
          values = Map.put(values, name, %{value: new, was: old})

          if free_text?(s.assigns[:editor_schema], key) do
            {s, pair} = remember(s, key, old, new)
            {s, values, Map.put(seqs, name, pair)}
          else
            {s, values, seqs}
          end
        end)

      payload = if seqs == %{}, do: %{values: values}, else: %{values: values, seqs: seqs}
      push_event(socket, @event, payload)
    end
  end

  @doc """
  Stores, for the post about to be saved, the base of each free-text field in
  `keys` that the page reported a number for (`seen`, the raw `_bp_seen`
  value). `Forms.upsert_draft/6` merges the post onto the stored value from
  it (`Barkpark.Content.TextRebase.rebase/3`).
  """
  def put_bases(socket, keys, seen) do
    seen = decode_seen(seen)
    history = history(socket)
    schema = socket.assigns[:editor_schema]

    bases =
      for key <- keys,
          free_text?(schema, key),
          n = Map.get(seen, "doc[#{key}]"),
          is_integer(n),
          {_seq, value, _kind} <- List.wrap(base_entry(Map.get(history, key, []), n)),
          into: %{},
          do: {key, value}

    assign(socket, :editor_field_bases, bases)
  end

  @doc false
  # The entry a post reporting number `n` was written from: the latest of the
  # values the page showed up to `n` and the page's own landed post.
  def base_entry(entries, n) do
    entries
    |> Enum.filter(fn {seq, _value, kind} -> kind == :own or seq <= n end)
    |> latest()
  end

  @doc """
  After a post of `keys` (`posted` is the posted `doc` map): when it landed,
  each free-text field's posted text is the page's base from now on. When the
  store took a merged text instead, the page is told (`push/3`) and the form
  holds the stored text. Always clears the bases `put_bases/3` stored.
  """
  def settle(socket, before, keys, posted) do
    socket = assign(socket, :editor_field_bases, %{})
    doc = socket.assigns[:editor_doc]

    if socket.assigns[:save_status] == "Saved" and is_map(doc) and
         doc != before.assigns[:editor_doc] do
      schema = socket.assigns[:editor_schema]

      sent =
        for key <- keys,
            free_text?(schema, key),
            value = Map.get(posted, key),
            is_binary(value),
            into: %{},
            do: {key, value}

      socket = Enum.reduce(sent, socket, fn {key, value}, s -> remember_own(s, key, value) end)
      stored = Map.new(sent, fn {key, _} -> {key, stored_value(doc, key)} end)

      moved =
        for {key, value} <- stored,
            is_binary(value),
            value != sent[key],
            into: %{},
            do: {key, value}

      if moved == %{} do
        socket
      else
        socket
        |> push(sent, moved)
        |> assign(:editor_form, Map.merge(socket.assigns[:editor_form] || %{}, moved))
      end
    else
      socket
    end
  end

  @doc """
  Keeps `before`'s history on `socket`, which `Shared.rebuild_panes/1` built
  from it: for a rebuild that tells the page what changed with `push/3`.
  """
  def keep_history(socket, before),
    do: assign(socket, :editor_remote_history, before.assigns[:editor_remote_history])

  @doc """
  A field two people type text into: `title` (unless the schema declares it
  otherwise), a `text` field, or a `string` field without `options.list`.
  """
  def free_text?(schema, key) do
    case field(schema, key) do
      nil -> key == "title"
      %{"type" => "text"} -> true
      %{"type" => "string"} = f -> not is_list(get_in(f, ["options", "list"]))
      _ -> false
    end
  end

  defp field(%{fields: fields}, key) when is_list(fields),
    do: Enum.find(fields, &(is_map(&1) and &1["name"] == key))

  defp field(_schema, _key), do: nil

  defp stored_value(doc, "title"), do: Map.get(doc, :title)
  defp stored_value(doc, key), do: Map.get(Map.get(doc, :content) || %{}, key)

  # Records `old` (unless it is the field's latest value) and `new`, each with
  # a fresh number; returns `[seq of old, seq of new]`.
  defp remember(socket, key, old, new) do
    entries = Map.get(history(socket), key, [])

    {socket, entries, was_seq} =
      case latest(entries) do
        {seq, ^old, _kind} ->
          {socket, entries, seq}

        _ ->
          {socket, seq} = next_seq(socket)
          {socket, entries ++ [{seq, old, :push}], seq}
      end

    {socket, seq} = next_seq(socket)
    {put_entries(socket, key, entries ++ [{seq, new, :push}]), [was_seq, seq]}
  end

  defp remember_own(socket, key, value) do
    {socket, seq} = next_seq(socket)
    put_entries(socket, key, [{seq, value, :own}])
  end

  defp latest([]), do: nil
  defp latest(entries), do: Enum.max_by(entries, fn {seq, _, _} -> seq end)

  defp next_seq(socket) do
    seq = (socket.assigns[:editor_remote_seq] || System.os_time(:microsecond)) + 1
    {assign(socket, :editor_remote_seq, seq), seq}
  end

  # The history belongs to one document; another document's is empty.
  defp history(socket) do
    case socket.assigns[:editor_remote_history] do
      {key, history} -> if key == doc_key(socket), do: history, else: %{}
      _ -> %{}
    end
  end

  defp put_entries(socket, key, entries) do
    history = Map.put(history(socket), key, Enum.take(entries, -@cap))
    assign(socket, :editor_remote_history, {doc_key(socket), history})
  end

  defp doc_key(socket) do
    case socket.assigns[:editor_doc] do
      %{doc_id: id} when is_binary(id) -> {socket.assigns[:editor_type], Content.published_id(id)}
      _ -> nil
    end
  end

  defp decode_seen(seen) when is_binary(seen) do
    case Jason.decode(seen) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_seen(_seen), do: %{}
end
