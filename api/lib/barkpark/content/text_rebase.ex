defmodule Barkpark.Content.TextRebase do
  @moduledoc """
  Puts one editor's text change on top of another's (task-e6ef964ac2e41d5a).

  An editor that posts a text field written from an older value (`base`)
  than the one the store now holds (`theirs`) would replace the other
  editor's words with its own (`ours`). `merge3/3` keeps both changes
  instead.

  Each side's change is one splice of `base`: the longest common prefix and
  suffix stay, the middle is replaced. Two splices that do not touch each
  other both apply. Two inserts at the same point keep `theirs` first, as it
  was saved first. Two splices that overlap keep the text of both over the
  span they cover, `theirs` then `ours`: odd to read, but nothing either
  editor wrote is lost, and the result shows in both editors.

  Text is split into graphemes, so a splice never cuts a letter from its
  accent or an emoji in half.
  """

  @doc """
  The text with both changes. `ours` when `theirs` did not change `base`,
  `theirs` when `ours` did not.
  """
  @spec merge3(String.t(), String.t(), String.t()) :: String.t()
  def merge3(base, ours, theirs)
      when is_binary(base) and is_binary(ours) and is_binary(theirs) do
    cond do
      ours == base or ours == theirs ->
        theirs

      theirs == base ->
        ours

      true ->
        merge_splices(String.graphemes(base), String.graphemes(ours), String.graphemes(theirs))
    end
  end

  @doc """
  Rebases each posted text field named in `bases` onto the stored value.

  `params` is the posted form (field key => value). `bases` maps a field key
  to the values the post may have been written from, oldest first: the values
  that editor was told of since it last posted the field, and the one its own
  last save left. `current` maps a field key to the value the store holds now.

  The post was written from the value it is nearest to (the smallest splice
  turns that value into the post). When that is the stored value, the post
  stands. When it is an older one, the post is merged onto the stored value
  with `merge3/3`; a post equal to an older value (a field the editor did not
  touch) keeps the stored value. On a tie the older value wins: a merge may
  repeat words, never drop them. A field whose posted or stored value is not
  a string is left alone.
  """
  @spec rebase(map(), map(), map()) :: map()
  def rebase(params, bases, current) when is_map(params) and is_map(bases) do
    Enum.reduce(bases, params, fn {key, candidates}, acc ->
      with posted when is_binary(posted) <- Map.get(acc, key),
           stored when is_binary(stored) <- Map.get(current, key),
           older = for(c <- List.wrap(candidates), is_binary(c) and c != stored, do: c),
           true <- older != [] and posted != stored,
           base = nearest(posted, older ++ [stored]),
           true <- base != stored do
        Map.put(acc, key, merge3(base, posted, stored))
      else
        _ -> acc
      end
    end)
  end

  def rebase(params, _bases, _current), do: params

  defp nearest(posted, candidates) do
    text = String.graphemes(posted)

    Enum.min_by(candidates, fn candidate ->
      {start, stop, inserted} = splice(String.graphemes(candidate), text)
      stop - start + length(inserted)
    end)
  end

  defp merge_splices(base, ours, theirs) do
    {os, oe, oins} = splice(base, ours)
    {ts, te, tins} = splice(base, theirs)

    cond do
      # Both insert at the same point: theirs was saved first.
      os == oe and ts == te and os == ts ->
        join([slice(base, 0, ts), tins, oins, slice(base, ts, length(base))])

      oe <= ts ->
        join([slice(base, 0, os), oins, slice(base, oe, ts), tins, slice(base, te, length(base))])

      te <= os ->
        join([slice(base, 0, ts), tins, slice(base, te, os), oins, slice(base, oe, length(base))])

      true ->
        s = min(os, ts)
        e = max(oe, te)
        theirs_span = [slice(base, s, ts), tins, slice(base, te, e)]
        ours_span = [slice(base, s, os), oins, slice(base, oe, e)]
        join([slice(base, 0, s), theirs_span, ours_span, slice(base, e, length(base))])
    end
  end

  # The one splice that turns `base` into `text`: base[start, stop) is
  # replaced by `inserted`.
  defp splice(base, text) do
    prefix = common_prefix(base, text, 0)
    max_suffix = min(length(base), length(text)) - prefix
    suffix = common_prefix(Enum.reverse(base), Enum.reverse(text), 0) |> min(max_suffix)
    inserted = slice(text, prefix, length(text) - suffix)
    {prefix, length(base) - suffix, inserted}
  end

  defp common_prefix([g | a], [g | b], n), do: common_prefix(a, b, n + 1)
  defp common_prefix(_a, _b, n), do: n

  defp slice(list, from, to) when to > from, do: Enum.slice(list, from, to - from)
  defp slice(_list, _from, _to), do: []

  defp join(parts), do: parts |> List.flatten() |> Enum.join()
end
