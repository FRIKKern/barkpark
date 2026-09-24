defmodule Barkpark.CycleFleetRuntimeAttemptAttributionTest do
  @moduledoc """
  task-7e030886e10dc0d3 — home witnesses for
  `CycleFleet.current_runtime_attempt_attribution/1`, whose `with` fall-through
  (`_ -> {:error, :task_not_claimed}`, census arm CY4 of task-888cded6b75503ee)
  had no test anywhere: deleting it redded nothing.

  WHAT ACTUALLY REACHES THE FALL-THROUGH. Not an unclaimed task. The `with`
  has three pattern steps that can fail with a value the `else` must place:

  * `claim when is_map(claim)` — a `nil` claim fails with `nil`, and `nil` is
    caught by the `nil -> :runtime_attempt_authority_not_found` arm, NOT the
    fall-through. A claim-less task row therefore reports "authority not
    found", not "task not claimed" (pinned below, so a change to that is a
    deliberate one).
  * `epoch when is_integer(epoch)` — same: a missing epoch is `nil` and lands
    in the authority arm.
  * a RELEASED task keeps its claim map (worker `nil`, integer epoch), so it
    passes both steps and is refused by `ClaimFence.verify/2` with
    `:task_not_claimed`, which the `{:error, reason}` arm passes through.

  So the fall-through is reached only by a stored claim that is truthy but
  MALFORMED: a claim that is not a map, or an epoch that is not an integer
  (e.g. the string a `bp doc patch` or a JSON round-trip through a string field
  would leave). Both tests below build exactly that state on a row that is
  otherwise live-claimed, so the only step that can refuse is the `with`'s own
  guard, and deleting the arm raises `WithClauseError` instead.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, CycleFleet, Repo, Tasks, Tenancy, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.CycleFleet.RuntimeAttempt

  @dataset "production"
  @worker "attribution-holder"

  setup do
    {workspace, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: workspace.id, project_id: project.id]
    {:ok, _dataset} = Tenancy.get_or_create_dataset(project, @dataset)
    register_task_schema!(scope)

    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => unique("attribution-task"),
          "title" => "Attribution task",
          "content" => %{
            "kind" => "task",
            "description" => "the brief",
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
      epic_id: unique("attribution-epic"),
      wave_id: unique("attribution-wave")
    }

    {:ok, _wave} =
      CycleFleet.open_wave(
        Map.merge(cycle_scope, %{
          profile: "epic",
          inventory: ["attribution-unit"],
          scale_contract: %{}
        })
      )

    {:ok, assignment} =
      CycleFleet.create_assignment(
        Map.merge(cycle_scope, %{
          assignment_id: "attribution-unit",
          phase: "survey",
          agent_type: "epic-surveyor",
          effort: "medium",
          task_id: claimed.id,
          snapshot: %{"purpose" => "runtime-attempt attribution"}
        })
      )

    claim = %{
      task_id: claimed.id,
      worker_id: get_in(claimed.content, ["claim", "worker"]),
      epoch: get_in(claimed.content, ["claim", "epoch"]),
      work_digest: get_in(claimed.content, ["claim", "work_digest"])
    }

    {:ok, %RuntimeAttempt{} = attempt} = CycleFleet.prepare_runtime_attempt(assignment, claim)

    # Control: on the untouched row the attribution resolves, so every refusal
    # below is caused by the ONE field each test corrupts, not by the fixture.
    assert {:ok, %{task: %{id: id, worker_id: @worker, epoch: epoch}}} =
             CycleFleet.current_runtime_attempt_attribution(attempt)

    assert id == claimed.id
    assert epoch == claim.epoch

    %{task: claimed, attempt: attempt, claim: claim}
  end

  describe "the with fall-through (CY4)" do
    test "a live claim whose epoch is stored as a non-integer is :task_not_claimed", ctx do
      put_claim!(ctx.task.id, fn claim -> Map.put(claim, "epoch", to_string(claim["epoch"])) end)

      # Precondition: the row is still in_progress with a binary worker and a
      # map claim, so authority lookup, task match and the is_map step pass;
      # only the `is_integer(epoch)` step can fail, with a truthy value.
      row = Repo.get!(Document, ctx.task.id)
      assert row.content["lifecycle_status"] == "in_progress"
      assert row.content["claim"]["worker"] == @worker
      assert is_binary(row.content["claim"]["epoch"])

      assert {:error, :task_not_claimed} =
               CycleFleet.current_runtime_attempt_attribution(ctx.attempt)
    end

    test "a stored claim that is not a map is :task_not_claimed", ctx do
      put_claim!(ctx.task.id, fn _claim -> @worker end)

      row = Repo.get!(Document, ctx.task.id)
      assert row.content["lifecycle_status"] == "in_progress"
      assert row.content["claim"] == @worker

      assert {:error, :task_not_claimed} =
               CycleFleet.current_runtime_attempt_attribution(ctx.attempt)
    end
  end

  describe "the arms around it (what does NOT reach the fall-through)" do
    test "a released task is refused by ClaimFence, passed through as :task_not_claimed", ctx do
      {:ok, released} = Tasks.release(ctx.task.id, @worker, observed_epoch: ctx.claim.epoch)

      # The claim survives release as a map with an integer epoch, so the
      # `with` reaches verify_runtime_attempt_claim and the refusal is
      # ClaimFence's, not the fall-through's.
      assert is_map(released.content["claim"])
      assert is_integer(released.content["claim"]["epoch"])

      assert {:error, :task_not_claimed} =
               CycleFleet.current_runtime_attempt_attribution(ctx.attempt)
    end

    test "a claim-less row reports :runtime_attempt_authority_not_found, not :task_not_claimed",
         ctx do
      put_claim!(ctx.task.id, fn _claim -> nil end)

      assert {:error, :runtime_attempt_authority_not_found} =
               CycleFleet.current_runtime_attempt_attribution(ctx.attempt)
    end

    test "an attempt naming a different task than its assignment is :runtime_attempt_authority_not_found",
         ctx do
      forged = %{ctx.attempt | task_id: Ecto.UUID.generate()}

      assert {:error, :runtime_attempt_authority_not_found} =
               CycleFleet.current_runtime_attempt_attribution(forged)
    end

    test "a non-attempt is :runtime_attempt_authority_not_found" do
      assert {:error, :runtime_attempt_authority_not_found} =
               CycleFleet.current_runtime_attempt_attribution(nil)
    end
  end

  defp put_claim!(task_id, fun) do
    row = Repo.get!(Document, task_id)

    row
    |> Ecto.Changeset.change(content: Map.put(row.content, "claim", fun.(row.content["claim"])))
    |> Repo.update!()
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
