defmodule Barkpark.PortableDoc.TaskResolverTest do
  # Pure block-transform + field-mapper — no DB, async safe.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.TaskResolver

  # A stub fetcher: echoes deterministic rows so we test the TRAVERSAL, not a DB.
  defp fetch(%{"parent_id" => "epic"}), do: [%{"title" => "a", "status" => "ready"}, %{"title" => "b", "status" => "done"}]
  defp fetch(%{"one" => true}), do: [%{"title" => "solo", "status" => "in_progress"}]
  defp fetch(_), do: []

  describe "resolve/2 — traversal + injection" do
    test "replaces a snapshot block's query with fetched rows" do
      [out] = TaskResolver.resolve([%{"type" => "task-list", "query" => %{"parent_id" => "epic"}}], &fetch/1)
      assert out["snapshot"] == [%{"title" => "a", "status" => "ready"}, %{"title" => "b", "status" => "done"}]
      refute Map.has_key?(out, "query")
    end

    test "task-detail takes the first fetched row as its task" do
      [out] = TaskResolver.resolve([%{"type" => "task-detail", "query" => %{"one" => true}}], &fetch/1)
      assert out["task"] == %{"title" => "solo", "status" => "in_progress"}
      refute Map.has_key?(out, "query")
    end

    test "task-detail with no matches injects an empty task, not a crash" do
      [out] = TaskResolver.resolve([%{"type" => "task-detail", "query" => %{"nope" => 1}}], &fetch/1)
      assert out["task"] == %{}
    end

    test "leaves an author-pinned snapshot (no query) untouched" do
      pinned = %{"type" => "task-list", "snapshot" => [%{"title" => "x"}]}
      assert TaskResolver.resolve([pinned], &fetch/1) == [pinned]
    end

    test "recurses into container children" do
      blocks = [%{"type" => "columns", "children" => [%{"type" => "task-board", "query" => %{"parent_id" => "epic"}}]}]
      [%{"children" => [board]}] = TaskResolver.resolve(blocks, &fetch/1)
      assert length(board["snapshot"]) == 2
    end

    test "non-list / non-fn inputs pass through" do
      assert TaskResolver.resolve("x", &fetch/1) == "x"
    end
  end

  describe "preview/2 — non-destructive DISPLAY channel (doctrine D5)" do
    test "yields an id-keyed snapshot entry for a query-carrying snapshot block" do
      blocks = [%{"id" => "b1", "type" => "task-list", "query" => %{"parent_id" => "epic"}}]

      assert TaskResolver.preview(blocks, &fetch/1) == [
               %{
                 "block_id" => "b1",
                 "type" => "task-list",
                 "snapshot" => [
                   %{"title" => "a", "status" => "ready"},
                   %{"title" => "b", "status" => "done"}
                 ]
               }
             ]
    end

    test "task-detail yields the first row as its task; no matches → empty task" do
      hit = [%{"id" => "d1", "type" => "task-detail", "query" => %{"one" => true}}]
      assert [%{"block_id" => "d1", "type" => "task-detail", "task" => task}] =
               TaskResolver.preview(hit, &fetch/1)

      assert task == %{"title" => "solo", "status" => "in_progress"}

      miss = [%{"id" => "d2", "type" => "task-detail", "query" => %{"nope" => 1}}]
      assert [%{"block_id" => "d2", "type" => "task-detail", "task" => %{}}] =
               TaskResolver.preview(miss, &fetch/1)
    end

    test "D5: the SOURCE blocks are returned UNCHANGED — the save baseline stays unresolved" do
      # This is the byte-stability invariant: preview/2 emits previews on the SIDE
      # and never rewrites the blocks the canvas saves against. A save right after
      # a preview therefore diffs identical blocks → ZERO ops. (Contrast resolve/2,
      # which REPLACES query→snapshot in place — the path the editor must NOT take.)
      blocks = [
        %{"id" => "b1", "type" => "task-list", "query" => %{"parent_id" => "epic"}},
        %{"id" => "p1", "type" => "paragraph", "content" => []}
      ]

      previews = TaskResolver.preview(blocks, &fetch/1)

      # The task block still carries its raw `query` and NO injected `snapshot`.
      [task_block, _para] = blocks
      assert task_block["query"] == %{"parent_id" => "epic"}
      refute Map.has_key?(task_block, "snapshot")

      # The preview rows live only in the separate channel.
      assert [%{"block_id" => "b1", "snapshot" => rows}] = previews
      assert length(rows) == 2
    end

    test "an author-pinned literal snapshot (no query) produces NO entry" do
      pinned = [%{"id" => "b1", "type" => "task-list", "snapshot" => [%{"title" => "x"}]}]
      assert TaskResolver.preview(pinned, &fetch/1) == []
    end

    test "a query block WITHOUT an addressable id is skipped (no node view to key)" do
      assert TaskResolver.preview(
               [%{"type" => "task-board", "query" => %{"parent_id" => "epic"}}],
               &fetch/1
             ) == []

      assert TaskResolver.preview(
               [%{"id" => "", "type" => "task-board", "query" => %{"parent_id" => "epic"}}],
               &fetch/1
             ) == []
    end

    test "recurses into container children" do
      blocks = [
        %{
          "type" => "columns",
          "children" => [%{"id" => "b1", "type" => "task-board", "query" => %{"parent_id" => "epic"}}]
        }
      ]

      assert [%{"block_id" => "b1", "type" => "task-board", "snapshot" => rows}] =
               TaskResolver.preview(blocks, &fetch/1)

      assert length(rows) == 2
    end

    test "graceful degrade: a RAISING fetcher (Tasks plugin off) → { error: true }, never a crash" do
      boom = fn _query -> raise "tasks plugin off" end
      blocks = [%{"id" => "b1", "type" => "task-list", "query" => %{"parent_id" => "epic"}}]

      assert TaskResolver.preview(blocks, boom) == [
               %{"block_id" => "b1", "type" => "task-list", "error" => true}
             ]
    end

    test "non-list / non-fn inputs yield no previews" do
      assert TaskResolver.preview("x", &fetch/1) == []
      assert TaskResolver.preview([%{"id" => "b", "type" => "task-list", "query" => %{}}], :nope) == []
    end
  end

  describe "row_from_task/1 — field mapping" do
    test "open with no blockers → ready; open with blockers → open (backlog)" do
      assert TaskResolver.row_from_task(%{"title" => "t", "lifecycle_status" => "open"})["status"] == "ready"
      assert TaskResolver.row_from_task(%{"title" => "t", "lifecycle_status" => "open", "dependency_count" => 2})["status"] == "open"
    end

    test "blocked / in_progress / done map straight through" do
      for s <- ~w(blocked in_progress done cancelled) do
        assert TaskResolver.row_from_task(%{"title" => "t", "lifecycle_status" => s})["status"] == s
      end
    end

    test "worker from claim.worker, else assignee" do
      assert TaskResolver.row_from_task(%{"title" => "t", "claim" => %{"worker" => "o3"}})["worker"] == "o3"
      assert TaskResolver.row_from_task(%{"title" => "t", "assignee" => "opus"})["worker"] == "opus"
    end

    test "criteria_progress → criteria; zero-total omitted" do
      assert TaskResolver.row_from_task(%{"title" => "t", "criteria_progress" => %{"met" => 2, "total" => 3}})["criteria"] == %{"met" => 2, "total" => 3}
      refute Map.has_key?(TaskResolver.row_from_task(%{"title" => "t", "criteria_progress" => %{"met" => 0, "total" => 0}}), "criteria")
    end

    test "a phase:/wave: label becomes the phase group; other labels ignored" do
      assert TaskResolver.row_from_task(%{"title" => "t", "labels" => ["proj:x", "wave:5"]})["phase"] == "5"
      refute Map.has_key?(TaskResolver.row_from_task(%{"title" => "t", "labels" => ["proj:x"]}), "phase")
    end

    test "tolerates atom keys (the render_doc shape)" do
      row = TaskResolver.row_from_task(%{title: "t", lifecycle_status: "in_progress", priority: "1"})
      assert row["title"] == "t"
      assert row["status"] == "in_progress"
      assert row["priority"] == "1"
    end

    test "prunes empty fields to a clean row" do
      row = TaskResolver.row_from_task(%{"title" => "t", "lifecycle_status" => "done"})
      assert row == %{"title" => "t", "status" => "done"}
    end
  end

  test "end-to-end: fetcher = row_from_task ∘ docs → component-ready snapshot" do
    docs = [
      %{title: "collect", lifecycle_status: "done", labels: ["wave:5"]},
      %{title: "inject", lifecycle_status: "open", labels: ["wave:5"]}
    ]

    fetch = fn %{"parent_id" => "resolver"} -> Enum.map(docs, &TaskResolver.row_from_task/1) end
    [out] = TaskResolver.resolve([%{"type" => "task-list", "query" => %{"parent_id" => "resolver"}}], fetch)

    assert out["snapshot"] == [
             %{"title" => "collect", "status" => "done", "phase" => "5"},
             %{"title" => "inject", "status" => "ready", "phase" => "5"}
           ]
  end
end
