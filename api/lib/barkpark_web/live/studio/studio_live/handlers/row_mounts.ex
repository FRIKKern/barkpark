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

  The count goes up for each index whose rich text A's side replaced with
  a form the server built (`replaced/2`): an array op, an undo or redo, a
  paste, a revert, a restore. A row whose rich text did not change keeps
  its count and its mount, so the words A has not posted yet stay put.

  A new socket starts with no counts. The page sends its counts on each
  join with its form generation (`data-bp-row-mounts`, `RejoinForm`), so a
  rejoin draws the page's wrapper ids and the editors keep what was typed
  while the socket was down.
  """

  import Phoenix.Component, only: [assign: 2]

  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.FormPath
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.RowDraws

  @doc """
  The socket after A's side put a form the server built in place of
  `old_form`: an array op, an undo or redo, a paste, a revert, a restore,
  a Reload, a navigation back to the same document. Each row whose rich
  text the new form holds differs from `old_form`'s at its index counts
  one more, so its editor draws the new value. A page's own post is not one
  of these: what it posted is what its editors show (`Shared.do_autosave/4`).
  Another editor's save is not either: its values reach the page's editors
  by the remote push (`RichTextRemote`).
  """
  def replaced(socket, old_form) do
    new_form = socket.assigns[:editor_form]

    if is_map(old_form) and is_map(new_form) and old_form != new_form do
      rows =
        for path <- RichTextRemote.every(socket.assigns[:editor_schema], new_form),
            RowDraws.row?(path),
            FormPath.get(old_form, path) != FormPath.get(new_form, path),
            uniq: true,
            do: RichTextRemote.input_name(Enum.drop(path, -1))

      bump(socket, rows)
    else
      socket
    end
  end

  defp bump(socket, []), do: socket

  defp bump(socket, rows) do
    counts =
      Enum.reduce(rows, socket.assigns[:editor_row_mounts] || %{}, fn row, acc ->
        Map.update(acc, row, 1, &(&1 + 1))
      end)

    assign(socket, editor_row_mounts: counts)
  end

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
