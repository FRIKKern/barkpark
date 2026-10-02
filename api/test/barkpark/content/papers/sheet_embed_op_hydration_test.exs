defmodule Barkpark.Content.Papers.SheetEmbedOpHydrationTest do
  @moduledoc """
  The canvas op paths honour the embed-pipeline contract
  (docs/contracts/sheets-engine.md §Embed pipeline): a paper save that ADDS a
  `{"type":"sheet","ref":…}` block, or RETARGETS one, hydrates its snapshot
  from the referenced sheet.

  Found live (r4-lane-c dogfood): a sheet chip inserted or retargeted in the
  canvas saved `ref` but kept `snapshot: null`, so the paper showed an empty
  0×0 grid until the sheet's next save. Only `upsert_blocks_doc` hydrated; the
  batch spine and the single-op path did not.

  Cost pin: hydration runs only for a new or retargeted sheet block, so a
  plain typing batch on a paper that embeds a sheet issues zero sheet queries.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  @dataset "sheets_op_hydration_test"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)
    :ok
  end

  defp create_sheet(id, value) do
    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => id,
          "content" => %{
            "locale" => "nb-NO",
            "tabs" => [
              %{
                "name" => "Tab1",
                "frozen_rows" => 1,
                "cells" => %{"A1" => %{"v" => "Name"}, "A2" => %{"v" => value}}
              }
            ]
          }
        },
        @dataset
      )

    Content.published_id(doc.doc_id)
  end

  defp seed_paper(slug, blocks) do
    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: slug, dataset: @dataset, blocks: blocks})
      )

    :ok
  end

  defp blocks(slug), do: get_in(Content.get_paper(slug, @dataset).content, ["blocks"])

  defp sheet_blocks(slug), do: Enum.filter(blocks(slug), &(&1["type"] == "sheet"))

  @para %{"id" => "p1", "type" => "paragraph", "text" => "Intro."}

  # Count this process's repo queries that read sheet rows.
  defp count_sheet_queries(fun) do
    test_pid = self()
    ref = make_ref()
    handler = "sheet-query-counter-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:barkpark, :repo, :query],
      fn _event, _measure, meta, _ ->
        if self() == test_pid and is_binary(meta[:query]) and meta[:query] =~ "'sheet'" do
          send(test_pid, {ref, :sheet_query})
        end
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, 0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(ref, n) do
    receive do
      {^ref, :sheet_query} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end

  test "a batch that inserts a sheet block hydrates its snapshot" do
    sheet = create_sheet("op-hy-1", "ready")
    slug = "op-hy-insert-#{System.unique_integer([:positive])}"
    seed_paper(slug, [@para])

    ops = [
      %{
        "op" => "insert-after",
        "afterId" => "p1",
        "block" => %{"id" => "s1", "type" => "sheet", "ref" => sheet, "tab" => 0}
      }
    ]

    {{:ok, _}, queries} =
      count_sheet_queries(fn -> Content.apply_paper_block_ops(slug, ops, @dataset) end)

    assert [%{"snapshot" => %{"rows" => [["ready"]]}}] = sheet_blocks(slug)
    assert queries > 0, "positive control: the insert reads the sheet"
  end

  test "a batch that retargets a sheet chip (snapshot cleared) hydrates the new sheet" do
    first = create_sheet("op-hy-a", "alpha")
    second = create_sheet("op-hy-b", "beta")
    slug = "op-hy-retarget-#{System.unique_integer([:positive])}"
    seed_paper(slug, [@para, %{"id" => "s1", "type" => "sheet", "ref" => first, "tab" => 0}])
    assert [%{"snapshot" => %{"rows" => [["alpha"]]}}] = sheet_blocks(slug)

    ops = [
      %{
        "op" => "replace-block",
        "id" => "s1",
        "block" => %{
          "id" => "s1",
          "type" => "sheet",
          "ref" => second,
          "tab" => 0,
          "snapshot" => nil
        }
      }
    ]

    assert {:ok, _} = Content.apply_paper_block_ops(slug, ops, @dataset)
    assert [%{"ref" => ^second, "snapshot" => %{"rows" => [["beta"]]}}] = sheet_blocks(slug)
  end

  test "the single-op path hydrates an appended sheet block" do
    sheet = create_sheet("op-hy-single", "solo")
    slug = "op-hy-single-#{System.unique_integer([:positive])}"
    seed_paper(slug, [@para])

    op = %{
      "op" => "append-block",
      "block" => %{"id" => "s1", "type" => "sheet", "ref" => sheet, "tab" => 0}
    }

    assert {:ok, _} = Content.apply_paper_block_op(slug, op, @dataset)
    assert [%{"snapshot" => %{"rows" => [["solo"]]}}] = sheet_blocks(slug)
  end

  test "a typing batch on a paper that embeds a sheet issues zero sheet queries" do
    sheet = create_sheet("op-hy-quiet", "still")
    slug = "op-hy-quiet-#{System.unique_integer([:positive])}"
    seed_paper(slug, [@para, %{"id" => "s1", "type" => "sheet", "ref" => sheet, "tab" => 0}])
    [before] = sheet_blocks(slug)

    ops = [
      %{"op" => "patch-block", "id" => "p1", "patch" => %{"text" => "Intro, edited."}}
    ]

    {{:ok, _}, queries} =
      count_sheet_queries(fn -> Content.apply_paper_block_ops(slug, ops, @dataset) end)

    assert queries == 0
    assert sheet_blocks(slug) == [before]
  end
end
