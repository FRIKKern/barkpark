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

  The hold stays on autosave (task-fe9d8741f0641f97). The page keeps
  reporting the old socket's number, so each autosave of the field is held
  again: the store keeps B's value, and the form A's latest words. Before,
  a field the banner named was written as typed on A's next key, so someone
  still typing saw the banner for one key and B's words were gone. An
  explicit Save writes A's words, and Reload takes the store's.

  A field other than the post's target whose posted value is a version the
  store held before is stale, not typed (task-727f65fc259d0c7b): the page
  showed it from before B's save. It was held under the banner, and A's
  next key wrote it over B's with the banner gone. It is put back to the
  store, never held, and the page's input is drawn the stored value.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Barkpark.Content.Revisions
  alias BarkparkWeb.ScopeHelpers

  alias BarkparkWeb.Studio.StudioLive.Handlers.Lifecycle
  alias BarkparkWeb.Studio.StudioLive.Handlers.RemoteValues
  alias BarkparkWeb.Studio.StudioLive.Handlers.TextConfirmed
  alias BarkparkWeb.Studio.StudioLive.Handlers.TextUnderLock

  @doc """
  `{doc, typed}`: the post with each held field put back to the stored
  value, and the held fields with A's words and the stored value
  (`[{key, words, stored}]`). `units` are every free-text field the post
  carries, not only its target (#28830 r1 review, B1): a post from before
  the rejoin carries the whole form as the page showed it, and an explicit
  Save is one too (B2). `on` is `:autosave` or `:save`: only a Save writes
  a field the banner names.
  """
  def split(socket, units, seen, doc, targets \\ [], on \\ :save)

  def split(socket, units, seen, doc, targets, on) when is_binary(seen) and is_map(doc) do
    schema = socket.assigns[:editor_schema]

    typed =
      case Lifecycle.base_doc(socket) do
        %{} = base ->
          text =
            Map.put(if(is_map(base.content), do: base.content, else: %{}), "title", base.title)

          for key <- Enum.uniq(units),
              RemoteValues.free_text_at?(schema, key),
              on == :autosave or not told?(socket, key),
              RemoteValues.born_untaken?(socket, key, seen),
              mine = RemoteValues.value_at(doc, key),
              stored = RemoteValues.value_at(text, key),
              is_binary(mine) and is_binary(stored) and mine != stored,
              not TextConfirmed.known?(seen, key, stored),
              do: {key, mine, stored}

        _ ->
          []
      end

    {Enum.reduce(typed, doc, fn {key, _mine, stored}, d -> RemoteValues.put_at(d, key, stored) end),
     stale(socket, typed, targets)}
  end

  def split(_socket, _units, _seen, doc, _targets, _on), do: {doc, []}

  # Each field other than the target whose posted value a stored version
  # held is tagged `:stale`. The store is asked only for such a field.
  defp stale(socket, typed, targets) do
    Enum.map(typed, fn {key, mine, stored} = entry ->
      if key not in targets and held_before?(socket, key, mine),
        do: {key, mine, stored, :stale},
        else: entry
    end)
  end

  defp held_before?(
         %{assigns: %{editor_doc: %{doc_id: id}, editor_type: type}} = socket,
         key,
         mine
       )
       when is_binary(id) and is_binary(type),
       do:
         Revisions.revision_holds?(
           id,
           type,
           socket.assigns.dataset,
           key,
           mine,
           ScopeHelpers.scope_opts(socket)
         )

  defp held_before?(_socket, _key, _mine), do: false

  @doc """
  `{targets, units}` of an autosave: its target (and the text subfield it
  changed), and those with every free-text field the post carries.
  """
  def units(schema, keys, path, doc) do
    targets = RemoteValues.units(keys, RemoteValues.text_path(schema, keys, path))
    {targets, targets ++ RemoteValues.text_units(schema, doc)}
  end

  @doc """
  The fields whose autosave a hold paused, until a Save or Reload: the
  banner says so (`editor_text_paused`, `Editor.doc_conflict_banner/1`).

  A's words for each held field in the form, unsaved, with the banner, and
  drawn into the page's input. The desk redraws its form on a rejoin, so
  the input already showed the stored value: the banner said A's words were
  kept, and A's next key saved the stored text over them (#28830 r1 review,
  B3). The input takes A's words while it still shows the stored value
  (bp-array-focus.js `takeFocused`); one still showing A's words keeps them.
  """
  def hold(socket, typed, on \\ :autosave)

  def hold(socket, [], _on), do: assign(socket, :editor_text_paused, [])

  def hold(socket, typed, on) do
    {stale, typed} = Enum.split_with(typed, &(tuple_size(&1) == 4))

    socket
    |> assign(:editor_text_paused, typed |> Enum.map(&top(elem(&1, 0))) |> Enum.uniq())
    |> held(typed)
    |> drawn(stale)
    |> named(stale, on)
  end

  # An explicit Save that put a field back says so, not "Saved" (#28850 r1
  # review): the post may be A's own edit back to an earlier version. The
  # banner names the field, which shows the stored value; typing on saves.
  defp named(socket, [_ | _] = stale, :save) do
    TextUnderLock.hold(
      socket,
      Enum.map(stale, &elem(&1, 0)),
      Enum.reduce(stale, %{}, fn {key, _mine, stored, :stale}, form ->
        RemoteValues.put_at(form, key, stored)
      end)
    )
  end

  defp named(socket, _stale, _on), do: socket

  defp held(socket, []), do: socket

  defp held(socket, typed) do
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

  # A stale field's input, still showing it, is drawn the stored value:
  # nothing redraws it (the form's value did not change), and `draw` sets
  # an input that is not focused (bp-array-focus.js).
  defp drawn(socket, []), do: socket

  defp drawn(socket, stale) do
    values =
      Map.new(stale, fn {key, mine, stored, :stale} ->
        {RemoteValues.input_name(key), %{value: stored, was: mine, draw: true}}
      end)

    Phoenix.LiveView.push_event(socket, "bp:form-remote-values", %{values: values})
  end

  # A field the banner already names was told: a Save writes A's words.
  defp told?(socket, key) do
    fields = socket.assigns[:editor_clash_fields] || []
    socket.assigns[:doc_conflict] == true and (fields == [] or top(key) in fields)
  end

  defp top([key | _]), do: key
  defp top(key), do: key
end
