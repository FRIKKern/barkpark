defmodule Barkpark.CycleFleetRuntimeAttemptFenceTest do
  @moduledoc """
  task-888cded6b75503ee — home witnesses for `CycleFleet`'s OWN runtime-attempt
  claim cond (`verify_runtime_attempt_claim/3`), which had none anywhere.

  WHY THE EXISTING ASSERTIONS DID NOT COUNT. `studio_chat/runtime_usage_test.exs`
  asserts `{:error, :foreign_claim}` and `{:error, :work_digest_mismatch}`
  through `CycleFleet.prepare_runtime_attempt/2`, and a name-keyed grep reads
  that as coverage of this cond. Measured by mutation it is not: delete this
  cond's `:foreign_claim` or `:work_digest_mismatch` arm and that suite stays
  green, because every fixture there is ALSO refused by `ClaimFence.verify/2`
  (the caller is not the task's live holder), which returns the same atom one
  call later. The cond's arms only DECIDE anything when ClaimFence would pass:
  the task's live claim has moved on (a new holder, or a re-claim over an
  edited brief) and the caller presents that NEW live claim against an attempt
  frozen under the OLD one. Each test below builds exactly that state, so
  deleting the arm turns the refusal into `{:ok, attempt}` and reds here.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, CycleFleet, Repo, Tasks, Tenancy, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.CycleFleet.RuntimeAttempt

  @dataset "production"
  @worker "fence-holder-a"

  setup do
    {workspace, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: workspace.id, project_id: project.id]
    {:ok, _dataset} = Tenancy.get_or_create_dataset(project, @dataset)
    register_task_schema!(scope)

    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => unique("attempt-cond-task"),
          "title" => "Attempt cond task",
          "content" => %{
            "kind" => "task",
            "description" => "the original brief",
            "acceptance_criteria" => [
              %{
                "criterion" => "the fixture states its bar",
                "met" => true,
                "evidence" => "fixture"
              }
            ],
            "lifecycle_status" => "open"
          }
        },
        @dataset,
        scope
      )

    {:ok, claimed} = Tasks.claim_by_id(task.doc_id, @worker, scope)

    cycle_scope = %{
      workspace_id: workspace.id,
      project_id: project.id,
      epic_id: unique("attempt-cond-epic"),
      wave_id: unique("attempt-cond-wave")
    }

    {:ok, _wave} =
      CycleFleet.open_wave(
        Map.merge(cycle_scope, %{
          profile: "epic",
          inventory: ["attempt-cond-unit"],
          scale_contract: %{}
        })
      )

    {:ok, assignment} =
      CycleFleet.create_assignment(
        Map.merge(cycle_scope, %{
          assignment_id: "attempt-cond-unit",
          phase: "survey",
          agent_type: "epic-surveyor",
          effort: "medium",
          task_id: claimed.id,
          snapshot: %{"purpose" => "runtime-attempt claim cond"}
        })
      )

    first_claim = live_claim(claimed)

    # The attempt is frozen under holder A's claim.
    {:ok, %RuntimeAttempt{} = attempt} =
      CycleFleet.prepare_runtime_attempt(assignment, first_claim)

    assert attempt.task_worker_id == @worker

    # Control: the exact replay is accepted, so every refusal below is caused
    # by the ONE thing each test moves, not by the fixture.
    assert {:ok, %RuntimeAttempt{}} = CycleFleet.prepare_runtime_attempt(assignment, first_claim)

    %{scope: scope, task: claimed, assignment: assignment, first_claim: first_claim}
  end

  test "a NEW live holder presenting its own current claim against an attempt frozen under another worker is :foreign_claim",
       ctx do
    {:ok, _} =
      Tasks.release(ctx.task.id, @worker, observed_epoch: ctx.first_claim.epoch)

    {:ok, reclaimed} = Tasks.claim_by_id(ctx.task.doc_id, "fence-holder-b", ctx.scope)
    b_claim = live_claim(reclaimed)

    # Precondition: B's claim IS the live one, so ClaimFence alone would pass
    # it — only the cond's worker arm can refuse this.
    assert {:ok, _} = Tasks.verify_claim_fence(ctx.task.id, fence_expectation(reclaimed, b_claim))
    refute b_claim.worker_id == ctx.first_claim.worker_id

    assert {:error, :foreign_claim} = CycleFleet.prepare_runtime_attempt(ctx.assignment, b_claim)
  end

  test "the SAME holder re-claiming over an edited brief is :work_digest_mismatch against the frozen attempt",
       ctx do
    {:ok, _} =
      Tasks.release(ctx.task.id, @worker, observed_epoch: ctx.first_claim.epoch)

    # Someone rewrites the brief while the lease is down.
    released = Repo.get!(Document, ctx.task.id)

    released
    |> Ecto.Changeset.change(
      content: Map.put(released.content, "description", "a rewritten brief")
    )
    |> Repo.update!()

    {:ok, reclaimed} = Tasks.claim_by_id(ctx.task.doc_id, @worker, ctx.scope)
    new_claim = live_claim(reclaimed)

    # Precondition: same worker (so the worker arm cannot fire first), a moved
    # digest, and a claim ClaimFence alone would accept.
    assert new_claim.worker_id == ctx.first_claim.worker_id
    refute new_claim.work_digest == ctx.first_claim.work_digest

    assert {:ok, _} =
             Tasks.verify_claim_fence(ctx.task.id, fence_expectation(reclaimed, new_claim))

    assert {:error, :work_digest_mismatch} =
             CycleFleet.prepare_runtime_attempt(ctx.assignment, new_claim)
  end

  defp live_claim(%Document{} = doc) do
    %{
      task_id: doc.id,
      worker_id: get_in(doc.content, ["claim", "worker"]),
      epoch: get_in(doc.content, ["claim", "epoch"]),
      work_digest: get_in(doc.content, ["claim", "work_digest"])
    }
  end

  defp fence_expectation(%Document{} = doc, claim) do
    claim
    |> Map.put(:doc_id, doc.doc_id)
    |> Map.put(:workspace_id, doc.workspace_id)
    |> Map.put(:project_id, doc.project_id)
    |> Map.put(:dataset_id, doc.dataset_id)
  end

  defp register_task_schema!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {key, value} -> {to_string(key), value} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
