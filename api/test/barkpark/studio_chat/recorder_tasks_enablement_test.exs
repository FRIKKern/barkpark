defmodule Barkpark.StudioChat.RecorderTasksEnablementTest do
  @moduledoc """
  task-b428d724ad80434f: the chat Recorder re-broadcasts a task lifecycle
  transition only when the Tasks plugin is ENABLED for the session's own
  workspace (`Barkpark.Plugins.Enablement`).

  Tasks is registered on the instance throughout. Workspace A has Tasks ON,
  workspace B switches it OFF in `workspaces.settings["plugins"]`. Per-workspace
  enablement is the SURFACED layer only: routes, lifecycle hooks and the write
  fences of an installed plugin keep running in B
  (`Barkpark.Plugins.Registry.ResolverChain.enablement_filtered_plugins/2`,
  `BarkparkWeb.Plugs.PluginRouteGuard`), so a real `Tasks.claim_by_id/3` in
  B's scope commits and broadcasts on B's ledger stream exactly as it does in
  A. Each session's own worker claims a task in its own workspace through that
  real write path; A's viewer gets the transition, B's does not.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, StudioChat, Tasks, Tenancy, TenancyFixtures}
  alias Barkpark.StudioChat.{Recorder, Runtime}

  @dataset "production"

  setup do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      Barkpark.StudioChat.RuntimeSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn
        {_, pid, _, _} when is_pid(pid) ->
          DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)

        _ ->
          :ok
      end)

      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    {ws_a, project_a} = TenancyFixtures.ensure_default_scope!()
    ws_b = TenancyFixtures.create_workspace!()
    project_b = TenancyFixtures.create_project!(ws_b)
    Barkpark.LabelFixtures.register_tags!(@dataset)

    %{
      a: [workspace_id: ws_a.id, project_id: project_a.id],
      b: [workspace_id: ws_b.id, project_id: project_b.id]
    }
  end

  # A chat session owned by `scope`'s workspace, its live Recorder, and its
  # worker id — the id `TaskTransition` matches `claim.worker` against.
  defp session!(scope) do
    ws = Keyword.fetch!(scope, :workspace_id)
    sid = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: sid, mode: "plan"}, {:workspace, ws})

    {:ok, recorder} =
      Recorder.ensure(%{session_id: sid, mode: "plan", resume: false, workspace_id: ws})

    Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))
    %{sid: sid, recorder: recorder, worker: Runtime.worker_id("claude", sid)}
  end

  # Task schemas plus one PUBLISHED open task in `scope`, returned by doc_id.
  defp task!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    n = System.unique_integer([:positive])

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => "rec-enab-#{n}",
          "title" => "Recorder enablement #{n}",
          "content" =>
            Barkpark.LabelFixtures.with_labels(%{
              "kind" => "task",
              "brief" => Barkpark.TaskBriefFixtures.brief(),
              "lifecycle_status" => "open",
              "priority" => 3,
              "acceptance_criteria" => [%{"criterion" => "one", "met" => false}]
            })
        },
        @dataset,
        scope
      )

    pid = Content.DraftId.published_id(doc.doc_id)
    {:ok, _} = Content.publish_document(pid, "task", @dataset, scope)
    pid
  end

  # The session's own worker claims the task through the REAL write path; sync
  # on the Recorder so the resulting ledger frame has been handled.
  defp claim!(session, task_id, scope) do
    assert {:ok, %{content: %{"claim" => %{"worker" => worker}}}} =
             Tasks.claim_by_id(task_id, session.worker, scope)

    assert worker == session.worker
    :sys.get_state(session.recorder)
    :ok
  end

  defp tasks_off!(scope) do
    {:ok, _} =
      Tenancy.set_workspace_plugin_settings(
        Keyword.fetch!(scope, :workspace_id),
        %{"tasks" => %{"enabled" => false}}
      )

    :ok
  end

  test "A (Tasks ON) gets its claim transition; B (Tasks OFF) gets none", ctx do
    :ok = tasks_off!(ctx.b)

    a = session!(ctx.a)
    b = session!(ctx.b)
    task_a = task!(ctx.a)
    task_b = task!(ctx.b)

    claim!(a, task_a, ctx.a)
    claim!(b, task_b, ctx.b)

    a_sid = a.sid
    b_sid = b.sid

    # Control: the same write path, the same Recorder code, Tasks ON.
    assert_receive {:chat_task_transition, ^a_sid, %{task_id: ^task_a, verb: "claimed"}}, 1_000

    # B's claim committed (asserted in claim!/3) in a Tasks-off workspace; its
    # viewer must not see it.
    refute_receive {:chat_task_transition, ^b_sid, _}, 300
  end

  test "the check reads the SESSION's workspace, not the Default's", ctx do
    :ok = tasks_off!(ctx.a)

    a = session!(ctx.a)
    b = session!(ctx.b)
    task_a = task!(ctx.a)
    task_b = task!(ctx.b)

    claim!(a, task_a, ctx.a)
    claim!(b, task_b, ctx.b)

    a_sid = a.sid
    b_sid = b.sid

    assert_receive {:chat_task_transition, ^b_sid, %{task_id: ^task_b, verb: "claimed"}}, 1_000
    refute_receive {:chat_task_transition, ^a_sid, _}, 300
  end
end
