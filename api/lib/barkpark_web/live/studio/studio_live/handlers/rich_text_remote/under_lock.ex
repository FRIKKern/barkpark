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
  def values(socket, seen, _posted) when is_list(seen), do: values(socket, seen)

  def values(socket, nil, posted) when is_map(posted) do
    shown = shown(socket)

    for {name, path, _html} <- posted_texts(socket, posted),
        {:ok, was} <- [Map.fetch(shown, name)],
        into: %{},
        do: {name, {path, was, nil}}
  end

  def values(_socket, _seen, _posted), do: %{}

  @doc """
  The socket after a post with no `_bp_rt_seen`: each object rich text it
  carries is what the page shows now (`values/3`), read onto the value it
  showed before so its blocks keep their keys.
  """
  def posted(socket, nil, posted) when is_map(posted) do
    shown = shown(socket)

    page =
      for {name, _path, html} <- posted_texts(socket, posted),
          into: own_page(socket),
          do: {name, PortableText.from_html(html, list(Map.get(shown, name)))}

    assign(socket, editor_rt_page: {PostIdentity.of(socket), page})
  end

  def posted(socket, _seen, _posted), do: socket

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

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

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
    end)
  end

  def acts(saved, acts, _values, _docs), do: {saved, acts}

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
