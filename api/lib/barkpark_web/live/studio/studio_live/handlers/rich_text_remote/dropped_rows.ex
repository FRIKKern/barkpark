defmodule BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.DroppedRows do
  @moduledoc """
  A row rich text the save fold could not place (task-3422ba9e403f8b75,
  task-c5534fec656190fc).

  The fold (`Fields.row_path/4`) writes a posted row into the row of its
  `_key` under the same parent. A row another editor removed, or moved
  under another parent, has no row to go to there, and its leaves are
  dropped: A's words typed in it were lost with no word (#29164 review,
  E13). A moved row is never written where it landed: it may be a copy
  Duplicate made with the same `_key` (#29180 review, P1b-P1d), and a hold
  there froze A's form over the other editor's later saves (#29223
  review, G3-G4b).

  Each dropped rich text A typed in (the post is not the draw its owner
  entry names) is kept in `editor_rt_clash` under `{:lost, name}`, and the
  conflict banner shows it as A's, with a line that says why, so A can copy
  it. Nothing is written for it. It ends on Reload, when another document
  opens, and when a later post or Save ends the conflict (`settled/1`): a
  later, unrelated clash showed the old line again (#29223 r2 review, B6).

  A row A removed itself (`removed/2`) is not another editor's doing: a
  post the page sent before it redrew carries it, and it is not shown
  (#29223 r2 review, B3).
  """

  import Phoenix.Component, only: [assign: 2]

  alias Barkpark.Content.PortableText
  alias BarkparkWeb.Components.Fields.CompositeField

  @doc """
  Of the dropped leaves (`{input name, value}`), A's words in each rich
  text A typed in, `{name, texts}`: one text per block. A leaf with no
  owner entry (a page that draws none) is not read, nor one of a row A
  removed itself (`removed`, its row keys).
  """
  def typed(dropped, owners, removed \\ MapSet.new()) do
    drawn = drawn(owners)

    for {name, html} <- dropped,
        is_binary(html),
        {:ok, {key, digest}} <- [Map.fetch(drawn, name)],
        not MapSet.member?(removed, key),
        blocks <- [PortableText.from_html(html, [])],
        not drawn?(blocks, digest),
        texts <- [texts(blocks)],
        texts != [],
        do: {name, texts}
  end

  @doc """
  The banner, with A's words of each `{name, texts}` (`typed/3`). With
  none, the words of an earlier post end with its conflict (`settled/1`).
  """
  def keep(socket, []), do: settled(socket)

  def keep(socket, lost) do
    clash =
      Enum.reduce(lost, socket.assigns[:editor_rt_clash] || %{}, fn {name, texts}, acc ->
        Map.put(acc, {:lost, name}, texts)
      end)

    assign(socket,
      doc_conflict: true,
      save_status: "Updated by another user",
      editor_rt_clash: clash
    )
  end

  @doc """
  The lost words end once a post or Save leaves no conflict: the banner is
  hidden then, and an unrelated clash later must not show them again.
  """
  def settled(socket) do
    clash = socket.assigns[:editor_rt_clash] || %{}

    if socket.assigns[:doc_conflict] != true and Enum.any?(Map.keys(clash), &lost?/1),
      do: assign(socket, editor_rt_clash: Map.reject(clash, fn {k, _} -> lost?(k) end)),
      else: socket
  end

  @doc "A row A removed with its own remove_row (`row`, the form's row)."
  def removed(socket, %{"_key" => key}) when is_binary(key) and key != "" do
    assign(socket,
      editor_rt_removed: MapSet.put(socket.assigns[:editor_rt_removed] || MapSet.new(), key)
    )
  end

  def removed(socket, _row), do: socket

  @doc """
  The rows A removed, less `keys`: rows the form holds again (`RowDraws`
  records each form the page draws). A later drop of such a row is another
  editor's doing (#29283 review, D2).
  """
  def back(socket, keys) do
    removed = socket.assigns[:editor_rt_removed]

    if removed && MapSet.size(removed) > 0,
      do: assign(socket, editor_rt_removed: MapSet.difference(removed, MapSet.new(keys))),
      else: socket
  end

  defp lost?({:lost, _name}), do: true
  defp lost?(_key), do: false

  # Each owner entry's input name, its row key and the digest of the HTML
  # drawn (`[name, key, digest | outer keys]`, `CompositeField`).
  defp drawn(owners) do
    for entry <- List.wrap(owners),
        is_binary(entry),
        {:ok, [name, key, digest | _]} <- [Jason.decode(entry)],
        is_binary(name),
        into: %{},
        do: {name, {key, digest}}
  end

  # A page drawn before the hex digest posts the old number
  # (`RowDraws`): read as it was drawn.
  defp drawn?(blocks, digest) when is_integer(digest),
    do: :erlang.phash2(CompositeField.drawn_html(blocks)) == digest

  defp drawn?(blocks, digest), do: CompositeField.drawn_digest(blocks) == digest

  defp texts(blocks) do
    for %{"children" => children} <- blocks,
        is_list(children),
        text <- [children |> Enum.map_join(&span_text/1) |> String.trim()],
        text != "",
        do: text
  end

  defp span_text(%{"text" => text}) when is_binary(text), do: text
  defp span_text(_child), do: ""
end
