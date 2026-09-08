defmodule BarkparkWeb.Studio.SharedPaperBoundaryHandoffTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.{PaperCanvas, Shared.Paper}

  test "accepted new top-level boundary retains one complete run without changing its source" do
    for type <- ["table", "section"] do
      before = %{"blocks" => [paragraph("intro")]}
      block = %{"id" => "new", "type" => type}
      after_content = %{"blocks" => before["blocks"] ++ [block]}
      context = %{container_kind: "document", container_run_ids: ["intro"]}
      ops = [%{"op" => "insert-after", "afterId" => "intro", "block" => block}]
      retained = PaperCanvas.retain_insertions(MapSet.new(), before, after_content, context, ops)
      assert retained == MapSet.new(["new"])

      assert [%{run_id: "paper-run-0", blocks: blocks}] =
               Paper.canvas_echo_runs("paper", after_content["blocks"], retained)

      assert blocks == after_content["blocks"]
      assert [{:run, [_]}, {:block, ^block}] = PaperCanvas.partition_runs(blocks)
      assert [{:run, ^blocks}] = PaperCanvas.partition_runs(blocks, retained)
    end
  end

  test "undo releases retained ownership and redo reacquires it with newer source intact" do
    for type <- ["table", "section"] do
      before = %{"blocks" => [paragraph("intro")]}
      block = %{"id" => "new", "type" => type, "title" => "Newer local input"}
      inserted = %{"blocks" => before["blocks"] ++ [block]}
      context = %{container_kind: "document", container_run_ids: ["intro"]}
      insert = %{"op" => "insert-after", "afterId" => "intro", "block" => block}

      retained = PaperCanvas.retain_insertions(MapSet.new(), before, inserted, context, [insert])
      undo_context = %{container_kind: "document", container_run_ids: ["intro", "new"]}

      released =
        PaperCanvas.retain_insertions(retained, inserted, before, undo_context, [
          %{"op" => "remove-block", "id" => "new"}
        ])

      assert released == MapSet.new()
      restored = PaperCanvas.retain_insertions(released, before, inserted, context, [insert])
      assert restored == MapSet.new(["new"])
      assert [{:run, blocks}] = PaperCanvas.partition_runs(inserted["blocks"], restored)
      assert blocks == inserted["blocks"]
      assert [%{blocks: ^blocks}] = Paper.canvas_echo_runs("paper", blocks, restored)
    end
  end

  test "existing boundaries, malformed contexts and nested insertions gain no exception" do
    table = %{"id" => "table", "type" => "table", "rows" => [["Keep"]]}
    before = %{"blocks" => [paragraph("intro"), table]}
    context = %{container_kind: "document", container_run_ids: ["intro"]}
    op = %{"op" => "replace-block", "id" => "table", "block" => table}

    assert MapSet.size(PaperCanvas.retain_insertions(MapSet.new(), before, before, context, [op])) ==
             0

    for invalid <- [
          nil,
          %{},
          %{container_kind: "document", container_run_ids: ["missing"]},
          %{container_kind: "section", container_id: "missing", container_run_ids: ["intro"]}
        ] do
      assert MapSet.size(
               PaperCanvas.retain_insertions(
                 MapSet.new(),
                 %{"blocks" => [paragraph("intro")]},
                 before,
                 invalid,
                 [op]
               )
             ) == 0
    end
  end

  test "removed IDs are pruned and ownership is isolated by document" do
    ids = MapSet.new(["table"])
    assert PaperCanvas.retained_ids(%{slug: "one", ids: ids}, "one") == ids
    assert PaperCanvas.retained_ids(%{slug: "one", ids: ids}, "two") == MapSet.new()
    assert PaperCanvas.retained_ids(nil, "one") == MapSet.new()
    assert PaperCanvas.prune_retained(ids, [paragraph("table")]) == MapSet.new()

    for malformed <- [nil, "opaque", %{"opaque" => true}] do
      assert PaperCanvas.prune_retained(ids, malformed) == MapSet.new()

      assert PaperCanvas.retain_insertions(
               ids,
               %{"blocks" => malformed},
               %{"blocks" => malformed},
               nil,
               []
             ) == MapSet.new()
    end

    assert PaperCanvas.retain_insertions(ids, %{}, %{"blocks" => []}, nil, []) == MapSet.new()
  end

  defp paragraph(id), do: %{"id" => id, "type" => "paragraph", "content" => []}
end
