defmodule BarkparkWeb.Studio.Desk.FieldDiff do
  @moduledoc """
  What Review changes compares, as the TanStack Studio computes it
  (`lib/changes.ts`, `lib/array-diff.ts`, `lib/doc-diff.ts`). Pure: no
  reads, no socket.

  A version of the document is its `values/1`: the content's fields with
  the title column under `"title"`. `changes/3` lists the top-level fields
  whose two values differ, in the form's order (the Title first, then the
  schema's fields). Two values are the same when they are equal once
  emptiness is set aside: no value, `""`, `[]` and `%{}` are all empty,
  and so is an object whose fields are all empty. The save path may write
  an untouched empty input as `""` where the published version had
  nothing; that is no change.

  The other functions take one change apart for drawing it:

  - `text_diff/2`: a word diff (Sanity's diff-match-patch over words):
    runs of words kept, removed and added.
  - `array_diff/2`: each item of the list after the change, added, moved or
    kept, then each removed one. Items are matched by `_key` (objects,
    references) or by value.
  - `blocks_diff/2`: rich text block by block; only the blocks that changed,
    each with the word diff of its text.
  - `authors/1`: who changed each field, from the revisions since the last
    publish.
  """

  @typedoc "One changed top-level field."
  @type change :: %{field: map(), name: String.t(), before: term(), after: term()}

  # The most words a text diff compares; past it a value is drawn as removed
  # then added, whole.
  @max_tokens 20_000

  @doc "The values of a document (or a revision): its content and its title."
  @spec values(map() | nil) :: map()
  def values(nil), do: %{}

  def values(doc) when is_map(doc) do
    content = Map.get(doc, :content) || Map.get(doc, "content") || %{}
    title = Map.get(doc, :title, Map.get(doc, "title"))
    Map.put(if(is_map(content), do: content, else: %{}), "title", title)
  end

  @doc """
  The fields Review changes compares, in the form's order: the Title (the
  schema's own `title` field, or the form's Title input), then the rest.
  """
  @spec fields(map() | nil) :: [map()]
  def fields(%{fields: fields}) when is_list(fields) do
    fields = Enum.filter(fields, &(is_map(&1) and is_binary(&1["name"])))
    title = Enum.find(fields, &(&1["name"] == "title")) || title_field()
    [title | Enum.reject(fields, &(&1["name"] == "title"))]
  end

  def fields(_schema), do: [title_field()]

  defp title_field, do: %{"name" => "title", "title" => "Title", "type" => "string"}

  @doc "The fields whose values differ between `before` and `after` (`values/1`)."
  @spec changes([map()], map(), map()) :: [change()]
  def changes(fields, before, after_) do
    Enum.flat_map(fields, fn %{"name" => name} = field ->
      {b, a} = {Map.get(before, name), Map.get(after_, name)}
      if same?(b, a), do: [], else: [%{field: field, name: name, before: b, after: a}]
    end)
  end

  @doc "Whether two stored values are the same, emptiness set aside."
  @spec same?(term(), term()) :: boolean()
  def same?(a, b), do: norm(a) == norm(b)

  defp norm(nil), do: nil
  defp norm(""), do: nil
  defp norm([]), do: nil

  # A slug or a reference is stored either way: as its text, or as the
  # object the form writes ({"_type": "slug", "current": …}, {"_ref": …}).
  defp norm(%{"current" => c} = slug)
       when is_binary(c) and map_size(slug) <= 2 and
              (map_size(slug) == 1 or
                 :erlang.map_get("_type", slug) == "slug"),
       do: norm(c)

  defp norm(%{"_ref" => r} = ref)
       when is_binary(r) and map_size(ref) <= 2 and
              (map_size(ref) == 1 or
                 :erlang.map_get("_type", ref) == "reference"),
       do: norm(r)

  # Rich text is its blocks; the html beside them is drawn from them (a doc
  # written through the API may have none until the form saves it).
  defp norm(%{"blocks" => blocks, "html" => _} = rich) when is_list(blocks),
    do: norm(Map.delete(rich, "html"))

  defp norm(%{} = map) do
    kept =
      Enum.reduce(map, %{}, fn {k, v}, acc ->
        case norm(v) do
          nil -> acc
          n -> Map.put(acc, k, n)
        end
      end)

    if kept == %{}, do: nil, else: kept
  end

  defp norm(list) when is_list(list), do: Enum.map(list, &(norm(&1) || :empty))
  defp norm(value), do: value

  @doc "Whether a value is empty (no value, `\"\"`, `[]`, `%{}`)."
  def empty?(value), do: norm(value) == nil

  # ── Text ────────────────────────────────────────────────────────────────

  @doc """
  The plain text of a value, for a word diff: a text as it is, a number or
  yes/no as written, a slug's `current`, a list of texts joined by ", ",
  rich text block by block. `nil` for a value that is not text.
  """
  @spec as_text(term()) :: String.t() | nil
  def as_text(nil), do: ""
  def as_text(v) when is_binary(v), do: v
  def as_text(v) when is_number(v) or is_boolean(v), do: to_string(v)
  def as_text(%{"current" => c}) when is_binary(c), do: c

  def as_text(list) when is_list(list) do
    cond do
      list == [] ->
        ""

      Enum.all?(list, &(is_binary(&1) or is_number(&1))) ->
        Enum.map_join(list, ", ", &to_string/1)

      blocks?(list) ->
        Enum.map_join(list, "\n", &block_text/1)

      true ->
        nil
    end
  end

  def as_text(_value), do: nil

  @typedoc "A run of a text diff."
  @type segment :: {:same | :removed | :added, String.t()}

  @doc "The word diff of two texts: runs kept, removed and added, in order."
  @spec text_diff(String.t(), String.t()) :: [segment()]
  def text_diff(before, after_) when is_binary(before) and is_binary(after_) do
    {b, a} = {tokens(before), tokens(after_)}

    if length(b) + length(a) > @max_tokens do
      Enum.reject([{:removed, before}, {:added, after_}], &(elem(&1, 1) == ""))
    else
      b
      |> List.myers_difference(a)
      |> Enum.map(fn {op, words} -> {kind(op), Enum.join(words)} end)
      |> semantic()
    end
  end

  defp tokens(text),
    do: Regex.scan(~r/\s+|[\p{L}\p{N}_]+|[^\s\p{L}\p{N}_]/u, text) |> List.flatten()

  defp kind(:eq), do: :same
  defp kind(:del), do: :removed
  defp kind(:ins), do: :added

  # diff-match-patch's semantic cleanup, as TanStack's textDiff runs it: a
  # kept run no longer than the edits on both sides of it becomes part of
  # them, so "Short excerpt for post 24." to "Changed for review." reads as
  # one removal and one addition, not word by word. Repeated until nothing
  # more folds; each pass removes a kept run, so it ends.
  defp semantic(segments) do
    segments = merge(segments)

    case fold(segments) do
      ^segments -> segments
      folded -> semantic(folded)
    end
  end

  defp fold(segments) do
    groups = Enum.chunk_by(segments, &(elem(&1, 0) == :same)) |> List.to_tuple()
    last = tuple_size(groups) - 1
    edits = fn i -> if i < 0 or i > last, do: 0, else: edit_size(elem(groups, i)) end

    hit =
      Enum.find(0..last//1, fn i ->
        case elem(groups, i) do
          [{:same, s}] -> String.length(s) <= min(edits.(i - 1), edits.(i + 1))
          _ -> false
        end
      end)

    case hit do
      nil ->
        segments

      i ->
        [{:same, s}] = elem(groups, i)

        groups
        |> put_elem(i, [{:removed, s}, {:added, s}])
        |> Tuple.to_list()
        |> Enum.concat()
    end
  end

  # The larger of a group's removed and added text; 0 for a kept run.
  defp edit_size([{:same, _}]), do: 0

  defp edit_size(group) do
    {r, a} = split(group)
    max(String.length(r), String.length(a))
  end

  defp split(segs) do
    {Enum.map_join(segs, &if(elem(&1, 0) == :removed, do: elem(&1, 1), else: "")),
     Enum.map_join(segs, &if(elem(&1, 0) == :added, do: elem(&1, 1), else: ""))}
  end

  # Neighbouring runs of one kind are one run; removals before additions.
  defp merge(segments) do
    segments
    |> Enum.reject(&(elem(&1, 1) == ""))
    |> Enum.chunk_by(&(elem(&1, 0) == :same))
    |> Enum.flat_map(fn
      [{:same, _} | _] = same -> [{:same, Enum.map_join(same, &elem(&1, 1))}]
      changed -> changed |> split() |> then(fn {r, a} -> [{:removed, r}, {:added, a}] end)
    end)
    |> Enum.reject(&(elem(&1, 1) == ""))
  end

  # ── Lists ───────────────────────────────────────────────────────────────

  @doc """
  A list's change, as Sanity's array diff: each item of `after_` in order,
  `:added`, `:moved` or `:kept`, then each item of `before` that is gone,
  `:removed`. Kept items are those in the longest common run of both.
  """
  @spec array_diff(list(), list()) :: [{term(), :added | :removed | :moved | :kept}]
  def array_diff(before, after_) when is_list(before) and is_list(after_) do
    {b, a} = {keys(before), keys(after_)}
    {in_b, in_a} = {MapSet.new(b), MapSet.new(a)}
    stay = stay(Enum.filter(b, &(&1 in in_a)), Enum.filter(a, &(&1 in in_b)))

    shown =
      Enum.zip_with(after_, a, fn item, k ->
        cond do
          k not in in_b -> {item, :added}
          k in stay -> {item, :kept}
          true -> {item, :moved}
        end
      end)

    gone = for {item, k} <- Enum.zip(before, b), k not in in_a, do: {item, :removed}
    shown ++ gone
  end

  def array_diff(before, after_), do: array_diff(List.wrap(before), List.wrap(after_))

  defp keys(items) do
    {keys, _seen} =
      Enum.map_reduce(items, %{}, fn item, seen ->
        own =
          case item do
            %{"_key" => k} when is_binary(k) -> "k:" <> k
            other -> "v:" <> inspect(other)
          end

        n = Map.get(seen, own, 0)
        {if(n == 0, do: own, else: "#{own}##{n}"), Map.put(seen, own, n + 1)}
      end)

    keys
  end

  # The keys of the longest common subsequence of two key lists.
  defp stay(kb, ka) do
    kb
    |> List.myers_difference(ka)
    |> Enum.flat_map(fn
      {:eq, k} -> k
      _ -> []
    end)
    |> MapSet.new()
  end

  # ── Rich text ───────────────────────────────────────────────────────────

  @doc "Whether a value is a list of rich-text blocks (Portable Text or PortableDoc)."
  @spec blocks?(term()) :: boolean()
  def blocks?([_ | _] = list),
    do: Enum.all?(list, &(is_map(&1) and (is_binary(&1["_type"]) or is_binary(&1["type"]))))

  def blocks?(_value), do: false

  @typedoc "A changed block: how it changed, how it is drawn, its text's diff."
  @type block_change :: %{
          kind: :added | :removed | :changed | :formatted,
          tag: String.t(),
          segments: [segment()]
        }

  @doc """
  Rich text's change, as Sanity draws it: only the blocks that changed, in
  their own style (`tag/1`: a heading, a quote, a list item, a paragraph),
  each with the word diff of its text. A block is matched by its `_key`
  (else its place); one whose text is the same but its marks are not has
  `:formatted`.
  """
  @spec blocks_diff(term(), term()) :: [block_change()]
  def blocks_diff(before, after_) do
    {before, after_} = {List.wrap(before), List.wrap(after_)}
    by_key = Map.new(Enum.with_index(before), fn {b, i} -> {block_key(b, i), b} end)
    after_keys = MapSet.new(Enum.with_index(after_), fn {b, i} -> block_key(b, i) end)

    now =
      for {block, i} <- Enum.with_index(after_),
          change = block_change(by_key[block_key(block, i)], block),
          do: change

    gone =
      for {block, i} <- Enum.with_index(before),
          block_key(block, i) not in after_keys,
          do: %{kind: :removed, tag: tag(block), segments: [{:removed, block_text(block)}]}

    now ++ gone
  end

  defp block_change(nil, block),
    do: %{kind: :added, tag: tag(block), segments: [{:added, block_text(block)}]}

  defp block_change(was, block) do
    {t0, t1} = {block_text(was), block_text(block)}

    cond do
      same?(was, block) -> nil
      t0 == t1 -> %{kind: :formatted, tag: tag(block), segments: [{:same, t1}]}
      true -> %{kind: :changed, tag: tag(block), segments: text_diff(t0, t1)}
    end
  end

  defp block_key(%{"_key" => k}, _i) when is_binary(k), do: k
  defp block_key(%{"id" => k}, _i) when is_binary(k), do: k
  defp block_key(_block, i), do: i

  @doc "The element a block is drawn as."
  @spec tag(map()) :: String.t()
  def tag(%{"listItem" => _}), do: "li"
  def tag(%{"type" => "list"}), do: "li"
  def tag(%{"style" => "h" <> n}) when n in ~w(1 2 3 4 5 6), do: "h" <> n
  def tag(%{"type" => "heading", "level" => n}) when n in 1..6, do: "h#{n}"
  def tag(%{"type" => "heading"}), do: "h2"
  def tag(%{"style" => "blockquote"}), do: "blockquote"
  def tag(%{"type" => t}) when t in ~w(blockquote pullquote), do: "blockquote"
  def tag(_block), do: "p"

  @doc "A block's words: its spans, its inline content, or its items."
  def block_text(%{"children" => children}) when is_list(children),
    do: Enum.map_join(children, &inline_text/1)

  def block_text(%{"content" => content}) when is_list(content),
    do: Enum.map_join(content, &inline_text/1)

  def block_text(%{"items" => items}) when is_list(items),
    do: Enum.map_join(items, "\n", &block_text/1)

  def block_text(%{"text" => text}) when is_binary(text), do: text
  def block_text(_block), do: ""

  defp inline_text(%{"text" => t}) when is_binary(t), do: t
  defp inline_text(%{"value" => t}) when is_binary(t), do: t
  defp inline_text(%{"children" => c}) when is_list(c), do: Enum.map_join(c, &inline_text/1)
  defp inline_text(%{"content" => c}) when is_list(c), do: Enum.map_join(c, &inline_text/1)
  defp inline_text(_node), do: ""

  # ── Authors ─────────────────────────────────────────────────────────────

  @doc """
  Who changed each field: `snapshots` are `{who, values}` pairs, newest
  first, ending with the version the draft started from. A field is
  credited to the author of every snapshot where it differs from the one
  before it.
  """
  @spec authors([{String.t(), map()}]) :: %{optional(String.t()) => [String.t()]}
  def authors(snapshots) do
    snapshots
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(%{}, fn [{who, now}, {_, before}], acc ->
      Map.keys(now)
      |> Enum.concat(Map.keys(before))
      |> Enum.uniq()
      |> Enum.reject(&String.starts_with?(&1, "_"))
      |> Enum.reject(&same?(now[&1], before[&1]))
      |> Enum.reduce(acc, fn k, acc -> Map.update(acc, k, [who], &Enum.uniq(&1 ++ [who])) end)
    end)
  end
end
