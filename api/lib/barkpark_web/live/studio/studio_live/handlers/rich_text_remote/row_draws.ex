defmodule BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.RowDraws do
  @moduledoc """
  The values a row's rich text editor may show, by the row's `_key` and the
  digest of the value drawn (task-82519fd79663e072, #29040 r1 review).

  A row's editor posts its owner entry, `[name, row key, digest of the
  value drawn]` (`CompositeField`). Its name carries the row's index, which
  moves when a row is moved, added or taken out, A's own presses included;
  the key and the digest do not. So the draws a post may name are kept by
  the row's key, never by the index:

    * the value this socket was born with (`RichTextRemote.born/1`) and
      each value it took from another editor's save or a Reload
      (`record_form/2`),
    * A's own last post on a draw (`record_own/4`): the page shows its own
      words on that draw, and draws them on its next remount.

  `fetch/4` finds the value a post was typed on; none is `:error`.
  """

  import Phoenix.Component, only: [assign: 3]

  alias BarkparkWeb.Components.Fields.CompositeField
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.FormPath
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  # Draws kept per row rich text: A's typing adds one per post.
  @cap 8

  @doc "Whether a rich text's path is inside a row (it carries an index)."
  def row?(path), do: Enum.any?(path, &is_integer/1)

  @doc "Records each row rich text value of `form` under its row key and digest."
  def record_form(socket, form) when is_map(form) do
    entries =
      for path <- RichTextRemote.every(socket.assigns[:editor_schema], form),
          row?(path),
          key = row_key(form, path),
          value = FormPath.get(form, path),
          do: {id(path, key), CompositeField.drawn_digest(value), value}

    record(socket, entries)
  end

  def record_form(socket, _form), do: socket

  @doc """
  Records A's own `value`, posted on the draw `digest` of the row `key` at
  `path`: under that draw, and under its own digest, which the next remount
  of the row draws.
  """
  def record_own(socket, path, {key, digest}, value) do
    record(socket, [
      {id(path, key), digest, value},
      {id(path, key), CompositeField.drawn_digest(value), value}
    ])
  end

  @doc "The value the draw `digest` of the row `key` at `path` showed."
  def fetch(socket, path, key, digest) do
    case List.keyfind(Map.get(all(socket), id(path, key), []), digest, 0) do
      {_digest, value} -> {:ok, value}
      nil -> :error
    end
  end

  # A row rich text is named by its path without indexes and its row's key.
  # A row with no key (task-12ff178d188b04b4) has only its index, as before.
  defp id(path, key) do
    case to_string(key) do
      "" -> {path, ""}
      key -> {Enum.reject(path, &is_integer/1), key}
    end
  end

  defp row_key(form, path) do
    case FormPath.get(form, Enum.drop(path, -1)) do
      %{"_key" => key} when is_binary(key) -> key
      _ -> ""
    end
  end

  defp record(socket, []), do: socket

  defp record(socket, entries) do
    case PostIdentity.of(socket) do
      nil ->
        socket

      doc ->
        draws =
          Enum.reduce(entries, all(socket), fn {id, digest, value}, draws ->
            kept = Map.get(draws, id, []) |> List.keydelete(digest, 0)
            Map.put(draws, id, Enum.take([{digest, value} | kept], @cap))
          end)

        assign(socket, :editor_rt_row_draws, {doc, draws})
    end
  end

  defp all(socket) do
    case socket.assigns[:editor_rt_row_draws] do
      {doc, %{} = draws} when not is_nil(doc) ->
        if doc == PostIdentity.of(socket), do: draws, else: %{}

      _ ->
        %{}
    end
  end
end
