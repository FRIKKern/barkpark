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

  alias Barkpark.Content.PortableText
  alias Barkpark.Content.PortableTextMerge
  alias BarkparkWeb.Studio.StudioLive.Handlers.Lifecycle
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.FormPath
  alias BarkparkWeb.Studio.StudioLive.Path

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
  Each top-level rich text the post carries (task-fa07c64d344638fb), with
  the value its editor shows: the stored row this socket last took
  (`Lifecycle.base_doc/1`). A top-level editor is remounted on every value
  the socket draws (its wrapper id carries the form generation), so it
  shows that row. While A is held, the page shows A's view over theirs, and
  a post on it is A's: read against theirs, so it is written as typed.
  """
  def top(socket, posted) when is_map(posted) do
    # `was` is the row the socket last took only because a top-level
    # wrapper remounts on every form generation. task-8d20a831ddd287a2
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
