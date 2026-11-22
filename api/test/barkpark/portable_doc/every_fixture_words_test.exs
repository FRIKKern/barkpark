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

  # A count pin, not a cap: 186 since the limit pack gained "em past the value depth",
  # once as an edge in limit-docs.json and once as its golden (task-11bbe4b4ae8c85f4).
  @documents 186

  @callout_documents [
    "blocks/callout",
    "locales/en.locale-golden",
    "ops/insert-after after",
    "ops/patch-block before",
    "ops/patch-block after",
    "ops/remove-block before"
  ]

  # Five of the walk's limit documents take the printer more than three seconds
  # each (measured 2026-11-21): three nest thousands of levels deep, and BPML
  # indents every level; two hold thousands of spans or marks. They are left out of
  # the words check, by name, so the test stays fast; each must still be in the walk.
  # Known, tracked by task-920376e45d19bcf2.
  @too_big [
    "limit-docs docs/many marks",
    "limit-docs docs/many spans",
    "limit-docs docs/nested columns",
    "limit-docs docs/nested section",
    "limit-docs docs/nested strong"
  ]

  # Document name => the printer's refusal, as "kind:type". None is a callout.
  @refused %{
    "blocks/api-endpoint" => "block:api-endpoint",
    "blocks/arrayOf" => "block:arrayOf",
    "blocks/card" => "block:heading",
    "blocks/chat-approval" => "block:chat-approval",
    "blocks/chat-plan" => "block:chat-plan",
    "blocks/chat-question" => "block:chat-question",
    "blocks/chat-thinking" => "block:chat-thinking",
    "blocks/chat-todo" => "block:chat-todo",
    "blocks/chat-tool-diff" => "block:chat-tool-diff",
    "blocks/code-tabs" => "block:code-tabs",
    "blocks/codelist" => "block:codelist",
    "blocks/composite" => "block:composite",
    "blocks/criteria-progress" => "block:criteria-progress",
    "blocks/diff" => "block:diff",
    "blocks/duel" => "block:duel",
    "blocks/embed" => "block:embed",
    "blocks/equation" => "block:equation",
    "blocks/field-boolean" => "block:field-boolean",
    "blocks/field-color" => "block:field-color",
    "blocks/field-datetime" => "block:field-datetime",
    "blocks/field-image" => "block:field-image",
    "blocks/field-number" => "block:field-number",
    "blocks/field-reference" => "block:field-reference",
    "blocks/field-select" => "block:field-select",
    "blocks/field-slug" => "block:field-slug",
    "blocks/field-string" => "block:field-string",
    "blocks/field-text" => "block:field-text",
    "blocks/filetree" => "block:filetree",
    "blocks/footnote" => "block:footnote",
    "blocks/form" => "block:form",
    "blocks/gauge-list" => "block:gauge-list",
    "blocks/heatmap" => "block:heatmap",
    "blocks/image" => "block:image",
    "blocks/localizedText" => "block:localizedText",
    "blocks/paragraph" => "mark:link",
    "blocks/pre-gate-badge" => "block:pre-gate-badge",
    "blocks/questionnaire" => "block:questionnaire",
    "blocks/roadmap" => "block:roadmap",
    "blocks/section" => "block:heading",
    "blocks/sheet" => "block:sheet",
    "blocks/stage" => "block:stage",
    "blocks/stat" => "block:stat",
    "blocks/status-legend" => "block:status-legend",
    "blocks/tabs" => "block:tabs",
    "blocks/task-board" => "block:task-board",
    "blocks/task-detail" => "block:task-detail",
    "blocks/task-list" => "block:task-list",
    "blocks/tasks" => "block:tasks",
    "blocks/video" => "block:video",
    "limit-docs docs/big number" => "block:heatmap",
    "limit-docs docs/heatmap" => "block:heatmap",
    "limit-docs docs/many merges" => "block:sheet",
    "limit-docs docs/multi edit" => "block:chat-tool-diff",
    "limit-docs docs/record table" => "head_cell:",
    "limit-docs docs/sheet" => "block:sheet",
    "limit-docs docs/tool diff" => "block:chat-tool-diff",
    "limits/bare-lists-at-the-depth-limit" => "inline:",
    "limits/heatmap-calendar-padding-past-the-stored-cells" => "block:heatmap",
    "limits/heatmap-matrix-padding-past-the-stored-cells" => "block:heatmap",
    "limits/heatmap-number-past-what-a-float-holds" => "block:heatmap",
    "limits/heatmap-padding-past-the-stored-cells" => "block:heatmap",
    "limits/heatmap-padding-within-the-stored-cells" => "block:heatmap",
    "limits/list-at-the-depth-limit" => "block:list",
    "limits/record-table-past-the-cap" => "head_cell:",
    "limits/sheet-merge-down-empty-rows" => "block:sheet",
    "limits/sheet-merge-past-the-cells-left" => "block:sheet",
    "limits/sheet-merge-with-no-stored-origin" => "block:sheet",
    "limits/sheet-merges-on-a-ragged-sheet" => "block:sheet",
    "limits/sheet-merges-sharing-an-origin" => "block:sheet",
    "limits/tabs-at-the-depth-limit" => "block:tabs",
    "limits/tabs-one-level-above-the-depth-limit" => "block:tabs",
    "locales/en.locale-golden" => "block:form",
    "ops/patch-card-body after" => "block:heading",
    "ops/patch-card-body before" => "block:heading"
  }

  # Document name => [{top-level block id, why}] for each block printed as <kept>.
  @kept %{}

  # {block type, field} => why the printout may lack that field's words. Empty: the
  # one fixture whose callout has a `text` field (task-04de6fc749b11380) is refused
  # for its form block, so no checked document needs a skip.
  @skipped %{}

  # Document name => the skipped fields that hid a word in it.
  @skip_hits %{}

  # Document name => [{word, in source, in printout}] the printout lacks. The
  # nested-list golden's `text` the reader does not show (not printed; the
  # write wall refuses an edit to its block, task-0b448ea0847a6b4f) and its
  # alias type name.
  @lost %{
    "nested-list-carriers" => [
      {"Inactive", 1, 0},
      {"fallback", 2, 1},
      {"ordered", 1, 0},
      {"parent", 2, 1}
    ]
  }

  setup_all do
    node = System.find_executable("node") || flunk("node is required for this test")
    {out, 0} = System.cmd(node, [@script], stderr_to_stdout: true)
    [head | lines] = String.split(out, "\n", trim: true)
    walk = Jason.decode!(head)
    docs = Enum.map(lines, &Jason.decode!/1)
    checked = Enum.reject(docs, &(&1["name"] in @too_big))
    outcomes = Map.new(checked, fn %{"name" => n, "blocks" => blocks} -> {n, check(blocks)} end)
    %{walk: walk, docs: docs, outcomes: outcomes}
  end

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

  test "every document left out as too big is still in the walk", %{docs: docs} do
    names = MapSet.new(docs, & &1["name"])
    assert Enum.reject(@too_big, &MapSet.member?(names, &1)) == []
  end

  test "each document prints, or is refused for the reason the table names",
       %{outcomes: outcomes} do
    actual = for {name, {:refused, why}} <- outcomes, into: %{}, do: {name, why}
    assert differing(actual, @refused) == [], full(differing(actual, @refused))

    IO.puts(
      "every-fixture words: #{map_size(outcomes)} documents checked " <>
        "(#{length(@too_big)} too big), #{map_size(outcomes) - map_size(actual)} printed, " <>
        "#{map_size(actual)} refused as expected"
    )
  end

  test "every word of a printed document is in its parsed printout, as often",
       %{outcomes: outcomes} do
    missing =
      for {name, {:printed, %{missing: [_ | _] = words}}} <- outcomes,
          into: %{},
          do: {name, words}

    assert differing(missing, @lost) == [], full(differing(missing, @lost))
  end

  test "the documents printing a <kept> line are the pinned ones", %{outcomes: outcomes} do
    actual =
      for {name, {:printed, %{kept: [_ | _] = kept}}} <- outcomes, into: %{}, do: {name, kept}

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

  test "no document is refused for a callout, and the callout golden prints",
       %{outcomes: outcomes} do
    refused = for {name, {:refused, "block:callout"}} <- outcomes, do: name

    assert refused == []
    assert match?({:printed, _}, outcomes["blocks/callout"])
  end

  defp full(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

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
