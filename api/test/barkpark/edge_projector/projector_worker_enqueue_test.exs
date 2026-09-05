defmodule Barkpark.EdgeProjector.ProjectorWorkerEnqueueTest do
  @moduledoc """
  Covers the three public enqueue functions of `ProjectorWorker`:
  `enqueue/2`, `enqueue_upsert/3`, and `enqueue_delete/3`.

  These build Oban job changesets (string-keyed args) and insert them.
  Tests assert the resulting job args, the `op` field, and that nil opts
  are dropped from the args map (`drop_nil/1` behaviour). The worker
  `perform/1` path is already covered by `ProjectorTest`.
  """

  use Barkpark.DataCase, async: true
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.EdgeProjector.ProjectorWorker

  describe "enqueue/2 — rebuild op" do
    test "inserts a rebuild job with the given scope and types (normalised: sorted + deduped)" do
      assert {:ok, _job} = ProjectorWorker.enqueue("production", types: ["post", "page"])

      # types participates in the uniqueness key, so enqueue canonicalises it
      # (sort + dedup) — ["post", "page"] is stored as ["page", "post"].
      assert_enqueued(
        worker: ProjectorWorker,
        args: %{"op" => "rebuild", "scope" => "production", "types" => ["page", "post"]}
      )
    end

    test "defaults to perspective 'published' when not supplied" do
      assert {:ok, _job} = ProjectorWorker.enqueue("staging", types: ["article"])

      assert_enqueued(
        worker: ProjectorWorker,
        args: %{"perspective" => "published", "scope" => "staging"}
      )
    end

    test "drops nil opts (workspace_id / project_id) from job args" do
      assert {:ok, _job} = ProjectorWorker.enqueue("ds", types: ["post"])

      # workspace_id and project_id must be absent when not supplied — drop_nil
      jobs = all_enqueued(worker: ProjectorWorker)

      assert Enum.any?(jobs, fn j ->
               j.args["scope"] == "ds" and
                 not Map.has_key?(j.args, "workspace_id") and
                 not Map.has_key?(j.args, "project_id")
             end)
    end

    test "includes workspace_id and project_id when supplied" do
      assert {:ok, _job} =
               ProjectorWorker.enqueue("production",
                 types: ["post"],
                 workspace_id: "ws-1",
                 project_id: "proj-1"
               )

      assert_enqueued(
        worker: ProjectorWorker,
        args: %{
          "op" => "rebuild",
          "scope" => "production",
          "workspace_id" => "ws-1",
          "project_id" => "proj-1"
        }
      )
    end
  end

  describe "enqueue/2 — uniqueness across types (lvw-t11-followup-dedup)" do
    test "a rebuild for one type does NOT swallow a same-window rebuild for another type" do
      # The mixed-type drop: a task save enqueues types ["task"]; a paper edit
      # < 30s later enqueues types ["paper"]. With types outside the unique
      # key, Oban returns the EXISTING ["task"] job and the paper rebuild is
      # silently discarded — the paper's edges never materialise (no retry).
      assert {:ok, _} = ProjectorWorker.enqueue("production", types: ["task"])
      assert {:ok, _} = ProjectorWorker.enqueue("production", types: ["paper"])

      assert_enqueued(
        worker: ProjectorWorker,
        args: %{"op" => "rebuild", "scope" => "production", "types" => ["task"]}
      )

      assert_enqueued(
        worker: ProjectorWorker,
        args: %{"op" => "rebuild", "scope" => "production", "types" => ["paper"]}
      )
    end

    test "same-type save bursts still collapse into ONE job (storm protection intact)" do
      assert {:ok, _} = ProjectorWorker.enqueue("production", types: ["post"])
      assert {:ok, _} = ProjectorWorker.enqueue("production", types: ["post"])
      assert {:ok, _} = ProjectorWorker.enqueue("production", types: ["post"])

      assert [_only_one] =
               all_enqueued(
                 worker: ProjectorWorker,
                 args: %{"op" => "rebuild", "scope" => "production", "types" => ["post"]}
               )
    end

    test "type-list ORDER cannot defeat the dedup (types normalised at enqueue)" do
      assert {:ok, _} = ProjectorWorker.enqueue("production", types: ["post", "page"])
      assert {:ok, _} = ProjectorWorker.enqueue("production", types: ["page", "post"])

      assert [job] = all_enqueued(worker: ProjectorWorker)
      assert job.args["types"] == ["page", "post"]
    end
  end

  describe "enqueue/2 — uniqueness across tenant scope" do
    test "the same dataset and type in different workspaces or projects enqueue independently" do
      suffix = System.unique_integer([:positive])
      workspace_a = "ws-a-#{suffix}"
      workspace_b = "ws-b-#{suffix}"
      project_a = "project-a-#{suffix}"
      project_b = "project-b-#{suffix}"

      assert {:ok, _} =
               ProjectorWorker.enqueue("production",
                 types: ["paper"],
                 workspace_id: workspace_a,
                 project_id: project_a
               )

      assert {:ok, _} =
               ProjectorWorker.enqueue("production",
                 types: ["paper"],
                 workspace_id: workspace_b,
                 project_id: project_b
               )

      jobs =
        all_enqueued(worker: ProjectorWorker)
        |> Enum.filter(&(&1.args["workspace_id"] in [workspace_a, workspace_b]))

      assert Enum.sort_by(Enum.map(jobs, & &1.args), & &1["workspace_id"]) ==
               Enum.sort_by(
                 [
                   %{
                     "op" => "rebuild",
                     "perspective" => "published",
                     "project_id" => project_a,
                     "scope" => "production",
                     "types" => ["paper"],
                     "workspace_id" => workspace_a
                   },
                   %{
                     "op" => "rebuild",
                     "perspective" => "published",
                     "project_id" => project_b,
                     "scope" => "production",
                     "types" => ["paper"],
                     "workspace_id" => workspace_b
                   }
                 ],
                 & &1["workspace_id"]
               )
    end

    test "an identical full tenant scope still deduplicates" do
      suffix = System.unique_integer([:positive])
      workspace = "ws-#{suffix}"
      opts = [types: ["paper"], workspace_id: workspace, project_id: "project-#{suffix}"]

      assert {:ok, _} = ProjectorWorker.enqueue("production", opts)
      assert {:ok, _} = ProjectorWorker.enqueue("production", opts)

      assert [_only_one] =
               all_enqueued(worker: ProjectorWorker)
               |> Enum.filter(&(&1.args["workspace_id"] == workspace))
    end
  end

  describe "enqueue_upsert/3 — upsert op" do
    test "inserts an upsert job with op='upsert' and the given _id" do
      assert {:ok, _job} =
               ProjectorWorker.enqueue_upsert("production", "doc-abc", types: ["post"])

      assert_enqueued(
        worker: ProjectorWorker,
        args: %{"op" => "upsert", "scope" => "production", "_id" => "doc-abc"}
      )
    end

    test "drops nil workspace_id from upsert job args" do
      assert {:ok, _job} =
               ProjectorWorker.enqueue_upsert("production", "doc-xyz", types: ["post"])

      jobs = all_enqueued(worker: ProjectorWorker)

      assert Enum.any?(jobs, fn j ->
               j.args["_id"] == "doc-xyz" and not Map.has_key?(j.args, "workspace_id")
             end)
    end
  end

  describe "enqueue_delete/3 — delete op" do
    test "inserts a delete job with op='delete' and the given _id" do
      assert {:ok, _job} =
               ProjectorWorker.enqueue_delete("production", "doc-del-1", types: ["post"])

      assert_enqueued(
        worker: ProjectorWorker,
        args: %{"op" => "delete", "scope" => "production", "_id" => "doc-del-1"}
      )
    end
  end
end
