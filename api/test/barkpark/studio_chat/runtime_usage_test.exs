defmodule Barkpark.StudioChat.RuntimeUsageTest do
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.{Content, Repo, StudioChat, Tasks, TenancyFixtures}
  alias Barkpark.StudioChat.Runtime.Event
  alias Barkpark.StudioChat.RuntimeUsage
  alias Barkpark.StudioChat.RuntimeUsage.Receipt

  @dataset "production"
  @worker "cycle-builder"

  setup do
    {workspace, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: workspace.id, project_id: project.id]
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
      StudioChat.create_session(%{
        id: session_id,
        provider: "codex",
        execution_target: "managed",
        provider_session_id: "provider-thread-1",
        mode: "plan"
      })

    # Frozen build-1 handoff fixture: integration will replace this literal map
    # with the server-side CycleFleet assignment projection, without changing
    # RuntimeUsage's receipt boundary.
    attribution = %{
      cycle_id: Ecto.UUID.generate(),
      assignment_id: Ecto.UUID.generate(),
      task: %{
        id: claimed.id,
        doc_id: claimed.doc_id,
        worker_id: @worker,
        epoch: get_in(claimed.content, ["claim", "epoch"]),
        work_digest: get_in(claimed.content, ["claim", "work_digest"])
      }
    }

    %{scope: scope, task: claimed, session_id: session_id, attribution: attribution}
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

    unsupported = %{event(ctx.session_id, "turn-unsupported", 0) | usage: nil}
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
      cycle_id: ctx.attribution.cycle_id,
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
