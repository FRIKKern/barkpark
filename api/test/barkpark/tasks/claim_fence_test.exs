defmodule Barkpark.Tasks.ClaimFenceTest do
  @moduledoc """
  felix-w13 — ClaimFence.verify/2 honors its {:ok,_}|{:error,reason} contract
  even when handed a non-UUID task_id.

  `id` is the Document :binary_id PK, so interpolating a non-UUID binary into
  `where: d.id == ^task_id` RAISES Ecto.Query.CastError — a crash the @spec
  promises never happens. verify/2 now casts via Ecto.UUID.cast BEFORE the
  query and collapses a non-UUID to {:error, :task_not_found} (a non-UUID can
  never name a live task). Covers:

    * a non-UUID task_id returns {:error, :task_not_found}, never raises
      (MUTATION: drop the Ecto.UUID.cast guard → this same call raises
      Ecto.Query.CastError → RED).
    * a well-formed-but-absent UUID still runs the query and returns
      {:error, :task_not_found} (proves the guard did not swallow the real path).
    * the happy path on a live claim returns {:ok, map} with the lease facts.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.ClaimFence

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp mk_task!(doc_id, scope) do
    content = %{
      "kind" => "task",
      "acceptance_criteria" => [
        %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
      ],
      "lifecycle_status" => "open"
    }

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # ─── the guard: a non-UUID id must not raise ─────────────────────────────

  describe "non-UUID task_id" do
    test "returns {:error, :task_not_found} instead of raising Ecto.Query.CastError" do
      # Reproducible red BEFORE the fix: this exact call raised CastError.
      assert {:error, :task_not_found} = ClaimFence.verify("not-a-uuid", %{})
      assert {:error, :task_not_found} = Tasks.verify_claim_fence("not-a-uuid", %{})
    end

    test "a non-binary task_id hits the fallback clause and is :task_not_found, not a FunctionClauseError" do
      # task-888cded6b75503ee: `verify/2`'s catch-all clause had no witness —
      # delete it and this call raised with every suite green.
      assert {:error, :task_not_found} = ClaimFence.verify(nil, %{})
      assert {:error, :task_not_found} = Tasks.verify_claim_fence(42, %{})
    end

    test "a well-formed but absent UUID still runs the query (guard did not swallow the real path)" do
      absent = Ecto.UUID.generate()
      assert {:error, :task_not_found} = ClaimFence.verify(absent, %{})
    end
  end

  # ─── happy path: a live claim verifies ───────────────────────────────────

  describe "live lease" do
    test "verify returns {:ok, lease facts} for a matching expectation", %{scope: scope} do
      task = mk_task!(uniq("cf-live"), scope)
      {:ok, claimed} = Tasks.claim_by_id(task.doc_id, "worker-1", scope)

      doc = Repo.get!(Document, claimed.id)
      claim = doc.content["claim"]

      expected = %{
        doc_id: doc.doc_id,
        worker_id: claim["worker"],
        epoch: claim["epoch"],
        work_digest: claim["work_digest"],
        workspace_id: doc.workspace_id,
        project_id: doc.project_id,
        dataset_id: doc.dataset_id
      }

      assert {:ok, facts} = ClaimFence.verify(doc.id, expected)
      assert facts.task_id == doc.id
      assert facts.task_worker_id == "worker-1"
      assert facts.task_epoch == claim["epoch"]
    end

    test "a stale epoch on a live claim returns {:error, :stale_claim}", %{scope: scope} do
      task = mk_task!(uniq("cf-stale"), scope)
      {:ok, claimed} = Tasks.claim_by_id(task.doc_id, "worker-2", scope)

      doc = Repo.get!(Document, claimed.id)
      claim = doc.content["claim"]

      expected = %{
        doc_id: doc.doc_id,
        worker_id: claim["worker"],
        epoch: claim["epoch"] + 1,
        work_digest: claim["work_digest"],
        workspace_id: doc.workspace_id,
        project_id: doc.project_id,
        dataset_id: doc.dataset_id
      }

      assert {:error, :stale_claim} = ClaimFence.verify(doc.id, expected)
    end
  end

  # ─── tenancy refusals: exactly ONE expected field off ────────────────────
  #
  # The cond in verify_task/2 is SEQUENTIAL: doc_id -> workspace_id ->
  # project_id -> dataset_id. A fixture that mismatches two of them only ever
  # reaches the first, so each test below starts from a fully-matching
  # expectation and overrides exactly ONE key. Deleting that arm from
  # claim_fence.ex must red that test and only that test.

  describe "tenancy refusals" do
    setup %{scope: scope} do
      task = mk_task!(uniq("cf-tenancy"), scope)
      {:ok, claimed} = Tasks.claim_by_id(task.doc_id, "worker-tenancy", scope)

      doc = Repo.get!(Document, claimed.id)
      claim = doc.content["claim"]

      matching = %{
        doc_id: doc.doc_id,
        worker_id: claim["worker"],
        epoch: claim["epoch"],
        work_digest: claim["work_digest"],
        workspace_id: doc.workspace_id,
        project_id: doc.project_id,
        dataset_id: doc.dataset_id
      }

      # Control: the un-perturbed expectation verifies, so every red below is
      # caused by the ONE overridden key and not by the fixture.
      assert {:ok, _} = ClaimFence.verify(doc.id, matching)

      %{doc: doc, matching: matching}
    end

    test "a doc_id that is not the task's returns {:error, :task_doc_mismatch}",
         %{doc: doc, matching: matching} do
      expected = %{matching | doc_id: matching.doc_id <> "-other"}

      assert {:error, :task_doc_mismatch} = ClaimFence.verify(doc.id, expected)
    end

    test "a workspace_id that is not the task's returns {:error, :task_workspace_mismatch}",
         %{doc: doc, matching: matching} do
      expected = %{matching | workspace_id: Ecto.UUID.generate()}

      refute expected.workspace_id == matching.workspace_id
      assert {:error, :task_workspace_mismatch} = ClaimFence.verify(doc.id, expected)
    end

    test "a project_id that is not the task's returns {:error, :task_project_mismatch}",
         %{doc: doc, matching: matching} do
      expected = %{matching | project_id: Ecto.UUID.generate()}

      refute expected.project_id == matching.project_id
      assert {:error, :task_project_mismatch} = ClaimFence.verify(doc.id, expected)
    end

    test "a dataset_id that is not the task's returns {:error, :task_dataset_mismatch}",
         %{doc: doc, matching: matching} do
      expected = %{matching | dataset_id: Ecto.UUID.generate()}

      refute expected.dataset_id == matching.dataset_id
      assert {:error, :task_dataset_mismatch} = ClaimFence.verify(doc.id, expected)
    end
  end

  # ─── lease refusals: exactly ONE field off ───────────────────────────────
  #
  # console-w31 / task-c9361be669b85c74. Reachability was DERIVED by mutation,
  # not by grepping for atom names: with each cond arm deleted in turn, this
  # file alone stayed at "8 tests, 0 failures" for :task_not_claimed,
  # :foreign_claim and :work_digest_mismatch. Those three arms had no subject
  # HERE — the module's own suite — and were reached only indirectly, from
  # studio_chat/runtime_usage_test.exs via CycleFleet/RuntimeUsage. A distant
  # integration test is not coverage of this module: refactor either caller and
  # these arms lose their only witness silently.
  #
  # The cond in verify_task/2 is SEQUENTIAL:
  #   task_not_claimed -> doc_id -> workspace -> project -> dataset ->
  #   foreign_claim (worker) -> stale_claim (epoch) -> work_digest_mismatch
  # so each test below starts from a fully-matching expectation (asserted {:ok,_}
  # in setup) and perturbs exactly ONE thing. A fixture off by two fields would
  # land on the earlier arm and pass for the wrong reason.

  describe "lease refusals" do
    setup %{scope: scope} do
      task = mk_task!(uniq("cf-lease"), scope)
      {:ok, claimed} = Tasks.claim_by_id(task.doc_id, "worker-lease", scope)

      doc = Repo.get!(Document, claimed.id)
      claim = doc.content["claim"]

      matching = %{
        doc_id: doc.doc_id,
        worker_id: claim["worker"],
        epoch: claim["epoch"],
        work_digest: claim["work_digest"],
        workspace_id: doc.workspace_id,
        project_id: doc.project_id,
        dataset_id: doc.dataset_id
      }

      # Control: the un-perturbed expectation verifies, so every red below is
      # caused by the ONE perturbation and not by the fixture.
      assert {:ok, _} = ClaimFence.verify(doc.id, matching)

      %{doc: doc, matching: matching}
    end

    test "a worker that is not the claim holder returns {:error, :foreign_claim}",
         %{doc: doc, matching: matching} do
      expected = %{matching | worker_id: matching.worker_id <> "-other"}

      refute expected.worker_id == matching.worker_id
      assert {:error, :foreign_claim} = ClaimFence.verify(doc.id, expected)
    end

    test "a work_digest that is not the claim's returns {:error, :work_digest_mismatch}",
         %{doc: doc, matching: matching} do
      # epoch and worker still match, so the cond cannot stop at :foreign_claim
      # or :stale_claim — this fixture can only land on the digest arm.
      expected = %{matching | work_digest: "0000000000000000"}

      refute expected.work_digest == matching.work_digest
      assert {:error, :work_digest_mismatch} = ClaimFence.verify(doc.id, expected)
    end

    test "a task whose lease is gone returns {:error, :task_not_claimed}",
         %{doc: doc, matching: matching} do
      # Disjunct A — lifecycle_status leaves "in_progress". The expectation is
      # untouched: the TASK changed, not the caller's claim.
      {:ok, released} = Tasks.release(doc.id, matching.worker_id, observed_epoch: matching.epoch)
      refute released.content["lifecycle_status"] == "in_progress"

      assert {:error, :task_not_claimed} = ClaimFence.verify(doc.id, matching)

      # Disjunct B — lifecycle_status says "in_progress" but claim.worker is not
      # a binary. Without the `is_binary` half of the arm this row reaches
      # Map.fetch!(claim, "worker") in the {:ok,_} arm on a claim that has none.
      widowed =
        doc
        |> Repo.reload!()
        |> Ecto.Changeset.change(
          content:
            doc.content
            |> Map.put("lifecycle_status", "in_progress")
            |> Map.put("claim", Map.put(doc.content["claim"] || %{}, "worker", nil))
        )
        |> Repo.update!()

      assert widowed.content["lifecycle_status"] == "in_progress"
      refute is_binary(widowed.content["claim"]["worker"])
      assert {:error, :task_not_claimed} = ClaimFence.verify(doc.id, matching)
    end
  end
end
