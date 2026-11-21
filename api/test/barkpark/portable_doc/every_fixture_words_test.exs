defmodule Barkpark.PortableDoc.EveryFixtureWordsTest do
  @moduledoc """
  Every shared Portable Doc fixture, printed as BPML, keeps every word it holds.

  The documents are the paper editor's shared fixture walk (`sharedFixtureWalk` in
  `assets/paper-editor/src/__source_wall_goldens.mjs`), read through node by
  `test/support/shared_fixture_documents.mjs`: the same documents the source-mode wall
  is measured on, found by the shape of each file under the goldens root rather than
  by a list kept here. node is required; a missing node is a failure, not a skip.

  Each document is printed with `Bpml.print_blocks/1`, not through the reader's view
  (`Papers.BpmlView`), and read back. It either prints, and then the words check of
  `Barkpark.Test.BpmlWords` holds for it, or the printer refuses it with the reason
  `@refused` names. A document that starts or stops being refused fails by name, and
  so does one that starts or stops printing a `<kept>` line (`@kept`), or a skip that
  starts or stops hiding words (`@skip_hits`), so these tables change only on purpose.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml.UnprintableError
  alias Barkpark.Test.BpmlWords

  @script Path.expand("../../support/shared_fixture_documents.mjs", __DIR__)

  @documents 184

  @callout_documents [
    "blocks/callout",
    "locales/en.locale-golden",
    "ops/insert-after after",
    "ops/patch-block before",
    "ops/patch-block after",
    "ops/remove-block before"
  ]

  # The walk's limit documents nest thousands of levels deep. BPML indents every
  # level, so one printout runs to tens of megabytes and minutes. Documents nested
  # deeper than @max_depth are left out of the words check, and they are exactly
  # these, by name.
  @max_depth 2000
  @too_deep [
    "limit-docs docs/nested columns",
    "limit-docs docs/nested section",
    "limit-docs docs/nested strong"
  ]

  # Document name => the printer's refusal, as "kind:type".
  @refused %{}

  # Document name => [{top-level block id, why}] for each block printed as <kept>.
  @kept %{}

  # {block type, field} => why the printout may lack that field's words.
  @skipped %{
    {"callout", "text"} => "the callout's text field is printed by task-04de6fc749b11380"
  }

  # Document name => the skipped fields that hid a word in it.
  @skip_hits %{"locales/en.locale-golden" => ["callout.text"]}

  setup_all do
    node = System.find_executable("node") || flunk("node is required for this test")
    {out, 0} = System.cmd(node, [@script], stderr_to_stdout: true)
    [head | lines] = String.split(out, "\n", trim: true)
    walk = Jason.decode!(head)
    docs = Enum.map(lines, &Jason.decode!/1)
    {deep, shallow} = Enum.split_with(docs, &(depth(&1["blocks"]) > @max_depth))
    outcomes = Map.new(shallow, fn %{"name" => n, "blocks" => blocks} -> {n, check(blocks)} end)
    %{walk: walk, docs: docs, deep: Enum.map(deep, & &1["name"]), outcomes: outcomes}
  end

  defp depth(value) when is_map(value),
    do: 1 + Enum.reduce(Map.values(value), 0, &max(depth(&1), &2))

  defp depth(value) when is_list(value), do: 1 + Enum.reduce(value, 0, &max(depth(&1), &2))
  defp depth(_value), do: 0

  defp check(blocks) do
    {:printed, BpmlWords.check(blocks, @skipped)}
  rescue
    e in UnprintableError -> {:refused, "#{e.kind}:#{e.type}"}
  end

  test "the walk reads every fixture file and finds the pinned documents",
       %{walk: walk, docs: docs} do
    assert walk["unread"] == []
    assert walk["skippedDocuments"] == []
    assert walk["count"] == length(docs)
    assert length(docs) == @documents

    callouts = for %{"name" => name, "blocks" => blocks} <- docs, callout?(blocks), do: name
    assert callouts == @callout_documents
  end

  test "only the pinned limit documents are too deep for the words check", %{deep: deep} do
    assert deep == @too_deep
  end

  test "each document prints, or is refused for the reason the table names",
       %{outcomes: outcomes} do
    actual = for {name, {:refused, why}} <- outcomes, into: %{}, do: {name, why}
    assert differing(actual, @refused) == []

    IO.puts(
      "every-fixture words: #{map_size(outcomes)} documents checked " <>
        "(#{length(@too_deep)} too deep), #{map_size(outcomes) - map_size(actual)} printed, " <>
        "#{map_size(actual)} refused as expected"
    )
  end

  test "every word of a printed document is in its parsed printout, as often",
       %{outcomes: outcomes} do
    missing =
      for {name, {:printed, %{missing: [_ | _] = words}}} <- outcomes,
          do: {name, Enum.take(words, 10)}

    assert Enum.sort(missing) == []
  end

  test "the documents printing a <kept> line are the pinned ones", %{outcomes: outcomes} do
    actual = for {name, {:printed, %{kept: [_ | _] = kept}}} <- outcomes, into: %{}, do: {name, kept}
    assert differing(actual, @kept) == []
  end

  test "each skip hides words only where pinned, and every skip hides some",
       %{outcomes: outcomes} do
    actual =
      for {name, {:printed, %{skips: [_ | _] = skips}}} <- outcomes, into: %{}, do: {name, skips}

    assert differing(actual, @skip_hits) == []

    used = actual |> Map.values() |> List.flatten() |> MapSet.new()
    unused = for {type, field} <- Map.keys(@skipped), "#{type}.#{field}" not in used, do: field
    assert unused == []
  end

  test "no callout is refused, and the callout golden prints", %{outcomes: outcomes} do
    refused = for name <- @callout_documents, match?({:refused, _}, outcomes[name]), do: name

    assert refused == []
    assert match?({:printed, _}, outcomes["blocks/callout"])
  end

  defp differing(actual, expected) do
    for name <- Map.keys(Map.merge(actual, expected)),
        actual[name] != expected[name],
        do: {name, expected: expected[name], actual: actual[name]}
  end

  defp callout?(value) when is_map(value),
    do: value["type"] == "callout" or Enum.any?(Map.values(value), &callout?/1)

  defp callout?(value) when is_list(value), do: Enum.any?(value, &callout?/1)
  defp callout?(_value), do: false
end
