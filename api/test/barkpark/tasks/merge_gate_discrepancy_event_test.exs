defmodule Barkpark.Tasks.MergeGateDiscrepancyEventTest do
  @moduledoc """
  task-415cc445dacc889a: the merge-reconcile discrepancy record
  (`content.merge_gate_autostamp.discrepancy`, written by
  `Close.record_discrepancy_only/3` on every arm that stamps nothing) moves the
  task's rev, so it must carry a `task.criterion` `mutation_events` row, as the
  stamping arm's `write_reconcile/6` already does for the same key.

  Without it the record naming a false close was invisible to `bp task events`,
  SSE and the board, and the silent rev move tripped the next CAS writer's
  fence with nothing to explain it.

  Fixture shape: `Barkpark.Tasks.MergeGateDiscrepancyTest`.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}

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

  # A done task whose merge gate the close already stamped: the
  # `:already_stamped` arm, which records a discrepancy and stamps nothing.
  defp sealed_task!(scope, autostamp) do
    doc_id = "mg-discrepancy-ev-#{System.unique_integer([:positive])}"

    content =
      %{
        "kind" => "task",
        "lifecycle_status" => "done",
        "acceptance_criteria" => [
          %{"criterion" => "feature built", "met" => true, "evidence" => "local run"},
          %{
            "criterion" => "MERGE GATE: PR merged to origin/main",
            "met" => true,
            "merge_gate" => true,
            "evidence" => "auto: lead-closed on merge"
          }
        ]
      }
      |> then(fn c ->
        if autostamp, do: Map.put(c, "merge_gate_autostamp", autostamp), else: c
      end)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp close_record(summary) do
    %{
      "close" => %{
        "verified" => false,
        "source" => "close_landed_digest",
        "indices" => [1],
        "asserted_worker" => "scratch-worker",
        "authenticated_token_id" => "tok-9",
        "landed" => summary,
        "witnessed_prs" => [],
        "ts" => "2026-09-10T00:00:00Z"
      }
    }
  end

  defp criterion_events(%Document{doc_id: doc_id}) do
    Repo.all(
      from(e in MutationEvent,
        where: e.doc_id == ^doc_id and e.mutation == "task.criterion",
        order_by: [asc: e.id]
      )
    )
  end

  @landed %{"prs" => [17_070], "commit" => "f7610ed6a"}

  test "a recorded discrepancy lands with a task.criterion event naming the new rev",
       %{scope: scope} do
    task = sealed_task!(scope, close_record("PR #99999"))
    assert criterion_events(task) == []

    assert {:ok, :already_stamped} = Tasks.reconcile_merge_gate(task.id, @landed)

    stored = Repo.get!(Document, task.id)
    assert stored.content["merge_gate_autostamp"]["discrepancy"]["unwitnessed_prs"] == ["99999"]

    events = criterion_events(task)

    assert length(events) == 1,
           "the discrepancy moved the rev with no mutation_events row — invisible to " <>
             "bp task events, SSE and the board"

    [ev] = events
    assert ev.rev == stored.rev
    assert ev.previous_rev == task.rev
    assert ev.source == "github-merge"
  end

  test "CONTROL: a replayed delivery records nothing new and writes no second event",
       %{scope: scope} do
    task = sealed_task!(scope, close_record("PR #99999"))

    assert {:ok, :already_stamped} = Tasks.reconcile_merge_gate(task.id, @landed)
    assert {:ok, :already_stamped} = Tasks.reconcile_merge_gate(task.id, @landed)

    assert length(criterion_events(task)) == 1
  end

  test "CONTROL: a reconcile with no discrepancy to record writes no event", %{scope: scope} do
    task = sealed_task!(scope, nil)

    assert {:ok, :already_stamped} = Tasks.reconcile_merge_gate(task.id, @landed)

    assert criterion_events(task) == []
    assert Repo.get!(Document, task.id).rev == task.rev
  end
end
