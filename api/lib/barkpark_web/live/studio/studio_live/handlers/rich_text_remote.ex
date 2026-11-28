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
      each rich text inside an object or a row whose drawn value changed
      (keys set aside, `drawn/1`) goes out on `bp:rt-remote` with a number
      and its HTML, as the first paint draws it; one past `@html_cap` bytes
      in an event of its own. bp-rt-remote.js puts it into the editor once
      A is idle (800 ms without input, no IME composition), keeping the
      caret in a block whose text did not change.
    * `repaint/2`, from Reload and a restore: every one is sent its stored
      value, shown at once, and every hold ends.
    * The page reports, per editor, the number of the last value it shows
      (`_bp_rt_seen[]`, `name|number`; while values wait, one less than
      the first of them, or than the merge of its own post, sent `own`:
      task-2833650e2e72d380). `split/3` reads a post against it:
      typed over a value A never saw, it is merged when the line-up is
      certain (`PortableTextMerge`), else held. A hold keeps theirs stored
      exactly, puts A's view in the form with the conflict banner, and
      sends the view; it ends only on a post that carries the view's own
      number and differs from it (#28349 r4 review: rules 1, 3 and 4).
    * `push_held/3`: another save during a hold is merged into A's view and
      sent as a new view of the same hold.

  A post with no `_bp_rt_seen` (a page loaded before this, or a change the
  server built) is read as before. Top-level rich text keeps its own path
  (task-8d20a831ddd287a2).
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Barkpark.Content.Forms.HtmlBody
  alias Barkpark.Content.PortableText
  alias Barkpark.Content.PortableTextMerge
  alias BarkparkWeb.Studio.StudioLive.Handlers.HeldFields
  alias BarkparkWeb.Studio.StudioLive.Handlers.Lifecycle
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.FormPath
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.KeylessShift
  alias BarkparkWeb.Studio.StudioLive.Path

  @event "bp:rt-remote"

  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  # #28256's size: a value past it goes to the page in an event of its own.
  @html_cap 20_000

  # Changes kept per input name. Past it, the oldest two fold into one: the
  # older one's `was`, the newer one's number and `now`
  # (task-d6870fd34d7769b3). A post older than every change logged is read
  # against the first `was`; one that saw a folded change but not the last
  # folded in has no base left, and is held.
  @log_cap 8

  @doc """
  Tells the page of each rich text inside an object or a row that another
  editor's save changed between `old_form` and `new_form`, and logs it.
  """
  def push(socket, old_form, new_form) do
    changed = changes(socket.assigns[:editor_schema], old_form || %{}, new_form || %{})

    socket
    |> __MODULE__.UnderLock.remounted(old_form, new_form)
    |> tell(changed, %{})
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

    socket
    |> drop_holds()
    |> __MODULE__.RowDraws.reload(form)
    |> tell(all, %{reload: true})
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
    socket = assign(socket, editor_rt_doc: PostIdentity.of(socket))
    log = socket.assigns[:editor_rt_log] || %{}
    entries = [entry | Map.get(log, name, [])]

    if length(entries) > @log_cap do
      {kept, [{old, was, _}]} = Enum.split(entries, @log_cap)
      {seq, _, now} = List.last(kept)
      folded = socket.assigns[:editor_rt_folded] || %{}

      assign(socket,
        editor_rt_log: Map.put(log, name, List.replace_at(kept, -1, {seq, was, now})),
        editor_rt_folded: Map.put_new(folded, name, old)
      )
    else
      assign(socket, editor_rt_log: Map.put(log, name, entries))
    end
  end

  # One event for the values up to `@html_cap` bytes; each larger one rides
  # an event of its own, so one long text never holds up the others' event
  # and the page takes it the same way.
  # Each event names the document its values are of (`PostIdentity.of/1`,
  # the editor form's `phx-value-_bp_doc`): the page drops a value whose
  # document its form no longer shows. The log and the page's values are
  # then this document's (`editor_rt_doc`, `forget/1`).
  defp send_values(socket, values) do
    {big, small} = Enum.split_with(values, fn {_name, v} -> byte_size(v.html) > @html_cap end)
    doc = PostIdentity.of(socket)
    socket = assign(socket, editor_rt_doc: doc)

    socket =
      if small == [],
        do: socket,
        else: push_event(socket, @event, %{doc: doc, values: Map.new(small)})

    Enum.reduce(big, socket, fn {name, v}, s ->
      push_event(s, @event, %{doc: doc, values: %{name => v}})
    end)
  end

  @doc """
  Reads the post `doc` against the numbers the page reported (`seen`, the
  raw `_bp_rt_seen`). Returns `{doc, acts}` for `hold/2`.

  A rich text that is held (`editor_rt_held`: the view A was sent after a
  clash, the base A typed on, theirs as stored) stays held until a post
  carries the view's own number (#28349 r4 review, blocker 1: an IME commit
  re-posts the held text with the number before the view). Before that, the
  post is merged again against the base and theirs and held again, whatever
  its text; once it shows, a post equal to the view saves nothing over
  theirs and keeps the banner (review H), and a post that differs is A's
  typing on what A was shown, saved as typed.

  A rich text not held whose number is older than a change the server
  logged for it was typed on the value before that change (the oldest such
  entry's `was`):

    * unchanged from it: theirs stands;
    * a certain merge (`PortableTextMerge`): the merge is saved;
    * a clash: theirs stays stored exactly (review rule 1), and the form
      holds A's view with theirs in the banner.

  Past `@log_cap` changes the oldest fold together, so the first `was`
  stays; a post that saw a folded change but not the last folded in has no
  base that fits, and is held as a clash is.

  A rich text whose number is current is A's to save as typed.
  """
  def split(socket, doc, seen), do: split(socket, doc, seen, nil)

  @doc """
  `split/3`, with the post's owner entries (`_bp_rt_owner[]`). A rich text
  not held in a list whose keyless rows moved under A's page
  (`KeylessShift`) is read as a draw not known (`unknown/4`), against the
  store's row at its index: its name is its index, so its log is another
  row's, and A's words were merged into B's new row with no banner
  (#29178 review, round 2: J2, J2t, J4c).
  """
  def split(socket, doc, seen, owners) when is_list(seen) and is_map(doc) do
    moved = KeylessShift.lists(socket, owners, doc)

    # A log of another document is none of this one's (a forget lost).
    {log, holds, folded, born} =
      if socket.assigns[:editor_rt_doc] == PostIdentity.of(socket),
        do:
          {socket.assigns[:editor_rt_log] || %{}, socket.assigns[:editor_rt_held] || %{},
           socket.assigns[:editor_rt_folded] || %{}, socket.assigns[:editor_rt_born] || %{}},
        else: {%{}, %{}, %{}, %{}}

    Enum.reduce(seen, {doc, []}, fn entry, {doc, acts} ->
      with {name, n} <- parse_seen(entry),
           path when path != [] <- Path.parse_path(name),
           posted when is_binary(posted) <- FormPath.get(doc, path) do
        all = Map.get(log, name, [])
        later = Enum.filter(all, fn {s, _, _} -> s > n end)
        gap? = later != [] and length(later) == length(all) and n >= Map.get(folded, name, n + 1)

        case {Map.get(born, name), Map.get(holds, name)} do
          {_born, nil} when moved != [] and length(path) >= 2 ->
            if KeylessShift.list_of(path) in moved,
              do: unknown(doc, acts, {name, path, posted}, stored_at(socket, path)),
              else: read(doc, acts, {name, path, posted}, {n, gap?}, nil, later)

          # A number of a socket gone (`born/1`; 0 is a page that never had a value).
          {{seq, value}, nil} when n > 0 and n < seq ->
            unknown(doc, acts, {name, path, posted}, newest(later, value))

          {_born, held} ->
            read(doc, acts, {name, path, posted}, {n, gap?}, held, later)
        end
      else
        _ -> {doc, acts}
      end
    end)
  end

  def split(_socket, doc, _seen, _owners), do: {doc, []}

  defp stored_at(socket, path) do
    case Lifecycle.base_doc(socket) do
      %{content: %{} = content} -> FormPath.get(content, path)
      _ -> nil
    end
  end

  @doc """
  The value a post on number `n` was typed on, as `split/3` reads it: the
  `was` of the oldest change logged past `n`. Nil when none is (the page
  typed on the newest value this socket knows).
  """
  def page_base(socket, name, n) do
    log =
      if socket.assigns[:editor_rt_doc] == PostIdentity.of(socket),
        do: socket.assigns[:editor_rt_log] || %{},
        else: %{}

    case Enum.filter(Map.get(log, name, []), fn {s, _, _} -> s > n end) do
      [] -> nil
      later -> later |> List.last() |> elem(1)
    end
  end

  # Held, the view not shown yet: held again.
  defp read(doc, acts, at, {n, _gap?}, %{seq: seq} = h, _later) when n < seq,
    do: over(doc, acts, at, h.base, h.theirs, true)

  # Held, the view shown: unchanged from it, nothing is saved over theirs.
  defp read(doc, acts, {name, path, posted}, _n, %{} = h, _later) do
    if drawn(PortableText.from_html(posted, list(h.view))) == drawn(h.view),
      do: {FormPath.put(doc, path, html(h.theirs)), [{:still, name, path} | acts]},
      else: {doc, [{:current, name} | acts]}
  end

  defp read(doc, acts, {name, _path, _posted}, _n, nil, []), do: {doc, [{:current, name} | acts]}

  # `gap?`: the post saw a change folded out of the log (`@log_cap`) but
  # not the last one folded in, so no base fits it: held.
  defp read(doc, acts, at, {_n, gap?}, nil, later) do
    {_seq, was, _now} = List.last(later)
    {_seq, _was, theirs} = hd(later)

    over(doc, acts, at, was, theirs, gap?)
  end

  defp newest([], value), do: value
  defp newest([{_seq, _was, now} | _], _value), do: now

  # Typed on a socket gone (`born/1`): the base is not known. The stored
  # value posted back saves nothing; anything else is held over it.
  defp unknown(doc, acts, {_name, path, posted} = at, theirs) do
    if unchanged?(PortableText.from_html(posted, list(theirs)), theirs),
      do: {FormPath.put(doc, path, html(theirs)), acts},
      else: over(doc, acts, at, theirs, theirs, true)
  end

  @doc "Whether a post draws as `base`; past the merge's object cap, by `PortableTextMerge.same_drawn?/2`."
  def unchanged?(mine, base) do
    if PortableTextMerge.past_cap?(mine, list(base)),
      do: PortableTextMerge.same_drawn?(mine, base),
      else: drawn(mine) == drawn(base)
  end

  defp over(doc, acts, {name, path, posted}, base, theirs, held?) do
    mine = PortableText.from_html(posted, list(base))
    stays = FormPath.put(doc, path, html(theirs))

    if not held? and unchanged?(mine, base) do
      {stays, acts}
    else
      case PortableTextMerge.merge(list(base), mine, list(theirs)) do
        {:ok, merged} when not held? ->
          {FormPath.put(doc, path, html(merged)), [{:merged, name, path, mine} | acts]}

        {:ok, merged} ->
          {stays, [{:held, name, path, {base, theirs, merged, nil}} | acts]}

        {:clash, texts, view} ->
          {stays, [{:held, name, path, {base, theirs, view, texts}} | acts]}
      end
    end
  end

  @doc """
  After the save, for each act of `split/3`. A merge is logged as a change
  over what the page shows (A's post) and sent to show once A is idle. A
  hold puts A's view in the form, unsaved, with the conflict banner and
  theirs in it, logs it over the base A typed on, and sends it; a post
  still on the shown view keeps all that and sends nothing.
  """
  def hold(socket, []), do: socket

  def hold(socket, acts) do
    strings = socket.assigns[:editor_rt_held_raw] || %{}
    socket = if strings == %{}, do: socket, else: assign(socket, editor_rt_held_raw: %{})

    Enum.reduce(Enum.reverse(acts), socket, fn
      {:current, name}, s ->
        s
        |> assign(
          editor_rt_clash: Map.delete(s.assigns[:editor_rt_clash] || %{}, name),
          editor_rt_held: Map.delete(s.assigns[:editor_rt_held] || %{}, name)
        )
        |> HeldFields.drop_paths([{:rt, name}])

      # `own`: the page reads its text from this one, not from what waited
      # before it (task-2833650e2e72d380).
      {:merged, _name, path, mine}, s ->
        stored = FormPath.get(s.assigns[:editor_form] || %{}, path)
        tell(s, [{path, mine, stored}], %{own: true})

      {:still, name, path}, s ->
        case (s.assigns[:editor_rt_held] || %{})[name] do
          %{view: view} -> keep_held(s, name, path, view, nil)
          nil -> s
        end

      {:held, name, path, {base, theirs, view, texts}}, s ->
        s
        |> keep_held(name, path, view, texts)
        |> send_view(name, {base, theirs, view}, held_string(strings, name, theirs))
    end)
  end

  # The HTML string a hold's `theirs` (its blocks) was read from
  # (`UnderLock.html_act`), kept with the hold: a resolve reads A's post
  # against it byte for byte (task-d9ffbd2e6639496b).
  defp held_string(strings, name, theirs) do
    case strings do
      %{^name => string} -> if HtmlBody.blocks(string) == theirs, do: string
      _ -> nil
    end
  end

  # The form shows A's view, unsaved, with the banner.
  defp keep_held(socket, name, path, view, texts) do
    [key | _] = path
    clash = socket.assigns[:editor_rt_clash] || %{}

    socket
    # The row the hold is in, by its `_key`, before an op moves it.
    |> HeldFields.hold_paths([{{:rt, name}, path}])
    |> assign(
      editor_form: put_view(socket, path, view),
      editor_dirty: true,
      editor_unsaved_keys: MapSet.put(socket.assigns[:editor_unsaved_keys] || MapSet.new(), key),
      doc_conflict: true,
      save_status: "Updated by another user",
      editor_clash_fields: Enum.uniq((socket.assigns[:editor_clash_fields] || []) ++ [key]),
      editor_rt_clash: Map.put(clash, name, texts || Map.get(clash, name, []))
    )
  end

  # The view in the shape the form holds for that field. A top-level rich
  # text (not on the block editor) is edited as the HTML its editor draws
  # (`Content.Forms`); blocks there draw the read-only field, with no input,
  # so A's held words could not be edited or saved (task-f69efe9a4365aeb5).
  # Read from the schema, not the form's value: a body never set has none.
  # An object's or a row's rich text holds blocks.
  defp put_view(socket, path, view) do
    form = socket.assigns[:editor_form] || %{}

    if is_list(view) and html_field?(socket.assigns[:editor_schema], path),
      do: FormPath.put(form, path, PortableText.to_html(view)),
      else: FormPath.put(form, path, view)
  end

  defp html_field?(%{fields: fields}, [key]) when is_list(fields) and is_binary(key) do
    Enum.any?(fields, fn field ->
      match?(%{"name" => ^key, "type" => "richText"}, field) and
        not Barkpark.PortableDoc.FieldVocabulary.blocks_field?(field)
    end)
  end

  defp html_field?(_schema, _path), do: false

  # A new number for the view; the hold, and the log, read a post against
  # the base A typed on (never A's own earlier post: review blocker 1).
  defp send_view(socket, name, {base, theirs, view}, string \\ nil) do
    {socket, seq} = next_seq(socket)
    holds = socket.assigns[:editor_rt_held] || %{}
    hold = %{seq: seq, base: base, theirs: theirs, view: view}
    hold = if is_binary(string), do: Map.put(hold, :raw, string), else: hold

    socket
    |> log(name, {seq, base, theirs})
    |> assign(editor_rt_held: Map.put(holds, name, hold))
    |> send_values(%{name => %{seq: seq, html: html(view), held: true}})
  end

  @doc """
  Once per socket, when it first shows a document and is connected: every
  rich text inside an object or a row is sent its stored value (`born`),
  logged with no base. A page that rejoins a new socket keeps its editors
  and its numbers, which are the old socket's (task-eeda66fac5af065f). A
  post on such a number is older than this, so it is held unless it is the
  stored value; the page draws the value once A is idle and has nothing
  unposted. A page that never had a value reports 0 and is read as typed
  on this mount (task-05a0cfa97d2580ff).
  """
  def born(socket) do
    if is_map(socket.assigns[:editor_rt_born]) or not Phoenix.LiveView.connected?(socket) or
         is_nil(PostIdentity.of(socket)) do
      socket
    else
      form = socket.assigns[:editor_form] || %{}

      {socket, values, born} =
        socket.assigns[:editor_schema]
        |> paths(form, form, :all)
        |> Enum.reduce({socket, %{}, %{}}, fn {path, _, now}, {s, values, born} ->
          {s, seq} = next_seq(s)
          name = input_name(path)

          {s, Map.put(values, name, %{seq: seq, html: html(now), born: true}),
           Map.put(born, name, {seq, now})}
        end)

      socket
      |> assign(editor_rt_born: born, editor_rt_born_doc: PostIdentity.of(socket))
      |> __MODULE__.RowDraws.record_form(form, :born)
      |> send_values(values)
    end
  end

  @doc """
  The document the log and the page's values are of (`editor_rt_doc`) is
  not the one open, none included (a project or workspace switch,
  `Shared.reset_nav_for_switch/1`): the log, its folds and holds go, keyed by
  input names the next document may share, and the page drops what waits
  for those names (task-29686209fb9fc5dc). A post on the next document is
  A's, as typed.
  """
  def forget(socket) do
    was = socket.assigns[:editor_rt_doc]
    now = PostIdentity.of(socket)

    if is_nil(was) or was == now do
      socket
    else
      socket
      |> assign(
        editor_rt_doc: nil,
        editor_rt_log: %{},
        editor_rt_folded: %{},
        editor_rt_held: %{},
        editor_rt_clash: %{},
        editor_held_paths: %{},
        editor_rt_born: %{},
        editor_rt_page: nil,
        editor_rt_row_draws: nil,
        editor_rt_row_first: nil,
        editor_rt_rekeyed: nil,
        editor_rt_removed: nil
      )
      |> push_event(@event, %{forget: true, doc: now, values: %{}})
    end
  end

  @doc """
  Ends every hold: the form was read again from the store. So do A's own
  row removals (`DroppedRows.removed/2`, #29283 review D4).
  """
  def drop_holds(socket),
    do:
      socket
      |> assign(editor_rt_held: %{}, editor_rt_clash: %{}, editor_rt_removed: nil)
      |> HeldFields.drop_paths()

  @doc """
  While A's words in an object are held (`Lifecycle`'s unsaved branch keeps
  the form's value), another save of the same rich text: merged into the
  view A holds, held over the base A typed on, and sent as a new view.
  Without it A's next post, typed on the old view, would write over that
  save unseen. `old` and `new` are the stored values before and after it.
  """
  def push_held(socket, old, new) do
    form = socket.assigns[:editor_form] || %{}
    holds = socket.assigns[:editor_rt_held] || %{}

    socket.assigns[:editor_schema]
    |> changes(old || %{}, new || %{})
    |> Enum.reduce(socket, fn {path, was, now}, s ->
      held = FormPath.get(form, path)
      name = input_name(path)
      h = holds[name]

      # Not held here: the form took theirs (`push/3` told the page).
      if is_nil(h) and drawn(held) in [drawn(was), drawn(now)] do
        s
      else
        base = if h, do: h.base, else: was

        {view, texts} =
          case PortableTextMerge.merge(list(was), list(held), list(now)) do
            {:ok, merged} -> {merged, nil}
            {:clash, texts, view} -> {view, texts}
          end

        clash = s.assigns[:editor_rt_clash] || %{}

        s
        |> assign(
          editor_form: FormPath.put(s.assigns[:editor_form], path, view),
          editor_rt_clash: if(texts, do: Map.put(clash, name, texts), else: clash)
        )
        |> send_view(name, {base, now, view})
      end
    end)
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

  @doc "Each rich text path inside an object or a row of `form`."
  def every(schema, form) when is_map(form),
    do: for({path, _, _} <- paths(schema, form, form, :all), do: path)

  def every(_schema, _form), do: []

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
  @doc false
  def parse_seen(entry) when is_binary(entry) do
    parts = String.split(entry, "|")
    name = parts |> Enum.drop(-1) |> Enum.join("|")

    case Integer.parse(List.last(parts)) do
      {n, ""} when name != "" -> {name, n}
      _ -> nil
    end
  end

  def parse_seen(_entry), do: nil

  @doc "The input name the composite draws for `path` (`CompositeField`, `ArrayField`)."
  def input_name([key | rest]) do
    Enum.reduce(rest, "doc[#{key}]", fn
      i, acc when is_integer(i) -> acc <> "[#{i}]"
      sub, acc -> acc <> "." <> sub
    end)
  end
end
