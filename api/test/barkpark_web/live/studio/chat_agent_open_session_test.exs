defmodule BarkparkWeb.Studio.ChatAgentOpenSessionTest do
  @moduledoc """
  wsc-steer-open-session-managed, criterion 2: Studio's agent detail renders
  "open session" ONLY when the agent's task has a live managed-Codex runtime
  attempt, and the control navigates to exactly that session.

  The fixtures go through the real writers: tasks through `Content` +
  `Tasks.claim_by_id/3`, the managed lane through `CycleFleet.open_wave/1`,
  `create_assignment/1` and `prepare_runtime_attempt/2` (which mints the bound
  Codex session). The join is the Doing strip's own (`AgentTaskJoin` over the
  epic siblings this session's claim points at), so the agent here is a
  `build:<slug>` label exactly as bp-epic-cycle emits it.

  CLICK AND KEYBOARD. The control is a `<.link patch>`, a real `<a href>`, so
  Enter on the focused link and a click take the same path in the browser.
  The test drives the click through `render_click/1` and asserts the patch
  lands on the session's URL, and asserts the element IS that anchor.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the studio_chat capability (StudioChat.RuntimeSupervisor / SessionRegistry and the /studio/chat routes)
  @moduletag :requires_plugins

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content, CycleFleet, Repo, StudioChat, Tasks, Tenancy, TenancyFixtures}
  alias Barkpark.Content.{Document, SchemaDefinition}
  alias Barkpark.CycleFleet.RuntimeAttempt
  alias Barkpark.StudioChat.AgentTaskJoin
  alias BarkparkWeb.Studio.ClaudeChat

  @admin_token "chat-agent-open-session-admin-token"
  @dataset "production"
  @managed_title "Managed codex slice with a bound session"
  @claude_title "Claude lane slice with no session at all"

  defmodule NullTitleAdapter do
    def post(_url, _body, _headers), do: {:error, :disabled_in_tests}
  end

  defmodule NullTitleCli do
    def run(_binary, _args), do: {:error, :disabled_in_tests}
  end

  setup %{conn: conn} do
    Barkpark.ChatSessionResidue.purge!()
    Repo.delete_all(from(s in SchemaDefinition, where: s.dataset < ^@dataset))
    Repo.delete_all(from(d in Document, where: d.dataset < ^@dataset))
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    {:ok, _dataset} = Tenancy.get_or_create_dataset(project, @dataset)

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    Barkpark.LabelFixtures.register_tags!(@dataset)

    {:ok, _} =
      Auth.create_token(@admin_token, "chat admin", @dataset, ["read", "write", "admin"], ws.id)

    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)
    Application.put_env(:barkpark, :studio_chat_title_http_adapter, NullTitleAdapter)
    Application.put_env(:barkpark, :studio_chat_title_cli, NullTitleCli)

    on_exit(fn ->
      if(Process.whereis(Barkpark.StudioChat.RuntimeSupervisor),
        do: DynamicSupervisor.which_children(Barkpark.StudioChat.RuntimeSupervisor),
        else: []
      )
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
      Application.delete_env(:barkpark, :studio_chat_title_http_adapter)
      Application.delete_env(:barkpark, :studio_chat_title_cli)
    end)

    cycle_scope = %{
      workspace_id: ws.id,
      project_id: project.id,
      epic_id: uniq("open-session-epic"),
      wave_id: uniq("open-session-wave")
    }

    {:ok, _wave} =
      CycleFleet.open_wave(
        Map.merge(cycle_scope, %{profile: "epic", inventory: ["unit-a"], scale_contract: %{}})
      )

    {:ok,
     conn: init_test_session(conn, %{"api_token" => @admin_token}),
     scope: scope,
     cycle_scope: cycle_scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp task!(scope, title, extra) do
    doc_id = uniq("aos")

    content =
      %{
        "kind" => "task",
        "brief" => Barkpark.TaskBriefFixtures.brief(),
        "description" => "open-session fixture #{doc_id}",
        "lifecycle_status" => "open",
        "dedup_bypass" => true,
        "acceptance_criteria" => [%{"criterion" => "the slice holds", "met" => false}]
      }
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
      |> Map.merge(extra)

    {:ok, _draft} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => title, "content" => content},
        @dataset,
        scope
      )

    {:ok, pub} = Content.publish_document(doc_id, "task", @dataset, scope)
    pub
  end

  defp claim!(scope, doc, worker) do
    {:ok, claimed} = Tasks.claim_by_id(doc.doc_id, worker, scope)
    claimed
  end

  defp builder_worker(title), do: "epic-builder-" <> AgentTaskJoin.emitter_slug(title)
  defp label(title), do: "build:" <> AgentTaskJoin.emitter_slug(title)

  defp managed_attempt!(cycle_scope, task) do
    {:ok, assignment} =
      CycleFleet.create_assignment(
        Map.merge(cycle_scope, %{
          assignment_id: "unit-a",
          phase: "survey",
          agent_type: "epic-surveyor",
          effort: "medium",
          task_id: task.id,
          snapshot: %{"purpose" => "open-session fixture"}
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

  # A workflow rail with one Build-phase agent per {agentId, label}. Each node
  # carries a brief, so the agent row offers its detail drill-down.
  defp rail_with(agents) do
    nodes =
      for {id, label} <- agents do
        %{
          "type" => "workflow_agent",
          "phaseIndex" => 1,
          "agentId" => id,
          "label" => label,
          "state" => "progress",
          "startedAt" => 100,
          "promptPreview" => "build the slice"
        }
      end

    %{
      "wf" => %{
        "status" => "running",
        "seq" => 1,
        "row" => %{"task_type" => "local_workflow", "description" => "wave 1"},
        "workflow" => [%{"type" => "workflow_phase", "index" => 1, "title" => "Build"} | nodes]
      }
    }
  end

  # The viewer's session: it holds a slice under `epic`, so the Doing strip's
  # epic fold (and therefore the agent join) covers the epic's builders.
  defp viewer_session!(scope, epic, agents) do
    sid = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: sid, mode: "plan"})
    {:ok, _} = StudioChat.set_rail_snapshot(sid, rail_with(agents))
    slice = task!(scope, "The slice this session runs", %{"parent_id" => epic.doc_id})
    claim!(scope, slice, ClaudeChat.worker_id(sid))
    sid
  end

  defp open_detail(view, agent_id) do
    view
    |> element(~s(button[phx-click="rail-agent-toggle"][phx-value-id="#{agent_id}"]))
    |> render_click()
  end

  setup %{scope: scope, cycle_scope: cycle_scope} do
    epic = task!(scope, "The epic", %{})

    managed = task!(scope, @managed_title, %{"parent_id" => epic.doc_id})
    managed = claim!(scope, managed, builder_worker(@managed_title))
    attempt = managed_attempt!(cycle_scope, managed)

    claude = task!(scope, @claude_title, %{"parent_id" => epic.doc_id})
    claude = claim!(scope, claude, builder_worker(@claude_title))

    sid =
      viewer_session!(scope, epic, [
        {"agent-managed", label(@managed_title)},
        {"agent-claude", label(@claude_title)}
      ])

    {:ok, sid: sid, attempt: attempt, managed: managed, claude: claude}
  end

  test "a managed Codex agent's detail offers open session, and it navigates to that session",
       %{conn: conn, sid: sid, attempt: attempt} do
    {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")
    refute has_element?(view, ~s([data-role="chat-agent-open-session"]))

    open_detail(view, "agent-managed")

    link = element(view, ~s(a[data-role="chat-agent-open-session"]))
    html = render(link)
    assert html =~ ~s(href="/studio/chat/#{attempt.session_id}")
    assert html =~ ~s(data-phx-link="patch")
    assert html =~ "open session"

    render_click(link)
    assert_patch(view, "/studio/chat/#{attempt.session_id}")
  end

  test "a Claude-lane agent's detail renders no session control at all",
       %{conn: conn, sid: sid} do
    {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")
    html = open_detail(view, "agent-claude")

    assert html =~ "build the slice"
    refute has_element?(view, ~s([data-role="chat-agent-open-session"]))
  end

  test "a stale attempt (the builder's claim released) renders no session control",
       %{conn: conn, sid: sid, managed: managed} do
    {:ok, _} =
      Tasks.release(managed.id, builder_worker(@managed_title),
        observed_epoch: get_in(managed.content, ["claim", "epoch"])
      )

    {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")
    open_detail(view, "agent-managed")

    refute has_element?(view, ~s([data-role="chat-agent-open-session"]))
  end
end
