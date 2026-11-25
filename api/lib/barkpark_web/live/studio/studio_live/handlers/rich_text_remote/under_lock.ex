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

  @doc "Input name => {path, the value this socket believed stored}."
  def values(socket, seen) when is_list(seen) do
    content =
      case Lifecycle.base_doc(socket) do
        %{content: %{} = content} -> content
        _ -> %{}
      end

    for entry <- seen,
        {name, _n} <- [RichTextRemote.parse_seen(entry)],
        path = Path.parse_path(name),
        path != [],
        into: %{},
        do: {name, {path, FormPath.get(content, path)}}
  end

  def values(_socket, _seen), do: %{}

  @doc "The save's options: each value by its content path, and the fields to report."
  def write_opts(values) when map_size(values) == 0, do: []

  def write_opts(values) do
    [
      rich_text_seen: Map.new(Map.values(values)),
      saved_over: values |> Map.values() |> Enum.map(fn {[key | _], _} -> key end) |> Enum.uniq()
    ]
  end

  @doc """
  `acts` with the act of each rich text whose store moved under the post
  (`saved` is the socket after the write, `doc` the post `split/3` gave),
  and the socket's form at the stored value of a merge.
  """
  def acts(saved, acts, values, doc) when map_size(values) > 0 do
    written = saved.assigns[:editor_doc]
    over = (is_map(written) && Map.get(written, :saved_over)) || %{}
    now = (is_map(written) && Map.get(written, :content)) || %{}

    Enum.reduce(values, {saved, acts}, fn {name, {path, was}}, {s, acts} ->
      before = FormPath.get(over, path)
      posted = FormPath.get(doc, path)

      cond do
        not Map.has_key?(over, hd(path)) or not is_binary(posted) ->
          {s, acts}

        PortableTextMerge.same_drawn?(was, before) ->
          {s, acts}

        holds?(acts, name) ->
          {s, acts}

        true ->
          moved(
            s,
            acts,
            {name, path},
            {list(was), list(before), list(FormPath.get(now, path))},
            posted
          )
      end
    end)
  end

  def acts(saved, acts, _values, _doc), do: {saved, acts}

  # The store kept over the post: held, A's words in the view. Else the
  # store took them merged: shown to the page as its own.
  defp moved(s, acts, {name, path}, {was, before, after_write}, posted) do
    mine = PortableText.from_html(posted, was)
    acts = Enum.reject(acts, &(elem(&1, 1) == name))

    if PortableTextMerge.same_drawn?(after_write, before) and
         not PortableTextMerge.same_drawn?(mine, before) do
      {view, texts} =
        case PortableTextMerge.merge(was, mine, before) do
          {:clash, texts, view} -> {view, texts}
          {:ok, _merged} -> {mine, nil}
        end

      {s, [{:held, name, path, {was, before, view, texts}} | acts]}
    else
      form = FormPath.put(s.assigns[:editor_form] || %{}, path, after_write)
      {Phoenix.Component.assign(s, editor_form: form), [{:merged, name, path, mine} | acts]}
    end
  end

  defp holds?(acts, name),
    do:
      Enum.any?(acts, &match?({kind, ^name, _, _} when kind in [:held], &1)) or
        Enum.any?(acts, &match?({:still, ^name, _}, &1))

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
end
