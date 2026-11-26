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

  alias Barkpark.Content.PortableText
  alias Barkpark.Content.PortableTextMerge
  alias BarkparkWeb.Components.Fields.CompositeField
  alias BarkparkWeb.Studio.StudioLive.Handlers.Lifecycle
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.FormPath
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
  under, as the post carries it (`_bp_rt_owner[]`, `[name, key, digest]` as
  JSON). A value `remounted/3` took under a new owner key is what the page
  shows only when the post names that key and that value's digest
  (task-c0a696a3a5a3900d): a post typed on the old mount, still in
  flight while the remount went out, names the old one and is read against
  the old value (#28951 r1 review, B1).
  """
  def values(socket, seen, _posted, _owners) when is_list(seen), do: values(socket, seen)

  def values(socket, nil, posted, owners) when is_map(posted) do
    shown = shown(socket, owners)

    for {name, path, _html} <- posted_texts(socket, posted),
        {:ok, was} <- [Map.fetch(shown, name)],
        into: %{},
        do: {name, {path, was, nil}}
  end

  def values(_socket, _seen, _posted, _owners), do: %{}

  @doc """
  The socket after a post with no `_bp_rt_seen`: each object rich text it
  carries is what the page shows now (`values/3`), read onto the value it
  showed before so its blocks keep their keys.
  """
  def posted(socket, seen, posted), do: posted(socket, seen, posted, nil)

  @doc "`posted/3`, reading the post's owner keys as `values/4` does."
  def posted(socket, nil, posted, owners) when is_map(posted) do
    shown = shown(socket, owners)
    texts = posted_texts(socket, posted)

    page =
      for {name, _path, html} <- texts,
          into: own_page(socket),
          do: {name, PortableText.from_html(html, list(Map.get(shown, name)))}

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
  were. A rich text in a row is read as before: a row with a new `_key` is
  another row.
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
              not Enum.any?(path, &is_integer/1),
              owner = Enum.drop(path, -1),
              key(FormPath.get(old_form, owner)) != key(FormPath.get(new_form, owner)),
              into: %{},
              do:
                {RichTextRemote.input_name(path),
                 {to_string(key(FormPath.get(new_form, owner))), FormPath.get(new_form, path)}}

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
  defp owner(owners, name) when is_list(owners) do
    Enum.find_value(owners, :error, fn
      entry when is_binary(entry) ->
        case Jason.decode(entry) do
          {:ok, [^name, key, digest]}
          when (is_binary(key) or is_nil(key)) and is_integer(digest) ->
            {:ok, to_string(key), digest}

          _ ->
            nil
        end

      _ ->
        nil
    end)
  end

  defp owner(_owners, _name), do: :error

  defp key(%{} = owner), do: Map.get(owner, "_key")
  defp key(_), do: nil

  # Each rich text inside an object (no row index on its path) the post
  # carries as the page's HTML.
  defp posted_texts(socket, posted) do
    for path <-
          RichTextRemote.every(
            socket.assigns[:editor_schema],
            socket.assigns[:editor_form] || %{}
          ),
        not Enum.any?(path, &is_integer/1),
        html = FormPath.get(posted, path),
        is_binary(html),
        do: {RichTextRemote.input_name(path), path, html}
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

  defp shown(socket) do
    born =
      if socket.assigns[:editor_rt_born_doc] == PostIdentity.of(socket),
        do:
          for(
            {name, {_seq, value}} <- socket.assigns[:editor_rt_born] || %{},
            into: %{},
            do: {name, value}
          ),
        else: %{}

    Map.merge(born, own_page(socket))
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
  def top(socket, posted) when is_map(posted) do
    # `was` is the row the socket last took only because a top-level
    # wrapper remounts on every form generation. Not after a socket
    # rejoin: generation 0 gives the same wrapper id, and the wrapper is
    # phx-update="ignore", so the page keeps the editor it had while
    # `base_doc` is the new store; a save B made meanwhile is written over
    # (main does the same, task-fe9d8741f0641f97). task-8d20a831ddd287a2
    # would stop those remounts: if it lands, `was` must become the value
    # the page shows (drawn at mount or its own last post), as
    # `values/3` reads an object's (#28896).
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
      case holds do
        %{^name => %{theirs: theirs}} -> {name, {[key], theirs, :resolve}}
        _ -> {name, {[key], Map.get(content, key), nil}}
      end
    end
  end

  def top(_socket, _posted), do: %{}

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
      {s, acts} =
        act(
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
