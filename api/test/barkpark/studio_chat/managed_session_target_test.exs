defmodule Barkpark.StudioChat.ManagedSessionTargetTest do
  @moduledoc """
  wsc-steer-open-session-managed, criterion 1: the shared resolver returns the
  exact session for a managed Codex assignment, and nothing for the Claude
  lane, a stale attempt, an ambiguous pair or a session outside the caller's
  scope. Every fixture is built through the real CycleFleet doors
  (`open_wave` / `create_assignment` / `prepare_runtime_attempt`), never by
  inserting attempt rows by hand.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, CycleFleet, Tasks, Tenancy, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.CycleFleet.RuntimeAttempt
  alias Barkpark.StudioChat.ManagedSessionTarget

  @dataset "production"
  @worker "managed-codex-builder"

  setup do
    {workspace, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: workspace.id, project_id: project.id]
    {:ok, _dataset} = Tenancy.get_or_create_dataset(project, @dataset)
    register_task_schema!(scope)

    cycle_scope = %{
      workspace_id: workspace.id,
      project_id: project.id,
      epic_id: unique("steer-epic"),
      wave_id: unique("steer-wave")
    }

    {:ok, _wave} =
      CycleFleet.open_wave(
        Map.merge(cycle_scope, %{
          profile: "epic",
          inventory: ["unit-a", "unit-b"],
          scale_contract: %{}
        })
      )

    %{scope: scope, cycle_scope: cycle_scope, workspace: workspace}
  end

  test "a managed Codex assignment resolves to exactly its bound session", ctx do
    task = claimed_task!(ctx.scope)
    attempt = attempt!(ctx.cycle_scope, "unit-a", task)

    assert {:ok, target} = ManagedSessionTarget.resolve(task.doc_id)
    assert target.session_id == attempt.session_id
    assert target.assignment_id == attempt.assignment_id
    assert target.task_doc_id == bare(task.doc_id)

    # The draft-twin spelling of the same task resolves to the same session.
    assert {:ok, %{session_id: same}} = ManagedSessionTarget.resolve("drafts." <> task.doc_id)
    assert same == attempt.session_id
  end

  test "a Claude-lane task (no runtime attempt) resolves to nothing", ctx do
    task = claimed_task!(ctx.scope)
    assert :none = ManagedSessionTarget.resolve(task.doc_id)
  end

  test "an unknown, blank or non-string task id resolves to nothing" do
    assert :none = ManagedSessionTarget.resolve("task-does-not-exist")
    assert :none = ManagedSessionTarget.resolve("")
    assert :none = ManagedSessionTarget.resolve("drafts.")
    assert :none = ManagedSessionTarget.resolve(nil)
  end

  test "a stale attempt (the claim it froze is no longer live) resolves to nothing", ctx do
    task = claimed_task!(ctx.scope)
    _attempt = attempt!(ctx.cycle_scope, "unit-a", task)
    assert {:ok, _} = ManagedSessionTarget.resolve(task.doc_id)

    {:ok, _released} =
      Tasks.release(task.id, @worker, observed_epoch: get_in(task.content, ["claim", "epoch"]))

    assert :none = ManagedSessionTarget.resolve(task.doc_id)
  end

  # epic_assignment_tasks is unique on task_id, so one task ROW can carry only
  # one assignment. The ambiguity that remains is a task whose published row
  # and draft twin are BOTH bound and both still hold the live claim.
  test "live attempts on a task's published row AND its draft twin are ambiguous", ctx do
    task = claimed_task!(ctx.scope)
    first = attempt!(ctx.cycle_scope, "unit-a", task)
    twin = twin_row!(task)
    second = attempt!(ctx.cycle_scope, "unit-b", twin)
    assert first.session_id != second.session_id
    assert first.task_id != second.task_id

    assert :none = ManagedSessionTarget.resolve(task.doc_id)
  end

  test "a session outside the caller's scope resolves to nothing", ctx do
    task = claimed_task!(ctx.scope)
    _attempt = attempt!(ctx.cycle_scope, "unit-a", task)

    assert {:ok, _} = ManagedSessionTarget.resolve(task.doc_id, scope: :global)
    assert :none = ManagedSessionTarget.resolve(task.doc_id, scope: Ecto.UUID.generate())
  end

  defp claimed_task!(scope) do
    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => unique("steer-task"),
          "title" => "Managed builder slice",
          "content" => %{
            "kind" => "task",
            "description" => "a managed codex slice",
            "acceptance_criteria" => [
              %{"criterion" => "the fixture states its bar", "met" => false}
            ],
            "lifecycle_status" => "open"
          }
        },
        @dataset,
        scope
      )

    {:ok, claimed} = Tasks.claim_by_id(task.doc_id, @worker, scope)
    claimed
  end

  defp attempt!(cycle_scope, unit, task) do
    {:ok, assignment} =
      CycleFleet.create_assignment(
        Map.merge(cycle_scope, %{
          assignment_id: unit,
          phase: "survey",
          agent_type: "epic-surveyor",
          effort: "medium",
          task_id: task.id,
          snapshot: %{"purpose" => "managed session target"}
        })
      )

    claim = %{
      task_id: task.id,
      worker_id: get_in(task.content, ["claim", "worker"]),
      epoch: get_in(task.content, ["claim", "epoch"]),
      work_digest: get_in(task.content, ["claim", "work_digest"])
    }

    {:ok, %RuntimeAttempt{} = attempt} = CycleFleet.prepare_runtime_attempt(assignment, claim)
    attempt
  end

  # The other spelling of the same task, carrying the same content (claim
  # included): the published/draft pair the join collapses into one task.
  defp twin_row!(%Document{} = row) do
    other =
      if String.starts_with?(row.doc_id, "drafts."),
        do: bare(row.doc_id),
        else: "drafts." <> row.doc_id

    row
    |> Map.from_struct()
    |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
    |> Map.merge(%{doc_id: other, slug_text: nil, author_text: nil, category_text: nil})
    |> then(&struct(Document, &1))
    |> Repo.insert!()
  end

  defp bare(doc_id), do: String.replace_prefix(doc_id, "drafts.", "")

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
