defmodule BarkparkWeb.Studio.ChatLiveNullOwnerEpicFoldTest do
  @moduledoc """
  task-95902fb0528c2370 — THE JOIN, not either half.

  Two halves, each defensible where it is written, fail OPEN in composition:

    * ChatLive's `owner_in_tenancy?/2` ADMITS a NULL-owned session into a
      SCOPED viewer's sidebar (`is_nil(owner) or owner == ws_id`), deliberately:
      a NULL `owner_workspace_id` is a legacy / pre-tenancy row and blanking
      those from a scoped admin's sidebar is a regression, not a fix.

    * `Barkpark.StudioChat.epic_goal/2` derives ITS scope from the SESSION's
      `owner_workspace_id`, so a NULL-owned session's three ledger hops run
      UNSCOPED — also deliberate, because on the FLAT instance-admin mount the
      global fold is the correct answer, and narrowing it there would blank the
      epic line for every operator session.

  Composed: a workspace-B-scoped viewer folds a NULL-owned session and the epic
  line it renders is read from the WHOLE task ledger, workspace A included.

  WHY THIS SUITE CANNOT BE PASSED BY EITHER HALF ALONE. Its ledger rows carry
  `workspace_id: <workspace A>`, and the session under test carries a NULL
  owner. The api-side narrowing (the scope-the-three-hops change) takes its
  `nil` arm for exactly this session, so applying it changes NOTHING here — a
  fixture where the FOLD half alone is correct still reds. And the CONTROLS
  below make a fix-by-hiding fail too: the NULL-owned row must STILL be listed
  and must STILL fold on the flat mount, so a clamp that merely fails closed
  reds the controls instead of the leak.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.StudioChat
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @ws_a_epic_title "WORKSPACE A EPIC — must never reach a ws-B viewer"
  @ws_b_epic_title "Workspace B epic — the positive control"

  setup %{conn: conn} do
    {_default_ws, _default_proj} = ensure_default!()

    {:ok, ws_a} =
      Tenancy.create_workspace(%{
        slug: "nof-wsa-#{System.unique_integer([:positive])}",
        name: "NOF WS A"
      })

    {:ok, ws_b} =
      Tenancy.create_workspace(%{
        slug: "nof-wsb-#{System.unique_integer([:positive])}",
        name: "NOF WS B"
      })

    {:ok, _proj_b} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

    # A ws-B admin and NOTHING more — not an instance admin.
    admin_raw = "nof-wsb-admin-#{System.unique_integer([:positive])}"

    {:ok, admin} =
      Auth.create_token(admin_raw, "nof wsb admin", "production", ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws_b.id, admin.id, "admin")

    # ── THE SUBJECT: a NULL-owned (admin/global) session with a workflow rail.
    null_sid = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: null_sid, mode: "plan"}, :global)
    {:ok, _} = StudioChat.set_rail_snapshot(null_sid, workflow_rail())
    null_session = StudioChat.get_session(null_sid, :global)
    assert is_nil(null_session.owner_workspace_id), "PRECONDITION: the subject must be NULL-owned"

    # Its worker holds a workspace-A slice under a workspace-A epic.
    seed_epic!(worker_for(null_sid), "nof-a", @ws_a_epic_title, ws_a.id)

    # ── THE POSITIVE CONTROL: a genuinely ws-B-owned session, ws-B ledger.
    b_sid = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: b_sid, mode: "plan"}, {:workspace, ws_b.id})
    {:ok, _} = StudioChat.set_rail_snapshot(b_sid, workflow_rail())
    b_session = StudioChat.get_session(b_sid, :global)
    assert b_session.owner_workspace_id == ws_b.id, "PRECONDITION: the control must be ws-B-owned"

    seed_epic!(worker_for(b_sid), "nof-b", @ws_b_epic_title, ws_b.id)

    enable_fake_chat()

    {:ok,
     conn: conn,
     scoped_path: "/w/#{ws_b.slug}/p/default/studio/chat",
     admin_raw: admin_raw,
     null_sid: null_sid,
     b_sid: b_sid}
  end

  describe "the scoped mount — a NULL-owned session's epic fold" do
    test "a ws-B-scoped viewer does NOT render a NULL-owned session's globally-folded epic", %{
      conn: conn,
      scoped_path: path,
      admin_raw: admin_raw,
      null_sid: null_sid,
      b_sid: b_sid
    } do
      conn = init_test_session(conn, %{"api_token" => admin_raw})
      {:ok, view, _html} = live(conn, path)

      # POSITIVE CONTROL, read in the SAME mount: the fold WORKS here, and the
      # epic line is a thing this view can render. Without this, the refutation
      # below would be green for any reason at all — a blank sidebar included.
      control = view |> element(~s([data-test-id="chat-epic-#{b_sid}"])) |> render()
      assert control =~ @ws_b_epic_title

      # CONTROL 2 — the NULL-owned row is STILL LISTED. The disposition suppresses
      # the derived LINE, not the row: a clamp that fail-closes reds here.
      assert has_element?(view, ~s([data-test-id="chat-workflow-#{null_sid}"])),
             "the NULL-owned legacy row must remain visible to a scoped admin"

      # THE LEAK.
      refute has_element?(view, ~s([data-test-id="chat-epic-#{null_sid}"])),
             "a NULL-owned session's epic line folded the WHOLE ledger for a ws-B viewer"

      refute render(view) =~ @ws_a_epic_title,
             "workspace A's epic title reached a workspace-B-scoped viewer"
    end
  end

  describe "the flat instance-admin mount — unchanged" do
    test "a flat admin still sees the NULL-owned session's global epic fold", %{
      conn: conn,
      admin_raw: admin_raw,
      null_sid: null_sid
    } do
      conn = init_test_session(conn, %{"api_token" => admin_raw})
      {:ok, view, _html} = live(conn, "/studio/chat")

      line = view |> element(~s([data-test-id="chat-epic-#{null_sid}"])) |> render()

      assert line =~ @ws_a_epic_title,
             "NO-REGRESSION: the flat instance-admin view is the global operator surface"
    end
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp worker_for(session_id), do: StudioChat.Runtime.worker_id("claude", session_id)

  # Lean ledger rows — `epic_goal/2` reads the published documents table
  # directly. `workspace_id` is set so that a workspace-scoped narrowing of the
  # three hops is MEASURABLE against this fixture rather than vacuous.
  defp seed_epic!(worker, prefix, title, workspace_id) do
    insert_task!("task-#{prefix}-epic", title, workspace_id, %{
      "lifecycle_status" => "in_progress",
      "wave_status" => "wave: building"
    })

    insert_task!("task-#{prefix}-held", "Held slice", workspace_id, %{
      "lifecycle_status" => "in_progress",
      "parent_id" => "task-#{prefix}-epic",
      "claim" => %{"worker" => worker}
    })

    insert_task!("task-#{prefix}-s1", "Slice 1", workspace_id, %{
      "lifecycle_status" => "done",
      "parent_id" => "task-#{prefix}-epic"
    })

    :ok
  end

  defp insert_task!(doc_id, title, workspace_id, content) do
    Barkpark.Repo.insert!(%Barkpark.Content.Document{
      doc_id: doc_id,
      type: "task",
      title: title,
      status: "published",
      workspace_id: workspace_id,
      content: content,
      rev: Ecto.UUID.generate()
    })
  end

  defp workflow_rail do
    %{
      "wf" => %{
        "status" => "running",
        "seq" => 1,
        "row" => %{"task_type" => "local_workflow", "description" => "wave 1"},
        "workflow" => [
          %{"type" => "workflow_phase", "index" => 1, "title" => "Explore"},
          %{"type" => "workflow_phase", "index" => 2, "title" => "Build"},
          %{
            "type" => "workflow_agent",
            "phaseIndex" => 1,
            "label" => "explore",
            "state" => "done",
            "startedAt" => 100,
            "tokens" => 10
          },
          %{
            "type" => "workflow_agent",
            "phaseIndex" => 2,
            "label" => "build:a",
            "state" => "progress",
            "startedAt" => 300
          }
        ]
      }
    }
  end

  defp ensure_default! do
    ws =
      case Tenancy.get_default_workspace() do
        nil ->
          {:ok, ws} = Tenancy.create_workspace(%{slug: "default", name: "Default"})
          ws

        ws ->
          ws
      end

    proj =
      case Tenancy.get_default_project() do
        nil ->
          {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
          proj

        proj ->
          proj
      end

    {ws, proj}
  end

  defp enable_fake_chat do
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
  end
end
