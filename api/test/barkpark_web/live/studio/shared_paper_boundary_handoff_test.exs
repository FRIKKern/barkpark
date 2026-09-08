defmodule BarkparkWeb.Studio.SharedPaperBoundaryHandoffTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.{PaperCanvas, Shared.Paper}

  test "accepted new top-level boundary retains one complete run without changing its source" do
    for type <- ["table", "section"] do
      before = %{"blocks" => [paragraph("intro")]}
      block = boundary(type, "new")
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
      block = Map.put(boundary(type, "new"), "title", "Newer local input")
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
    table = table("table")
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

  test "a Section run owns its newly inserted Table and echo does not duplicate it" do
    intro = paragraph("intro")
    target = paragraph("target")
    before = %{"blocks" => [section("outer", [intro, target])]}
    table = table("nested-table")
    after_content = %{"blocks" => [section("outer", [intro, table])]}
    context = section_context("outer", ["intro", "target"])

    owners =
      PaperCanvas.retain_insertions(%{}, before, after_content, context, [
        %{"op" => "replace-block", "id" => "target", "block" => table}
      ])

    assert owners == %{{:section, "outer"} => MapSet.new(["nested-table"])}

    retained = %{slug: "paper", owners: owners}

    expected_run = PaperCanvas.run_id(PaperCanvas.section_run_slug("paper", "outer"), 0)

    assert [%{run_id: ^expected_run, blocks: [^intro, ^table]}] =
             Paper.canvas_echo_runs("paper", after_content["blocks"], retained)
  end

  test "each Columns position owns only its inserted boundary and preserves peer echoes" do
    left = paragraph("left")
    target = paragraph("target")
    peer = paragraph("peer")
    before = %{"blocks" => [columns("cols", [[left, target], [peer]])]}
    table = table("column-table")
    after_content = %{"blocks" => [columns("cols", [[left, table], [peer]])]}

    owners =
      PaperCanvas.retain_insertions(
        %{},
        before,
        after_content,
        columns_context("cols", 0, ["left", "target"]),
        [%{"op" => "replace-block", "id" => "target", "block" => table}]
      )

    assert owners == %{{:columns, "cols", 0} => MapSet.new(["column-table"])}

    runs =
      Paper.canvas_echo_runs("paper", after_content["blocks"], %{slug: "paper", owners: owners})

    left_run = PaperCanvas.run_id(PaperCanvas.columns_run_slug("paper", "cols", 0), 0)
    peer_run = PaperCanvas.run_id(PaperCanvas.columns_run_slug("paper", "cols", 1), 0)

    assert %{blocks: [^left, ^table]} = Enum.find(runs, &(&1.run_id == left_run))

    assert %{blocks: [^peer]} = Enum.find(runs, &(&1.run_id == peer_run))
  end

  test "a retained nested Section stays wholly inside its parent's run" do
    intro = paragraph("intro")
    target = paragraph("target")
    before = %{"blocks" => [section("outer", [intro, target])]}
    nested = section("nested", [paragraph("nested-body")])
    after_content = %{"blocks" => [section("outer", [intro, nested])]}

    owners =
      PaperCanvas.retain_insertions(
        %{},
        before,
        after_content,
        section_context("outer", ["intro", "target"]),
        [%{"op" => "replace-block", "id" => "target", "block" => nested}]
      )

    runs =
      Paper.canvas_echo_runs("paper", after_content["blocks"], %{slug: "paper", owners: owners})

    expected_run = PaperCanvas.run_id(PaperCanvas.section_run_slug("paper", "outer"), 0)
    assert [%{run_id: ^expected_run, blocks: [^intro, ^nested]}] = runs
  end

  test "unrelated acknowledgements retain existing owner buckets" do
    first_table = table("first-table")
    second_table = table("second-table")
    left = paragraph("left")
    right = paragraph("right")
    before = %{"blocks" => [section("one", [left, first_table]), section("two", [right])]}

    after_content = %{
      "blocks" => [section("one", [left, first_table]), section("two", [right, second_table])]
    }

    prior = %{{:section, "one"} => MapSet.new(["first-table"])}

    owners =
      PaperCanvas.retain_insertions(
        prior,
        before,
        after_content,
        section_context("two", ["right"]),
        [%{"op" => "append-block", "block" => second_table}]
      )

    assert owners == %{
             {:section, "one"} => MapSet.new(["first-table"]),
             {:section, "two"} => MapSet.new(["second-table"])
           }
  end

  test "nested undo prunes ownership and redo reacquires the exact owner" do
    intro = paragraph("intro")
    before = %{"blocks" => [section("outer", [intro])]}
    table = table("nested-table")
    inserted = %{"blocks" => [section("outer", [intro, table])]}
    context = section_context("outer", ["intro"])
    insert = %{"op" => "append-block", "block" => table}

    retained = PaperCanvas.retain_insertions(%{}, before, inserted, context, [insert])

    released =
      PaperCanvas.retain_insertions(
        retained,
        inserted,
        before,
        section_context("outer", ["intro", "nested-table"]),
        [%{"op" => "remove-block", "id" => "nested-table"}]
      )

    assert released == %{}

    assert PaperCanvas.retain_insertions(released, before, inserted, context, [insert]) ==
             retained
  end

  test "an exactly-once replay reacquires an already persisted boundary" do
    intro = paragraph("intro")
    table = table("replayed-table")
    current = %{"blocks" => [section("outer", [intro, table])]}

    assert PaperCanvas.retain_insertions(
             %{},
             current,
             current,
             section_context("outer", ["intro", "target"]),
             [%{"op" => "replace-block", "id" => "target", "block" => table}],
             :replayed
           ) == %{{:section, "outer"} => MapSet.new(["replayed-table"])}

    assert PaperCanvas.retain_insertions(
             %{},
             current,
             current,
             section_context("outer", ["intro", "target"]),
             [%{"op" => "replace-block", "id" => "target", "block" => table}],
             :applied
           ) == %{}
  end

  test "refresh prunes cross-container moves, column moves and changed boundary types" do
    table = table("owned")

    ownership = %{
      slug: "paper",
      owners: %{
        {:section, "left"} => MapSet.new(["owned"]),
        {:columns, "cols", 0} => MapSet.new(["column-owned"]),
        document: MapSet.new(["changed"])
      }
    }

    blocks = [
      section("left", []),
      section("right", [table]),
      columns("cols", [[], [%{"id" => "column-owned", "type" => "section", "blocks" => []}]]),
      paragraph("changed")
    ]

    assert PaperCanvas.refresh_retained(ownership, "paper", blocks) == %{
             slug: "paper",
             owners: %{}
           }

    assert PaperCanvas.refresh_retained(ownership, "other", blocks) == nil
  end

  test "refresh releases ownership when a Section stack canvas becomes a grid" do
    table = table("owned")

    ownership = %{
      slug: "paper",
      owners: %{{:section, "outer"} => MapSet.new(["owned"])}
    }

    stack = [section("outer", [table])]
    assert PaperCanvas.refresh_retained(ownership, "paper", stack) == ownership

    grid = [put_in(section("outer", [table]), ["layout"], %{"mode" => "grid", "tracks" => 2})]

    released = PaperCanvas.refresh_retained(ownership, "paper", grid)
    assert released == %{slug: "paper", owners: %{}}

    assert PaperCanvas.refresh_retained(released, "paper", stack) == released
  end

  test "refresh releases ownership when a Columns position is no longer editable" do
    ownership = %{
      slug: "paper",
      owners: %{{:columns, "cols", 0} => MapSet.new(["owned"])}
    }

    for malformed <- [
          [columns("cols", [])],
          [%{"id" => "cols", "type" => "columns", "columns" => ["opaque"]}]
        ] do
      assert PaperCanvas.refresh_retained(ownership, "paper", malformed) == %{
               slug: "paper",
               owners: %{}
             }
    end
  end

  test "preexisting boundaries, malformed trees and unsupported nested origins fail closed" do
    table = table("existing")
    before = %{"blocks" => [section("outer", [table])]}

    assert PaperCanvas.retain_insertions(
             %{},
             before,
             before,
             section_context("outer", ["existing"]),
             [%{"op" => "replace-block", "id" => "existing", "block" => table}]
           ) == %{}

    duplicate = %{"blocks" => [section("outer", [paragraph("same")]), paragraph("same")]}

    assert PaperCanvas.retain_insertions(
             %{},
             duplicate,
             duplicate,
             section_context("outer", ["same"]),
             [%{"op" => "append-block", "block" => table}]
           ) == %{}

    for unsupported <- [
          %{container_id: "expandable", container_run_ids: ["target"]},
          %{container_kind: "terminal", container_id: "terminal", container_run_ids: ["target"]},
          %{
            container_kind: "tabs",
            container_id: "tabs",
            container_row_id: "row",
            container_run_ids: ["target"]
          },
          %{
            container_kind: "steps",
            container_id: "steps",
            container_row_id: "row",
            container_run_ids: ["target"]
          },
          %{container_kind: "figure", container_id: "figure", container_run_ids: ["target"]}
        ] do
      assert PaperCanvas.retain_insertions(%{}, before, before, unsupported, []) == %{}
    end
  end

  defp paragraph(id), do: %{"id" => id, "type" => "paragraph", "content" => []}

  defp boundary("table", id), do: table(id)
  defp boundary("section", id), do: section(id, [paragraph("#{id}-body")])

  defp table(id),
    do: %{"id" => id, "type" => "table", "head" => [[], []], "rows" => [[[], []]]}

  defp section(id, blocks), do: %{"id" => id, "type" => "section", "blocks" => blocks}

  defp columns(id, columns), do: %{"id" => id, "type" => "columns", "columns" => columns}

  defp section_context(id, run_ids),
    do: %{container_kind: "section", container_id: id, container_run_ids: run_ids}

  defp columns_context(id, index, run_ids),
    do: %{
      container_kind: "columns",
      container_id: id,
      container_column_index: index,
      container_run_ids: run_ids
    }
end
