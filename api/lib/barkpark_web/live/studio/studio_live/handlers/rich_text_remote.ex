defmodule BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote do
  @moduledoc """
  Another editor's save of a rich text field inside an object or an array
  row, put into this tab's open editor in place (task-47be2cdf59d0acd5).

  The editor sits in a `phx-update="ignore"` wrapper, so a re-render never
  changes its text. Remounting it with the new value (a new wrapper id) threw
  away what A had typed and not yet posted, the caret and an IME composition
  (#28349 review). TanStack's PortableTextInput never remounts a focused
  editor; it takes theirs in when the editor is free.

  So the server tells the page, and never remounts:

    * `push/3`, from `Lifecycle.doc_updated/2` and someone else's discard:
      each rich text inside an object or a row whose drawn value changed,
      compared with the keys set aside (`drawn/1`, so A's own post, which
      comes back with new keys, is no change), goes out on `bp:rt-remote`
      with a number and its HTML: the same `PortableText.to_html/1` the first
      paint draws. A value past `@html_cap` bytes goes in an event of its
      own. bp-rt-remote.js puts it into the editor through the editor's own
      first-paint path once A is idle: no input for 800 ms (so the last keys
      are posted) and no IME composition. A focused editor takes it too, and
      keeps its caret in a block whose text did not change.
    * `repaint/2`, from Reload and a restore (presses of A's own): every one
      is sent its stored value, shown at once.
    * The page reports, per editor, the number of the last value it shows
      (`_bp_rt_seen[]`, `name|number`). `split/3` reads a post or a Save: a
      rich text whose number is older than a change the server logged for
      it was written over theirs. Unchanged from what the page was shown,
      theirs stands; changed, nothing is written over theirs: `hold/2` keeps
      A's text in the form with the conflict banner, and acknowledges it
      (`own: true`). Both changed it and A sees the banner: A's next post
      saves A's over theirs ("type on to save yours over theirs"), as
      TanStack's clash line says.

  A post with no `_bp_rt_seen` (a page loaded before this, or a change the
  server built) is read as before. Top-level rich text keeps its own path
  (task-8d20a831ddd287a2).
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Barkpark.Content.PortableText
  alias BarkparkWeb.Studio.StudioLive.Path

  @event "bp:rt-remote"

  # #28256's size: a value past it goes to the page in an event of its own.
  @html_cap 20_000

  # Changes kept per input name. A post reporting a number older than all of
  # them is read against the oldest one's `was`.
  @log_cap 8

  @doc """
  Tells the page of each rich text inside an object or a row that another
  editor's save changed between `old_form` and `new_form`, and logs it.
  """
  def push(socket, old_form, new_form) do
    changed = changes(socket.assigns[:editor_schema], old_form || %{}, new_form || %{})
    tell(socket, changed, %{})
  end

  @doc """
  After the form is read again from the store on a press of this tab's own
  (Reload, a restore): every rich text inside an object or a row is sent its
  stored value with a new number, to show at once (`reload: true`), whatever
  the editor holds. The press drops the held words, so the editor must not
  keep showing them: its next post would write them over theirs with no
  banner (#28349 r2 review, SV2). Each one that changed from `old_form` is
  logged as a change, so a post from an editor that never showed it is held
  as any other.
  """
  def repaint(socket, old_form) do
    schema = socket.assigns[:editor_schema]
    form = socket.assigns[:editor_form] || %{}
    was = Map.new(changes(schema, old_form || %{}, form), fn {path, was, _} -> {path, was} end)

    all =
      for {path, _, now} <- paths(schema, form, form, :all),
          do: {path, Map.get(was, path, :unchanged), now}

    tell(socket, all, %{reload: true})
  end

  defp tell(socket, [], _flags), do: socket

  defp tell(socket, entries, flags) do
    {socket, values} =
      Enum.reduce(entries, {socket, %{}}, fn {path, was, now}, {s, values} ->
        {s, seq} = next_seq(s)
        name = input_name(path)
        s = if was == :unchanged, do: s, else: log(s, name, {seq, was, now})
        {s, Map.put(values, name, Map.merge(%{seq: seq, html: html(now)}, flags))}
      end)

    send_values(socket, values)
  end

  defp log(socket, name, entry) do
    log = socket.assigns[:editor_rt_log] || %{}
    entries = Enum.take([entry | Map.get(log, name, [])], @log_cap)
    assign(socket, editor_rt_log: Map.put(log, name, entries))
  end

  # One event for the values up to `@html_cap` bytes; each larger one rides
  # an event of its own, so one long text never holds up the others' event
  # and the page takes it the same way.
  defp send_values(socket, values) do
    {big, small} = Enum.split_with(values, fn {_name, v} -> byte_size(v.html) > @html_cap end)

    socket =
      if small == [], do: socket, else: push_event(socket, @event, %{values: Map.new(small)})

    Enum.reduce(big, socket, fn {name, v}, s -> push_event(s, @event, %{values: %{name => v}}) end)
  end

  @doc """
  Reads the post `doc` against the numbers the page reported (`seen`, the
  raw `_bp_rt_seen`). Returns `{doc, held}`: each rich text written over a
  later change of theirs takes theirs in `doc`, and `held` lists those A had
  changed, `{name, path, posted_html}`, for `hold/2`.
  """
  def split(socket, doc, seen) when is_list(seen) and is_map(doc) do
    log = socket.assigns[:editor_rt_log] || %{}
    form = socket.assigns[:editor_form] || %{}

    Enum.reduce(seen, {doc, []}, fn entry, {doc, held} ->
      with {name, n} <- parse_seen(entry),
           [_ | _] = later <- Enum.filter(Map.get(log, name, []), fn {s, _, _} -> s > n end),
           path when path != [] <- Path.parse_path(name),
           posted when is_binary(posted) <- get(doc, path) do
        {_seq, was, _now} = List.last(later)
        theirs = get(form, path)
        doc = put(doc, path, html(theirs))

        if drawn(PortableText.from_html(posted, list(was))) == drawn(was),
          do: {doc, held},
          else: {doc, [{name, path, posted} | held]}
      else
        _ -> {doc, held}
      end
    end)
  end

  def split(_socket, doc, _seen), do: {doc, []}

  @doc """
  After the save: each held rich text is A's again in the form, unsaved,
  with the conflict banner, and the page is told its text is the base of
  its next post.
  """
  def hold(socket, []), do: socket

  def hold(socket, held) do
    form = socket.assigns[:editor_form] || %{}
    keys = held |> Enum.map(fn {_name, [key | _], _posted} -> key end) |> Enum.uniq()

    form =
      Enum.reduce(held, form, fn {_name, path, posted}, form ->
        put(form, path, PortableText.from_html(posted, list(get(form, path))))
      end)

    {socket, values} =
      Enum.reduce(held, {socket, %{}}, fn {name, _path, posted}, {s, values} ->
        {s, seq} = next_seq(s)
        {s, Map.put(values, name, %{seq: seq, html: posted, own: true})}
      end)

    socket
    |> assign(
      editor_form: form,
      editor_dirty: true,
      editor_unsaved_keys:
        MapSet.union(socket.assigns[:editor_unsaved_keys] || MapSet.new(), MapSet.new(keys)),
      doc_conflict: true,
      save_status: "Updated by another user",
      editor_clash_fields: Enum.uniq((socket.assigns[:editor_clash_fields] || []) ++ keys)
    )
    |> send_values(values)
  end

  @doc """
  What the editor draws, with every `_key` set by position: two values that
  differ only in keys (A's post, rebuilt with new keys) draw the same.
  """
  def drawn(value) do
    if PortableText.value?(value), do: value |> canon() |> PortableText.to_html(), else: ""
  end

  @doc "Each rich text path inside an object or a row whose drawn value changed."
  def changes(schema, old_form, new_form), do: paths(schema, old_form, new_form, :changed)

  # Every rich text path inside an object or a row (`:all`), or each one whose
  # drawn value differs between the two forms (`:changed`).
  defp paths(%{fields: fields}, old_form, new_form, mode) when is_list(fields) do
    Enum.flat_map(fields, fn
      %{"name" => key} = field when is_binary(key) ->
        walk(field, [key], Map.get(old_form, key), Map.get(new_form, key), {false, mode})

      _ ->
        []
    end)
  end

  defp paths(_schema, _old, _new, _mode), do: []

  # `inside?`: a top-level rich text is not this module's.
  defp walk(%{"type" => "richText"}, path, old, new, {true, mode}) do
    if drawable?(old) and drawable?(new) and (mode == :all or drawn(old) != drawn(new)),
      do: [{path, old, new}],
      else: []
  end

  defp walk(%{"type" => "arrayOf", "of" => of}, path, old, new, {_inside?, mode})
       when is_list(of) and is_list(new) do
    old = if is_list(old), do: old, else: []

    new
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, i} ->
      was = Enum.at(old, i)

      with %{} <- row,
           %{} <- was,
           true <- Map.get(row, "_key") == Map.get(was, "_key"),
           %{"fields" => [_ | _] = fields} <- member(of, row) do
        fields(fields, path ++ [i], was, row, mode)
      else
        _ -> []
      end
    end)
  end

  defp walk(%{"fields" => [_ | _] = fields}, path, old, new, {_inside?, mode})
       when is_map(old) and is_map(new),
       do: fields(fields, path, old, new, mode)

  defp walk(_field, _path, _old, _new, _inside?), do: []

  defp fields(fields, path, old, new, mode) do
    Enum.flat_map(fields, fn
      %{"name" => sub} = field when is_binary(sub) ->
        walk(field, path ++ [sub], Map.get(old, sub), Map.get(new, sub), {true, mode})

      _ ->
        []
    end)
  end

  defp member(of, row) do
    type = Map.get(row, "_type")
    Enum.find(of, &(is_map(&1) and (&1["name"] == type or (is_nil(type) and length(of) == 1))))
  end

  defp drawable?(value), do: value in [nil, "", []] or PortableText.value?(value)

  # Keys by position: block `b0`, its spans `b0s0` and defs `b0m0`, each
  # mark that names a def renamed with it.
  defp canon(blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.map(fn {block, i} -> canon_block(block, "b#{i}") end)
  end

  defp canon_block(%{} = block, k) do
    defs = if is_list(block["markDefs"]), do: block["markDefs"], else: []

    renamed =
      defs
      |> Enum.with_index()
      |> Map.new(fn {d, j} -> {is_map(d) && d["_key"], "#{k}m#{j}"} end)

    block
    |> rekey(k)
    |> then(fn b ->
      if is_list(b["markDefs"]),
        do:
          Map.put(b, "markDefs", Enum.map(defs, &(is_map(&1) && rekey(&1, renamed[&1["_key"]])))),
        else: b
    end)
    |> then(fn b ->
      if is_list(b["children"]) do
        children =
          b["children"]
          |> Enum.with_index()
          |> Enum.map(fn {child, j} -> canon_child(child, "#{k}s#{j}", renamed) end)

        Map.put(b, "children", children)
      else
        b
      end
    end)
  end

  defp canon_block(block, _k), do: block

  defp canon_child(%{} = child, k, renamed) do
    child = rekey(child, k)

    if is_list(child["marks"]),
      do: Map.put(child, "marks", Enum.map(child["marks"], &Map.get(renamed, &1, &1))),
      else: child
  end

  defp canon_child(child, _k, _renamed), do: child

  defp rekey(%{"_key" => _} = map, k), do: Map.put(map, "_key", k)
  defp rekey(map, _k), do: map

  defp html(value) do
    if PortableText.value?(value), do: PortableText.to_html(value), else: ""
  end

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  # From the clock, as `RemoteValues` numbers its values: a page that rejoins
  # a new socket and still holds the old socket's numbers reads every change
  # this socket logs as later than what it shows.
  defp next_seq(socket) do
    seq = max((socket.assigns[:editor_rt_seq] || 0) + 1, System.os_time(:microsecond))
    {assign(socket, editor_rt_seq: seq), seq}
  end

  # `name|number`, split at the last `|`.
  defp parse_seen(entry) when is_binary(entry) do
    parts = String.split(entry, "|")
    name = parts |> Enum.drop(-1) |> Enum.join("|")

    case Integer.parse(List.last(parts)) do
      {n, ""} when name != "" -> {name, n}
      _ -> nil
    end
  end

  defp parse_seen(_entry), do: nil

  @doc "The input name the composite draws for `path` (`CompositeField`, `ArrayField`)."
  def input_name([key | rest]) do
    Enum.reduce(rest, "doc[#{key}]", fn
      i, acc when is_integer(i) -> acc <> "[#{i}]"
      sub, acc -> acc <> "." <> sub
    end)
  end

  # A post's rows can come as a list or as a map keyed "0", "1", ….
  defp get(value, []), do: value
  defp get(list, [i | rest]) when is_list(list) and is_integer(i), do: get(Enum.at(list, i), rest)

  defp get(%{} = map, [seg | rest]) when not is_struct(map) do
    case Map.fetch(map, seg) do
      {:ok, v} -> get(v, rest)
      :error -> if is_integer(seg), do: get(Map.get(map, Integer.to_string(seg)), rest)
    end
  end

  defp get(_value, _path), do: nil

  defp put(_value, [], new), do: new

  defp put(list, [i | rest], new) when is_list(list) and is_integer(i) and i < length(list),
    do: List.update_at(list, i, &put(&1, rest, new))

  defp put(%{} = map, [seg | rest], new) when not is_struct(map) do
    key =
      if is_integer(seg) and not Map.has_key?(map, seg) and
           Map.has_key?(map, Integer.to_string(seg)),
         do: Integer.to_string(seg),
         else: seg

    if Map.has_key?(map, key), do: Map.put(map, key, put(Map.get(map, key), rest, new)), else: map
  end

  defp put(value, _path, _new), do: value
end
