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
  was saved first. When `theirs` is an insert at an edge of `ours`' splice
  and `ours` already holds that insert there, the page had it, and `ours`
  stands. Two splices that overlap give `ours`,
  the last post, as before this module: keeping the text of both brought back
  words either side had deleted (#25994 review).

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
        merge_splices(String.graphemes(base), String.graphemes(ours), String.graphemes(theirs)) ||
          ours
    end
  end

  # Above this many bytes in any of the three values, a post stands as sent
  # (last post wins, as before this module): a merge of a 1 MB field took 2 s
  # inside the document's patch lock (#25908 review).
  @max_bytes 65_536

  @doc """
  Rebases each posted text field named in `bases` onto the stored value.

  `params` is the posted form (field key => value). `bases` maps a free-text
  field key to the ONE value the page reports it edited from
  (`BarkparkWeb.Studio.StudioLive.Handlers.RemoteValues.bases/3`). `current`
  maps a field key to the value the store holds now.

  When the stored value is still the base, the post is left as sent: the page
  edited from what the store holds. When the store moved on from the base,
  the post is merged onto the stored value with `merge3/3`, so a post that
  left the field as its base keeps the stored value, and one that changed it
  keeps both changes. A field
  whose base, posted or stored value is not a string, or is larger than
  #{@max_bytes} bytes, is left alone.
  """
  @spec rebase(map(), map(), map()) :: map()
  def rebase(params, bases, current) when is_map(params) and is_map(bases) do
    Enum.reduce(bases, params, fn {key, base}, acc ->
      with posted when is_binary(posted) <- Map.get(acc, key),
           stored when is_binary(stored) <- Map.get(current, key),
           true <- is_binary(base) and stored != base and posted != stored,
           true <- Enum.all?([base, posted, stored], &(byte_size(&1) <= @max_bytes)) do
        Map.put(acc, key, merge3(base, posted, stored))
      else
        _ -> acc
      end
    end)
  end

  def rebase(params, _bases, _current), do: params

  @doc false
  def max_bytes, do: @max_bytes

  # The merged text, or nil when the two splices overlap (the caller keeps
  # `ours`).
  defp merge_splices(base, ours, theirs) do
    {os, oe, oins} = splice(base, ours)
    {ts, te, tins} = splice(base, theirs)

    cond do
      # Theirs inserts at an edge of ours' splice, and ours already holds that
      # insert there: the page had it, from a base older than it showed.
      ts == te and
          ((ts == os and Enum.take(oins, length(tins)) == tins) or
             (ts == oe and Enum.take(oins, -length(tins)) == tins)) ->
        nil

      # Both insert at the same point: theirs was saved first.
      os == oe and ts == te and os == ts ->
        join([slice(base, 0, ts), tins, oins, slice(base, ts, length(base))])

      oe <= ts ->
        join([slice(base, 0, os), oins, slice(base, oe, ts), tins, slice(base, te, length(base))])

      te <= os ->
        join([slice(base, 0, ts), tins, slice(base, te, os), oins, slice(base, oe, length(base))])

      true ->
        nil
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
