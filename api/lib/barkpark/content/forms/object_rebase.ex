defmodule Barkpark.Content.Forms.ObjectRebase do
  @moduledoc """
  An object field's edit written subfield by subfield (task-04e50efa8405b956).

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

  alias Barkpark.Content.PortableTextMerge

  @doc """
  `params` with each object field rebased onto `theirs`. Only a field the
  schema calls `composite`, held as an object in all three, is touched.
  """
  @spec onto(map(), map(), map(), map() | nil, map()) :: map()
  def onto(params, base, theirs, schema, seen \\ %{})

  def onto(params, base, theirs, %{fields: fields}, seen) when is_list(fields),
    do: rebase(fields, params, base, theirs, {seen, []})

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
