defmodule BarkparkWeb.Studio.StudioLive.Handlers.TextRejoin do
  @moduledoc """
  A free-text post from a page that rejoined a new socket while another
  editor saved the field (task-4fc7383b936f606a), as `RichTextRemote.born/1`
  reads rich text (task-eeda66fac5af065f).

  The page keeps its `_bp_seen`, numbered by the old socket. The new
  socket's base is the store, so a post typed while the page was away was
  written as sent, over B's save, with no banner. A connected mount now
  sends each free-text field its stored value (`RemoteValues.born/1`). A
  post that did not take it (`RemoteValues.born_untaken?/3`) and differs
  from the store is held (`split/5`, `hold/2`): the store keeps its value,
  and A's words stay in the form, unsaved, with the banner. Typing on saves
  them, as after any hold the banner told. A field showing the stored value
  takes the number, and its posts read as before.

  A page that typed while away with no other save is held too: a banner
  that was not needed, never words lost without one (task-6496826d722a5a06).
  """

  alias BarkparkWeb.Studio.StudioLive.Handlers.Lifecycle
  alias BarkparkWeb.Studio.StudioLive.Handlers.RemoteValues
  alias BarkparkWeb.Studio.StudioLive.Handlers.TextUnderLock

  @doc """
  `{doc, typed}`: the post with each held field put back to the stored
  value, and the held fields with A's words and the stored value
  (`[{key, words, stored}]`). `units` are every free-text field the post
  carries, not only its target (#28830 r1 review, B1): a post from before
  the rejoin carries the whole form as the page showed it, and an explicit
  Save is one too (B2).
  """
  def split(socket, units, seen, doc) when is_binary(seen) and is_map(doc) do
    schema = socket.assigns[:editor_schema]

    typed =
      case Lifecycle.base_doc(socket) do
        %{} = base ->
          text =
            Map.put(if(is_map(base.content), do: base.content, else: %{}), "title", base.title)

          for key <- Enum.uniq(units),
              RemoteValues.free_text_at?(schema, key),
              not told?(socket, key),
              RemoteValues.born_untaken?(socket, key, seen),
              mine = RemoteValues.value_at(doc, key),
              stored = RemoteValues.value_at(text, key),
              is_binary(mine) and is_binary(stored) and mine != stored,
              do: {key, mine, stored}

        _ ->
          []
      end

    {Enum.reduce(typed, doc, fn {key, _mine, stored}, d -> RemoteValues.put_at(d, key, stored) end),
     typed}
  end

  def split(_socket, _units, _seen, doc), do: {doc, []}

  @doc """
  The units of an autosave: its target (and the text subfield it changed)
  and every free-text field the post carries.
  """
  def units(schema, keys, path, doc),
    do:
      RemoteValues.units(keys, RemoteValues.text_path(schema, keys, path)) ++
        RemoteValues.text_units(schema, doc)

  @doc """
  A's words for each held field in the form, unsaved, with the banner, and
  drawn into the page's input. The desk redraws its form on a rejoin, so
  the input already showed the stored value: the banner said A's words were
  kept, and A's next key saved the stored text over them (#28830 r1 review,
  B3). The input takes A's words while it still shows the stored value
  (bp-array-focus.js `takeFocused`); one still showing A's words keeps them.
  """
  def hold(socket, []), do: socket

  def hold(socket, typed) do
    values =
      Map.new(typed, fn {key, mine, stored} ->
        {RemoteValues.input_name(key), %{value: mine, was: stored}}
      end)

    socket
    |> TextUnderLock.hold(
      Enum.map(typed, &elem(&1, 0)),
      Enum.reduce(typed, %{}, fn {key, mine, _stored}, form ->
        RemoteValues.put_at(form, key, mine)
      end)
    )
    |> Phoenix.LiveView.push_event("bp:form-remote-values", %{values: values})
  end

  # A field the banner already names was told: typing on saves A's words.
  defp told?(socket, key) do
    fields = socket.assigns[:editor_clash_fields] || []
    socket.assigns[:doc_conflict] == true and (fields == [] or top(key) in fields)
  end

  defp top([key | _]), do: key
  defp top(key), do: key
end
