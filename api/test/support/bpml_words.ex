defmodule Barkpark.Test.BpmlWords do
  @moduledoc """
  The words check two BPML tests share (`EveryFixtureWordsTest` and
  `BpmlCalloutBodyTest`): a document printed with `Bpml.print_blocks/1` (not
  the reader's view) and read back with `Bpml.parse_copy_blocks/1` keeps every
  word it holds, as many times as it holds it.

  Words are counted per document, from the strings of the source blocks and
  from the strings of the PARSED printout, so a word that survives elsewhere,
  or only in the markup, cannot stand in for one that was dropped. A word may
  be missing only when its field is on the caller's skip table; every skip
  that hides a word is reported, so callers pin them. A top-level block printed
  as `<kept>` shows none of its words: it is left out of both counts and
  reported, so callers pin those too.

  A list typed by an alias the printer reads as a list (`ListItems.alias_kind/1`,
  the table the printer and parser use) is counted as a `list`, on both sides:
  the alias is its type's other name, not a word the document holds.
  """

  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.PortableDoc.Bpml.ListItems

  @word ~r/[\p{L}\p{N}]+/u

  @doc """
  `%{missing: [{word, in_source, in_printout}], skips: [field], kept: [{id, why}]}`
  for `blocks`. `skipped` maps `{type, field}` to why its words may be missing.
  Raises what `print_blocks/1` raises.
  """
  def check(blocks, skipped) do
    bpml = Bpml.print_blocks(blocks)
    {:ok, parsed} = Bpml.parse_copy_blocks(bpml)
    kept = for %{"type" => "$kept", "id" => id, "why" => why} <- parsed, do: {id, why}
    kept_ids = MapSet.new(kept, &elem(&1, 0))

    {source, skips} =
      blocks |> Enum.reject(&MapSet.member?(kept_ids, &1["id"])) |> count(skipped)

    {printout, _} = parsed |> Enum.reject(&(&1["type"] == "$kept")) |> count(skipped)

    missing =
      for {word, n} <- source, Map.get(printout, word, 0) < n, do: {word, n, printout[word] || 0}

    %{missing: Enum.sort(missing), skips: skips |> Enum.uniq() |> Enum.sort(), kept: kept}
  end

  defp count(blocks, skipped) do
    {counts, skips} = walk(blocks, "doc", nil, skipped, {%{}, []})
    {counts, skips}
  end

  defp walk(%{} = map, owner, _key, skipped, acc) do
    map = own_type(map)
    owner = if is_binary(map["type"]), do: map["type"], else: owner
    Enum.reduce(map, acc, fn {k, v}, acc -> walk(v, owner, k, skipped, acc) end)
  end

  defp walk(list, owner, key, skipped, acc) when is_list(list),
    do: Enum.reduce(list, acc, &walk(&1, owner, key, skipped, &2))

  defp walk(value, owner, key, skipped, {counts, skips}) when is_binary(value) do
    words = Regex.scan(@word, value)

    cond do
      words == [] ->
        {counts, skips}

      Map.has_key?(skipped, {owner, key}) ->
        {counts, ["#{owner}.#{key}" | skips]}

      true ->
        {Enum.reduce(words, counts, fn [w], c -> Map.update(c, w, 1, &(&1 + 1)) end), skips}
    end
  end

  defp walk(_value, _owner, _key, _skipped, acc), do: acc

  defp own_type(%{"type" => type} = map) do
    if ListItems.list?(map) and ListItems.alias_kind(type) != nil,
      do: %{map | "type" => "list"},
      else: map
  end

  defp own_type(map), do: map
end
