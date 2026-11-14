defmodule BarkparkWeb.ChatEventsTaskFrameDatasetBoundTest do
  @moduledoc """
  `GET /v1/chat/sessions/:id/events` forwards the Recorder's live task
  transition as an SSE `task` frame: task id, title, status. The Recorder
  listens on the ledger dataset (`production`), so every such frame is a
  production task's. A token minted with an explicit dataset is held to that
  one, so a token bound elsewhere gets no `task` frame
  (task-48c1905ca5bb8892). An unbound token, and a token bound to the ledger
  dataset itself, still get it (controls). The session's other frames are
  untouched.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the studio_chat capability owns the chat supervisors and /v1/chat routes.
  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, StudioChat, Tasks, Tenancy}
  alias Barkpark.StudioChat.Recorder
  alias BarkparkWeb.Studio.ClaudeChat

  @own "bound-own"
  @prod "production"
  @prod_title "PRODUCTION TASK the bound token must not see"
  @sentinel "SENTINEL-TITLE-AFTER-THE-CLAIM"

  setup do
    Barkpark.ChatSessionResidue.purge!()
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      if sup = Process.whereis(Barkpark.StudioChat.RuntimeSupervisor) do
        for {_, pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(pid) do
          DynamicSupervisor.terminate_child(sup, pid)
        end
      end

      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    ws = create_workspace!("chat-sse-task-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    scope = [workspace_id: ws.id]

    for ds <- [@prod, @own] do
      {:ok, _} = Tenancy.get_or_create_dataset(proj, ds)
      upsert_task_schemas!(ds, scope)
      Barkpark.LabelFixtures.register_tags!(ds)
    end

    sid = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: sid, mode: "plan"}, {:workspace, ws.id})

    {:ok, _} =
      Recorder.ensure(%{session_id: sid, mode: "plan", resume: false, workspace_id: ws.id})

    {:ok, ws: ws, sid: sid, task: task!(@prod, scope, @prod_title)}
  end

  # Open the stream with a token minted into `dataset`, let the session's
  # worker claim the production task, then end the stream and return every
  # byte it wrote. The sentinel title frame travels the same per-session topic
  # after the claim, so its presence proves the stream was live throughout.
  defp stream_bytes(%{ws: ws, sid: sid, task: task}, dataset, token_opts) do
    raw = "chat-sse-task-" <> Ecto.UUID.generate()
    perms = ["read", "write", "admin"]
    {:ok, _} = Auth.create_token(raw, "chat sse task", dataset, perms, ws.id, token_opts)

    stream =
      Task.async(fn ->
        scoped_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get("/v1/chat/sessions/#{sid}/events")
      end)

    Process.sleep(300)
    topic = Recorder.topic(sid)
    Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)

    {:ok, _} =
      Tasks.claim_by_id(task.doc_id, ClaudeChat.worker_id(sid),
        workspace_id: ws.id,
        dataset: @prod
      )

    # The Recorder did re-broadcast the claim on the session topic.
    assert_receive {:chat_task_transition, ^sid, %{task_id: task_id}}, 2_000
    assert task_id == task.doc_id
    Process.sleep(100)

    Phoenix.PubSub.broadcast(Barkpark.PubSub, topic, {:chat_title, sid, @sentinel})
    Phoenix.PubSub.broadcast(Barkpark.PubSub, topic, :retire)

    case Task.yield(stream, 3_000) || Task.shutdown(stream, :brutal_kill) do
      {:ok, conn} ->
        assert conn.status == 200
        assert conn.resp_body =~ @sentinel
        conn.resp_body

      _ ->
        flunk("the events stream did not end on :retire")
    end
  end

  test "a token bound to another dataset gets no task frame for a production claim", ctx do
    body = stream_bytes(ctx, @own, dataset_bound: true)

    refute body =~ "event: task"
    refute body =~ ctx.task.doc_id
    refute body =~ @prod_title
    # The session's own frames still arrive.
    assert body =~ "event: title"
  end

  test "an unbound token still gets the task frame (control)", ctx do
    body = stream_bytes(ctx, @own, [])

    assert body =~ "event: task"
    assert body =~ ctx.task.doc_id
    assert body =~ @prod_title
  end

  test "a token bound to the ledger dataset still gets the task frame (control)", ctx do
    body = stream_bytes(ctx, @prod, dataset_bound: true)

    assert body =~ "event: task"
    assert body =~ ctx.task.doc_id
  end

  defp upsert_task_schemas!(dataset, scope) do
    for schema_def <- Tasks.schema_definitions(dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, dataset, scope)
    end
  end

  defp task!(dataset, scope, title) do
    doc_id = "chat-sse-task-#{System.unique_integer([:positive])}"

    content =
      %{
        "kind" => "task",
        "brief" => Barkpark.TaskBriefFixtures.brief(),
        "description" => "fixture #{doc_id}",
        "lifecycle_status" => "open",
        "dedup_bypass" => true,
        "acceptance_criteria" => [%{"criterion" => "fixture", "met" => false}]
      }
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())

    attrs = %{"doc_id" => doc_id, "title" => title, "content" => content}
    {:ok, _} = Content.create_document("task", attrs, dataset, scope)
    {:ok, pub} = Content.publish_document(doc_id, "task", dataset, scope)
    pub
  end
end
