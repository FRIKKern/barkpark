defmodule BarkparkWeb.ChatManagedSessionTest do
  @moduledoc """
  `GET /v1/chat/managed-session?task=<doc_id>` (wsc-steer-open-session-managed):
  the door the TUI's agent detail asks before it offers "open session". It is a
  thin wrapper over `StudioChat.ManagedSessionTarget.resolve/2` (whose branches
  are pinned in `managed_session_target_test.exs`); this file pins the HTTP
  contract: auth first, 200 with the session for a live managed attempt, one
  indistinct 404 for every miss, 400 without a task.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the studio_chat capability gates every /v1/chat route.
  @moduletag :requires_plugins

  alias Barkpark.{Auth, Content, CycleFleet, Tasks, Tenancy, TenancyFixtures}
  alias Barkpark.CycleFleet.RuntimeAttempt

  @dataset "production"
  @worker "managed-codex-builder"

  setup do
    {workspace, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: workspace.id, project_id: project.id]
    {:ok, _dataset} = Tenancy.get_or_create_dataset(project, @dataset)

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {key, value} -> {to_string(key), value} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    admin = "chat-managed-session-admin-#{System.unique_integer([:positive])}"
    reader = "chat-managed-session-reader-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(admin, "chat-admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(reader, "chat-reader", @dataset, ["read"])

    cycle_scope = %{
      workspace_id: workspace.id,
      project_id: project.id,
      epic_id: unique("managed-session-epic"),
      wave_id: unique("managed-session-wave")
    }

    {:ok, _wave} =
      CycleFleet.open_wave(
        Map.merge(cycle_scope, %{profile: "epic", inventory: ["unit-a"], scale_contract: %{}})
      )

    %{scope: scope, cycle_scope: cycle_scope, admin: admin, reader: reader}
  end

  defp authed(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("accept", "application/json")
  end

  test "auth runs first: no bearer is 401, a non-chat reader is 403", %{reader: reader} do
    assert scoped_conn() |> get("/v1/chat/managed-session?task=x") |> json_response(401)
    assert authed(reader) |> get("/v1/chat/managed-session?task=x") |> json_response(403)
  end

  test "a live managed attempt answers 200 with its session", ctx do
    task = claimed_task!(ctx.scope)
    attempt = attempt!(ctx.cycle_scope, task)
    bare = String.replace_prefix(task.doc_id, "drafts.", "")

    body =
      authed(ctx.admin) |> get("/v1/chat/managed-session?task=#{bare}") |> json_response(200)

    assert body == %{"task_id" => bare, "session_id" => attempt.session_id}
  end

  test "a Claude-lane task and an unknown task answer the same 404", ctx do
    task = claimed_task!(ctx.scope)

    claude =
      authed(ctx.admin)
      |> get("/v1/chat/managed-session?task=#{task.doc_id}")
      |> json_response(404)

    unknown =
      authed(ctx.admin) |> get("/v1/chat/managed-session?task=task-nope") |> json_response(404)

    assert claude["error"]["code"] == unknown["error"]["code"]
    assert claude["error"]["message"] == unknown["error"]["message"]
    assert claude["error"]["message"] == "no managed session for this task"
  end

  test "a missing task parameter is 400", ctx do
    assert authed(ctx.admin) |> get("/v1/chat/managed-session") |> json_response(400)
    assert authed(ctx.admin) |> get("/v1/chat/managed-session?task=") |> json_response(400)
  end

  defp claimed_task!(scope) do
    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => unique("managed-session-task"),
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

  defp attempt!(cycle_scope, task) do
    {:ok, assignment} =
      CycleFleet.create_assignment(
        Map.merge(cycle_scope, %{
          assignment_id: "unit-a",
          phase: "survey",
          agent_type: "epic-surveyor",
          effort: "medium",
          task_id: task.id,
          snapshot: %{"purpose" => "managed session door"}
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

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
