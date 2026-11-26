defmodule BarkparkWeb.Studio.StudioLive.Handlers.HeldFields do
  @moduledoc """
  A field held under the banner, through a write of the whole form
  (task-881a41cd3227e73c).

  A held field's form value is A's words: B's save is stored, and the
  banner tells A that their words wait unsaved (`TextUnderLock.hold/3`,
  `TextRejoin.hold/3`, `RichTextRemote.hold/2`). An array op, a tag press, a
  tree codelist pick and a slug Generate save the whole editor form, so they
  wrote A's held words over B's save. Then the save's "Saved" cleared the
  banner (`Fields.settle_dirty/2`), and the paused line said autosave was
  paused for a field that had just been written.

  `stored/3` gives such a write the form with the store's value in each
  held top-level field other than the write's own. `restore/2`, run after
  the write has settled, puts A's words back into the form and keeps the
  banner, the held field's unsaved mark and the hold state as they were.
  A Save or Reload still ends the hold, as before.
  """

  import Phoenix.Component, only: [assign: 2]

  # The hold, as the banner and the next post read it.
  @kept [:editor_clash_fields, :editor_text_paused, :editor_rt_held, :editor_rt_clash]

  @doc """
  `{form, held}`: `form` with the store's value in each held top-level
  field not in `own`, and what `restore/2` needs (`nil`: nothing held).
  """
  def stored(socket, form, own) when is_map(form) do
    case tops(socket.assigns, own) do
      [] ->
        {form, nil}

      tops ->
        doc = socket.assigns[:editor_doc]
        mine = socket.assigns[:editor_form] || %{}

        {Enum.reduce(tops, form, &store_value(&2, &1, doc)),
         %{tops: tops, mine: Map.take(mine, tops), kept: Map.take(socket.assigns, @kept)}}
    end
  end

  def stored(_socket, form, _own), do: {form, nil}

  @doc "The hold `stored/3` read, back on the socket after the write."
  def restore(socket, nil), do: socket

  def restore(socket, %{tops: tops, mine: mine, kept: kept}) do
    a = socket.assigns

    socket
    |> assign(
      editor_form: Map.merge(a[:editor_form] || %{}, mine),
      editor_dirty: true,
      editor_unsaved_keys:
        MapSet.union(a[:editor_unsaved_keys] || MapSet.new(), MapSet.new(tops)),
      doc_conflict: true,
      save_status:
        if(a[:save_status] in [nil, "Saved"],
          do: "Updated by another user",
          else: a[:save_status]
        ),
      editor_clash_fields:
        Enum.uniq((kept[:editor_clash_fields] || []) ++ (a[:editor_clash_fields] || [])),
      editor_text_paused: kept[:editor_text_paused] || a[:editor_text_paused] || [],
      editor_rt_held: Map.merge(a[:editor_rt_held] || %{}, kept[:editor_rt_held] || %{}),
      editor_rt_clash: Map.merge(a[:editor_rt_clash] || %{}, kept[:editor_rt_clash] || %{})
    )
  end

  defp tops(assigns, own) do
    if assigns[:doc_conflict] == true,
      do: Enum.uniq(assigns[:editor_clash_fields] || []) -- List.wrap(own),
      else: []
  end

  # Only a field the write posts. One the store does not hold is left out:
  # the save keeps a stored key the form does not post (`Content.Forms`).
  defp store_value(form, top, _doc) when not is_map_key(form, top), do: form

  defp store_value(form, "title", %{title: title}) when is_binary(title),
    do: Map.put(form, "title", title)

  defp store_value(form, top, %{content: %{} = content}) when is_map_key(content, top),
    do: Map.put(form, top, Map.fetch!(content, top))

  defp store_value(form, top, _doc), do: Map.delete(form, top)
end
