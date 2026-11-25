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

  alias Barkpark.Content.DiffMatchPatch
  alias Barkpark.Content.DiffMatchPatch.Make

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
  @max_changed_units 700

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
  @spec rebase(map(), map(), map(), map()) :: map()
  #
  # A key may be a path into an object (`["meta", "label"]`,
  # task-71ff11d4e7374985): the subfield is merged as a top-level field is.
  #
  # `seen` (task-5b8f13c40a052514): per field, the value the tab believed
  # the store held when it posted. A field with no base from the page is
  # merged from it. Where the store moved from it, another tab's save landed
  # under this post, unseen: an overlap keeps the store, never `ours` over
  # words this tab was never shown (the caller holds the post with the
  # banner). Where the store still holds it, an overlap is `ours`, as
  # before: the tab was told, and typed on.
  def rebase(params, bases, current, seen \\ %{})

  def rebase(params, bases, current, seen) when is_map(params) and is_map(bases) do
    seen = if is_map(seen), do: seen, else: %{}

    Enum.reduce(Map.keys(bases) ++ (Map.keys(seen) -- Map.keys(bases)), params, fn key, acc ->
      base = Map.get(bases, key, Map.get(seen, key))

      with posted when is_binary(posted) <- at(acc, key),
           stored when is_binary(stored) <- at(current, key),
           true <- is_binary(base) and stored != base and posted != stored,
           true <- Enum.all?([base, posted, stored], &(byte_size(&1) <= @max_bytes)) do
        put(acc, key, onto(base, posted, stored, is_map_key(seen, key) and seen[key] != stored))
      else
        _ -> acc
      end
    end)
  end

  def rebase(params, _bases, _current, _seen), do: params

  defp onto(base, posted, stored, false), do: merge3(base, posted, stored)
  defp onto(base, base, stored, true), do: stored

  defp onto(base, posted, stored, true),
    do:
      merge_splices(String.graphemes(base), String.graphemes(posted), String.graphemes(stored)) ||
        stored

  defp at(map, [key]) when is_map(map), do: Map.get(map, key)

  defp at(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      %{} = inner when not is_struct(inner) -> at(inner, rest)
      _ -> nil
    end
  end

  defp at(map, key) when is_map(map), do: Map.get(map, key)
  defp at(_map, _key), do: nil

  # Only called where `at/2` found a string, so every map on the path is there.
  defp put(map, [key], value), do: Map.put(map, key, value)

  defp put(map, [key | rest], value),
    do: Map.put(map, key, put(Map.fetch!(map, key), rest, value))

  defp put(map, key, value), do: Map.put(map, key, value)

  @doc false
  def max_bytes, do: @max_bytes

  @doc """
  `merge3/3` that gives nil, not `ours`, where the two changes cannot both
  apply (they overlap, or a value is over the size bound). The desk's undo
  (`BarkparkWeb.Studio.Desk.DocUndo`) takes one of this editor's changes
  back out of the stored text with it, and leaves the text as it is rather
  than take another editor's words with it.
  """
  @spec merge3_both(String.t(), String.t(), String.t()) :: String.t() | nil
  def merge3_both(base, ours, theirs)
      when is_binary(base) and is_binary(ours) and is_binary(theirs) do
    cond do
      ours == base or ours == theirs ->
        theirs

      theirs == base ->
        ours

      Enum.any?([base, ours, theirs], &(byte_size(&1) > @max_bytes)) ->
        nil

      true ->
        merge_splices(String.graphemes(base), String.graphemes(ours), String.graphemes(theirs))
    end
  end

  @doc """
  The conflict decision for words not yet saved under another editor's save
  (`Handlers.Lifecycle`): `merge3_both/3`, and nil also where TanStack's
  `merge3` (barkpark-studio merge.ts) gives null. That one makes `ours` into
  a diff-match-patch patch and applies it to `theirs`, placing each hunk by
  the text around it; a hunk with nowhere to go (the text it was typed next
  to was cleared or rewritten) is a clash, not words kept on their own
  (task-881f16e32fffbe9a). A text too big to decide in a fraction of a
  second is a clash too. The desk's undo keeps `merge3_both/3`.
  """
  @spec merge3_clash(String.t(), String.t(), String.t()) :: String.t() | nil
  def merge3_clash(base, ours, theirs)
      when is_binary(base) and is_binary(ours) and is_binary(theirs) do
    with merged when is_binary(merged) <- merge3_both(base, ours, theirs) do
      if places?(base, ours, theirs), do: merged
    end
  end

  defp places?(base, ours, theirs) when ours == base or ours == theirs or theirs == base,
    do: true

  # Too big to decide quickly is not placed: a clash, the banner. The port
  # has no deadline (TanStack's diff stops at a second), so it is not run on
  # a text over `apply/2`'s unit limit or a change from `base` to `ours` over
  # `@max_changed_units`, and `Make.text/2` gives up past
  # `Make.max_diffs/0` diff parts. A refusal by `apply/2` is not placed
  # either. A held field in a text over the unit limit is therefore a clash
  # under every remote save; the banner keeps its words, and the save path
  # still merges its next post.
  defp places?(base, ours, theirs) do
    {base, ours} = {units(base), units(ours)}
    limit = DiffMatchPatch.limits().text_units

    if Enum.any?([base, ours, units(theirs)], &(length(&1) > limit)) or
         changed_units(base, ours) > @max_changed_units do
      false
    else
      with patch when is_binary(patch) <- Make.text(base, ours),
           {:ok, _text, applied} <- DiffMatchPatch.apply(patch, theirs) do
        Enum.all?(applied)
      else
        _too_big_or_refused -> false
      end
    end
  end

  # The units between the common prefix and the common suffix.
  defp changed_units(a, b) do
    prefix = common_prefix(a, b, 0)
    {a, b} = {Enum.drop(a, prefix), Enum.drop(b, prefix)}
    suffix = common_prefix(Enum.reverse(a), Enum.reverse(b), 0)
    max(length(a), length(b)) - suffix
  end

  defp units(string) do
    bin = :unicode.characters_to_binary(string, :utf8, {:utf16, :big})
    for <<u::16 <- bin>>, do: u
  end

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
