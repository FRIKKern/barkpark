defmodule Barkpark.EpicFleetTest do
  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Barkpark.TenancyFixtures

  alias Barkpark.EpicFleet
  alias Barkpark.EpicFleet.{Assignment, Result}
  alias Barkpark.Tenancy

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
      assert {:ok, assignment, :created} = EpicFleet.create_assignment_with_status(attrs)
      assert assignment.snapshot == left
      assert assignment.snapshot_digest == EpicFleet.digest(left)

      assert {:ok, replay, :replayed} =
               EpicFleet.create_assignment_with_status(%{attrs | snapshot: right})

      assert replay.id == assignment.id

      changed = put_in(left, ["policy", "effort"], "medium")

      assert {:error, :assignment_conflict} =
               EpicFleet.create_assignment(%{attrs | snapshot: changed})

      assert Repo.aggregate(Assignment, :count) == 1
    end

    test "concurrent exact inserts report one creator and replay all losers", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      attrs = assignment_attrs(scope, "build-concurrent")

      outcomes =
        1..12
        |> Task.async_stream(
          fn _ -> EpicFleet.create_assignment_with_status(attrs) end,
          max_concurrency: 12,
          ordered: false,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, outcome} -> outcome end)

      assert 1 == Enum.count(outcomes, &match?({:ok, %Assignment{}, :created}, &1))
      assert 11 == Enum.count(outcomes, &match?({:ok, %Assignment{}, :replayed}, &1))

      assert outcomes
             |> Enum.map(fn {:ok, assignment, _status} -> assignment.id end)
             |> Enum.uniq()
             |> length() == 1
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

    test "replacement keeps the original phase and agent type", %{scope: scope} do
      {:ok, original} = EpicFleet.create_assignment(assignment_attrs(scope, "build-1"))

      base =
        scope
        |> assignment_attrs("build-1-retry")
        |> Map.put(:replaces_assignment_id, original.id)

      assert {:error, :replacement_phase_mismatch} =
               base
               |> Map.merge(%{phase: "review", agent_type: "code-reviewer"})
               |> EpicFleet.create_assignment()

      assert {:error, :replacement_agent_type_mismatch} =
               base
               |> Map.put(:agent_type, "other-builder")
               |> EpicFleet.create_assignment()

      assert Repo.aggregate(Assignment, :count) == 1
    end

    test "concurrent direct successors admit exactly one replacement", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      {:ok, original} = EpicFleet.create_assignment(assignment_attrs(scope, "build-1"))
      {:ok, _failed} = EpicFleet.record_result(original, "failed", result_attrs("failed"))

      outcomes =
        1..12
        |> Task.async_stream(
          fn ordinal ->
            scope
            |> assignment_attrs("build-1-retry-#{ordinal}")
            |> Map.put(:replaces_assignment_id, original.id)
            |> EpicFleet.create_assignment()
          end,
          max_concurrency: 12,
          ordered: false,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, outcome} -> outcome end)

      assert 1 == Enum.count(outcomes, &match?({:ok, %Assignment{}}, &1))

      assert 11 == Enum.count(outcomes, &match?({:error, :assignment_already_replaced}, &1))

      assert Repo.aggregate(
               from(a in Assignment, where: a.replaces_assignment_id == ^original.id),
               :count
             ) == 1
    end
  end

  describe "terminal results" do
    test "terminal state vocabulary is exact and every state persists", %{scope: scope} do
      assert Result.terminal_states() == ["completed", "failed", "cancelled"]

      Enum.each(Result.terminal_states(), fn status ->
        assignment_id = "build-#{status}"
        {:ok, assignment} = EpicFleet.create_assignment(assignment_attrs(scope, assignment_id))

        attrs = result_attrs(status, "paper://#{assignment_id}")

        assert {:ok, %Result{status: ^status}} =
                 EpicFleet.record_result(assignment, "key-#{status}", attrs)
      end)

      {:ok, assignment} = EpicFleet.create_assignment(assignment_attrs(scope, "build-invalid"))

      assert {:error, changeset} =
               EpicFleet.record_result(
                 assignment,
                 "key-invalid",
                 result_attrs("unknown", "paper://bad")
               )

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

    test "same key with different semantic payload returns a deterministic conflict", %{
      scope: scope
    } do
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

    test "database rejects result DELETE", %{scope: scope} do
      {:ok, assignment} = EpicFleet.create_assignment(assignment_attrs(scope, "build-1"))
      {:ok, result} = EpicFleet.record_result(assignment, "terminal-1", result_attrs())

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("DELETE FROM epic_assignment_results WHERE id = $1", [
          Ecto.UUID.dump!(result.id)
        ])
      end
    end

    test "database requires pinned evidence for completed results", %{scope: scope} do
      {:ok, assignment} = EpicFleet.create_assignment(assignment_attrs(scope, "build-1"))
      digest = String.duplicate("a", 64)

      assert_raise Postgrex.Error, ~r/epic_assignment_results_completed_evidence/, fn ->
        Repo.query!(
          """
          INSERT INTO epic_assignment_results
            (id, assignment_id, idempotency_key, status, evidence_digest, payload, payload_digest, inserted_at)
          VALUES (gen_random_uuid(), $1, 'raw-complete', 'completed', $2, '{}'::jsonb, $2, now())
          """,
          [Ecto.UUID.dump!(assignment.id), digest]
        )
      end
    end
  end

  describe "forward hardening migration" do
    test "an already-created ledger receives the corrected evidence and cascade constraints" do
      version = 20_260_715_000_300

      assert %{rows: [[^version]]} =
               Repo.query!("SELECT version FROM schema_migrations WHERE version = $1", [version])

      assert %{rows: [[evidence_check]]} =
               Repo.query!("""
               SELECT pg_get_constraintdef(oid)
               FROM pg_constraint
               WHERE conname = 'epic_assignment_results_completed_evidence'
               """)

      assert evidence_check =~ "evidence IS NOT NULL"
      assert evidence_check =~ "evidence_revision IS NOT NULL"

      assert %{rows: [["c"], ["c"]]} =
               Repo.query!("""
               SELECT confdeltype::text
               FROM pg_constraint
               WHERE conname IN (
                 'epic_assignments_workspace_id_fkey',
                 'epic_assignment_results_assignment_id_fkey'
               )
               ORDER BY conname
               """)

      assert %{rows: [[true]]} =
               Repo.query!(
                 "SELECT to_regclass('epic_assignments_replaces_assignment_index') IS NOT NULL"
               )
    end
  end

  describe "workspace teardown" do
    test "canonical deletion cascades only the target workspace ledger" do
      deleted_workspace = create_workspace!()
      survivor_workspace = create_workspace!()

      deleted_scope = %{
        workspace_id: deleted_workspace.id,
        epic_id: "epic-delete",
        wave_id: "wave-1"
      }

      survivor_scope = %{
        workspace_id: survivor_workspace.id,
        epic_id: "epic-survive",
        wave_id: "wave-1"
      }

      {:ok, deleted_assignment} =
        EpicFleet.create_assignment(assignment_attrs(deleted_scope, "build-delete"))

      {:ok, deleted_result} =
        EpicFleet.record_result(deleted_assignment, "terminal-delete", result_attrs())

      {:ok, survivor_assignment} =
        EpicFleet.create_assignment(assignment_attrs(survivor_scope, "build-survive"))

      {:ok, survivor_result} =
        EpicFleet.record_result(survivor_assignment, "terminal-survive", result_attrs())

      assert {:ok, _workspace} = Tenancy.delete_workspace(deleted_workspace)

      assert is_nil(EpicFleet.get_assignment(deleted_assignment.id))
      assert is_nil(Repo.get(Result, deleted_result.id))
      assert EpicFleet.get_assignment(survivor_assignment.id).id == survivor_assignment.id
      assert Repo.get(Result, survivor_result.id).id == survivor_result.id
    end
  end

  describe "fleet reduction" do
    test "replacement results count once and expose digest-pinned evidence", %{scope: scope} do
      {:ok, original} = EpicFleet.create_assignment(assignment_attrs(scope, "build-1"))

      assert {:ok, _failed} =
               EpicFleet.record_result(
                 original,
                 "terminal-original",
                 result_attrs("failed", "paper://build/1/failed")
               )

      replacement_attrs =
        scope
        |> assignment_attrs("build-1-retry")
        |> Map.put(:replaces_assignment_id, original.id)

      {:ok, replacement} = EpicFleet.create_assignment(replacement_attrs)

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
      assert summary.fleet.build.unresolved_failures == 0
      assert summary.fleet.build.unresolved_missing == 0
    end

    test "one logical assignment cannot fork into sibling replacements", %{scope: scope} do
      {:ok, original} = EpicFleet.create_assignment(assignment_attrs(scope, "build-1"))
      {:ok, _failed} = EpicFleet.record_result(original, "failed", result_attrs("failed"))

      attrs =
        scope
        |> assignment_attrs("build-1-retry")
        |> Map.put(:replaces_assignment_id, original.id)

      assert {:ok, _replacement} = EpicFleet.create_assignment(attrs)
      assert {:ok, replay} = EpicFleet.create_assignment(attrs)
      assert replay.assignment_id == "build-1-retry"

      assert {:error, :assignment_already_replaced} =
               attrs
               |> Map.put(:assignment_id, "build-1-sibling")
               |> EpicFleet.create_assignment()
    end

    test "replacement must preserve phase and typed agent contract", %{scope: scope} do
      {:ok, original} = EpicFleet.create_assignment(assignment_attrs(scope, "build-1"))
      {:ok, _failed} = EpicFleet.record_result(original, "failed", result_attrs("failed"))

      assert {:error, :replacement_phase_mismatch} =
               scope
               |> assignment_attrs("verify-retry")
               |> Map.merge(%{
                 phase: "verify",
                 agent_type: "epic-verifier",
                 replaces_assignment_id: original.id
               })
               |> EpicFleet.create_assignment()
    end

    test "replacement requires a failed or cancelled predecessor", %{scope: scope} do
      {:ok, pending} = EpicFleet.create_assignment(assignment_attrs(scope, "build-pending"))

      pending_retry =
        scope
        |> assignment_attrs("build-pending-retry")
        |> Map.put(:replaces_assignment_id, pending.id)

      assert {:error, :replacement_predecessor_pending} =
               EpicFleet.create_assignment(pending_retry)

      {:ok, completed} = EpicFleet.create_assignment(assignment_attrs(scope, "build-completed"))
      {:ok, _result} = EpicFleet.record_result(completed, "completed", result_attrs())

      assert {:error, :replacement_predecessor_not_replaceable} =
               scope
               |> assignment_attrs("build-completed-retry")
               |> Map.put(:replaces_assignment_id, completed.id)
               |> EpicFleet.create_assignment()

      {:ok, cancelled} = EpicFleet.create_assignment(assignment_attrs(scope, "build-cancelled"))

      {:ok, _result} =
        EpicFleet.record_result(cancelled, "cancelled", result_attrs("cancelled"))

      assert {:ok, _replacement} =
               scope
               |> assignment_attrs("build-cancelled-retry")
               |> Map.put(:replaces_assignment_id, cancelled.id)
               |> EpicFleet.create_assignment()
    end

    test "an unreplaced failed leaf remains unresolved", %{scope: scope} do
      {:ok, failed} = EpicFleet.create_assignment(assignment_attrs(scope, "build-failed"))
      {:ok, _result} = EpicFleet.record_result(failed, "failed", result_attrs("failed"))

      assert {:ok, summary} = EpicFleet.reduce_fleet(scope, %{build: 1})
      assert summary.fleet.build.unresolved_failures == 1
      assert summary.fleet.build.completed == 0
    end

    test "wrong effort is invalid evidence and cannot complete the planned fleet", %{scope: scope} do
      {:ok, assignment} =
        scope
        |> assignment_attrs("build-wrong-effort")
        |> Map.put(:effort, "medium")
        |> EpicFleet.create_assignment()

      {:ok, _result} = EpicFleet.record_result(assignment, "completed", result_attrs())

      assert {:ok, summary} = EpicFleet.reduce_fleet(scope, %{build: 1})
      assert summary.fleet.build.completed == 0
      assert summary.fleet.build.missing == 1
      assert summary.fleet.build.invalid_assignments == 1
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

  defp assignment_attrs(scope, assignment_id),
    do: assignment_attrs(scope, assignment_id, %{"task" => assignment_id})

  defp assignment_attrs(scope, assignment_id, snapshot) do
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
