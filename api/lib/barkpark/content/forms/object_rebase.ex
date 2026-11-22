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
  of the same text, so the tab could not hold it. A clash inside one block
  is written as posted, as before; the tab's hold (`RichTextRemote`) covers
  the case it was told of.
  """

  alias Barkpark.Content.PortableTextMerge

  @doc """
  `params` with each object field rebased onto `theirs`. Only a field the
  schema calls `composite`, held as an object in all three, is touched.
  """
  @spec onto(map(), map(), map(), map() | nil) :: map()
  def onto(params, base, theirs, %{fields: fields}) when is_list(fields),
    do: rebase(fields, params, base, theirs)

  def onto(params, _base, _theirs, _schema), do: params

  defp rebase(fields, mine, base, theirs) do
    Enum.reduce(fields, mine, fn
      %{"name" => key, "type" => "composite"} = field, acc when is_binary(key) ->
        case {Map.fetch(acc, key), Map.get(base, key), Map.get(theirs, key)} do
          {{:ok, %{} = m}, %{} = b, %{} = t}
          when not is_struct(m) and not is_struct(b) and not is_struct(t) ->
            Map.put(acc, key, object(field, m, b, t))

          _ ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  defp object(field, mine, base, theirs) do
    subs = if is_list(field["fields"]), do: field["fields"], else: []

    rich = for %{"name" => n, "type" => "richText"} <- subs, into: MapSet.new(), do: n

    kept =
      Enum.reduce(mine, theirs, fn {key, value}, acc ->
        cond do
          Map.has_key?(base, key) and value === Map.fetch!(base, key) -> acc
          MapSet.member?(rich, key) -> Map.put(acc, key, rich_text(base[key], value, theirs[key]))
          true -> Map.put(acc, key, value)
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
    rebase(subs, kept, base, theirs)
  end

  defp rich_text(base, mine, theirs)
       when is_list(base) and is_list(mine) and is_list(theirs) and theirs !== base do
    case PortableTextMerge.merge(base, mine, theirs) do
      {:ok, merged} -> merged
      {:clash, _texts, _view} -> mine
    end
  end

  defp rich_text(_base, mine, _theirs), do: mine
end
