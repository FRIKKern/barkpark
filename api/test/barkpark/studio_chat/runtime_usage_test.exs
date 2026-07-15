defmodule Barkpark.StudioChat.RuntimeUsageTest do
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.{Content, CycleFleet, Repo, StudioChat, Tasks, Tenancy, TenancyFixtures}
  alias Barkpark.CycleFleet.AssignmentTask
  alias Barkpark.StudioChat.Runtime.Event
  alias Barkpark.StudioChat.RuntimeUsage
  alias Barkpark.StudioChat.RuntimeUsage.Receipt

  @dataset "production"
  @worker "cycle-builder"

  setup do
    {workspace, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: workspace.id, project_id: project.id]
    {:ok, dataset} = Tenancy.get_or_create_dataset(project, @dataset)
    register_task_schema!(scope)

    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => unique("usage-task"),
          "title" => "Usage task",
          "content" => %{"kind" => "task", "lifecycle_status" => "open"}
        },
        @dataset,
        scope
      )

    {:ok, claimed} = Tasks.claim_by_id(task.doc_id, @worker, scope)
    session_id = Ecto.UUID.generate()

    {:ok, _session} =
      StudioChat.create_session(
        %{
          id: session_id,
          provider: "codex",
          execution_target: "managed",
          provider_session_id: "provider-thread-1",
          mode: "plan"
        },
        {:workspace, workspace.id}
      )

    cycle_scope = %{
      workspace_id: workspace.id,
      project_id: project.id,
      epic_id: unique("runtime-epic"),
      wave_id: unique("runtime-wave")
    }

    {:ok, wave} =
      CycleFleet.open_wave(
        Map.merge(cycle_scope, %{
          profile: "epic",
          inventory: ["runtime-unit"],
          scale_contract: %{}
        })
      )

    assignment_attrs =
      Map.merge(cycle_scope, %{
        assignment_id: unique("runtime-assignment"),
        phase: "survey",
        agent_type: "epic-surveyor",
        effort: "medium",
        task_id: claimed.id,
        snapshot: %{"purpose" => "runtime usage authority"}
      })

    {:ok, assignment} = CycleFleet.create_assignment(assignment_attrs)

    attribution = %{
      assignment_id: assignment.id,
      task: %{
        id: claimed.id,
        worker_id: @worker,
        epoch: get_in(claimed.content, ["claim", "epoch"]),
        work_digest: get_in(claimed.content, ["claim", "work_digest"])
      }
    }

    %{
      workspace: workspace,
      project: project,
      dataset: dataset,
      scope: scope,
      cycle_scope: cycle_scope,
      assignment_attrs: assignment_attrs,
      task: claimed,
      wave: wave,
      assignment: assignment,
      session_id: session_id,
      attribution: attribution
    }
  end

  test "valid monotonic terminal-minus-baseline receipts reduce to token_count", ctx do
    assert {:ok, :recorded} =
             RuntimeUsage.observe(
               ctx.attribution,
               :baseline,
               event(ctx.session_id, "turn-1", 100, input_tokens: 60, output_tokens: 40)
             )

    assert {:ok, :recorded} =
             RuntimeUsage.observe(
               ctx.attribution,
               :terminal,
               event(ctx.session_id, "turn-1", 145, input_tokens: 85, output_tokens: 60)
             )

    assert %{
             "token_count" => %{"state" => "observed", "value" => 45, "unit" => "tokens"},
             "context_occupancy" => %{
               "state" => "unsupported",
               "reason" => "exact_context_occupancy_unavailable"
             }
           } = RuntimeUsage.reduce(identity(ctx, "turn-1"))
  end

  test "exact duplicate is a no-op while divergent replay is invalid", ctx do
    baseline = event(ctx.session_id, "turn-replay", 10)

    assert {:ok, :recorded} = RuntimeUsage.observe(ctx.attribution, :baseline, baseline)
    assert {:ok, :duplicate} = RuntimeUsage.observe(ctx.attribution, :baseline, baseline)

    assert {:error, {:invalid, :divergent_replay}} =
             RuntimeUsage.observe(
               ctx.attribution,
               :baseline,
               event(ctx.session_id, "turn-replay", 11)
             )

    assert Repo.aggregate(Receipt, :count) == 1
  end

  test "a decrease in any shared counter makes the reduction invalid", ctx do
    assert {:ok, :recorded} =
             RuntimeUsage.observe(
               ctx.attribution,
               :baseline,
               event(ctx.session_id, "turn-decrease", 50, input_tokens: 30)
             )

    assert {:ok, :recorded} =
             RuntimeUsage.observe(
               ctx.attribution,
               :terminal,
               event(ctx.session_id, "turn-decrease", 60, input_tokens: 29)
             )

    assert %{"token_count" => %{"state" => "invalid", "reason" => "counter_decreased"}} =
             RuntimeUsage.reduce(identity(ctx, "turn-decrease"))
  end

  test "missing boundary and absent provider capability remain typed", ctx do
    assert %{
             "token_count" => %{
               "state" => "missing",
               "reason" => "boundary_receipts_missing"
             }
           } = RuntimeUsage.reduce(identity(ctx, "turn-none"))

    assert {:ok, :recorded} =
             RuntimeUsage.observe(
               ctx.attribution,
               :baseline,
               event(ctx.session_id, "turn-missing", 10)
             )

    assert %{"token_count" => %{"state" => "missing", "reason" => "terminal_missing"}} =
             RuntimeUsage.reduce(identity(ctx, "turn-missing"))

    unsupported = %{
      event(ctx.session_id, "turn-unsupported", 0)
      | usage: %{state: :unsupported, reason: :provider_capability_absent}
    }

    assert {:ok, :recorded} = RuntimeUsage.observe(ctx.attribution, :terminal, unsupported)

    assert %{
             "token_count" => %{
               "state" => "unsupported",
               "reason" => "provider_capability_absent"
             }
           } = RuntimeUsage.reduce(identity(ctx, "turn-unsupported"))
  end

  test "malformed boundaries, event kinds, and counters are invalid", ctx do
    valid = event(ctx.session_id, "turn-invalid", 1)

    assert {:error, {:invalid, :invalid_boundary}} =
             RuntimeUsage.observe(ctx.attribution, :middle, valid)

    assert {:error, {:invalid, :invalid_event}} =
             RuntimeUsage.observe(ctx.attribution, :baseline, %{valid | kind: :error})

    assert {:error, {:invalid, :missing_usage}} =
             RuntimeUsage.observe(ctx.attribution, :baseline, %{valid | usage: nil})

    malformed = %{valid | usage: %{total: %{total_tokens: "1"}}}

    assert {:error, {:invalid, :invalid_counter}} =
             RuntimeUsage.observe(ctx.attribution, :baseline, malformed)
  end

  test "stale, foreign, reaped, and work-drifted claims cannot mint new receipts", ctx do
    stale = put_in(ctx.attribution, [:task, :epoch], ctx.attribution.task.epoch + 1)
    foreign = put_in(ctx.attribution, [:task, :worker_id], "another-worker")
    drifted = put_in(ctx.attribution, [:task, :work_digest], "0000000000000000")

    assert {:error, {:invalid, :stale_claim}} =
             RuntimeUsage.observe(stale, :baseline, event(ctx.session_id, "turn-stale", 1))

    assert {:error, {:invalid, :foreign_claim}} =
             RuntimeUsage.observe(foreign, :baseline, event(ctx.session_id, "turn-foreign", 1))

    assert {:error, {:invalid, :work_digest_mismatch}} =
             RuntimeUsage.observe(drifted, :baseline, event(ctx.session_id, "turn-drift", 1))

    assert {:ok, released} =
             Tasks.release(ctx.task.id, @worker, observed_epoch: ctx.attribution.task.epoch)

    assert released.content["lifecycle_status"] == "open"

    assert {:error, {:invalid, :task_not_claimed}} =
             RuntimeUsage.observe(
               ctx.attribution,
               :baseline,
               event(ctx.session_id, "turn-reaped", 1)
             )
  end

  test "recorded duplicates stay no-ops after the claim is reaped", ctx do
    observation = event(ctx.session_id, "turn-durable-duplicate", 5)
    assert {:ok, :recorded} = RuntimeUsage.observe(ctx.attribution, :baseline, observation)

    assert {:ok, _released} =
             Tasks.release(ctx.task.id, @worker, observed_epoch: ctx.attribution.task.epoch)

    assert {:ok, :duplicate} = RuntimeUsage.observe(ctx.attribution, :baseline, observation)
  end

  test "cross-cycle, cross-assignment, and cross-session attribution fail closed", ctx do
    observation = event(ctx.session_id, "turn-scope", 10)
    assert {:ok, :recorded} = RuntimeUsage.observe(ctx.attribution, :baseline, observation)

    wrong_cycle = %{identity(ctx, "turn-scope") | cycle_id: Ecto.UUID.generate()}

    assert %{"token_count" => %{"state" => "invalid", "reason" => "cycle_mismatch"}} =
             RuntimeUsage.reduce(wrong_cycle)

    wrong_session = %{identity(ctx, "turn-scope") | session_id: Ecto.UUID.generate()}

    assert %{"token_count" => %{"state" => "invalid", "reason" => "session_mismatch"}} =
             RuntimeUsage.reduce(wrong_session)

    foreign_assignment = %{ctx.attribution | assignment_id: Ecto.UUID.generate()}

    assert {:error, {:invalid, :divergent_replay}} =
             RuntimeUsage.observe(foreign_assignment, :baseline, observation)

    wrong_target = %{observation | provider_session_id: "another-provider-thread"}

    assert {:error, {:invalid, :provider_session_mismatch}} =
             RuntimeUsage.observe(ctx.attribution, :baseline, wrong_target)
  end

  test "authority join rejects cross-tenant, wrong-project, wrong-session, and missing rows",
       ctx do
    foreign_workspace = TenancyFixtures.create_workspace!(unique("runtime-foreign-ws"))

    foreign_project =
      TenancyFixtures.create_project!(foreign_workspace, unique("runtime-foreign-p"))

    foreign_scope = [workspace_id: foreign_workspace.id, project_id: foreign_project.id]
    {:ok, _foreign_dataset} = Tenancy.get_or_create_dataset(foreign_project, @dataset)
    register_task_schema!(foreign_scope)

    {:ok, foreign_task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => unique("foreign-usage-task"),
          "title" => "Foreign usage task",
          "content" => %{"kind" => "task", "lifecycle_status" => "open"}
        },
        @dataset,
        foreign_scope
      )

    {:ok, foreign_task} = Tasks.claim_by_id(foreign_task.doc_id, @worker, foreign_scope)

    cross_tenant =
      put_in(ctx.attribution, [:task], %{
        id: foreign_task.id,
        worker_id: @worker,
        epoch: get_in(foreign_task.content, ["claim", "epoch"]),
        work_digest: get_in(foreign_task.content, ["claim", "work_digest"])
      })

    assert {:error, {:invalid, :authority_not_found}} =
             RuntimeUsage.observe(
               cross_tenant,
               :baseline,
               event(ctx.session_id, "turn-cross-tenant", 1)
             )

    other_project = TenancyFixtures.create_project!(ctx.workspace, unique("runtime-other-p"))
    other_scope = [workspace_id: ctx.workspace.id, project_id: other_project.id]
    {:ok, _other_dataset} = Tenancy.get_or_create_dataset(other_project, @dataset)
    register_task_schema!(other_scope)

    {:ok, other_task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => unique("other-project-task"),
          "title" => "Other project task",
          "content" => %{"kind" => "task", "lifecycle_status" => "open"}
        },
        @dataset,
        other_scope
      )

    {:ok, other_task} = Tasks.claim_by_id(other_task.doc_id, @worker, other_scope)

    wrong_project =
      put_in(ctx.attribution, [:task], %{
        id: other_task.id,
        worker_id: @worker,
        epoch: get_in(other_task.content, ["claim", "epoch"]),
        work_digest: get_in(other_task.content, ["claim", "work_digest"])
      })

    assert {:error, {:invalid, :authority_not_found}} =
             RuntimeUsage.observe(
               wrong_project,
               :baseline,
               event(ctx.session_id, "turn-wrong-project", 1)
             )

    foreign_session_id = Ecto.UUID.generate()

    {:ok, _foreign_session} =
      StudioChat.create_session(
        %{
          id: foreign_session_id,
          provider: "codex",
          execution_target: "managed",
          provider_session_id: "provider-thread-1",
          mode: "plan"
        },
        {:workspace, foreign_workspace.id}
      )

    assert {:error, {:invalid, :authority_not_found}} =
             RuntimeUsage.observe(
               ctx.attribution,
               :baseline,
               event(foreign_session_id, "turn-wrong-session", 1)
             )

    missing = put_in(ctx.attribution, [:task, :id], Ecto.UUID.generate())

    assert {:error, {:invalid, :authority_not_found}} =
             RuntimeUsage.observe(
               missing,
               :baseline,
               event(ctx.session_id, "turn-missing-task", 1)
             )
  end

  test "a second valid same-project Task claim cannot mint usage for the assignment", ctx do
    {:ok, other_task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => unique("same-project-usage-task"),
          "title" => "Another valid usage task",
          "content" => %{"kind" => "task", "lifecycle_status" => "open"}
        },
        @dataset,
        ctx.scope
      )

    {:ok, other_task} = Tasks.claim_by_id(other_task.doc_id, @worker, ctx.scope)

    swapped =
      put_in(ctx.attribution, [:task], %{
        id: other_task.id,
        worker_id: @worker,
        epoch: get_in(other_task.content, ["claim", "epoch"]),
        work_digest: get_in(other_task.content, ["claim", "work_digest"])
      })

    assert {:error, {:invalid, :authority_not_found}} =
             RuntimeUsage.observe(
               swapped,
               :baseline,
               event(ctx.session_id, "turn-same-project-task-swap", 1)
             )

    assert {:error, :assignment_task_conflict} =
             CycleFleet.bind_assignment_task(ctx.assignment, other_task.id)
  end

  test "assignment binding is replay-stable and append-only", ctx do
    binding = Repo.get!(AssignmentTask, ctx.assignment.id)

    assert {:ok, assignment_replay} = CycleFleet.create_assignment(ctx.assignment_attrs)
    assert assignment_replay.id == ctx.assignment.id
    assert Repo.aggregate(AssignmentTask, :count) == 1

    assert {:ok, replay} = CycleFleet.bind_assignment_task(ctx.assignment, ctx.task.id)
    assert replay.assignment_id == binding.assignment_id
    assert replay.task_id == binding.task_id
    assert replay.inserted_at == binding.inserted_at

    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Repo.update_all(
        from(b in AssignmentTask, where: b.assignment_id == ^ctx.assignment.id),
        set: [task_id: Ecto.UUID.generate()]
      )
    end

    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Repo.delete_all(from(b in AssignmentTask, where: b.assignment_id == ^ctx.assignment.id))
    end
  end

  test "a rejected Task authority rolls back the assignment insert", ctx do
    logical_id = unique("runtime-invalid-task-assignment")

    assert {:error, :assignment_task_authority_not_found} =
             CycleFleet.create_assignment(
               Map.merge(ctx.cycle_scope, %{
                 assignment_id: logical_id,
                 phase: "survey",
                 agent_type: "epic-surveyor",
                 effort: "medium",
                 task_id: Ecto.UUID.generate(),
                 snapshot: %{"purpose" => "must roll back"}
               })
             )

    refute CycleFleet.get_assignment(ctx.cycle_scope, logical_id)
  end

  test "assignment and Task foreign keys preserve guarded teardown semantics" do
    assert %{rows: [["c", false, false], ["a", true, true]]} =
             Repo.query!(
               """
               SELECT confdeltype::text, condeferrable, condeferred
               FROM pg_constraint
               WHERE conname IN (
                 'epic_assignment_tasks_assignment_id_fkey',
                 'epic_assignment_tasks_task_id_fkey'
               )
               ORDER BY conname
               """,
               []
             )
  end

  test "native envelopes and unallowlisted counters never enter the receipt", ctx do
    event = %{
      event(ctx.session_id, "turn-redaction", 9,
        input_tokens: 6,
        secret_counter: 999
      )
      | native: %{
          "prompt" => "do not persist me",
          "tool_data" => %{"token" => "super-secret"},
          "path" => "/private/repo",
          "error" => "native failure",
          "env" => %{"DATABASE_URL" => "postgres://secret"}
        }
    }

    assert {:ok, :recorded} = RuntimeUsage.observe(ctx.attribution, :baseline, event)
    [receipt] = Repo.all(Receipt)

    assert receipt.counters == %{"input_tokens" => 6, "total_tokens" => 9}

    %{rows: [[stored]]} =
      Repo.query!("SELECT to_jsonb(r)::text FROM chat_runtime_usage_receipts AS r")

    refute stored =~ "do not persist me"
    refute stored =~ "super-secret"
    refute stored =~ "/private/repo"
    refute stored =~ "DATABASE_URL"
    refute stored =~ "secret_counter"
  end

  test "the database rejects updates of accepted receipts", ctx do
    assert {:ok, :recorded} =
             RuntimeUsage.observe(
               ctx.attribution,
               :baseline,
               event(ctx.session_id, "turn-append-only", 4)
             )

    receipt = Repo.one!(Receipt)

    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Repo.update_all(from(r in Receipt, where: r.id == ^receipt.id), set: [task_epoch: 99])
    end
  end

  defp event(session_id, turn_id, total_tokens, counters \\ []) do
    total =
      counters
      |> Map.new()
      |> Map.put(:total_tokens, total_tokens)

    %Event{
      provider: "codex",
      session_id: session_id,
      provider_session_id: "provider-thread-1",
      turn_id: turn_id,
      kind: :usage,
      usage: %{total: total},
      native: %{}
    }
  end

  defp identity(ctx, turn_id) do
    %{
      cycle_id: ctx.wave.id,
      assignment_id: ctx.attribution.assignment_id,
      session_id: ctx.session_id,
      provider: "codex",
      provider_session_id: "provider-thread-1",
      turn_id: turn_id
    }
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
