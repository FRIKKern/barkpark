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

  # No assertion below reads the WHOLE queue as an exact match any more: every
  # `assert [job] = ...` filters by the enqueuing test's own args (the last
  # unfiltered one, in "type-list ORDER cannot defeat the dedup", was filtered
  # by scope on 2026-09-17). The two remaining unfiltered reads use `Enum.any?`
  # and are therefore tolerant of extra rows. The DELETE below stays anyway,
  # because a leftover queue is still noise the sandbox should not inherit: the
  # SQL sandbox rolls back what a test writes, but `oban_jobs` rows COMMITTED by
  # an earlier non-sandboxed run are ordinary visible reads inside the
  # transaction, with nothing to roll back. On 2026-09-10 the unpartitioned
  # `barkpark_test` on the dev host carried 1284 leftover `scheduled`
  # ProjectorWorker rows (519 when this was first measured in August), and 30+
  # MIX_TEST_PARTITION databases carried their own. A fresh partition starts
  # empty and hides it, which is why this reads as an intermittent flake rather
  # than as the deterministic environment fault it is.
  #
  # So assert the precondition instead of inheriting it. This DELETE runs inside
  # the per-test sandbox transaction and is rolled back with everything else, so
  # it never touches a shared database's committed rows and cannot race a
  # concurrent suite on the same box.
  # See tooling/grip/ledger/clean-main-red-baseline-2026-09-10.md §4.
  setup do
    Barkpark.Repo.delete_all(Oban.Job)
    :ok
  end

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
      # Filter the read by THIS test's own scope, not by the whole
      # ProjectorWorker queue. `assert [job] = all_enqueued(worker:
      # ProjectorWorker)` asserted "one ProjectorWorker row exists ANYWHERE the
      # transaction can see", which is a statement about the database, not about
      # enqueue/2. The setup `delete_all` covers rows committed BEFORE this
      # test's sandbox transaction opened; it cannot cover a row committed by a
      # concurrent unboxed suite AFTER it, and it cannot cover a foreign row
      # written inside the transaction. The scope is unique per run, so the
      # filter selects exactly the two enqueues below and nothing else — the
      # dedup claim (two enqueues, one job) is unchanged.
      scope = "ds-order-#{System.unique_integer([:positive])}"

      assert {:ok, _} = ProjectorWorker.enqueue(scope, types: ["post", "page"])
      assert {:ok, _} = ProjectorWorker.enqueue(scope, types: ["page", "post"])

      assert [job] = all_enqueued(worker: ProjectorWorker, args: %{"scope" => scope})
      assert job.args["types"] == ["page", "post"]
    end

    test "a foreign ProjectorWorker row does not defeat the ORDER dedup assertion" do
      # MUTATION ARM for the assertion above. A contaminating row reaches that
      # assertion as an ordinary visible ProjectorWorker row this test never
      # enqueued; insert one directly so the shape is reproduced deterministically
      # instead of waiting for another agent's leak. `Repo.insert` runs inside the
      # per-test sandbox transaction, so the row is rolled back and never reaches
      # the shared `barkpark_test` database — this arm cannot become the very
      # pollution it guards against.
      scope = "ds-order-#{System.unique_integer([:positive])}"

      assert {:ok, _foreign} =
               Barkpark.Repo.insert(
                 ProjectorWorker.new(%{
                   "op" => "rebuild",
                   "scope" => "ds-foreign-#{System.unique_integer([:positive])}",
                   "types" => ["page", "post"],
                   "perspective" => "published",
                   "workspace_id" => "ws-foreign-contaminant"
                 })
               )

      assert {:ok, _} = ProjectorWorker.enqueue(scope, types: ["post", "page"])
      assert {:ok, _} = ProjectorWorker.enqueue(scope, types: ["page", "post"])

      # The unfiltered read the assertion above used to make: two rows, so
      # `assert [job] = ...` would raise a MatchError on this queue state.
      assert length(all_enqueued(worker: ProjectorWorker)) == 2

      # The filtered read is indifferent to the foreign row.
      assert [job] = all_enqueued(worker: ProjectorWorker, args: %{"scope" => scope})
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
