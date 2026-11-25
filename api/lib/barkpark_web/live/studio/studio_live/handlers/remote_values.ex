defmodule BarkparkWeb.Studio.StudioLive.Handlers.RemoteValues do
  @moduledoc """
  Another editor's save, told to the field this tab is resting in
  (task-e6ef964ac2e41d5a), and the base this tab's next post of a free-text
  field was written from (task-35956a566dd2c862).

  A LiveView patch never sets the value of the focused input. So when another
  editor saved the field this tab had focused, the tab kept showing the old
  text, and its next keystroke posted that text back over the other's words.

  `push/3` sends the page each changed text field: its new value and the value
  the page showed before (`bp:form-remote-values`). bp-array-focus.js sets the
  focused input only while it still shows exactly the old value: anything else
  is typing the page has not sent yet, and stays. It writes nothing.

  ## The base of a post

  When the page could not take the new value (the person was typing), its
  next post is written from an older value than the store holds. For a
  free-text field (`free_text?/2`) the server keeps what it told the page,
  each value with a sequence number (`editor_remote_history`), and the push
  carries the numbers (`seqs`: `[seq of was, seq of value]`). The page reports
  in the hidden `_bp_seen` input, per field, the number of the last value it
  showed: the new one when the field shows it after the event, else the old
  one. `bases/3` maps that number back to the value the server sent, so a
  forged number can only pick a value the server already sent to this tab.

  The page's own landed post (`:own`) is its base until it shows a later
  value: it is what the field shows after the save. Every older entry is
  dropped then, so an older remote value can never be picked again.

  Any other path that loads the form from the store (Reload, an explicit
  save, navigation: `Shared.rebuild_panes/1`) sends the page no numbers, so
  it drops the history (#25994 review): the page's last number then maps to
  nothing. Only a rebuild that then pushes keeps it (`keep_history/2`). The
  numbers start from the clock at the first one, so a page that rejoins a new
  socket and still reports the old socket's numbers matches nothing either.

  A post that names no number for a field (task-f18af43e26e46ff4) left the
  page before the first push it would have numbered: two people's posts
  cross, and the second to land was sent before the first's push arrived.
  It was typed from what the page showed before any push it has not taken:
  its own landed post, or the value the first push says it showed
  (`:origin`), which is what the page reports for it once that push
  arrives. Once the kept history has dropped that entry, nothing tells, and
  the post stands. That reading needs a page that numbers every value it
  shows, an undrawn field included: bp-array-focus.js says so with `v` in
  `_bp_seen` (`@seen_version`), written by the page, never drawn by the
  server. A tab still running an older copy of that file (loaded before a
  deploy) sends no `v`: its posts with no number stand, and the numbers the
  server drew into its form (`seen_value/1`) are not read, as before. Only
  the numbers that copy wrote itself count. A change the server built
  itself (no `_bp_seen` at all) is never merged. Nor is any field that is
  not free text: a date or a select is a choice, not text two people type
  into.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Barkpark.Content

  @event "bp:form-remote-values"
  @born_event "bp:form-born"

  # The `v` bp-array-focus.js writes into `_bp_seen` (its SEEN_VERSION).
  @seen_version 2

  # The `_bp_seen` key the server draws its numbers under (`seen_value/1`).
  @drawn_key "drawn"

  # Entries kept per field. A page that reports a number older than these is
  # not merged.
  @cap 16

  @doc """
  Tells the page of each top-level text field that differs between `old_form`
  and `new_form`, with the value it showed before. A free-text field is
  remembered, and its numbers ride along in `seqs`.

  `bases` gives, per field, what to remember under those numbers when it is
  not the shown value: `{base of was, base of value}`. A field with unsaved
  words of this tab's own shows them (`was`), but its next post is made on
  the stored value they were typed on, and a merged value on the stored one
  it was merged onto (TanStack's edit-bases.ts: a base never holds this
  editor's unsaved words, or the next version reads them as removed).
  """
  def push(socket, old_form, new_form, bases \\ %{}) do
    changed = changes(socket.assigns[:editor_schema], old_form, new_form, [])

    if changed == [] do
      socket
    else
      {socket, values, seqs} =
        Enum.reduce(changed, {socket, %{}, %{}}, fn {key, old, new}, {s, values, seqs} ->
          name = input_name(key)
          values = Map.put(values, name, %{value: new, was: old})

          if free_text_at?(s.assigns[:editor_schema], key) do
            {was_base, base} = Map.get(bases, key, {old, new})
            {s, pair} = remember(s, key, was_base, base)
            {s, values, Map.put(seqs, name, pair)}
          else
            {s, values, seqs}
          end
        end)

      payload = if seqs == %{}, do: %{values: values}, else: %{values: values, seqs: seqs}
      push_event(socket, @event, payload)
    end
  end

  @doc """
  Stores, for the post about to be saved, the base of each free-text field in
  `keys` that the page reported a number for (`seen`, the raw `_bp_seen`
  value). `Forms.upsert_draft/6` merges the post onto the stored value from
  it (`Barkpark.Content.TextRebase.rebase/3`).
  """
  def put_bases(socket, keys, seen, path \\ nil)

  def put_bases(socket, keys, seen, path) when is_binary(seen) do
    seen = decode_seen(seen)
    history = history(socket)
    schema = socket.assigns[:editor_schema]
    crossing? = Map.get(seen, "v") == @seen_version
    # The numbers the server drew into the form (`seen_value/1`) count only
    # for a page that keeps them current: an older copy of the JS posts them
    # back unchanged after it skipped a push for an undrawn field.
    drawn = if crossing?, do: drawn_numbers(seen), else: %{}

    bases =
      for key <- units(keys, text_path(schema, keys, path)),
          free_text_at?(schema, key),
          name <- [input_name(key)],
          # A generator, not `n = ...`: a nil filter would drop the field.
          n <- [Map.get(seen, name) || Map.get(drawn, name)],
          is_integer(n) or (is_nil(n) and crossing?),
          {_seq, value, _kind} <- List.wrap(base_entry(Map.get(history, key, []), n)),
          into: %{},
          do: {key, value}

    assign(socket, :editor_field_bases, bases)
  end

  def put_bases(socket, _keys, _seen, _path), do: assign(socket, :editor_field_bases, %{})

  @doc """
  Whether a post with `seen` (the raw `_bp_seen`) names no number for `key`
  from a page that numbers every value it shows, while the server never sent
  it one: the page shows the value the form was drawn with
  (`Handlers.UnsavedBases`).
  """
  def unnumbered?(socket, key, seen) when is_binary(seen) do
    seen = decode_seen(seen)
    name = input_name(key)

    Map.get(seen, "v") == @seen_version and is_nil(Map.get(seen, name)) and
      is_nil(Map.get(drawn_numbers(seen), name)) and Map.get(history(socket), key, []) == []
  end

  def unnumbered?(_socket, _key, _seen), do: false

  @doc """
  Adds the bases of a change the server built (`Fields.autosave_built/2`)
  to those `put_bases/3` stored: the value each field was computed from.
  """
  def add_bases(socket, bases) when is_map(bases) and map_size(bases) > 0,
    do:
      assign(
        socket,
        :editor_field_bases,
        Map.merge(socket.assigns[:editor_field_bases] || %{}, bases)
      )

  def add_bases(socket, _bases), do: socket

  @doc """
  The save's options from the socket: each free-text field's base
  (`:field_bases`), the value a field must still hold for the write to
  land (`:field_expect`, set by `Desk.DocUndo` from the value it read), and
  the fields whose value the write lands over the saved document reports
  (`:saved_over`, set by `Desk.DocUndo` for the step it keeps), and each
  rich text's value the socket believed stored (`:rich_text_seen`,
  `RichTextRemote.UnderLock`).
  """
  def write_opts(socket) do
    rich =
      BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.UnderLock.write_opts(
        socket.assigns[:editor_rt_under_lock] || %{}
      )

    text =
      BarkparkWeb.Studio.StudioLive.Handlers.TextUnderLock.write_opts(
        socket.assigns[:editor_text_under_lock] || %{}
      )

    [
      field_bases: socket.assigns[:editor_field_bases] || %{},
      field_expect: socket.assigns[:editor_field_expect] || %{},
      saved_over:
        Enum.uniq(
          (socket.assigns[:editor_saved_over] || []) ++
            (rich[:saved_over] || []) ++ (text[:saved_over] || [])
        ),
      rich_text_seen: rich[:rich_text_seen] || %{},
      text_seen: text[:text_seen] || %{}
    ]
  end

  @doc """
  Once per socket, when it first shows a document and is connected
  (task-4fc7383b936f606a): every free-text field is sent its stored value
  under a number of its own (`:born`), as `RichTextRemote.born/1` sends
  rich text. A page that rejoins a new socket keeps its `_bp_seen`, the old
  socket's numbers, which this socket never sent. A field showing the
  stored value takes the number; one typed on while the page was away
  keeps its old number, or none (`born_untaken?/3`).
  """
  def born(socket) do
    if socket.assigns[:editor_text_born] || not Phoenix.LiveView.connected?(socket) ||
         is_nil(doc_key(socket)) do
      socket
    else
      form = socket.assigns[:editor_form] || %{}

      {socket, values, seqs} =
        socket.assigns[:editor_schema]
        |> born_units(form)
        |> Enum.reduce({socket, %{}, %{}}, fn {key, value}, {s, values, seqs} ->
          {s, seq} = next_seq(s)
          name = input_name(key)
          s = put_entries(s, key, Map.get(history(s), key, []) ++ [{seq, value, :born}])
          {s, Map.put(values, name, value), Map.put(seqs, name, seq)}
        end)

      # Its own event: a field showing the value takes the number; one that
      # does not, and has none, reports 0, which this socket never sends
      # (bp-array-focus.js).
      socket = assign(socket, :editor_text_born, true)

      if values == %{},
        do: socket,
        else: push_event(socket, @born_event, %{values: values, seqs: seqs})
    end
  end

  @doc """
  Whether `key` holds a value this socket sent at birth (`born/1`) that the
  post (`seen`, the raw `_bp_seen`, from a page that numbers its values)
  does not report: the page had not taken it, so its post was typed on
  what the page showed before the rejoin, which this socket never saw. The
  page then reports a number this socket did not send (the old socket's,
  or 0). A post with no number took no push: it shows the born value.
  """
  def born_untaken?(socket, key, seen) when is_binary(seen) do
    seen = decode_seen(seen)
    name = input_name(key)
    n = Map.get(seen, name) || Map.get(drawn_numbers(seen), name)
    entries = Map.get(history(socket), key, [])

    Map.get(seen, "v") == @seen_version and is_integer(n) and
      Enum.any?(entries, &match?({_, _, :born}, &1)) and is_nil(base_entry(entries, n))
  end

  def born_untaken?(_socket, _key, _seen), do: false

  # Each free-text value of the form, by key or path into a `composite`.
  defp born_units(schema, form, at \\ []) do
    Enum.flat_map(form, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if free_text_at?(schema, key), do: [{unit(at, key), value}], else: []

      {key, %{} = inner} when is_binary(key) and not is_struct(inner) ->
        case field(schema, key) do
          %{"type" => "composite", "fields" => subs} when is_list(subs) ->
            born_units(%{fields: subs}, inner, at ++ [key])

          _ ->
            []
        end

      _ ->
        []
    end)
  end

  @doc "Whether the raw `_bp_seen` is from a page that numbers every value it shows."
  def crossing?(seen) when is_binary(seen), do: Map.get(decode_seen(seen), "v") == @seen_version
  def crossing?(_seen), do: false

  @doc false
  # The entry a post reporting number `n` was written from: the latest of the
  # values the page showed up to `n` and the page's own landed post. With no
  # number, the page took no push yet: its own post, the first push's `was`,
  # or the value this socket was born with (`born/1`), which the page shows.
  def base_entry(entries, nil) do
    entries
    |> Enum.filter(fn {_seq, _value, kind} -> kind in [:own, :origin, :born] end)
    |> latest()
  end

  def base_entry(entries, n) do
    entries
    |> Enum.filter(fn {seq, _value, kind} -> kind == :own or seq <= n end)
    |> latest()
  end

  @doc """
  After a post of `keys` (`posted` is the posted `doc` map): when it landed,
  each free-text field's posted text is the page's base from now on. When the
  store took a merged text instead, the page is told (`push/3`) and the form
  holds the stored text. Always clears the bases `put_bases/3` stored.
  """
  def settle(socket, before, keys, posted, path \\ nil) do
    socket = assign(socket, :editor_field_bases, %{})
    doc = socket.assigns[:editor_doc]

    if socket.assigns[:save_status] == "Saved" and is_map(doc) and
         doc != before.assigns[:editor_doc] do
      schema = socket.assigns[:editor_schema]

      # A field held over a store that moved under the post
      # (`TextUnderLock`) keeps A's words and is told nothing.
      held = socket.assigns[:editor_text_held] || []

      sent =
        for key <- units(keys, text_path(schema, keys, path)),
            key not in held,
            free_text_at?(schema, key),
            value = value_at(posted, key),
            is_binary(value),
            into: %{},
            do: {key, value}

      socket = Enum.reduce(sent, socket, fn {key, value}, s -> remember_own(s, key, value) end)
      stored = Map.new(sent, fn {key, _} -> {key, stored_value(doc, key)} end)

      moved =
        for {key, value} <- stored,
            is_binary(value),
            value != sent[key],
            into: %{},
            do: {key, value}

      if moved == %{} do
        socket
      else
        socket
        |> push(nest(sent), nest(moved))
        |> assign(
          :editor_form,
          Enum.reduce(moved, socket.assigns[:editor_form] || %{}, &put_at/2)
        )
      end
    else
      socket
    end
  end

  @doc """
  The `_bp_seen` a form starts from when it is drawn (task-f18af43e26e46ff4):
  per free-text field, the number of the latest value the server holds for
  it, which is what a form drawn now shows. A form that was not on the page
  when a push came (a document view was open in its place) started from
  "{}", and its next post was merged from an older value than the one the
  person saw. The input is `phx-update="ignore"`: a form already on the page
  keeps the numbers bp-array-focus.js wrote.

  The numbers sit under their own key (`"drawn"`), read only beside `v`: an
  older copy of the JS keeps the key but never updates it, so after it skips
  a push for a field it does not draw, the drawn number is stale (#26988
  review, round 3). A number the page wrote under the field's own name wins.
  """
  def seen_value(assigns) do
    assigns
    |> history()
    |> Enum.flat_map(fn {key, entries} ->
      case latest(entries) do
        {seq, _value, _kind} -> [{input_name(key), seq}]
        nil -> []
      end
    end)
    |> Map.new()
    |> case do
      drawn when drawn == %{} -> "{}"
      drawn -> Jason.encode!(%{@drawn_key => drawn})
    end
  end

  @doc """
  Keeps `before`'s history on `socket`, which `Shared.rebuild_panes/1` built
  from it: for a rebuild that tells the page what changed with `push/3`.
  """
  def keep_history(socket, before),
    do: assign(socket, :editor_remote_history, before.assigns[:editor_remote_history])

  @doc """
  A field two people type text into: `title` (unless the schema declares it
  otherwise), a `text` field, or a `string` field without `options.list`.
  """
  def free_text?(schema, key) do
    case field(schema, key) do
      nil -> key == "title"
      %{"type" => "text"} -> true
      %{"type" => "string"} = f -> not is_list(get_in(f, ["options", "list"]))
      _ -> false
    end
  end

  @doc """
  `free_text?/2` for a field key, or for a path into an object
  (task-71ff11d4e7374985): `["meta", "label"]` is free text when `meta` is a
  `composite` field and `label` one of its subfields that is free text.
  TanStack merges every pending path as text (edit-bases.ts `rebase`).
  """
  def free_text_at?(schema, key) when is_binary(key), do: free_text?(schema, key)
  def free_text_at?(schema, [key]) when is_binary(key), do: free_text?(schema, key)

  def free_text_at?(schema, [key | rest]) when is_binary(key) do
    case field(schema, key) do
      %{"type" => "composite", "fields" => subs} when is_list(subs) ->
        match?([_ | _], rest) and sub_text?(%{fields: subs}, rest)

      _ ->
        false
    end
  end

  def free_text_at?(_schema, _key), do: false

  # A subfield is free text only when the object declares it.
  defp sub_text?(schema, [sub]) when is_binary(sub),
    do: field(schema, sub) != nil and free_text?(schema, sub)

  defp sub_text?(schema, path), do: free_text_at?(schema, path)

  @doc """
  The text subfield a post is a change of (`path`, `Fields.target_path/2`),
  when it sits inside an object field the post names (`keys`); else nil. A
  top-level field is its key, as before.
  """
  def text_path(schema, [key], [key, _ | _] = path) do
    if free_text_at?(schema, path), do: path
  end

  def text_path(_schema, _keys, _path), do: nil

  @doc """
  Each free-text value of a posted form, by its key or, inside a
  `composite` object, its path: what an explicit Save posts at once
  (task-998551f010da1d5e).
  """
  def text_units(schema, form, at \\ []) when is_map(form) do
    Enum.flat_map(form, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if free_text_at?(schema, key), do: [unit(at, key)], else: []

      {key, %{} = inner} when is_binary(key) and not is_struct(inner) ->
        case field(schema, key) do
          %{"type" => "composite", "fields" => subs} when is_list(subs) ->
            text_units(%{fields: subs}, inner, at ++ [key])

          _ ->
            []
        end

      _ ->
        []
    end)
  end

  @doc "The post's field keys, and the text subfield path it changed (or nil)."
  def units(keys, nil), do: keys
  def units(keys, path), do: keys ++ [path]

  @doc "The input a field key, or a path into an object, is drawn as."
  def input_name(key) when is_binary(key), do: "doc[#{key}]"
  def input_name([key | rest]), do: Enum.join(["doc[#{key}]" | rest], ".")

  @doc "The value at a field key, or at a path into an object, of a form map."
  def value_at(map, key) when is_binary(key) and is_map(map), do: Map.get(map, key)
  def value_at(map, [key]) when is_map(map), do: Map.get(map, key)

  def value_at(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      %{} = inner when not is_struct(inner) -> value_at(inner, rest)
      _ -> nil
    end
  end

  def value_at(_map, _key), do: nil

  @doc "`map` with `value` at a field key, or at a path into an object."
  def put_at({key, value}, map), do: put_at(map, key, value)

  def put_at(map, key, value) when is_binary(key), do: Map.put(map, key, value)
  def put_at(map, [key], value), do: Map.put(map, key, value)

  def put_at(map, [key | rest], value) do
    inner =
      case Map.get(map, key) do
        %{} = inner when not is_struct(inner) -> inner
        _ -> %{}
      end

    Map.put(map, key, put_at(inner, rest, value))
  end

  # Each text value that differs between two forms, with its key: a
  # top-level field by its key, a subfield of a `composite` object by its
  # path (task-71ff11d4e7374985), so the page is told the subfield it rests
  # in too.
  defp changes(schema, old_form, new_form, at) do
    Enum.flat_map(new_form, fn
      {key, new} when is_binary(key) and is_binary(new) ->
        case Map.get(old_form, key) do
          old when is_binary(old) and old != new -> [{unit(at, key), old, new}]
          _ -> []
        end

      {key, %{} = new} when is_binary(key) and not is_struct(new) ->
        with %{"type" => "composite", "fields" => subs} when is_list(subs) <- field(schema, key),
             %{} = old when not is_struct(old) <- Map.get(old_form, key) do
          changes(%{fields: subs}, old, new, at ++ [key])
        else
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp unit([], key), do: key
  defp unit(at, key), do: at ++ [key]

  defp nest(values), do: Enum.reduce(values, %{}, &put_at/2)

  defp field(%{fields: fields}, key) when is_list(fields),
    do: Enum.find(fields, &(is_map(&1) and &1["name"] == key))

  defp field(_schema, _key), do: nil

  defp stored_value(doc, "title"), do: Map.get(doc, :title)
  defp stored_value(doc, key), do: value_at(Map.get(doc, :content) || %{}, key)

  # Records `old` (unless it is the field's latest value) and `new`, each with
  # a fresh number; returns `[seq of old, seq of new]`.
  defp remember(socket, key, old, new) do
    entries = Map.get(history(socket), key, [])

    {socket, entries, was_seq} =
      case latest(entries) do
        {seq, ^old, _kind} ->
          {socket, entries, seq}

        # The first value the server says this page showed.
        nil ->
          {socket, seq} = next_seq(socket)
          {socket, [{seq, old, :origin}], seq}

        _ ->
          {socket, seq} = next_seq(socket)
          {socket, entries ++ [{seq, old, :push}], seq}
      end

    {socket, seq} = next_seq(socket)
    {put_entries(socket, key, entries ++ [{seq, new, :push}]), [was_seq, seq]}
  end

  defp remember_own(socket, key, value) do
    {socket, seq} = next_seq(socket)
    put_entries(socket, key, [{seq, value, :own}])
  end

  defp latest([]), do: nil
  defp latest(entries), do: Enum.max_by(entries, fn {seq, _, _} -> seq end)

  defp next_seq(socket) do
    seq = (socket.assigns[:editor_remote_seq] || System.os_time(:microsecond)) + 1
    {assign(socket, :editor_remote_seq, seq), seq}
  end

  # The history belongs to one document; another document's is empty.
  defp history(%{assigns: assigns}), do: history(assigns)

  defp history(assigns) do
    case assigns[:editor_remote_history] do
      {key, history} -> if key == doc_key(assigns), do: history, else: %{}
      _ -> %{}
    end
  end

  defp put_entries(socket, key, entries) do
    history = Map.put(history(socket), key, Enum.take(entries, -@cap))
    assign(socket, :editor_remote_history, {doc_key(socket), history})
  end

  defp doc_key(%{assigns: assigns}), do: doc_key(assigns)

  defp doc_key(assigns) do
    case assigns[:editor_doc] do
      %{doc_id: id} when is_binary(id) -> {assigns[:editor_type], Content.published_id(id)}
      _ -> nil
    end
  end

  defp decode_seen(seen) when is_binary(seen) do
    case Jason.decode(seen) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_seen(_seen), do: %{}

  defp drawn_numbers(seen) do
    case Map.get(seen, @drawn_key) do
      drawn when is_map(drawn) -> drawn
      _ -> %{}
    end
  end
end
