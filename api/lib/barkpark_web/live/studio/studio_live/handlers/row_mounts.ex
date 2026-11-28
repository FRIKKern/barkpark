defmodule BarkparkWeb.Studio.StudioLive.Handlers.RowMounts do
  @moduledoc """
  How many times another row came to sit under a row's place: the count its
  rich text editor's wrapper id carries (`CompositeField`, `bp-rt-sub-…`).

  The editor sits in a `phx-update="ignore"` wrapper. Its id named the
  input and the row's `_key`, so for keyless rows it was the same for any
  row at one index. After A removed keyless row P, the editor at index 0
  kept P's text, P's owner entry and P's input while Q moved up under it,
  and A's next edit in row 0, even only Q's note, wrote P's text over Q's
  (task-dd336795aff64006). A changed count changes the id, so the page
  remounts the editor and draws the row now there.

  The count goes up for each index whose row A's own array change (a
  remove, a move, an insert) replaced. A row before the change keeps its
  count and its mount, so the words A has not posted yet stay put.

  A new socket starts with no counts. The page sends its counts on each
  join with its form generation (`data-bp-row-mounts`, `RejoinForm`), so a
  rejoin draws the page's wrapper ids and the editors keep what was typed
  while the socket was down.
  """

  import Phoenix.Component, only: [assign: 2]

  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote

  @doc """
  The socket after A's own array change at `list_path` (`["rows"]`) from
  the rows `old` to `new`: each index whose row changed counts one more.
  """
  def changed(socket, list_path, old, new) when is_list(list_path) do
    old = if is_list(old), do: old, else: []
    new = if is_list(new), do: new, else: []

    case for(
           j <- 0..(max(length(old), length(new)) - 1)//1,
           Enum.at(old, j) != Enum.at(new, j),
           do: RichTextRemote.input_name(list_path ++ [j])
         ) do
      [] ->
        socket

      rows ->
        counts =
          Enum.reduce(rows, socket.assigns[:editor_row_mounts] || %{}, fn row, acc ->
            Map.update(acc, row, 1, &(&1 + 1))
          end)

        assign(socket, editor_row_mounts: counts)
    end
  end

  def changed(socket, _list_path, _old, _new), do: socket

  @doc """
  The count for the object at input path `path` (`doc[rows][0]`,
  `doc[sections][0].items[1]`): its own row's and each outer row's, so an
  editor in a row inside a row that moved remounts too. 0 for none.
  """
  def count(counts, path) when is_map(counts) and map_size(counts) > 0 and is_binary(path) do
    ~r/\[\d+\]/
    |> Regex.scan(path, return: :index)
    |> Enum.map(fn [{at, len}] -> Map.get(counts, binary_part(path, 0, at + len), 0) end)
    |> Enum.sum()
  end

  def count(_counts, _path), do: 0

  @max_bytes 16_384
  @max_rows 500
  @max_count 100_000

  @doc "The counts as the editor form carries them for the next join: JSON, or nil for none."
  def attr(assigns) do
    case assigns[:editor_row_mounts] do
      %{} = counts when map_size(counts) > 0 -> Jason.encode!(counts)
      _ -> nil
    end
  end

  @doc """
  The counts a page sent at a join (`attr/1`'s JSON): a map of row input
  paths to counts, or `%{}` for a value that is not one. Bounded: a page
  only picks its own wrapper ids with it.
  """
  def parse(json) when is_binary(json) and byte_size(json) <= @max_bytes do
    with {:ok, %{} = counts} when map_size(counts) <= @max_rows <- Jason.decode(json),
         true <- Enum.all?(counts, &count?/1) do
      counts
    else
      _ -> %{}
    end
  end

  def parse(_json), do: %{}

  defp count?({"doc[" <> _ = path, n}),
    do: byte_size(path) <= 512 and is_integer(n) and n > 0 and n <= @max_count

  defp count?(_entry), do: false
end
