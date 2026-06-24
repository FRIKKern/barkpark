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
    test "inserts a rebuild job with the given scope and types" do
      assert {:ok, _job} = ProjectorWorker.enqueue("production", types: ["post", "page"])

      assert_enqueued(
        worker: ProjectorWorker,
        args: %{"op" => "rebuild", "scope" => "production", "types" => ["post", "page"]}
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
      assert {:ok, _job} = ProjectorWorker.enqueue_upsert("production", "doc-xyz", types: ["post"])

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
