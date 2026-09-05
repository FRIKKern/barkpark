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
end
