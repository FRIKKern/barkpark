defmodule BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.MovedRows do
  @moduledoc """
  A row rich text the save fold found under another parent
  (task-3422ba9e403f8b75).

  A posted row whose list no longer holds its `_key` goes to the one row of
  that field shape that holds the key (`Fields.row_path/4`). That row may be
  the one another editor moved, or a copy Duplicate made of it with the same
  `_key` while the original was removed (#29180 review, P1b-P1d): the post
  cannot tell which. So A's words are never written there. The store keeps
  the row as it is, and A's words are held in it, with the banner, as a
  rich text the store kept over is held (`RichTextRemote.hold/2`): A sees
  them where they landed and decides with Save or Reload.

  A row A did not type in (its post is the draw its owner entry names) is
  not held. A leaf with no owner entry (not a rich text, or a page that
  draws none) is dropped, as before the re-target.
  """

  alias Barkpark.Content.PortableText
  alias BarkparkWeb.Components.Fields.CompositeField
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.FormPath

  @doc """
  Each re-targeted leaf (`{posted name, form path, value}`) A typed in,
  held at that path. The form holds the store's row there.
  """
  def hold(socket, [], _owners), do: socket

  def hold(socket, moved, owners) do
    drawn = drawn(owners)
    form = socket.assigns[:editor_form] || %{}

    acts =
      for {name, path, html} <- moved,
          is_binary(html),
          {:ok, digest} <- [Map.fetch(drawn, name)],
          not drawn?(PortableText.from_html(html, []), digest) do
        theirs = list(FormPath.get(form, path))
        view = PortableText.from_html(html, theirs)
        {:held, RichTextRemote.input_name(path), path, {theirs, theirs, view, texts(theirs)}}
      end

    RichTextRemote.hold(socket, acts)
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

  # A page drawn before the hex digest posts the old number (`RowDraws`).
  defp drawn?(blocks, digest) when is_integer(digest),
    do: :erlang.phash2(CompositeField.drawn_html(blocks)) == digest

  defp drawn?(blocks, digest), do: CompositeField.drawn_digest(blocks) == digest

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  # The row's words as the store holds them, one per block: the banner's.
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
