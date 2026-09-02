defmodule Barkpark.StudioChat.RuntimeUsageTest do
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.{Content, CycleFleet, Repo, StudioChat, Tasks, Tenancy, TenancyFixtures}
  alias Barkpark.CycleFleet.{AssignmentTask, RuntimeAttempt}
  alias Barkpark.StudioChat.Session
  alias Barkpark.StudioChat.Runtime
  alias Barkpark.StudioChat.Runtime.Event
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.StudioChat.RuntimeUsage
  alias Barkpark.StudioChat.RuntimeUsage.Receipt

  @dataset "production"
  @worker "cycle-builder"

  defmodule FakeCodex do
    @behaviour Barkpark.StudioChat.Runtime.Adapter

    def start(opts) do
      {:ok,
       %{
         runtime: spawn(fn -> receive_loop() end),
         provider_session_id: Map.get(opts, :provider_session_id),
         runtime_ingress_token: Map.fetch!(opts, :runtime_ingress_token),
         open_opts: opts
       }}
    end

    def resume(opts), do: start(opts)
    def send_turn(_runtime, _content), do: :ok
    def steer(_runtime, _command), do: :ok
    def interrupt(_runtime), do: {:ok, "interrupt"}
    def answer_approval(_runtime, _approval_id, _decision), do: :ok
    def readiness(_opts), do: %{ready?: true}
    def capabilities, do: %{modes: [], models: [], efforts: []}

    def close(%{runtime: pid}) do
      send(pid, :stop)
      :ok
    end

    defp receive_loop do
      receive do
        :stop -> :ok
        _ -> receive_loop()
      end
    end
  end

  defmodule TransactionRejectingRecorder do
    def ensure(opts) do
      if Barkpark.Repo.in_transaction?() do
        {:error, :runtime_opened_inside_transaction}
      else
        send(self(), {:runtime_recorder_opts, opts})
        {:ok, self()}
      end
    end
  end

  setup do
    previous_adapters = Application.get_env(:barkpark, :studio_chat_runtime_adapters)
    Application.put_env(:barkpark, :studio_chat_runtime_adapters, %{codex: FakeCodex})

    on_exit(fn ->
      Barkpark.StudioChat.RuntimeSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn
        {_, pid, _, _} when is_pid(pid) ->
          DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)

        _ ->
          :ok
      end)

      if previous_adapters,
        do: Application.put_env(:barkpark, :studio_chat_runtime_adapters, previous_adapters),
        else: Application.delete_env(:barkpark, :studio_chat_runtime_adapters)
    end)

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

    claim = %{
      task_id: claimed.id,
      worker_id: @worker,
      epoch: get_in(claimed.content, ["claim", "epoch"]),
      work_digest: get_in(claimed.content, ["claim", "work_digest"])
    }

    {:ok, attempt} = CycleFleet.prepare_runtime_attempt(assignment, claim)
    {:ok, _session} = StudioChat.set_provider_session_id(attempt.session_id, "provider-thread-1")
    session_id = attempt.session_id
    attribution = RuntimeAttempt.attribution(attempt)

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
      attempt: attempt,
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

  test "one immutable attempt is replayed and runtime opening happens after commit", ctx do
    assert {:ok, replay} =
             CycleFleet.prepare_runtime_attempt(ctx.assignment, ctx.attribution.task)

    assert replay.assignment_id == ctx.attempt.assignment_id
    assert replay.session_id == ctx.attempt.session_id
    assert Repo.aggregate(RuntimeAttempt, :count) == 1

    assert {:ok, %{attempt: started, session: session, recorder: recorder}} =
             CycleFleet.start_runtime_attempt(ctx.assignment, ctx.attribution.task, %{
               recorder: TransactionRejectingRecorder,
               minter: :must_not_reach_managed_attempt
             })

    assert started.session_id == ctx.attempt.session_id
    assert session.id == ctx.attempt.session_id
    assert recorder == self()
    assert_receive {:runtime_recorder_opts, recorder_opts}
    refute Map.has_key?(recorder_opts, :minter)

    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Repo.update_all(RuntimeAttempt, set: [task_epoch: ctx.attempt.task_epoch + 1])
    end

    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Repo.delete_all(from(a in RuntimeAttempt, where: a.assignment_id == ^ctx.assignment.id))
    end
  end

  test "attempt authority rejects cross-Task claims and unsupported runtimes", ctx do
    assert {:error, :runtime_attempt_conflict} =
             CycleFleet.prepare_runtime_attempt(ctx.assignment, %{
               ctx.attribution.task
               | id: Ecto.UUID.generate()
             })

    attempts_before = Repo.aggregate(RuntimeAttempt, :count)
    sessions_before = Repo.aggregate(Session, :count)

    assert {:error, :provider_capability_absent} =
             CycleFleet.prepare_runtime_attempt(ctx.assignment, ctx.attribution.task, %{
               provider: "claude"
             })

    assert {:error, :provider_capability_absent} =
             CycleFleet.prepare_runtime_attempt(ctx.assignment, ctx.attribution.task, %{
               execution_target: "registered_host"
             })

    assert {:error, :provider_capability_absent} =
             CycleFleet.prepare_runtime_attempt(ctx.assignment, ctx.attribution.task, %{
               runtime_surface: "native_omx"
             })

    assert Repo.aggregate(RuntimeAttempt, :count) == attempts_before
    assert Repo.aggregate(Session, :count) == sessions_before
  end

  test "a new attempt requires the exact current bound-Task claim", ctx do
    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => unique("attempt-fence-task"),
          "title" => "Attempt fence task",
          "content" => %{"kind" => "task", "lifecycle_status" => "open"}
        },
        @dataset,
        ctx.scope
      )

    {:ok, claimed} = Tasks.claim_by_id(task.doc_id, @worker, ctx.scope)

    cycle_scope = %{
      workspace_id: ctx.workspace.id,
      project_id: ctx.project.id,
      epic_id: unique("attempt-fence-epic"),
      wave_id: unique("attempt-fence-wave")
    }

    {:ok, _wave} =
      CycleFleet.open_wave(
        Map.merge(cycle_scope, %{
          profile: "epic",
          inventory: ["attempt-fence-unit"],
          scale_contract: %{}
        })
      )

    {:ok, assignment} =
      CycleFleet.create_assignment(
        Map.merge(cycle_scope, %{
          assignment_id: "attempt-fence-unit",
          phase: "survey",
          agent_type: "epic-surveyor",
          effort: "medium",
          task_id: claimed.id,
          snapshot: %{"purpose" => "claim fence"}
        })
      )

    claim = %{
      id: claimed.id,
      worker_id: @worker,
      epoch: get_in(claimed.content, ["claim", "epoch"]),
      work_digest: get_in(claimed.content, ["claim", "work_digest"])
    }

    sessions_before = Repo.aggregate(Session, :count)

    assert {:error, :stale_claim} =
             CycleFleet.prepare_runtime_attempt(assignment, %{claim | epoch: claim.epoch + 1})

    assert {:error, :foreign_claim} =
             CycleFleet.prepare_runtime_attempt(assignment, %{claim | worker_id: "foreign-worker"})

    assert {:error, :work_digest_mismatch} =
             CycleFleet.prepare_runtime_attempt(assignment, %{
               claim
               | work_digest: "0000000000000000"
             })

    refute Repo.get(RuntimeAttempt, assignment.id)
    assert Repo.aggregate(Session, :count) == sessions_before

    assert {:ok, %RuntimeAttempt{assignment_id: assignment_id}} =
             CycleFleet.prepare_runtime_attempt(assignment, claim)

    assert assignment_id == assignment.id
  end

  test "fresh cross-project and cross-workspace claims mint no session or attempt", ctx do
    local = create_runtime_authority!(ctx.workspace, ctx.project, "fresh-local")

    other_project =
      TenancyFixtures.create_project!(ctx.workspace, unique("fresh-other-project"))

    other_project_authority =
      create_runtime_authority!(ctx.workspace, other_project, "fresh-other-project")

    foreign_workspace = TenancyFixtures.create_workspace!(unique("fresh-foreign-workspace"))

    foreign_project =
      TenancyFixtures.create_project!(foreign_workspace, unique("fresh-foreign-project"))

    foreign_authority =
      create_runtime_authority!(foreign_workspace, foreign_project, "fresh-foreign")

    attempts_before = Repo.aggregate(RuntimeAttempt, :count)
    sessions_before = Repo.aggregate(Session, :count)

    assert {:error, :runtime_attempt_task_mismatch} =
             CycleFleet.prepare_runtime_attempt(local.assignment, other_project_authority.claim)

    assert {:error, :runtime_attempt_task_mismatch} =
             CycleFleet.prepare_runtime_attempt(local.assignment, foreign_authority.claim)

    assert Repo.aggregate(RuntimeAttempt, :count) == attempts_before
    assert Repo.aggregate(Session, :count) == sessions_before
  end

  test "Recorder freezes available cumulative snapshots and duplicate events stay safe", ctx do
    {:ok, recorder} =
      Recorder.ensure(%{
        session_id: ctx.session_id,
        provider: "codex",
        provider_session_id: "provider-thread-1",
        mode: "plan"
      })

    project(recorder, event(ctx.session_id, "previous-turn", 100))
    project(recorder, lifecycle(ctx.session_id, "recorder-turn", :turn_started))
    project(recorder, event(ctx.session_id, "recorder-turn", 145))
    project(recorder, lifecycle(ctx.session_id, "recorder-turn", :turn_completed))

    assert %{"token_count" => %{"state" => "observed", "value" => 45}} =
             RuntimeUsage.reduce(identity(ctx, "recorder-turn"))

    project(recorder, event(ctx.session_id, "previous-turn", 100))
    project(recorder, lifecycle(ctx.session_id, "recorder-turn", :turn_started))
    project(recorder, event(ctx.session_id, "recorder-turn", 145))
    project(recorder, lifecycle(ctx.session_id, "recorder-turn", :turn_completed))

    assert Repo.aggregate(Receipt, :count) == 2
  end

  test "Recorder keeps an unavailable first-turn baseline typed missing", ctx do
    {:ok, recorder} =
      Recorder.ensure(%{
        session_id: ctx.session_id,
        provider: "codex",
        provider_session_id: "provider-thread-1",
        mode: "plan"
      })

    project(recorder, lifecycle(ctx.session_id, "first-turn", :turn_started))
    project(recorder, event(ctx.session_id, "first-turn", 17))
    project(recorder, lifecycle(ctx.session_id, "first-turn", :turn_completed))

    assert %{"token_count" => %{"state" => "missing", "reason" => "baseline_missing"}} =
             RuntimeUsage.reduce(identity(ctx, "first-turn"))

    [terminal] = Repo.all(Receipt)
    assert terminal.boundary == "terminal"
    assert terminal.counters["total_tokens"] == 17
  end

  test "Recorder preserves a baseline-only turn as terminal_missing", ctx do
    {:ok, recorder} =
      Recorder.ensure(%{
        session_id: ctx.session_id,
        provider: "codex",
        provider_session_id: "provider-thread-1",
        mode: "plan"
      })

    project(recorder, event(ctx.session_id, "prior-turn", 21))
    project(recorder, lifecycle(ctx.session_id, "baseline-only-turn", :turn_started))
    project(recorder, lifecycle(ctx.session_id, "baseline-only-turn", :turn_completed))

    assert %{"token_count" => %{"state" => "missing", "reason" => "terminal_missing"}} =
             RuntimeUsage.reduce(identity(ctx, "baseline-only-turn"))

    [baseline] = Repo.all(Receipt)
    assert baseline.boundary == "baseline"
    assert baseline.counters["total_tokens"] == 21
  end

  test "Recorder uses the renewed current epoch and rejects generic usage injection", ctx do
    {:ok, recorder} =
      Recorder.ensure(%{
        session_id: ctx.session_id,
        provider: "codex",
        provider_session_id: "provider-thread-1",
        mode: "plan"
      })

    generic_project(recorder, event(ctx.session_id, "injected-prior", 900))
    generic_project(recorder, lifecycle(ctx.session_id, "injected-turn", :turn_started))
    generic_project(recorder, event(ctx.session_id, "injected-turn", 999))
    generic_project(recorder, lifecycle(ctx.session_id, "injected-turn", :turn_completed))
    assert Repo.aggregate(Receipt, :count) == 0

    project(recorder, event(ctx.session_id, "trusted-prior", 30))
    project(recorder, lifecycle(ctx.session_id, "renewed-turn", :turn_started))

    assert {:ok, pulsed} =
             Tasks.pulse_by_id(ctx.task.id, @worker, text: "renew runtime usage lease")

    renewed_epoch = get_in(pulsed.content, ["claim", "epoch"])
    assert renewed_epoch > ctx.attribution.task.epoch

    project(recorder, event(ctx.session_id, "renewed-turn", 47))
    project(recorder, lifecycle(ctx.session_id, "renewed-turn", :turn_completed))

    assert %{"token_count" => %{"state" => "observed", "value" => 17}} =
             RuntimeUsage.reduce(identity(ctx, "renewed-turn"))

    assert Enum.map(Repo.all(from(r in Receipt, order_by: r.boundary)), & &1.task_epoch) == [
             ctx.attribution.task.epoch,
             renewed_epoch
           ]
  end

  test "attempt replay requires the caller's current live claim after pulse and release", ctx do
    assert {:ok, pulsed} =
             Tasks.pulse_by_id(ctx.task.id, @worker, text: "renew replay fence")

    assert {:error, :stale_claim} =
             CycleFleet.prepare_runtime_attempt(ctx.assignment, ctx.attribution.task)

    current_claim = %{
      task_id: pulsed.id,
      worker_id: @worker,
      epoch: get_in(pulsed.content, ["claim", "epoch"]),
      work_digest: get_in(pulsed.content, ["claim", "work_digest"])
    }

    assert {:ok, replay} = CycleFleet.prepare_runtime_attempt(ctx.assignment, current_claim)
    assert replay.assignment_id == ctx.attempt.assignment_id

    assert {:ok, _released} =
             Tasks.release(pulsed.id, @worker, observed_epoch: current_claim.epoch)

    assert {:error, :task_not_claimed} =
             CycleFleet.prepare_runtime_attempt(ctx.assignment, current_claim)
  end

  test "Task-backed Recorder opens without minter or task hands", ctx do
    {:ok, recorder} =
      Recorder.ensure(%{
        session_id: ctx.session_id,
        provider: "codex",
        provider_session_id: "provider-thread-1",
        mode: "plan",
        minter: :must_not_reach_runtime
      })

    assert {:ok, runtime} = Recorder.session_pid(recorder)
    refute Map.has_key?(runtime.open_opts, :minter)
    refute Map.has_key?(runtime.open_opts.session_opts, :minter)
    assert Runtime.task_hands("codex", runtime) == :not_attempted
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

    unbound_session_id = Ecto.UUID.generate()

    {:ok, _unbound_session} =
      StudioChat.create_session(
        %{
          id: unbound_session_id,
          provider: "codex",
          execution_target: "managed",
          provider_session_id: "provider-thread-1",
          mode: "plan"
        },
        {:workspace, ctx.workspace.id}
      )

    assert {:error, {:invalid, :authority_not_found}} =
             RuntimeUsage.observe(
               ctx.attribution,
               :baseline,
               event(unbound_session_id, "turn-unbound-session", 1)
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
    assert %{rows: [["c", false, false], ["r", false, false], ["a", true, true]]} =
             Repo.query!(
               """
               SELECT confdeltype::text, condeferrable, condeferred
               FROM pg_constraint
               WHERE conname IN (
                 'epic_assignment_runtime_attempts_assignment_id_fkey',
                 'epic_assignment_runtime_attempts_session_id_fkey',
                 'epic_assignment_runtime_attempts_task_id_fkey'
               )
               ORDER BY conname
               """,
               []
             )
  end

  test "project teardown removes only its runtime attempt" do
    workspace = TenancyFixtures.create_workspace!(unique("attempt-project-teardown-ws"))
    doomed_project = TenancyFixtures.create_project!(workspace, unique("attempt-doomed-project"))

    survivor_project =
      TenancyFixtures.create_project!(workspace, unique("attempt-survivor-project"))

    doomed = create_runtime_authority!(workspace, doomed_project, "attempt-doomed")
    survivor = create_runtime_authority!(workspace, survivor_project, "attempt-survivor")
    {:ok, doomed_attempt} = CycleFleet.prepare_runtime_attempt(doomed.assignment, doomed.claim)

    {:ok, survivor_attempt} =
      CycleFleet.prepare_runtime_attempt(survivor.assignment, survivor.claim)

    assert {:ok, _project} = Repo.delete(doomed_project)
    refute Repo.get(RuntimeAttempt, doomed_attempt.assignment_id)
    assert Repo.get(RuntimeAttempt, survivor_attempt.assignment_id)
    assert Repo.get(Session, survivor_attempt.session_id)
  end

  test "workspace teardown removes only its runtime attempt" do
    doomed_workspace = TenancyFixtures.create_workspace!(unique("attempt-doomed-workspace"))

    doomed_project =
      TenancyFixtures.create_project!(doomed_workspace, unique("attempt-doomed-project"))

    survivor_workspace =
      TenancyFixtures.create_workspace!(unique("attempt-survivor-workspace"))

    survivor_project =
      TenancyFixtures.create_project!(survivor_workspace, unique("attempt-survivor-project"))

    doomed = create_runtime_authority!(doomed_workspace, doomed_project, "workspace-doomed")

    survivor =
      create_runtime_authority!(survivor_workspace, survivor_project, "workspace-survivor")

    {:ok, doomed_attempt} = CycleFleet.prepare_runtime_attempt(doomed.assignment, doomed.claim)

    {:ok, survivor_attempt} =
      CycleFleet.prepare_runtime_attempt(survivor.assignment, survivor.claim)

    assert {:ok, _workspace} = Tenancy.delete_workspace(doomed_workspace)
    refute Repo.get(RuntimeAttempt, doomed_attempt.assignment_id)
    assert Repo.get(RuntimeAttempt, survivor_attempt.assignment_id)
    assert Repo.get(Session, survivor_attempt.session_id)
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

  # Charter D115 / felix-w19 — observe/3 acquires FOR SHARE on the receipt's authority
  # join (assignment -> wave -> binding -> runtime attempt -> task document -> dataset
  # -> session) BEFORE inserting the Receipt row. The assignment row is the
  # mutation-sensitive lock target: chat_runtime_usage_receipts carries NO foreign key
  # on assignment_id (or cycle_id), so the insert's RI machinery never reaches
  # epic_assignments on its own — while the task document row is independently
  # FOR-SHAREd by Tasks.ClaimFence.verify and the session row is FOR-KEY-SHAREd by the
  # receipt's session_id FK; both of those are false-green. Spike-proven 2026-08-17:
  # lock present -> 55P03 at the authority SELECT; delete the `lock: "FOR SHARE"`
  # clause from authoritative_join/1 and this same drive returns {:ok, :recorded}.
  #
  # Runs unboxed (two real Postgres connections that actually block each other), so it
  # builds its own committed fixtures instead of the sandboxed setup context. Manual
  # teardown via Tenancy.delete_workspace/1; the 55P03 rollback leaves no receipt row,
  # so the append-only receipt ledger never blocks the teardown.
  test "observe FOR SHARE serializes against a concurrent assignment-row lock (55P03)" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      workspace = TenancyFixtures.create_workspace!(unique("usage-lock-ws"))
      project = TenancyFixtures.create_project!(workspace, unique("usage-lock-p"))

      try do
        authority = create_runtime_authority!(workspace, project, "usage-lock")
        {:ok, attempt} = CycleFleet.prepare_runtime_attempt(authority.assignment, authority.claim)

        {:ok, _session} =
          StudioChat.set_provider_session_id(attempt.session_id, "provider-thread-1")

        attribution = RuntimeAttempt.attribution(attempt)
        parent = self()

        # Connection A: a real second connection holds FOR UPDATE on the assignment
        # row and rendezvous-signals the parent BEFORE releasing (holder-first).
        holder =
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
              Repo.transaction(fn ->
                Repo.query!("SELECT id FROM epic_assignments WHERE id = $1 FOR UPDATE", [
                  Ecto.UUID.dump!(authority.assignment.id)
                ])

                send(parent, :assignment_row_locked)

                receive do
                  :release -> :ok
                after
                  10_000 -> :timeout
                end
              end)
            end)
          end)

        assert_receive :assignment_row_locked, 5_000

        # Connection B: drive the REAL observe/3 under a SESSION-level lock_timeout
        # (SET LOCAL outside observe's own txn is a no-op); RESET to 0 in the
        # after-block — the GUC persists on the pooled connection and would poison
        # later tests.
        try do
          Repo.query!("SET lock_timeout = '750ms'")

          error =
            assert_raise Postgrex.Error, fn ->
              RuntimeUsage.observe(
                attribution,
                :baseline,
                event(attempt.session_id, "turn-authority-lock", 10)
              )
            end

          assert error.postgres.code == :lock_not_available
          assert error.postgres.pg_code == "55P03"
        after
          Repo.query!("SET lock_timeout = 0")
          send(holder.pid, :release)
          Task.await(holder, 10_000)
        end
      after
        park_unboxed_sessions!(workspace)
        assert {:ok, _workspace} = Tenancy.delete_workspace(workspace)
      end
    end)
  end

  # ── the unboxed drive's committed residue (wave-26 pollution class) ─────────
  #
  # `unboxed_run` COMMITS — that is the point (two real connections have to block
  # each other), but it also means every row the drive writes OUTLIVES the test.
  # `prepare_runtime_attempt/2` mints a chat_sessions row for the attempt, and
  # the teardown above does NOT reach it: `Tenancy.delete_workspace/1` returns
  # `{:ok, _}` and leaves the session behind. Measured on main (2026-09-01):
  # running this file against an empty `chat_sessions` leaves exactly ONE
  # committed row, cleaned by nothing, forever.
  #
  # A committed session escapes every LATER test's sandbox rollback and rides
  # `list_sessions/2`'s recency-desc ordering ahead of that test's own pinned
  # fixtures — the class #12041 named: an extra row reddens `StudioChatTest`'s
  # list_sessions recency/cap tests and (for a NULL-owner row) the sidebar
  # byte-lock in `ChatRenderGoldenTest`, which renders it as an EXTRA session
  # card (region 7783 vs golden 6554 — no render change at all). Those two files
  # answer it with a setup-time purge of their own; a victim-side belt protects
  # only its own file, and only against rows committed BEFORE its setup ran.
  #
  # DELETING the residue is not available: `epic_assignment_runtime_attempts` is
  # an append-only ledger (a DELETE raises `barkpark_epic_ledger_immutable`) and
  # it carries an ON DELETE RESTRICT FK to `chat_sessions`, so the attempt row
  # pins the session row in place. Archive it instead — `list_sessions/2` filters
  # `archived_at IS NULL` on every default listing, so the parked residue can
  # never reach a later test's sidebar again while the ledger stays intact.
  defp park_unboxed_sessions!(workspace) do
    Repo.update_all(
      from(s in Session,
        where: s.owner_workspace_id == ^workspace.id and is_nil(s.archived_at)
      ),
      set: [archived_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )

    :ok
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

  defp lifecycle(session_id, turn_id, kind) do
    %Event{
      provider: "codex",
      session_id: session_id,
      provider_session_id: "provider-thread-1",
      turn_id: turn_id,
      idempotency_key: "#{kind}:#{turn_id}",
      durability: :durable,
      kind: kind,
      terminal_state: if(kind == :turn_completed, do: :completed),
      native: %{}
    }
  end

  defp project(recorder, event) do
    assert {:ok, %{runtime_ingress_token: token}} = Recorder.session_pid(recorder)
    send(recorder, {:studio_chat_managed_runtime_event, token, event})
    assert {:ok, _runtime} = Recorder.session_pid(recorder)
  end

  defp generic_project(recorder, event) do
    assert :ok = GenServer.call(recorder, {:project_runtime_event, event})
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

  defp create_runtime_authority!(workspace, project, suffix) do
    scope = [workspace_id: workspace.id, project_id: project.id]
    {:ok, _dataset} = Tenancy.get_or_create_dataset(project, @dataset)
    register_task_schema!(scope)

    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => unique("#{suffix}-task"),
          "title" => "Runtime authority #{suffix}",
          "content" => %{"kind" => "task", "lifecycle_status" => "open"}
        },
        @dataset,
        scope
      )

    {:ok, claimed} = Tasks.claim_by_id(task.doc_id, @worker, scope)

    cycle_scope = %{
      workspace_id: workspace.id,
      project_id: project.id,
      epic_id: unique("#{suffix}-epic"),
      wave_id: unique("#{suffix}-wave")
    }

    {:ok, _wave} =
      CycleFleet.open_wave(
        Map.merge(cycle_scope, %{
          profile: "epic",
          inventory: ["#{suffix}-unit"],
          scale_contract: %{}
        })
      )

    {:ok, assignment} =
      CycleFleet.create_assignment(
        Map.merge(cycle_scope, %{
          assignment_id: unique("#{suffix}-assignment"),
          phase: "survey",
          agent_type: "epic-surveyor",
          effort: "medium",
          task_id: claimed.id,
          snapshot: %{"purpose" => "runtime authority #{suffix}"}
        })
      )

    claim = %{
      task_id: claimed.id,
      worker_id: @worker,
      epoch: get_in(claimed.content, ["claim", "epoch"]),
      work_digest: get_in(claimed.content, ["claim", "work_digest"])
    }

    %{assignment: assignment, task: claimed, claim: claim}
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
