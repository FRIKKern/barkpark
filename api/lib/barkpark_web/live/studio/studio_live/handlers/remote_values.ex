defmodule BarkparkWeb.Studio.StudioLive.Handlers.RemoteValues do
  @moduledoc """
  Another editor's save, told to the field this tab is typing in
  (task-e6ef964ac2e41d5a).

  A LiveView patch never sets the value of the focused input. So when another
  editor saved the field this tab had focused, the tab kept the old text, and
  its next post wrote that text back over the other's words.

  `push/3` sends the page each changed text field: its new value and the value
  the page showed before (`bp:form-remote-values`). bp-array-focus.js sets the
  focused input when it still shows exactly the old value, and keeps typing
  the page has not sent yet.

  So a post can still be written from an older value: typing kept over a
  push, or a post the browser sent before the push reached it. Until the page
  posts a field again, each value this tab was told for it is remembered as a
  value the page may be editing from (`editor_remote_pending`). `bases/2`
  hands them to the save, which writes the post on top of the stored value
  from the one it is nearest to (`Barkpark.Content.TextRebase`), so both
  editors' words stay. `settle/4` sends what the store then holds back to the
  page.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Barkpark.Content.DraftId

  @event "bp:form-remote-values"
  @max_candidates 16

  @doc """
  Tells the page of each top-level text field that differs between `old_form`
  and `new_form`, and remembers both values as ones the page may edit from.
  """
  def push(socket, old_form, new_form) do
    values =
      for {key, new} <- new_form,
          is_binary(key) and is_binary(new),
          old = Map.get(old_form, key),
          is_binary(old) and old != new,
          into: %{},
          do: {key, {old, new}}

    push_values(socket, values)
  end

  @doc """
  Each posted text field, as field key => the values this tab was told of
  since it last posted it, oldest first (often none). The save adds the value
  the tab's own last save left, and rebases a field written from an older
  value than the store holds.
  """
  def bases(posted, socket) when is_map(posted) do
    pending = pending(socket)
    for {key, value} <- posted, is_binary(value), into: %{}, do: {key, Map.get(pending, key, [])}
  end

  def bases(_posted, _socket), do: %{}

  @doc """
  After an autosave of `posted`: the page has now shown what it posted, so
  nothing is pending for those fields. Each field in `bases` the store holds
  differently from what was posted (the save kept another editor's words)
  goes back to the page and into the form buffer. `before` is the
  `editor_doc` the save started from; an unchanged one means nothing was
  written.
  """
  def settle(socket, bases, posted, before) do
    socket = forget(socket, Map.keys(posted))
    doc = socket.assigns[:editor_doc]

    if bases == %{} or not is_map(doc) or doc == before do
      socket
    else
      values =
        for {key, _} <- bases,
            sent = Map.get(posted, key),
            stored = stored_value(doc, key),
            is_binary(sent) and is_binary(stored) and sent != stored,
            into: %{},
            do: {key, {sent, stored}}

      form =
        Enum.reduce(values, socket.assigns[:editor_form] || %{}, fn {key, {_, stored}}, acc ->
          Map.put(acc, key, stored)
        end)

      socket |> assign(editor_form: form) |> push_values(values)
    end
  end

  defp push_values(socket, values) when values == %{}, do: socket

  defp push_values(socket, values) do
    pending =
      Enum.reduce(values, pending(socket), fn {key, {old, new}}, acc ->
        seen = Map.get(acc, key, [])
        Map.put(acc, key, Enum.take(Enum.uniq(seen ++ [old, new]), -@max_candidates))
      end)

    payload =
      Map.new(values, fn {key, {old, new}} -> {"doc[#{key}]", %{value: new, was: old}} end)

    socket
    |> assign(editor_remote_pending: {doc_key(socket), pending})
    |> push_event(@event, %{values: payload})
  end

  defp forget(socket, keys) do
    case pending(socket) do
      empty when empty == %{} -> socket
      pending -> assign(socket, editor_remote_pending: {doc_key(socket), Map.drop(pending, keys)})
    end
  end

  # What is pending belongs to one document; another one open has none.
  defp pending(socket) do
    doc = doc_key(socket)

    case socket.assigns[:editor_remote_pending] do
      {^doc, pending} when is_map(pending) -> pending
      _ -> %{}
    end
  end

  defp doc_key(socket) do
    case socket.assigns[:editor_doc] do
      %{doc_id: id} when is_binary(id) -> DraftId.published_id(id)
      _ -> nil
    end
  end

  defp stored_value(doc, "title"), do: Map.get(doc, :title)
  defp stored_value(doc, key), do: Map.get(Map.get(doc, :content) || %{}, key)
end
