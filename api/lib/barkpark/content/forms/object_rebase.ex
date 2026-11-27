defmodule Barkpark.Content.Forms.ObjectRebase do
  @moduledoc """
  An object field's edit written subfield by subfield (task-04e50efa8405b956).
  A row's rich text, in an array at the top level or in an object, is read
  the same way, matched to the store's row by `_key` (task-2dce62676ad14c3c).

  A post carries every subfield of an object, so one that left the page
  before another editor's save carries that editor's subfields at their old
  values. The top-level rule of a save (`Forms.classic_save_content/7`) one
  level down: a subfield the post did not change from `base` (the row the
  form was drawn from) takes what `theirs` (the store now, or the form
  buffer) holds, and only a changed one is written. TanStack writes one path
  per change, so a sibling another editor saved is never written over.

  `mine` is the post after `Forms.edits/3`: an untouched subfield there is
  exactly the base's value (`restore_untouched`), so the test is `===`.

  A `richText` subfield that both the post and the store changed since
  `base` is merged block by block (`PortableTextMerge`, #28349 r4 SV1): a
  post can reach the server before its tab is told of another editor's save
  of the same text, so the tab could not hold it.

  `seen` maps a rich text's path to the value the tab believed the store
  held when it read the post (`RichTextRemote`, task-00c56c6a88ed0b8f). Read
  here, under the document's lock: the store still holds it, and the post
  is written as the tab read it; the store moved on, and the post is merged
  onto the store from it, and a clash keeps the store (the tab holds its
  words with the banner). Two tabs typing in one word wrote the later post
  over the earlier with no word. A Studio post with no `_bp_rt_seen` (a page
  without bp-rt-remote.js) is given `seen` from the value that page shows
  (`UnderLock.values/3`, task-0437fdf2f2a6ccba). A rich text with no
  `seen` here (another caller) is merged from `base`, and a clash is
  written as posted, as before.
  """

  alias Barkpark.Content.Forms.HtmlBody
  alias Barkpark.Content.PortableTextMerge

  @doc """
  `params` with each object field rebased onto `theirs`. Only a field the
  schema calls `composite`, held as an object in all three, is touched, and
  the rich text of an `arrayOf` row, held as a list in all three.
  """
  @spec onto(map(), map(), map(), map() | nil, map()) :: map()
  def onto(params, base, theirs, schema, seen \\ %{})

  def onto(params, base, theirs, %{fields: fields}, seen) when is_list(fields) do
    fields
    |> rebase(params, base, theirs, {seen, []})
    |> top_rich(fields, base, theirs, seen)
  end

  def onto(params, _base, _theirs, _schema, _seen), do: params

  defp rebase(fields, mine, base, theirs, {seen, at}) do
    Enum.reduce(fields, mine, fn
      %{"name" => key, "type" => "composite"} = field, acc when is_binary(key) ->
        case {Map.fetch(acc, key), Map.get(base, key), Map.get(theirs, key)} do
          {{:ok, %{} = m}, %{} = b, %{} = t}
          when not is_struct(m) and not is_struct(b) and not is_struct(t) ->
            Map.put(acc, key, object(field, m, b, t, {seen, at ++ [key]}))

          _ ->
            acc
        end

      # A row's rich text (task-2dce62676ad14c3c): the array was written as
      # posted, over a row text another editor saved under the post.
      %{"name" => key, "type" => "arrayOf"} = field, acc when is_binary(key) ->
        case {Map.fetch(acc, key), Map.get(base, key), Map.get(theirs, key)} do
          {{:ok, m}, b, t} when is_list(m) and is_list(b) and is_list(t) ->
            Map.put(acc, key, rows(field, m, b, t, {seen, at ++ [key]}))

          _ ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  # Each posted row with a `_key` the store still holds: its rich text
  # subfields read as an object's are, onto the store's row of that key.
  # The row's other subfields, its order and the rows themselves are
  # written as posted, as before.
  #
  # Only when every row's `_key` is unique in all three (as `Forms`'
  # `keyed_rows?`): two rows of one key matched the first for both, and the
  # second's text was written over (#28898 r1 review, D1).
  defp rows(field, mine, base, theirs, {seen, at}) do
    if unique_keys?(mine) and unique_keys?(base) and unique_keys?(theirs),
      do: keyed_rows(field, mine, base, theirs, {seen, at}),
      else: mine
  end

  defp unique_keys?(rows) do
    keys = for %{"_key" => k} <- rows, do: k
    length(keys) == length(Enum.uniq(keys))
  end

  defp keyed_rows(field, mine, base, theirs, {seen, at}) do
    mine
    |> Enum.with_index()
    |> Enum.map(fn {row, i} ->
      with %{"_key" => k} when is_binary(k) <- row,
           false <- is_struct(row),
           %{} = t <- by_key(theirs, k),
           [_ | _] = rich <- rich_subs(field["of"], row) do
        b = by_key(base, k) || %{}
        Enum.reduce(rich, row, &row_text(&1, &2, b, t, {seen, at ++ [i, &1]}))
      else
        _ -> row
      end
    end)
  end

  defp row_text(name, row, base, theirs, {seen, path}) do
    case Map.fetch(row, name) do
      {:ok, value} ->
        if Map.has_key?(base, name) and value === Map.fetch!(base, name),
          do: put_theirs(row, name, theirs),
          else:
            Map.put(row, name, rich_text(base[name], value, theirs[name], Map.fetch(seen, path)))

      :error ->
        row
    end
  end

  # Untouched by the post: the store's row text, or none when it has none.
  defp put_theirs(row, name, theirs) do
    case Map.fetch(theirs, name) do
      {:ok, value} -> Map.put(row, name, value)
      :error -> Map.delete(row, name)
    end
  end

  defp by_key(rows, key), do: Enum.find(rows, &(is_map(&1) and Map.get(&1, "_key") == key))

  defp rich_subs(of, row) do
    of = if is_list(of), do: of, else: [of]
    type = Map.get(row, "_type")

    case Enum.find(
           of,
           &(is_map(&1) and (&1["name"] == type or (is_nil(type) and length(of) == 1)))
         ) do
      %{"fields" => subs} when is_list(subs) ->
        for %{"name" => n, "type" => "richText"} when is_binary(n) <- subs, do: n

      _ ->
        []
    end
  end

  # A top-level rich text the post changed, with what the page showed
  # (`seen`, `UnderLock.top/3`), task-fa07c64d344638fb: read as an object's
  # is. Two tabs typing in it wrote the later post over the earlier with no
  # word. With no `seen` it is written as posted, as before. A body the
  # store holds as an HTML string is posted as one, and read as one
  # (`HtmlBody`, task-bb19ab06ab1e87b2). A Portable Text field the store
  # holds as a string is posted as blocks, and read as such a body is
  # (`HtmlBody.stored_string?/2`, task-49a96a7780dad558).
  defp top_rich(params, fields, base, theirs, seen) do
    Enum.reduce(fields, params, fn
      %{"name" => key, "type" => "richText"} = field, acc when is_binary(key) ->
        case {Map.fetch(seen, [key]), Map.fetch(acc, key), theirs[key]} do
          {{:ok, was}, {:ok, mine}, stored} when is_list(mine) ->
            cond do
              not HtmlBody.stored_string?(field, stored) ->
                Map.put(acc, key, rich_text(base[key], mine, theirs[key], {:ok, was}))

              HtmlBody.rebase(mine, stored, was) === mine ->
                acc

              # The store's string stays as stored: the field is left out
              # of the write (`Content.Forms` keeps a stored key the post
              # does not carry), and A is held (`UnderLock`).
              true ->
                Map.delete(acc, key)
            end

          {{:ok, was}, {:ok, mine}, stored} when is_binary(mine) ->
            if HtmlBody.field?(field, stored),
              do: Map.put(acc, key, HtmlBody.rebase(mine, stored, was)),
              else: acc

          _ ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  defp object(field, mine, base, theirs, {seen, at}) do
    subs = if is_list(field["fields"]), do: field["fields"], else: []

    rich = for %{"name" => n, "type" => "richText"} <- subs, into: MapSet.new(), do: n

    kept =
      Enum.reduce(mine, theirs, fn {key, value}, acc ->
        cond do
          Map.has_key?(base, key) and value === Map.fetch!(base, key) ->
            acc

          MapSet.member?(rich, key) ->
            Map.put(
              acc,
              key,
              rich_text(base[key], value, theirs[key], Map.fetch(seen, at ++ [key]))
            )

          true ->
            Map.put(acc, key, value)
        end
      end)

    # A subfield the post took off that nobody else changed goes; one
    # another editor changed or added stays theirs.
    kept =
      Enum.reduce(theirs, kept, fn {key, value}, acc ->
        if not Map.has_key?(mine, key) and Map.has_key?(base, key) and
             value === Map.fetch!(base, key),
           do: Map.delete(acc, key),
           else: acc
      end)

    # A changed object subfield is itself written subfield by subfield; an
    # untouched one is theirs already, and rebasing it changes nothing.
    rebase(subs, kept, base, theirs, {seen, at})
  end

  # What the tab believed stored: the store still holds it, or the post is
  # merged onto the store from it, and a clash keeps the store. "Still
  # holds" counts each block's own fields (task-6174d8fa01658a68): a
  # `level` or unknown field another editor set draws the same, and mine
  # was written over it.
  # A row post whose draw is not known (`UnderLock`, task-82519fd79663e072):
  # the store is kept unless the post draws the same; A is held.
  defp rich_text(_base, mine, theirs, {:ok, :unknown}) when is_list(mine) do
    if is_list(theirs) and not PortableTextMerge.same_drawn?(mine, theirs),
      do: theirs,
      else: mine
  end

  defp rich_text(_base, mine, theirs, {:ok, was}) when is_list(mine) do
    theirs = if is_list(theirs), do: theirs, else: []
    was = if is_list(was), do: was, else: []

    if PortableTextMerge.same_shape?(was, theirs) do
      mine
    else
      case PortableTextMerge.merge(was, mine, theirs) do
        {:ok, merged} -> merged
        {:clash, _texts, _view} -> theirs
      end
    end
  end

  defp rich_text(base, mine, theirs, _seen)
       when is_list(base) and is_list(mine) and is_list(theirs) and theirs !== base do
    case PortableTextMerge.merge(base, mine, theirs) do
      {:ok, merged} -> merged
      {:clash, _texts, _view} -> mine
    end
  end

  defp rich_text(_base, mine, _theirs, _seen), do: mine
end
