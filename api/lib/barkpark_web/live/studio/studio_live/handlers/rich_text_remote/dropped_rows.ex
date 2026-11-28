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
  it. Nothing is written for it. It ends as every hold's words do: on
  Reload, or when another document opens.
  """

  import Phoenix.Component, only: [assign: 2]

  alias Barkpark.Content.PortableText
  alias BarkparkWeb.Components.Fields.CompositeField

  @doc """
  Of the dropped leaves (`{input name, value}`), A's words in each rich
  text A typed in, `{name, texts}`: one text per block. A leaf with no
  owner entry (a page that draws none) is not read.
  """
  def typed(dropped, owners) do
    drawn = drawn(owners)

    for {name, html} <- dropped,
        is_binary(html),
        {:ok, digest} <- [Map.fetch(drawn, name)],
        blocks <- [PortableText.from_html(html, [])],
        not drawn?(blocks, digest),
        texts <- [texts(blocks)],
        texts != [],
        do: {name, texts}
  end

  @doc "The banner, with A's words of each `{name, texts}` (`typed/2`)."
  def keep(socket, []), do: socket

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

  # Each owner entry's input name and the digest of the HTML drawn
  # (`[name, key, digest | outer keys]`, `CompositeField`).
  defp drawn(owners) do
    for entry <- List.wrap(owners),
        is_binary(entry),
        {:ok, [name, _key, digest | _]} <- [Jason.decode(entry)],
        is_binary(name),
        into: %{},
        do: {name, digest}
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
