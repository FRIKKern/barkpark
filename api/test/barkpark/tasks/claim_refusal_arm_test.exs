defmodule Barkpark.Tasks.ClaimRefusalArmTest do
  @moduledoc """
  `claim_by_id/3` collapses THREE different refusals into one `:not_ready`
  atom, and the CLI turns that into one sentence covering all three
  ("someone else holds it or it isn't ready"). Three remedies, one word.

  task-eb2b6170e19f1611 filed this as a readiness-predicate BUG, on the
  premise that `task-ed7ae8110c7c8b41` (open, priority 0, claim released
  cleanly, no blockers) was wrongly excluded while a control row of the
  "same shape" claimed fine. That premise is FALSE, and this file proves it
  both ways:

    * the measured shape (open + VACANT released claim + no expired_at +
      priority 0) claims fine — so the shape is not the discriminator;
    * the actual discriminator is `content.queue_gate.state == "human_gated"`,
      set by the row's own author ("Do not claim this row to build"), read by
      `QueueGate.executable?/2` via `Claim.check_executable_for_targeted_claim/2`.
      The refusal is CORRECT. What was wrong is that it is unreadable.

  So the shippable defect is the one the row's own "REMAINING ASK" names:
  make the refusal SAY which arm fired. `TasksController.not_ready_arm/2` is
  that answer, and these tests pin all three arms.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias BarkparkWeb.TasksController

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # The EXACT claim shape measured on task-ed7ae8110c7c8b41 on 2026-08-23:
  # worker null, released_at + released_by present, epoch 5, NO expired_at key.
  @released_claim %{
    "worker" => nil,
    "epoch" => 5,
    "released_by" => "worker-import-grant",
    "released_at" => "2026-08-20T17:32:26.000000Z"
  }

  defp task!(scope, extra_content) do
    doc_id = uniq("arm")

    content =
      Map.merge(
        %{
          "kind" => "task",
          "acceptance_criteria" => [
            %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
          ],
          "lifecycle_status" => "open",
          "priority" => 0
        },
        extra_content
      )

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp reread(doc), do: Repo.get!(Document, doc.id)

  describe "the premise: the measured claim shape is NOT the blocker" do
    test "open + vacant released claim + no expired_at + priority 0 claims fine",
         %{scope: scope} do
      doc = task!(scope, %{"claim" => @released_claim})

      assert {:ok, claimed} = Tasks.claim_by_id(doc.doc_id, "go-tree-triage", scope)
      assert claimed.content["lifecycle_status"] == "in_progress"
      # Monotonic across release-then-reclaim: 5 → 6.
      assert get_in(claimed.content, ["claim", "epoch"]) == 6
    end
  end

  describe "not_ready_arm/2 names WHICH arm refused" do
    test "queue_gated: an author-set human_gated row (the real task-ed7ae8110c7c8b41 cause)",
         %{scope: scope} do
      gate = %{
        "version" => 1,
        "state" => "human_gated",
        "reason" => "needs an OPERATOR, not a builder. Do not claim this row to build."
      }

      doc = task!(scope, %{"claim" => @released_claim, "queue_gate" => gate})

      # The refusal itself is UNCHANGED — this arm is correct behaviour.
      assert {:error, :not_ready} = Tasks.claim_by_id(doc.doc_id, "go-tree-triage", scope)

      arm = TasksController.not_ready_arm(reread(doc), "go-tree-triage")
      assert arm.reason == "not_ready"
      assert arm.arm == "queue_gated"
      assert arm.execution_class == "human_gated"
      assert arm.gate_reason =~ "Do not claim this row to build"
      assert arm.message =~ "gated by its AUTHOR"
      refute Map.has_key?(arm, :held_by)
    end

    test "held_by_other: a live claim held by someone else", %{scope: scope} do
      doc = task!(scope, %{})
      {:ok, _} = Tasks.claim_by_id(doc.doc_id, "w-holder", scope)

      assert {:error, :not_ready} = Tasks.claim_by_id(doc.doc_id, "w-intruder", scope)

      arm = TasksController.not_ready_arm(reread(doc), "w-intruder")
      assert arm.reason == "not_ready"
      assert arm.arm == "held_by_other"
      assert arm.held_by == "w-holder"
      assert arm.message =~ "re-claim with it VERBATIM"
    end

    test "held_by_other also fires on a STRANDED row, and points at release", %{scope: scope} do
      doc = task!(scope, %{})
      {:ok, _} = Tasks.claim_by_id(doc.doc_id, "w-dead", scope)
      {:ok, _} = Tasks.stage(doc.id, "open")

      assert {:error, :not_ready} = Tasks.claim_by_id(doc.doc_id, "w-rescuer", scope)

      arm = TasksController.not_ready_arm(reread(doc), "w-rescuer")
      assert arm.arm == "held_by_other"
      assert arm.held_by == "w-dead"
      assert arm.message =~ "bp task release"
    end

    test "not_claimable_status: a lifecycle outside open|blocked", %{scope: scope} do
      doc = task!(scope, %{"lifecycle_status" => "considering"})

      assert {:error, :not_ready} = Tasks.claim_by_id(doc.doc_id, "w-any", scope)

      arm = TasksController.not_ready_arm(reread(doc), "w-any")
      assert arm.arm == "not_claimable_status"
      assert arm.lifecycle_status == "considering"
      assert arm.message =~ "bp task stage"
    end

    test "an absent pre-claim snapshot degrades to unknown, never a crash" do
      assert %{ok: false, reason: "not_ready", arm: "unknown"} =
               TasksController.not_ready_arm(nil, "w")
    end
  end
end
