defmodule BarkparkWeb.Studio.StudioLive.RefusedSave do
  @moduledoc """
  A save the store refused: which field, why, and the rest of the form still
  saves (task-a0debf39daa6137d).

  The browser posts the whole form on every change. So one value the store
  refuses rode along with every later edit, each of those saves was refused
  too, the footer said only "Save failed", and a reload lost them all.

  `write/4` wraps the editor's one write (`Shared.do_autosave/3`):

  1. The whole post is tried first, as before. When it lands, nothing here
     does anything, and a field held earlier that was in it is released.
  2. Refused: the post is tried again without the fields held earlier (other
     than the one being changed now).
  3. Still refused, and the caller named the field being changed
     (`target/2`, or a post of one field): only that field is posted.
  4. Still refused: that field is held. Its value stays in the form buffer,
     and the reason is kept with it.

  A post from the explicit Save button is never cut down: it lands whole or
  says why not.

  Only the field being changed is ever blamed or posted alone. Every other
  posted value is what the browser showed, which can be older than what the
  store took from another editor (#25946 review).

  A held field is shown from the assigns, not stored in them twice:
  `marks/2` adds "Not saved: <reason>" under the field, `status/1` names the
  held fields in the save region, `token/1` is the save token the desk's
  tab-close guard reads, `keys/1` are the fields a remote save must not
  replace. A held field whose form value is no longer the refused one (a
  reload, another document, a new value) counts for nothing.

  With no field to name, `status/1` adds the reason to "Save failed".

  ## A refused clear is not held

  In the desk, a change that takes text away from the stored value is a
  clear: the field or a key in it unset (`Forms.unset/0`, or "" over a
  value), a language or a key left out, or emptied, also inside an array
  row. A refused clear is not held (task-48b10c6eb7ec20c5,
  task-8513709a4e52f781). Held, it was in the buffer, so the next post of
  another field wrote it, and undo then took back only that other field.

  The buffer keeps the stored value instead (a pick puts its form in the
  buffer before the write; that is set back), and `editor_refused_clears`
  keeps the field with the reason. While the buffer still holds that value:
  the field reads "Not saved: <reason>" and is named in the save region, as
  a held field is, and a later post of another field, the explicit Save
  too, leaves it out, as the page can still show it empty (the input had
  the focus when the refusal came back). A change of the field itself is a
  new try. A reload, or another document, drops it.
  """
  use Gettext, backend: BarkparkWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias Barkpark.Content
  alias Barkpark.Content.Forms
  alias BarkparkWeb.Studio.SaveStatus
  alias BarkparkWeb.Studio.StudioLive.PostedEdits
  alias BarkparkWeb.Studio.StudioLive.Shared

  @failed ["Save failed", "Save cancelled"]
  @reason_max 300

  @doc "Names the top-level fields the next `write/4` is a change of."
  def target(socket, keys) when is_list(keys), do: assign(socket, :editor_save_target, keys)

  @doc """
  Codelist fields whose post was not a code (`Forms.CodelistShape.split/2`)
  and was not written: the form buffer takes the stored value back, so the
  page draws what the store holds, and each field is held over it with the
  reason. So the field reads "Not saved: Not a code (kept as stored)" and the
  save region names it, until the buffer gets another value (a code typed or
  picked, a reload).
  """
  def not_codes(socket, []), do: socket

  def not_codes(socket, keys) when is_list(keys) do
    stored =
      socket.assigns[:editor_doc]
      |> Forms.doc_to_form(socket.assigns[:editor_schema])
      |> Map.take(keys)

    socket = PostedEdits.put(socket, Map.merge(Map.new(keys, &{&1, nil}), stored))
    form = socket.assigns[:editor_form] || %{}
    reason = gettext("Not a code (kept as stored)")
    doc_key = doc_key(socket.assigns)

    held =
      case socket.assigns[:editor_refused] do
        {^doc_key, held} -> held
        _ -> %{}
      end

    held = Enum.reduce(keys, held, &Map.put(&2, &1, {Map.get(form, &1), reason}))
    assign(socket, editor_refused: {doc_key, held})
  end

  @doc """
  The refusal branch of the write: the save token and the reason, as words.
  A changeset, a hook's own text or a known tag; never an inspected term.
  """
  def failed(socket, token, reason) do
    assign(socket,
      save_status: token,
      editor_save_error: reason_text(reason),
      editor_save_error_fields: by_field(reason)
    )
  end

  @doc """
  Runs `writer.(socket, params, trigger)`, and when the store refuses it,
  saves what can be saved and holds the field being changed (see the
  moduledoc).
  """
  def write(socket, params, trigger, writer) when is_map(params) and is_function(writer, 3) do
    keys = target_keys(socket, params)
    {socket, params} = drop_refused_clears(socket, params, keys)

    socket =
      assign(socket,
        editor_save_target: nil,
        # The field this write is a change of, for `PostedEdits`.
        editor_post_target: keys,
        editor_save_error: nil,
        editor_save_error_fields: nil
      )

    out = writer.(socket, params, trigger)

    cond do
      not failed?(out) -> release(out, params)
      trigger == :save -> out
      true -> fall_back(socket, out, params, trigger, keys, writer)
    end
  end

  def write(socket, params, trigger, writer), do: writer.(socket, params, trigger)

  # Each cut-down post is tried from the socket as it was before the refused
  # attempt, so a landed one carries no flash from the refusal.
  defp fall_back(socket, out, params, trigger, keys, writer) do
    held_keys = Map.keys(live(socket.assigns)) -- keys

    attempts =
      [Map.drop(params, held_keys), Map.take(params, keys)]
      |> Enum.reject(&(&1 == params or &1 == %{}))
      |> Enum.dedup()

    last =
      Enum.reduce_while(attempts, out, fn post, _last ->
        tried = writer.(socket, post, trigger)
        if failed?(tried), do: {:cont, tried}, else: {:halt, release(tried, post)}
      end)

    if failed?(last), do: hold(last, params, keys), else: last
  end

  defp target_keys(socket, params) do
    case socket.assigns[:editor_save_target] do
      [_ | _] = keys -> Enum.filter(keys, &Map.has_key?(params, &1))
      _ -> if map_size(params) == 1, do: Map.keys(params), else: []
    end
  end

  defp failed?(socket),
    do: socket.assigns[:save_status] in @failed and is_map(socket.assigns[:editor_doc])

  # A field in a post that landed is saved.
  defp release(socket, post) do
    case socket.assigns[:editor_refused] do
      {key, held} when held != %{} ->
        assign(socket, :editor_refused, {key, Map.drop(held, Map.keys(post))})

      _ ->
        socket
    end
  end

  # The refused value goes into the form buffer in the shape a landed save
  # leaves there (`Forms.coerce_params/2`), with the reason beside it.
  #
  # A refusal that names its fields (an enforcing dataset's schema check)
  # holds only a changed field it names, with that field's own words. When it
  # names another field (the stored document already breaks a rule), nothing
  # is held: the save region says which field, and the typed value stays in
  # the form (`Fields.keep_unsaved_values/3`).
  defp hold(socket, _params, []), do: socket

  defp hold(socket, params, keys) do
    named = socket.assigns[:editor_save_error_fields]
    reason = fn key -> (is_map(named) && named[key]) || socket.assigns[:editor_save_error] end
    stored = stored_form(socket.assigns)

    # A clear is never held, whichever field the refusal names.
    {clears, keys} =
      Enum.split_with(keys, &clear?(socket.assigns, Map.get(stored, &1), Map.get(params, &1)))

    socket = refuse_clears(socket, clears, stored, reason)
    keys = if is_map(named), do: Enum.filter(keys, &Map.has_key?(named, &1)), else: keys

    values =
      params
      |> Forms.coerce_params(socket.assigns[:editor_schema])
      |> Map.take(keys)
      |> Forms.unset_as_nil()

    doc_key = doc_key(socket.assigns)

    held =
      case socket.assigns[:editor_refused] do
        {^doc_key, held} -> held
        _ -> %{}
      end

    held = Enum.reduce(values, held, fn {k, v}, acc -> Map.put(acc, k, {v, reason.(k)}) end)

    socket
    |> assign(editor_refused: {doc_key, held})
    |> PostedEdits.put(values)
  end

  # The open document as the form draws it from the store.
  defp stored_form(assigns),
    do: Forms.doc_to_form(assigns[:editor_doc], assigns[:editor_schema])

  # A clear: the posted value takes text away from the stored one. Only in
  # the desk, the one host that unsets.
  defp clear?(%{desk_base: base}, stored, value) when is_binary(base),
    do: takes_away?(stored, value)

  defp clear?(_assigns, _stored, _value), do: false

  # `new` leaves blank, or leaves out, something `old` holds. An array is
  # compared row by row only while it keeps its length; a row's `_key` and
  # `_type` are not text.
  defp takes_away?(old, new) do
    cond do
      blank?(old) -> false
      blank?(new) -> true
      plain_map?(old) and plain_map?(new) -> Enum.any?(old, &key_taken?(&1, new))
      is_list(old) and is_list(new) and length(old) == length(new) -> zip_taken?(old, new)
      true -> false
    end
  end

  defp key_taken?({key, _old}, _new) when key in ["_key", "_type"], do: false
  defp key_taken?({key, old}, new), do: takes_away?(old, Map.get(new, key))

  defp zip_taken?(old, new),
    do: old |> Enum.zip(new) |> Enum.any?(fn {o, n} -> takes_away?(o, n) end)

  defp blank?(value) when value in [nil, "", []], do: true
  defp blank?(%Forms.Unset{}), do: true

  defp blank?(%{} = map) when not is_struct(map),
    do: Enum.all?(map, fn {key, value} -> key in ["_key", "_type"] or blank?(value) end)

  defp blank?(_value), do: false

  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  defp refuse_clears(socket, [], _stored, _reason), do: socket

  defp refuse_clears(socket, keys, stored, reason) do
    form = socket.assigns[:editor_form] || %{}

    back =
      for key <- keys, takes_away?(Map.get(stored, key), Map.get(form, key)), into: %{} do
        {key, Map.get(stored, key)}
      end

    socket = PostedEdits.put(socket, back)
    form = socket.assigns[:editor_form] || %{}
    refused = Map.new(keys, &{&1, {Map.get(form, &1), reason.(&1)}})

    assign(
      socket,
      :editor_refused_clears,
      {doc_key(socket.assigns), Map.merge(live_clears(socket.assigns), refused)}
    )
  end

  @doc "The top-level fields of the open document whose clear was refused."
  def clears(%{assigns: assigns}), do: assigns |> live_clears() |> Map.keys()

  # A post of another field leaves a refused clear out; a change of the field
  # itself is a new try, so it is posted and no longer left out.
  defp drop_refused_clears(socket, params, keys) do
    case live_clears(socket.assigns) do
      refused when refused == %{} ->
        {socket, params}

      refused ->
        socket =
          assign(
            socket,
            :editor_refused_clears,
            {doc_key(socket.assigns), Map.drop(refused, keys)}
          )

        {socket, Map.drop(params, Map.keys(refused) -- keys)}
    end
  end

  @doc "The held top-level fields of the open document."
  def keys(%{assigns: assigns}), do: keys(assigns)
  def keys(assigns), do: assigns |> live() |> Map.keys()

  @doc """
  The save token for the page: "Save failed" while a field is held, so the
  desk asks before the tab closes over it. Else the socket's own token.
  """
  def token(assigns) do
    if not_saved(assigns) == %{}, do: assigns[:save_status] || "", else: "Save failed"
  end

  @doc """
  The save region's words: the held fields by title, or the failed token
  with its reason. A conflict that named the fields another editor rewrote
  (`editor_clash_fields`, set by `Lifecycle.doc_updated/2`) says so in
  TanStack's words (barkpark-studio `edits.ts` `clash`,
  task-c0374ce0961cc1bf). Any other token is returned as it is.
  """
  def status(assigns) do
    token = assigns[:save_status] || ""
    held = not_saved(assigns)
    reason = assigns[:editor_save_error]
    clashed = clash_fields(assigns)

    cond do
      held != %{} ->
        titles = held |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &title(assigns, &1))
        gettext("Not saved") <> ": " <> titles

      token in @failed and is_binary(reason) ->
        SaveStatus.label(token) <> ": " <> reason

      token == "Updated by another user" and clashed != [] ->
        gettext(
          "Someone else rewrote %{fields} meanwhile. Your text is kept here, not saved: type on to save yours over theirs.",
          fields: Enum.map_join(clashed, ", ", &title(assigns, &1))
        )

      true ->
        token
    end
  end

  # The fields the last conflict found rewritten, in the schema's order;
  # only while that conflict stands.
  defp clash_fields(assigns) do
    case {assigns[:doc_conflict], assigns[:editor_clash_fields]} do
      {true, [_ | _] = keys} ->
        order = assigns |> schema_fields() |> Enum.map(&(is_map(&1) && &1["name"]))
        Enum.sort_by(keys, &(Enum.find_index(order, fn name -> name == &1 end) || length(order)))

      _ ->
        []
    end
  end

  defp schema_fields(assigns) do
    case assigns[:editor_schema] do
      %{fields: fields} when is_list(fields) -> fields
      _ -> []
    end
  end

  @doc "`errors` (the editor's findings tree) with each held field's reason."
  def marks(errors, assigns) do
    errors = if is_map(errors), do: errors, else: %{}

    Enum.reduce(not_saved(assigns), errors, fn {key, {_value, reason}}, acc ->
      mark =
        if is_binary(reason),
          do: gettext("Not saved") <> ": " <> reason,
          else: gettext("Not saved")

      Map.update(acc, key, [mark], fn
        list when is_list(list) -> [mark | list]
        %{} = tree -> Map.update(tree, :__self__, [mark], &[mark | List.wrap(&1)])
        _ -> [mark]
      end)
    end)
  end

  # Every field the page must call not saved: held, or a refused clear.
  defp not_saved(assigns), do: Map.merge(live_clears(assigns), live(assigns))

  # Held for the open document, and the form still holds the refused value.
  defp live(assigns), do: live(assigns, :editor_refused)

  # A refused clear of the open document, while the form still holds the
  # value it was refused over.
  defp live_clears(assigns), do: live(assigns, :editor_refused_clears)

  defp live(assigns, name) do
    form = assigns[:editor_form] || %{}

    with {key, held} when is_map(held) <- assigns[name],
         true <- key == doc_key(assigns) do
      Map.filter(held, fn {k, {value, _reason}} -> Map.fetch(form, k) == {:ok, value} end)
    else
      _ -> %{}
    end
  end

  defp doc_key(assigns) do
    case assigns[:editor_doc] do
      %{doc_id: id} when is_binary(id) -> {assigns[:editor_type], Content.published_id(id)}
      _ -> nil
    end
  end

  defp title(assigns, key) do
    fields =
      case assigns[:editor_schema] do
        %{fields: fields} when is_list(fields) -> fields
        _ -> []
      end

    case Enum.find(fields, &(is_map(&1) and &1["name"] == key)) do
      %{"title" => title} when is_binary(title) and title != "" -> title
      _ -> key
    end
  end

  defp reason_text(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&Shared.translate_changeset_error/1)
    |> Enum.sort_by(fn {field, _} -> to_string(field) end)
    |> Enum.map_join(" · ", fn {field, messages} ->
      "#{field}: #{messages |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.join("; ")}"
    end)
    |> clip()
  end

  defp reason_text({:schema_validation_failed, errors, _findings}),
    do: reason_text({:schema_validation_failed, errors})

  defp reason_text({:schema_validation_failed, errors}) when is_map(errors) do
    errors
    |> BarkparkWeb.StudioLocale.localize_findings()
    |> Enum.sort_by(fn {field, _} -> to_string(field) end)
    |> Enum.map_join(" · ", fn {field, messages} -> "#{field}: #{words(messages)}" end)
    |> clip()
  end

  defp reason_text({:rev_mismatch, _}),
    do: gettext("The document changed since you loaded it — reload and retry.")

  defp reason_text({:halted, reason}), do: reason_text(reason)
  defp reason_text(reason) when is_binary(reason), do: clip(reason)
  defp reason_text(reason) when is_atom(reason) and not is_nil(reason), do: tag(reason)
  defp reason_text({reason, _}) when is_atom(reason), do: tag(reason)
  defp reason_text(_reason), do: nil

  # The schema check's findings by top-level field (`seo.description` and
  # `links[1].title` belong to `seo` and `links`), each with its own words.
  # nil for a refusal that names no fields.
  defp by_field({:schema_validation_failed, errors, _findings}),
    do: by_field({:schema_validation_failed, errors})

  defp by_field({:schema_validation_failed, errors}) when is_map(errors) do
    errors
    |> BarkparkWeb.StudioLocale.localize_findings()
    |> Enum.group_by(fn {field, _} ->
      field |> to_string() |> String.split([".", "["]) |> hd()
    end)
    |> Map.new(fn {top, entries} ->
      text =
        Enum.map_join(entries, " · ", fn {field, messages} ->
          if to_string(field) == top, do: words(messages), else: "#{field}: #{words(messages)}"
        end)

      {top, clip(text)}
    end)
  end

  defp by_field(_reason), do: nil

  defp words(messages),
    do: messages |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.join("; ")

  defp tag(atom), do: atom |> Atom.to_string() |> String.replace("_", " ")

  defp clip(""), do: nil

  defp clip(text) do
    if String.length(text) > @reason_max,
      do: String.slice(text, 0, @reason_max) <> "…",
      else: text
  end
end
