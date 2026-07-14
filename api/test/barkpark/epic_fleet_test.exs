defmodule Barkpark.EpicFleetTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.EpicFleet
  alias Barkpark.EpicFleet.{Assignment, Result}

  setup do
    {workspace, _project} = Barkpark.TenancyFixtures.ensure_default_scope!()

    scope = %{
      workspace_id: workspace.id,
      epic_id: "epic-#{System.unique_integer([:positive])}",
      wave_id: "wave-1"
    }

    %{scope: scope}
  end

  describe "assignment snapshots" do
    test "snapshot digest is canonical and assignment replay is immutable", %{scope: scope} do
      left = %{"policy" => %{"effort" => "high", "checks" => ["test", "lint"]}}
      right = %{policy: %{checks: ["test", "lint"], effort: "high"}}

      assert EpicFleet.digest(left) == EpicFleet.digest(right)

      attrs = assignment_attrs(scope, "build-1", left)
      assert {:ok, assignment} = EpicFleet.create_assignment(attrs)
      assert assignment.snapshot == left
      assert assignment.snapshot_digest == EpicFleet.digest(left)

      assert {:ok, replay} = EpicFleet.create_assignment(%{attrs | snapshot: right})
      assert replay.id == assignment.id

      changed = put_in(left, ["policy", "effort"], "medium")
      assert {:error, :assignment_conflict} = EpicFleet.create_assignment(%{attrs | snapshot: changed})
      assert Repo.aggregate(Assignment, :count) == 1
    end

    test "database rejects assignment UPDATE", %{scope: scope} do
      {:ok, assignment} = EpicFleet.create_assignment(assignment_attrs(scope, "build-1"))

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("UPDATE epic_assignments SET effort = 'medium' WHERE id = $1", [
          Ecto.UUID.dump!(assignment.id)
        ])
      end
    end

    test "database rejects assignment DELETE", %{scope: scope} do
      {:ok, assignment} = EpicFleet.create_assignment(assignment_attrs(scope, "build-1"))

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("DELETE FROM epic_assignments WHERE id = $1", [Ecto.UUID.dump!(assignment.id)])
      end
    end
  end

  describe "terminal results" do
    test "terminal state vocabulary is exact and every state persists", %{scope: scope} do
      assert Result.terminal_states() == ["completed", "failed", "cancelled"]

      Enum.each(Result.terminal_states(), fn status ->
        assignment_id = "build-#{status}"
        {:ok, assignment} = EpicFleet.create_assignment(assignment_attrs(scope, assignment_id))

        attrs = result_attrs(status, "paper://#{assignment_id}")
        assert {:ok, %Result{status: ^status}} = EpicFleet.record_result(assignment, "key-#{status}", attrs)
      end)

      {:ok, assignment} = EpicFleet.create_assignment(assignment_attrs(scope, "build-invalid"))

      assert {:error, changeset} =
               EpicFleet.record_result(assignment, "key-invalid", result_attrs("unknown", "paper://bad"))

      assert "is invalid" in errors_on(changeset).status
    end

    test "concurrent same-key replay creates one row and returns one result", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      {:ok, assignment} = EpicFleet.create_assignment(assignment_attrs(scope, "build-1"))
      attrs = result_attrs("completed", "paper://build/1")

      ids =
        1..20
        |> Task.async_stream(
          fn _ ->
            {:ok, result} = EpicFleet.record_result(assignment, "terminal-1", attrs)
            {result.id, result.payload_digest}
          end,
          max_concurrency: 20,
          ordered: false,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, value} -> value end)
        |> Enum.uniq()

      assert [{result_id, digest}] = ids
      assert is_binary(result_id)
      assert String.length(digest) == 64
      assert Repo.aggregate(Result, :count) == 1
    end

    test "same key with different semantic payload returns a deterministic conflict", %{scope: scope} do
      {:ok, assignment} = EpicFleet.create_assignment(assignment_attrs(scope, "build-1"))
      attrs = result_attrs("completed", "paper://build/1")

      assert {:ok, result} = EpicFleet.record_result(assignment, "terminal-1", attrs)
      assert {:ok, replay} = EpicFleet.record_result(assignment, "terminal-1", attrs)
      assert replay.id == result.id

      assert {:error, :idempotency_conflict} =
               EpicFleet.record_result(
                 assignment,
                 "terminal-1",
                 Map.put(attrs, :summary, "different")
               )

      assert {:error, :terminal_result_conflict} =
               EpicFleet.record_result(assignment, "another-key", attrs)

      assert Repo.aggregate(Result, :count) == 1
    end

    test "database rejects result UPDATE and keeps evidence append-only", %{scope: scope} do
      {:ok, assignment} = EpicFleet.create_assignment(assignment_attrs(scope, "build-1"))
      {:ok, result} = EpicFleet.record_result(assignment, "terminal-1", result_attrs())

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("UPDATE epic_assignment_results SET summary = 'tampered' WHERE id = $1", [
          Ecto.UUID.dump!(result.id)
        ])
      end
    end
  end

  describe "fleet reduction" do
    test "replacement results count once and expose digest-pinned evidence", %{scope: scope} do
      {:ok, original} = EpicFleet.create_assignment(assignment_attrs(scope, "build-1"))

      replacement_attrs =
        scope
        |> assignment_attrs("build-1-retry")
        |> Map.put(:replaces_assignment_id, original.id)

      {:ok, replacement} = EpicFleet.create_assignment(replacement_attrs)

      assert {:ok, _failed} =
               EpicFleet.record_result(
                 original,
                 "terminal-original",
                 result_attrs("failed", "paper://build/1/failed")
               )

      assert {:ok, completed} =
               EpicFleet.record_result(
                 replacement,
                 "terminal-retry",
                 result_attrs("completed", "paper://build/1/retry")
               )

      assert {:ok, summary} = EpicFleet.reduce_fleet(scope, %{build: 1})
      assert summary.source == :ledger
      assert summary.ledger_present?
      assert String.length(summary.ledger_digest) == 64

      assert %{
               planned: 1,
               started: 2,
               completed: 1,
               failed: 1,
               missing: 0,
               assignments: [
                 %{
                   id: "build-1-retry",
                   agent_type: "epic-builder",
                   status: "completed",
                   evidence: "paper://build/1/retry"
                 }
               ]
             } = summary.fleet.build

      assert [proof] = summary.fleet.build.evidence_proofs
      assert proof.result_id == completed.id
      assert proof.revision == "paper-rev-1"
      assert String.length(proof.digest) == 64
      assert String.length(proof.payload_digest) == 64
    end

    test "legacy absence is explicit and never fabricates completion evidence", %{scope: scope} do
      assert {:ok, summary} = EpicFleet.reduce_fleet(scope)
      assert summary.source == :legacy_absent
      refute summary.ledger_present?

      assert summary.fleet.survey.completed == 0
      assert summary.fleet.survey.missing == 12
      assert summary.fleet.verify.missing == 6
      assert summary.fleet.build.missing == 3
      assert summary.fleet.review.missing == 3

      assert Enum.all?(summary.fleet, fn {_phase, phase} ->
               phase.assignments == [] and phase.evidence_proofs == []
             end)
    end
  end

  defp assignment_attrs(scope, assignment_id, snapshot \\ %{"task" => assignment_id}) do
    Map.merge(scope, %{
      assignment_id: assignment_id,
      phase: "build",
      agent_type: "epic-builder",
      effort: "high",
      snapshot: snapshot
    })
  end

  defp result_attrs(
         status \\ "completed",
         evidence \\ "paper://build/1"
       ) do
    %{
      status: status,
      summary: "terminal #{status}",
      evidence: evidence,
      evidence_revision: "paper-rev-1",
      payload: %{"tests" => "pass", "commit" => "abc123"}
    }
  end
end
