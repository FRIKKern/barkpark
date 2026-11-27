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
  alias BarkparkWeb.Studio.StudioLive.Handlers.Lifecycle
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.FormPath
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.RowDraws
  alias BarkparkWeb.Studio.StudioLive.Path
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @doc """
  Each re-targeted leaf (`{posted name, form path, value}`) A typed in,
  held at that path. The form holds the store's row there.
  """
  def hold(socket, [], _owners), do: socket

  def hold(socket, moved, owners) do
    drawn = drawn(owners)
    stored = stored(socket)

    acts =
      for {name, path, html} <- moved,
          is_binary(html),
          {:ok, digest} <- [Map.fetch(drawn, name)],
          not drawn?(PortableText.from_html(html, []), digest) do
        # The store's row, never the form's: a hold already open there put
        # A's view in the form (#29180 review, round 2).
        theirs = list(FormPath.get(stored, path))
        view = PortableText.from_html(html, theirs)
        {:held, RichTextRemote.input_name(path), path, {theirs, theirs, view, texts(theirs)}}
      end

    RichTextRemote.hold(socket, acts)
  end

  @doc """
  The folded post `doc` with the stored value at each held row rich text
  the post did not write (`written`, the paths the fold wrote from it).

  A hold puts A's view in the form at its path (`RichTextRemote.hold/2`).
  A post from A's stale page names the row's old path, so `split/3` never
  reads the held name, and the fold seeds the array from the form, A's
  view with it: it was written over the store, over a later save of
  another editor, or into a Duplicate copy (#29180 review, round 2: F1.1,
  F4, F8). The value the socket knows as stored goes there instead, so
  the row is written as stored, and the save's rebase takes a newer one.
  Only a value the seed took from the form is replaced.
  """
  def stored_at_holds(doc, socket, written) do
    form = socket.assigns[:editor_form] || %{}
    stored = stored(socket)

    Enum.reduce(holds(socket), doc, fn {name, _hold}, doc ->
      path = Path.parse_path(name)
      value = FormPath.get(stored, path)

      if RowDraws.row?(path) and not MapSet.member?(written, path) and not is_nil(value) and
           FormPath.get(doc, path) == FormPath.get(form, path),
         do: FormPath.put(doc, path, value),
         else: doc
    end)
  end

  # The holds of the document this socket shows (`editor_rt_doc`).
  defp holds(socket) do
    if socket.assigns[:editor_rt_doc] == PostIdentity.of(socket),
      do: socket.assigns[:editor_rt_held] || %{},
      else: %{}
  end

  # The newest stored row this socket has seen: another editor's frame
  # taken in since its own last write counts (`Lifecycle.base_doc/1`), or
  # a hold over a later save of B's wrote the older row back (F4).
  defp stored(socket) do
    case Lifecycle.base_doc(socket) do
      %{content: %{} = content} -> content
      _ -> %{}
    end
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
