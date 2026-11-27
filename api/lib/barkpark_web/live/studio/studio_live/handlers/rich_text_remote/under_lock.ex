defmodule BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.UnderLock do
  @moduledoc """
  A rich text post read under the document's lock (task-00c56c6a88ed0b8f).

  `RichTextRemote.split/3` reads a post against the changes this socket was
  told of. Another tab's save can land after that read and before this
  socket's write, and its broadcast waits behind this post: in real Chrome
  two tabs typing in one word lost the earlier post's words with no banner.

  So the save is told, per rich text the page reported a number for, what
  this socket believed the store held (`values/2`, the newest stored
  version it has seen, `Lifecycle.base_doc/1`). `Forms.ObjectRebase` reads
  it under the lock: the store still holds it, and the post is written as
  `split/3` read it; the store moved on, and the post is merged onto the
  store, and a clash keeps the store. `acts/4` reads the write's outcome
  (`:saved_over`, the value the write landed over) and gives `hold/2` the
  act for it: a merge is shown to the page as its own; a store kept over
  the post is held, A's words in the view, with the banner.
  """

  import Phoenix.Component, only: [assign: 2]

  alias Barkpark.Content.Forms.HtmlBody
  alias Barkpark.Content.PortableText
  alias Barkpark.Content.PortableTextMerge
  alias BarkparkWeb.Components.Fields.CompositeField
  alias BarkparkWeb.Studio.StudioLive.Handlers.Lifecycle
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.FormPath
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.KeylessShift
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.RowDraws
  alias BarkparkWeb.Studio.StudioLive.Handlers.TextConfirmed
  alias BarkparkWeb.Studio.StudioLive.Path
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @doc """
  Input name => {path, the value this socket believed stored, the value the
  page typed on when `split/3` reads the post past a logged change (else
  nil)}.
  """
  def values(socket, seen) when is_list(seen) do
    content =
      case Lifecycle.base_doc(socket) do
        %{content: %{} = content} -> content
        _ -> %{}
      end

    for entry <- seen,
        {name, n} <- [RichTextRemote.parse_seen(entry)],
        path = Path.parse_path(name),
        path != [],
        into: %{},
        do: {name, {path, FormPath.get(content, path), RichTextRemote.page_base(socket, name, n)}}
  end

  def values(_socket, _seen), do: %{}

  @doc """
  `values/2`, and for a post with no `_bp_rt_seen` (a page without
  bp-rt-remote.js) each rich text inside an object the post carries, read
  against the value that page shows (`shown/1`): what this socket drew it
  at mount (`editor_rt_born`), or this socket's own last post of it
  (`editor_rt_page`). Its editor sits in a `phx-update="ignore"` wrapper
  that only a remount redraws, so another editor's save, taken by the
  socket into `editor_form`, never reaches it (#28896 r1 review, B1). A
  clash then keeps the store and holds A with the banner, as a post with a
  number does; it was written as posted, over B (task-0437fdf2f2a6ccba). A
  rich text in a row, or one with no value drawn, is read as before.
  """
  def values(socket, seen, posted), do: values(socket, seen, posted, nil)

  @doc """
  `values/3`, with the owner `_key` each object rich text's editor was drawn
  under, as the post carries it (`_bp_rt_owner[]`, `[name, key, digest, outer keys]` as
  JSON). A value `remounted/3` took under a new owner key is what the page
  shows only when the post names that key and that value's digest
  (task-c0a696a3a5a3900d): a post typed on the old mount, still in
  flight while the remount went out, names the old one and is read against
  the old value (#28951 r1 review, B1).
  """
  def values(socket, seen, _posted, _owners) when is_list(seen), do: values(socket, seen)

  def values(socket, nil, posted, owners) when is_map(posted) do
    shown = shown(socket, owners)
    shifted = shifted(socket, owners)

    for {name, path, _html} <- posted_texts(socket, posted, owners),
        {:ok, was} <- [was(socket, shown, owners, name, path)],
        into: %{},
        do: {name, {path, if(list_of(path) in shifted, do: :unknown, else: was), nil}}
  end

  def values(_socket, _seen, _posted, _owners), do: %{}

  # The lists whose keyless rows moved under A's page (`KeylessShift`):
  # each rich text of such a list is read as a draw not known, the store
  # kept and A held (#29178 review, Q2-Q4c and R2r).
  defp shifted(socket, owners), do: KeylessShift.lists(socket.assigns[:editor_form], owners)

  defp list_of(path), do: KeylessShift.list_of(path)

  @doc """
  The socket after a post with no `_bp_rt_seen`: each object rich text it
  carries is what the page shows now (`values/3`), read onto the value it
  showed before so its blocks keep their keys.
  """
  def posted(socket, seen, posted), do: posted(socket, seen, posted, nil)

  @doc "`posted/3`, reading the post's owner keys as `values/4` does."
  def posted(socket, nil, posted, owners) when is_map(posted) do
    shown = shown(socket, owners)
    texts = posted_texts(socket, posted, owners)

    page =
      for {name, path, html} <- texts,
          into: own_page(socket),
          do:
            {name,
             PortableText.from_html(html, list(shown_at(socket, shown, owners, name, path)))}

    # A row's own value is the page's on the draw its post named, by the
    # row's key (`RowDraws`): A's own move or delete shifts its index.
    socket =
      Enum.reduce(texts, socket, fn {name, path, _html}, s ->
        case row?(path) && row_owner(s, owners, name, path) do
          {:ok, key, digest} ->
            RowDraws.record_own(s, path, {key, digest}, Map.fetch!(page, name))

          _ ->
            s
        end
      end)

    # A post typed on the remounted editor is the page's own value from now
    # on; one typed on the old mount leaves the remount still to come.
    drawn =
      Map.drop(
        rekeyed(socket),
        for({name, _, _} <- texts, drawn?(socket, owners, name), do: name)
      )

    assign(socket,
      editor_rt_page: {PostIdentity.of(socket), page},
      editor_rt_rekeyed: {PostIdentity.of(socket), drawn}
    )
  end

  def posted(socket, _seen, _posted, _owners), do: socket

  @doc """
  The socket after it took `new_form` over `old_form`: each rich text inside
  an object whose own `_key` changed is recorded with that key and the value
  taken (`editor_rt_rekeyed`). The editor's wrapper id carries the key
  (`CompositeField`, `bp-rt-sub-…`), so even a page without bp-rt-remote.js
  remounts it and draws the new value, and the owner key it posts
  (`_bp_rt_owner[]`) changes with it (task-c29534c0655f0489). Until a post
  names the new key, the page may not show it yet (`values/4`). The mount
  draw and the numbers the page reported (`editor_rt_born`) are left as they
  were. A row's rich text is recorded by its row's `_key` (`RowDraws`): its
  wrapper id carries the key, so a row moved, added or taken out under an
  index remounts it (task-82519fd79663e072).
  """
  def remounted(socket, old_form, new_form) do
    old_form = old_form || %{}
    new_form = new_form || %{}

    case PostIdentity.of(socket) do
      nil ->
        socket

      doc ->
        moved =
          for path <- RichTextRemote.every(socket.assigns[:editor_schema], new_form),
              not row?(path),
              owner = Enum.drop(path, -1),
              key(FormPath.get(old_form, owner)) != key(FormPath.get(new_form, owner)),
              into: %{},
              do:
                {RichTextRemote.input_name(path),
                 {to_string(key(FormPath.get(new_form, owner))), FormPath.get(new_form, path)}}

        socket = RowDraws.record_form(socket, new_form)

        if moved == %{},
          do: socket,
          else: assign(socket, editor_rt_rekeyed: {doc, Map.merge(rekeyed(socket), moved)})
    end
  end

  defp rekeyed(socket) do
    case socket.assigns[:editor_rt_rekeyed] do
      {doc, %{} = keyed} when not is_nil(doc) ->
        if doc == PostIdentity.of(socket), do: keyed, else: %{}

      _ ->
        %{}
    end
  end

  # Whether the post names the owner key `remounted/3` recorded for `name`
  # AND the digest of the value it recorded: the page draws the re-keyed
  # value. The key alone is not enough: a key that comes back to one drawn
  # earlier ("" -> m2 -> "") would let a post typed on the first draw match
  # the newest (task-c0a696a3a5a3900d). No owner, no digest, or one never
  # recorded, is the old mount.
  defp drawn?(socket, owners, name) do
    case Map.fetch(rekeyed(socket), name) do
      {:ok, {key, value}} -> owner(owners, name) == {:ok, key, CompositeField.drawn_digest(value)}
      :error -> false
    end
  end

  # Each entry is `[input_name, owner_key, digest]` as JSON: the name and key
  # may hold any character. The key is nil for an owner with none, read as "".
  # The digest is `CompositeField.drawn_digest/1`'s hex string. A page drawn
  # before it was one posts its old number: never an object's new draw, and
  # a row's draw as it was read before (`RowDraws.fetch/4`).
  defp owner(owners, name) when is_list(owners) do
    Enum.find_value(owners, :error, fn entry ->
      case entry(entry) do
        {^name, key, digest, _outer} -> {:ok, key, digest}
        _ -> nil
      end
    end)
  end

  defp owner(_owners, _name), do: :error

  # A row inside another row also names the `_key` of each row on the way,
  # its own left out (`RowDraws.outer_keys/2`, an index for a keyless one).
  # Any other entry, and one from a page drawn before, has none: `:any`.
  defp entry(entry) when is_binary(entry) do
    case Jason.decode(entry) do
      {:ok, [name, key, digest | rest]}
      when is_binary(name) and (is_binary(key) or is_nil(key)) and
             (is_binary(digest) or is_integer(digest)) ->
        case rest do
          [] -> {name, to_string(key), digest, :any}
          [outer] when is_list(outer) -> {name, to_string(key), digest, outer}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp entry(_entry), do: nil

  # A row's owner entry, matched to the row the form holds at `path` by its
  # `_key` and the keys of the rows on the way: the entry of its input name
  # where those name the row, else the one entry of that name with other
  # indexes that does. A post sent before the page drew another's insert or
  # move names the row by the index it was drawn at, and the fold
  # (`Fields.fold_dot_paths/2`) put its text into the row of its `_key`:
  # matched by index, the row was not read under the lock and A's text was
  # written over another's edit of it (task-46bcc2dfb805acce). Matched by
  # the inner key alone, two sections whose items share a key (a duplicated
  # section) swapped named each other's draw, and A was held
  # (task-1a748ef7bc04ae49), unless one row of that shape holds the key
  # (`only_row?/3`). Two entries of one shape and keys name none.
  defp row_owner(socket, owners, name, path) do
    form = socket.assigns[:editor_form] || %{}
    key = to_string(key(FormPath.get(form, Enum.drop(path, -1))))

    outer =
      if only_row?(form, Enum.drop(path, -1), key),
        do: :any,
        else: RowDraws.outer_keys(form, path)

    shape = shape(name)

    found =
      for entry <- List.wrap(owners),
          {other, ^key, digest, at} <- [entry(entry)],
          :any in [at, outer] or at == outer,
          shape(other) == shape,
          do: {other, digest}

    case List.keyfind(found, name, 0) do
      {_, digest} ->
        {:ok, key, digest}

      nil ->
        case found |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
          [digest] -> {:ok, key, digest}
          _ -> :error
        end
    end
  end

  # One row of this field shape (its path, any indexes) holds `key`: an
  # entry drawn under other outer rows names it, as another editor moved it
  # there (task-3422ba9e403f8b75). Two (a duplicated section): only the
  # entry drawn under the same outer rows does.
  defp only_row?(_form, _at, ""), do: false

  defp only_row?(form, at, key) do
    shape = Enum.map(at, &if(is_integer(&1), do: :row, else: &1))
    match?([_], for(%{"_key" => ^key} <- rows_of(form, shape), do: key))
  end

  defp rows_of(value, []), do: [value]

  defp rows_of(rows, [:row | rest]) when is_list(rows),
    do: Enum.flat_map(rows, &rows_of(&1, rest))

  defp rows_of(%{} = value, [seg | rest]) when is_binary(seg),
    do: rows_of(Map.get(value, seg), rest)

  defp rows_of(_value, _shape), do: []

  defp shape(name), do: String.replace(name, ~r/\[\d+\]/, "[]")

  defp key(%{} = owner), do: Map.get(owner, "_key")
  defp key(_), do: nil

  # Each rich text the post carries as the page's HTML: inside an object,
  # and in a row when the post names the draw it was typed on (an owner
  # entry with a digest) under the `_key` of the row at that index now. A
  # row post with none is written as posted, as before: its index may name
  # another row than the one drawn there.
  defp posted_texts(socket, posted, owners) do
    form = socket.assigns[:editor_form] || %{}

    for path <- RichTextRemote.every(socket.assigns[:editor_schema], form),
        name = RichTextRemote.input_name(path),
        not row?(path) or row_owner(socket, owners, name, path) != :error,
        html = FormPath.get(posted, path),
        is_binary(html),
        do: {name, path, html}
  end

  defp row?(path), do: RowDraws.row?(path)

  defp shown_at(socket, shown, owners, name, path) do
    case was(socket, shown, owners, name, path) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  # What the page showed for `name`. An object's: `shown/2`. A row's: the
  # draw its owner entry names by row key and digest (`RowDraws`,
  # task-82519fd79663e072): A's own last post on that draw, a value the
  # socket took, or the mount draw. None of them: `:unknown`, and the store
  # is kept and A held (`ObjectRebase`, `act/5`), never written over.
  defp was(socket, shown, owners, name, path) do
    if row?(path),
      do: {:ok, row_draw(socket, owners, name, path)},
      else: Map.fetch(shown, name)
  end

  defp row_draw(socket, owners, name, path) do
    {:ok, key, digest} = row_owner(socket, owners, name, path)

    case RowDraws.fetch(socket, path, key, digest) do
      {:ok, value} -> value
      :error -> :unknown
    end
  end

  # The value a page without bp-rt-remote.js shows, by input name, of the
  # document open: each is stamped with the document it was drawn or posted
  # on, so a switch that left them in place does not carry them over.
  defp shown(socket, owners) do
    drawn =
      for {name, {_key, value}} <- rekeyed(socket),
          drawn?(socket, owners, name),
          into: %{},
          do: {name, value}

    Map.merge(shown(socket), drawn)
  end

  defp shown(socket), do: Map.merge(born(socket), own_page(socket))

  defp born(socket) do
    if socket.assigns[:editor_rt_born_doc] == PostIdentity.of(socket),
      do:
        for(
          {name, {_seq, value}} <- socket.assigns[:editor_rt_born] || %{},
          into: %{},
          do: {name, value}
        ),
      else: %{}
  end

  defp own_page(socket) do
    case socket.assigns[:editor_rt_page] do
      {doc, %{} = page} when not is_nil(doc) ->
        if doc == PostIdentity.of(socket), do: page, else: %{}

      _ ->
        %{}
    end
  end

  @doc """
  Each top-level rich text the post carries (task-fa07c64d344638fb), with
  the value its editor shows: the stored row this socket last took
  (`Lifecycle.base_doc/1`). A top-level editor is remounted on every value
  the socket draws (its wrapper id carries the form generation), so it
  shows that row, on every remount except a socket rejoin: a new socket
  starts at generation 0, the same wrapper id, so the page keeps the editor
  it had (task-fe9d8741f0641f97). While A is held, the page shows A's view
  over theirs, and a post on it is A's: read against theirs, so it is
  written as typed.
  """
  def top(socket, posted, seen \\ nil)

  def top(socket, posted, seen) when is_map(posted) do
    # `was` is the row the socket last took only because a top-level
    # wrapper remounts on every form generation. Not after a socket
    # rejoin: generation 0 gives the same wrapper id, and the wrapper is
    # phx-update="ignore", so the page keeps the editor it had while
    # `base_doc` is the new store. There an autosave is read against the
    # digest the page kept (`TextConfirmed.rejoin_seen/4`,
    # task-fe9d8741f0641f97). task-8d20a831ddd287a2 would stop the
    # remounts: if it lands, `was` must become the value the page shows
    # (drawn at mount or its own last post), as `values/3` reads an
    # object's (#28896).
    content =
      case Lifecycle.base_doc(socket) do
        %{content: %{} = content} -> content
        _ -> %{}
      end

    holds = socket.assigns[:editor_rt_held] || %{}

    for %{"name" => key, "type" => "richText"} <- fields(socket.assigns[:editor_schema]),
        is_binary(key),
        is_binary(Map.get(posted, key)),
        name = RichTextRemote.input_name([key]),
        into: %{} do
      # An autosave (`seen`, its `_bp_seen`) on a socket that mounted as a
      # rejoin is read against the digest the page kept (`TextConfirmed`,
      # task-fe9d8741f0641f97) before a hold's view: typing on A's view
      # stays held until a Save or Reload.
      case {seen && TextConfirmed.rejoin_seen(socket, name, Map.get(content, key), seen), holds} do
        {:unknown, _} ->
          {name, {[key], :unknown, nil}}

        {_, %{^name => %{theirs: theirs}}} ->
          {name, {[key], Map.get(holds[name], :raw, theirs), :resolve}}

        # Sent before the redraw of another's save reached the page: read
        # against the value the page still showed (`TextConfirmed.took/3`).
        _ ->
          {name, {[key], TextConfirmed.page_base(socket, name, Map.get(content, key), seen), nil}}
      end
    end
  end

  def top(_socket, _posted, _seen), do: %{}

  defp fields(%{fields: fields}) when is_list(fields), do: fields
  defp fields(_schema), do: []

  @doc "The save's options: each value by its content path, and the fields to report."
  def write_opts(values) when map_size(values) == 0, do: []

  def write_opts(values) do
    [
      rich_text_seen: Map.new(Map.values(values), fn {path, was, _page} -> {path, was} end),
      saved_over:
        values |> Map.values() |> Enum.map(fn {[key | _], _, _} -> key end) |> Enum.uniq()
    ]
  end

  @doc """
  `acts` with the act of each rich text whose store moved under the post
  (`saved` is the socket after the write, `doc` the post `split/3` gave),
  and the socket's form at the stored value of a merge.
  """
  #
  # `doc` is the post as written (after `split/3`), `posted` as the page
  # sent it. A rich text `split/3` held (again, or still on the view) was
  # held against the store this socket knew; when the store moved under the
  # lock, the hold is read again against it (`rehold/5`,
  # task-4dbb75a6eb9ceeea), or the view kept the old store and typing on it
  # erased the save that landed.
  def acts(saved, acts, values, {doc, posted_doc}) when map_size(values) > 0 do
    written = saved.assigns[:editor_doc]
    over = (is_map(written) && Map.get(written, :saved_over)) || %{}
    now = (is_map(written) && Map.get(written, :content)) || %{}

    Enum.reduce(values, {saved, acts}, fn {name, {path, was, page}}, {s, acts} ->
      act =
        if html_body?(s, path, over) or shown_string?(s, path, over, was),
          do: &html_act/5,
          else: &act/5

      {s, acts} =
        act.(
          s,
          acts,
          {name, path, was, if(page == :resolve, do: nil, else: page)},
          {over, now},
          {doc, posted_doc}
        )

      resolve(s, acts, name, page)
    end)
  end

  def acts(saved, acts, _values, _docs), do: {saved, acts}

  # A top-level post on A's view while held (`top/2`'s `:resolve`) is A's:
  # the hold ends unless the store moved under it again and it is held anew.
  defp resolve(s, acts, name, :resolve) do
    if Enum.any?(acts, &match?({:held, ^name, _, _}, &1)),
      do: {s, acts},
      else: {s, [{:current, name} | acts]}
  end

  defp resolve(s, acts, _name, _page), do: {s, acts}

  # A top-level body the store held as an HTML string or as nothing
  # (`HtmlBody.field?/2`, task-bb19ab06ab1e87b2, task-077fbe951d7c338e), or
  # a Portable Text field it held as a string (`HtmlBody.stored_string?/2`,
  # task-49a96a7780dad558):
  # the write kept the store over a post typed on a value it no longer
  # holds, and A is held, as on a block body. Read as blocks for the hold's
  # view; the store stays a string.
  defp html_body?(s, [key], over) when is_map_key(over, key) do
    stored = Map.fetch!(over, key)
    HtmlBody.field?(field(s, key), stored) or string_field?(s, key, stored)
  end

  defp html_body?(_s, _path, _over), do: false

  # A Portable Text field whose page showed a string the store no longer
  # holds as one (removed: task-7565817187a53934) is read by that string.
  defp shown_string?(s, [key], over, was) when is_map_key(over, key) and is_binary(was),
    do: HtmlBody.stored_string?(field(s, key), was)

  defp shown_string?(_s, _path, _over, _was), do: false

  defp string_field?(s, key, stored), do: HtmlBody.stored_string?(field(s, key), stored)

  defp field(s, key),
    do: Enum.find(fields(s.assigns[:editor_schema]), &match?(%{"name" => ^key}, &1))

  defp html_act(s, acts, {name, [key] = path, was, _page}, {over, _now}, {doc, _posted_doc}) do
    before = Map.fetch!(over, key)
    posted = FormPath.get(doc, path)

    held? =
      if string_field?(s, key, before) or (is_binary(was) and string_field?(s, key, was)),
        do: HtmlBody.string_held?(before, was),
        else: HtmlBody.held?(posted, before, was)

    if is_binary(posted) and not holds?(acts, name) and held?,
      do:
        {keep_string(s, name, before),
         [{:held, name, path, html_hold(posted, before, was)} | drop(acts, name)]},
      else: {s, acts}
  end

  # The string a body is held on, for the hold (`RichTextRemote.hold/2`
  # keeps it as its `raw`): the hold's `theirs` is its blocks
  # (`html_hold/3`), which drop markup the editor does not draw. Read
  # against them, a resolve took a string changed only there (an iframe)
  # for the one A was held on, and wrote over it; and a Portable Text field
  # holding a string never matched its string, so typing on the view stayed
  # held (task-d9ffbd2e6639496b).
  defp keep_string(s, name, before) when is_binary(before) do
    raw = s.assigns[:editor_rt_held_raw] || %{}
    Phoenix.Component.assign(s, editor_rt_held_raw: Map.put(raw, name, before))
  end

  defp keep_string(s, _name, _before), do: s

  # A row post whose draw is not known (`was/5`): read against the store it
  # landed on, so A's words the store kept are held, never lost unheld.
  defp act(s, acts, {name, path, :unknown, page}, {over, now}, {doc, _posted_doc}) do
    before = FormPath.get(over, path)
    posted = FormPath.get(doc, path)

    if Map.has_key?(over, hd(path)) and is_binary(posted),
      do:
        moved(
          s,
          acts,
          {name, path},
          {list(before), list(before), list(FormPath.get(now, path))},
          {posted, page}
        ),
      else: {s, acts}
  end

  defp act(s, acts, {name, path, was, page}, {over, now}, {doc, posted_doc}) do
    before = FormPath.get(over, path)
    posted = FormPath.get(doc, path)

    cond do
      not Map.has_key?(over, hd(path)) or not is_binary(posted) ->
        {s, acts}

      # Both stored: a block field another editor set (`level`, an
      # unknown field) is a move too (task-6174d8fa01658a68, #28867
      # review B1), or A's words the store kept over went unheld.
      PortableTextMerge.same_shape?(was, before) ->
        {s, acts}

      holds?(acts, name) ->
        rehold(s, acts, {name, path}, list(before), FormPath.get(posted_doc, path))

      true ->
        moved(
          s,
          acts,
          {name, path},
          {list(was), list(before), list(FormPath.get(now, path))},
          {posted, page}
        )
    end
  end

  # Held by `split/3` over the store this socket knew, `before` landed under
  # the lock: A's text (the post; the view for a post still on it) merged
  # again from the hold's base onto `before`, held as `split/3` holds.
  defp rehold(s, acts, {name, path}, before, posted) do
    case held_base(s, acts, name) do
      {base, mine} when is_binary(posted) or is_list(mine) ->
        mine = mine || PortableText.from_html(posted, list(base))

        hold =
          case PortableTextMerge.merge(list(base), mine, before) do
            {:clash, texts, view} -> {base, before, view, texts}
            {:ok, merged} -> {base, before, merged, nil}
          end

        {s, [{:held, name, path, hold} | drop(acts, name)]}

      _ ->
        {s, acts}
    end
  end

  # The hold's base, and A's text when it is the view (`:still`), else nil.
  defp held_base(s, acts, name) do
    case Enum.find(acts, &(elem(&1, 1) == name)) do
      {:held, ^name, _path, {base, _theirs, _view, _texts}} ->
        {base, nil}

      {:still, ^name, _path} ->
        case (s.assigns[:editor_rt_held] || %{})[name] do
          %{base: base, view: view} -> {base, list(view)}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # `written` is what the write was given (after `split/3`, which may have
  # merged a change A's page was told of into it). It left this rich text
  # as A believed it stored: nothing of A's to keep, no act (`over/6`'s
  # rule). The store kept over it: held, A's words in the view. Else the
  # store took them merged: shown to the page as its own, logged over the
  # page's own text, `split/3`'s `mine` where it merged (#28792 review B1).
  # `written` comes from the page's HTML, which carries no block field, so
  # it is compared by the drawing; `after_write` and `before` are both
  # stored, so by shape (task-6174d8fa01658a68).
  # A hold where `split/3` merged is read against what the page typed on,
  # not `was`: the page has not drawn the change merged in, and a post on
  # its text would read as taking it out (task-77c9532e1e04907b).
  defp moved(s, acts, {name, path}, {was, before, after_write}, {posted, page}) do
    written = PortableText.from_html(posted, was)
    mine = Enum.find_value(acts, &match_merged(&1, name))

    cond do
      PortableTextMerge.same_drawn?(written, was) ->
        {s, acts}

      PortableTextMerge.same_shape?(after_write, before) and
          not PortableTextMerge.same_drawn?(written, before) ->
        {base, text} = if mine && page, do: {list(page), mine}, else: {was, written}

        {view, texts} =
          case PortableTextMerge.merge(base, text, before) do
            {:clash, texts, view} -> {view, texts}
            {:ok, _merged} -> {text, nil}
          end

        {s, [{:held, name, path, {base, before, view, texts}} | drop(acts, name)]}

      true ->
        form = FormPath.put(s.assigns[:editor_form] || %{}, path, after_write)
        acts = [{:merged, name, path, mine || written} | drop(acts, name)]
        {Phoenix.Component.assign(s, editor_form: form), acts}
    end
  end

  defp html_hold(posted, before, was) do
    base = HtmlBody.blocks(if was == :unknown, do: before, else: was)
    theirs = HtmlBody.blocks(before)
    mine = PortableText.from_html(posted, base)

    case PortableTextMerge.merge(base, mine, theirs) do
      {:clash, texts, view} -> {base, theirs, view, texts}
      # The view A types on is the two merged (drawn as HTML,
      # `RichTextRemote.keep_held`): a Save or the next key keeps B's
      # change (task-077fbe951d7c338e).
      {:ok, merged} -> {base, theirs, merged, nil}
    end
  end

  defp match_merged({:merged, name, _path, mine}, name), do: mine
  defp match_merged(_act, _name), do: nil

  defp drop(acts, name), do: Enum.reject(acts, &(elem(&1, 1) == name))

  defp holds?(acts, name),
    do:
      Enum.any?(acts, &match?({kind, ^name, _, _} when kind in [:held], &1)) or
        Enum.any?(acts, &match?({:still, ^name, _}, &1))

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
end
