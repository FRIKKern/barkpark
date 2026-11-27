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
  held top-level field other than the write's own, read from the store
  row as it is now, not the row A's socket last drew. `restore/2`, run after
  the write has settled, puts A's words back into the form and keeps the
  banner, the held field's unsaved mark and the hold state as they were.
  A Save or Reload still ends the hold, as before.

  A held path inside the write's own top (a row's rich text, a label in an
  object, while an array op writes the object) takes the store's value too,
  and gets A's words back after (task-ffb773f49c564973). Each hold records
  its path when it starts (`hold_paths/2`: `RichTextRemote.keep_held`,
  `TextUnderLock.hold/3`), each row on it by its `_key`, in
  `editor_held_paths`: an op moves rows, and a hold's input name keeps the
  index it started at (#29078 r1 review). The row is found by its `_key` in
  the form after the op and in the store. A rich text's entry counts while
  `editor_rt_held` holds it; a Save, a Reload or a load ends them all. An
  entry of a text hold that has ended only keeps a value the form shows
  unsaved until A's next post or Save, and only while the banner names its
  top.
  """

  import Phoenix.Component, only: [assign: 2]

  alias Barkpark.Content
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.FormPath
  alias BarkparkWeb.Studio.StudioLive.Path

  # The hold, as the banner and the next post read it.
  @kept [
    :editor_clash_fields,
    :editor_text_paused,
    :editor_held_paths,
    :editor_rt_held,
    :editor_rt_clash
  ]

  @doc """
  `{form, held}`: `form` with the store's value in each held top-level
  field not in `own`, and what `restore/2` needs (`nil`: nothing held).
  """
  def stored(socket, form, own) when is_map(form) do
    mine = socket.assigns[:editor_form] || %{}

    case {tops(socket.assigns, own), own_paths(socket.assigns, own, mine)} do
      {[], []} ->
        {form, nil}

      {tops, paths} ->
        doc = store_row(socket)
        form = Enum.reduce(tops, form, &store_value(&2, &1, doc))
        form = Enum.reduce(paths, form, &store_at(&2, &1, doc))

        {form,
         %{
           tops: tops,
           mine: Map.take(mine, tops),
           paths:
             for(kp <- paths, {:ok, at} <- [find(mine, kp)], do: {kp, FormPath.get(mine, at)}),
           kept: Map.take(socket.assigns, @kept)
         }}
    end
  end

  def stored(_socket, form, _own), do: {form, nil}

  # The open document's row in the store now. `editor_doc` is the row A's
  # socket had when the hold began: B's second save during the hold is not
  # in it, and a write of the whole form put B's first value back over the
  # second (#29078 r2 review, task-50094855250e5dad).
  defp store_row(socket) do
    own = socket.assigns[:editor_doc]

    with %{doc_id: id} when is_binary(id) <- own,
         type when is_binary(type) <- socket.assigns[:editor_type],
         {%{} = doc, _, _} <-
           Content.fetch_doc_with_draft(
             type,
             id,
             socket.assigns.dataset,
             ScopeHelpers.scope_opts(socket)
           ) do
      doc
    else
      _ -> own
    end
  end

  @doc """
  Records each `{id, path}` of a hold that starts (`{:rt, name}` or
  `{:text, key}`), its rows by `_key` in the form as it is now. A hold
  already recorded keeps its path: its input name may have kept an index
  an op has since moved.
  """
  def hold_paths(socket, entries) do
    form = socket.assigns[:editor_form] || %{}

    paths =
      Enum.reduce(entries, socket.assigns[:editor_held_paths] || %{}, fn {id, path}, paths ->
        Map.put_new(paths, id, keyed(form, path))
      end)

    assign(socket, editor_held_paths: paths)
  end

  @doc "Forgets the recorded path of each hold in `ids`: it has ended."
  def drop_paths(socket, ids),
    do:
      assign(socket, editor_held_paths: Map.drop(socket.assigns[:editor_held_paths] || %{}, ids))

  @doc "Ends every recorded hold path: a Save, a Reload, a load."
  def drop_paths(socket), do: assign(socket, editor_held_paths: %{})

  @doc "The hold `stored/3` read, back on the socket after the write."
  def restore(socket, nil), do: socket

  def restore(socket, %{tops: tops, mine: mine, kept: kept} = held) do
    a = socket.assigns
    paths = Map.get(held, :paths, [])
    form = Enum.reduce(paths, Map.merge(a[:editor_form] || %{}, mine), &put_mine/2)
    keys = tops ++ for({[top | _], _} <- paths, do: top)

    socket
    |> assign(
      editor_form: form,
      editor_dirty: true,
      editor_unsaved_keys:
        MapSet.union(a[:editor_unsaved_keys] || MapSet.new(), MapSet.new(keys)),
      doc_conflict: true,
      save_status:
        if(a[:save_status] in [nil, "Saved"],
          do: "Updated by another user",
          else: a[:save_status]
        ),
      editor_clash_fields:
        Enum.uniq((kept[:editor_clash_fields] || []) ++ (a[:editor_clash_fields] || [])),
      editor_text_paused: kept[:editor_text_paused] || a[:editor_text_paused] || [],
      editor_held_paths: Map.merge(a[:editor_held_paths] || %{}, kept[:editor_held_paths] || %{}),
      editor_rt_held: Map.merge(a[:editor_rt_held] || %{}, kept[:editor_rt_held] || %{}),
      editor_rt_clash: Map.merge(a[:editor_rt_clash] || %{}, kept[:editor_rt_clash] || %{})
    )
  end

  defp tops(assigns, own) do
    if assigns[:doc_conflict] == true,
      do: Enum.uniq(assigns[:editor_clash_fields] || []) -- List.wrap(own),
      else: []
  end

  # Each recorded held path (`hold_paths/2`) below a top in `own` that the
  # banner names. A held top-level field is the write's own field: the
  # write is A's edit of it. A rich text held with no recorded path is read
  # from its name against the form.
  defp own_paths(assigns, own, mine) do
    if assigns[:doc_conflict] == true do
      named = assigns[:editor_clash_fields] || []
      recorded = assigns[:editor_held_paths] || %{}

      rich =
        for name <- Map.keys(assigns[:editor_rt_held] || %{}),
            do: Map.get_lazy(recorded, {:rt, name}, fn -> keyed(mine, Path.parse_path(name)) end)

      text = for {{:text, _}, path} <- recorded, do: path

      for [top, _ | _] = path <- rich ++ text,
          top in List.wrap(own),
          top in named,
          uniq: true,
          do: path
    else
      []
    end
  end

  defp keyed(_value, []), do: []

  defp keyed(list, [i | rest]) when is_list(list) and is_integer(i) do
    case Enum.at(list, i) do
      %{"_key" => key} = row when is_binary(key) -> [{:key, key} | keyed(row, rest)]
      row -> [i | keyed(row, rest)]
    end
  end

  defp keyed(value, [seg | rest]), do: [seg | keyed(FormPath.get(value, [seg]), rest)]

  # The index path of a keyed path in `value`; `:error` where a row is gone.
  defp find(_value, []), do: {:ok, []}

  defp find(list, [{:key, key} | rest]) when is_list(list) do
    case Enum.find_index(list, &match?(%{"_key" => ^key}, &1)) do
      nil -> :error
      i -> with {:ok, at} <- find(Enum.at(list, i), rest), do: {:ok, [i | at]}
    end
  end

  defp find(_value, [{:key, _} | _]), do: :error

  defp find(value, [seg | rest]),
    do: with({:ok, at} <- find(FormPath.get(value, [seg]), rest), do: {:ok, [seg | at]})

  defp store_at(form, kp, doc) do
    store = stored_map(doc)

    with {:ok, from} <- find(store, kp),
         {:ok, to} <- find(form, kp),
         do: FormPath.put(form, to, FormPath.get(store, from)),
         else: (_ -> form)
  end

  defp put_mine({kp, value}, form) do
    case find(form, kp) do
      {:ok, at} -> FormPath.put(form, at, value)
      :error -> form
    end
  end

  defp stored_map(%{content: %{} = content} = doc), do: Map.put(content, "title", doc.title)
  defp stored_map(_doc), do: %{}

  # Only a field the write posts. One the store does not hold is left out:
  # the save keeps a stored key the form does not post (`Content.Forms`).
  defp store_value(form, top, _doc) when not is_map_key(form, top), do: form

  defp store_value(form, "title", %{title: title}) when is_binary(title),
    do: Map.put(form, "title", title)

  defp store_value(form, top, %{content: %{} = content}) when is_map_key(content, top),
    do: Map.put(form, top, Map.fetch!(content, top))

  defp store_value(form, top, _doc), do: Map.delete(form, top)
end
