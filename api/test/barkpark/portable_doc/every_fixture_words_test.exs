defmodule Barkpark.PortableDoc.EveryFixtureWordsTest do
  @moduledoc """
  Every shared Portable Doc fixture, printed as BPML, keeps every word it holds.

  The documents are the paper editor's shared fixture walk (`sharedFixtureWalk` in
  `assets/paper-editor/src/__source_wall_goldens.mjs`), read through node by
  `test/support/shared_fixture_documents.mjs`: the same documents the source-mode wall
  is measured on, found by the shape of each file under the goldens root rather than
  by a list kept here. node is required; a missing node is a failure, not a skip.

  Each document either prints, and then every word of every string it holds appears
  in the printout, or the printer refuses it with the reason `@refused` names. A
  document that starts or stops being refused fails by name, so the table only
  changes on purpose. A word may be missing only when its field is on `@skipped`,
  which says why.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.PortableDoc.Bpml.UnprintableError

  @script Path.expand("../../support/shared_fixture_documents.mjs", __DIR__)

  # Document name => the printer's refusal, as "kind:type".
  @refused %{}

  # {block type, field} => why the printout may lack that field's words. `type` is
  # spelled by the tag, not as a word.
  @skipped %{
    {:any, "type"} => "the block type is spelled by its tag",
    {"callout", "text"} => "the callout's text field is printed by task-04de6fc749b11380"
  }

  setup_all do
    node = System.find_executable("node") || flunk("node is required for this test")
    {out, 0} = System.cmd(node, [@script], stderr_to_stdout: true)
    [head | lines] = String.split(out, "\n", trim: true)
    walk = Jason.decode!(head)
    docs = Enum.map(lines, &Jason.decode!/1)
    outcomes = Map.new(docs, fn %{"name" => n, "blocks" => blocks} -> {n, print(blocks)} end)
    %{walk: walk, docs: docs, outcomes: outcomes}
  end

  defp print(blocks) do
    {:printed, Bpml.print_blocks(blocks)}
  rescue
    e in UnprintableError -> {:refused, "#{e.kind}:#{e.type}"}
  end

  test "the walk reads every fixture file and finds documents", %{walk: walk, docs: docs} do
    assert walk["unread"] == []
    assert walk["skippedDocuments"] == []
    assert walk["count"] == length(docs)
    assert docs != []
  end

  test "each document prints, or is refused for the reason the table names",
       %{outcomes: outcomes} do
    actual = for {name, {:refused, why}} <- outcomes, into: %{}, do: {name, why}
    differing =
      for name <- Map.keys(Map.merge(actual, @refused)),
          actual[name] != @refused[name],
          do: {name, expected: @refused[name], actual: actual[name]}

    assert Enum.sort(differing) == []

    IO.puts(
      "every-fixture words: #{map_size(outcomes)} documents, " <>
        "#{map_size(outcomes) - map_size(actual)} printed, #{map_size(actual)} refused as expected"
    )
  end

  test "every word of a printed document appears in its printout",
       %{docs: docs, outcomes: outcomes} do
    missing =
      for %{"name" => name, "blocks" => blocks} <- docs,
          {:printed, bpml} <- [outcomes[name]],
          {field, word} <- words(blocks),
          not String.contains?(bpml, word),
          uniq: true,
          do: {name, field, word}

    assert Enum.take(missing, 40) == []
  end

  test "no callout is refused, and the callout golden prints", %{docs: docs, outcomes: outcomes} do
    callouts = for %{"name" => name, "blocks" => blocks} <- docs, callout?(blocks), do: name
    refused = for name <- callouts, match?({:refused, _}, outcomes[name]), do: name

    assert refused == []
    assert "blocks/callout" in callouts
    assert match?({:printed, _}, outcomes["blocks/callout"])
  end

  # {"type.field", word} for every word of every string the blocks hold, minus the
  # fields on @skipped. The type is the nearest enclosing map's `type`.
  defp words(blocks), do: words(blocks, "doc", nil, [])

  defp words(value, owner, _key, acc) when is_map(value) do
    owner = if is_binary(value["type"]), do: value["type"], else: owner
    Enum.reduce(value, acc, fn {k, v}, acc -> words(v, owner, k, acc) end)
  end

  defp words(value, owner, key, acc) when is_list(value),
    do: Enum.reduce(value, acc, &words(&1, owner, key, &2))

  defp words(value, owner, key, acc) when is_binary(value) do
    if Map.has_key?(@skipped, {:any, key}) or Map.has_key?(@skipped, {owner, key}) do
      acc
    else
      ~r/[\p{L}\p{N}]+/u
      |> Regex.scan(value)
      |> Enum.reduce(acc, fn [word], acc -> [{"#{owner}.#{key}", word} | acc] end)
    end
  end

  defp words(_value, _owner, _key, acc), do: acc

  defp callout?(value) when is_map(value),
    do: value["type"] == "callout" or Enum.any?(Map.values(value), &callout?/1)

  defp callout?(value) when is_list(value), do: Enum.any?(value, &callout?/1)
  defp callout?(_value), do: false
end
