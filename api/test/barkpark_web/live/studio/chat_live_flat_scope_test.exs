defmodule BarkparkWeb.Studio.ChatLiveFlatScopeTest do
  @moduledoc """
  task-58b55b015f222b51 — the FLAT `/studio/chat` mount must not act in the
  seeded Default workspace on behalf of an operator whose home is elsewhere.

  `ChatLive` is dual-mounted. The scoped route `/w/:ws/p/:proj/studio/chat`
  rides `:scoped_admin_studio`, which carries `{LiveScope, :resolve}` and
  membership-gates the URL workspace. The FLAT route rides `:admin_studio`,
  whose on_mount list is `[LiveAuth :admin, LiveAuth :require_org_mfa,
  StudioChrome :default]` — no LiveScope, no PluginScopeSession.

  Two consumers read that assign:

    * `ChatLive.execution_hosts/1` — lists the workspace's
      REGISTERED EXECUTION HOSTS in the picker. A registered host is a remote
      command-execution target, so showing the wrong tenant's inventory is
      materially worse than a chat-history leak.
    * `ChatLive.ensure_session/1` — stamps `owner_workspace_id`
      on the created `chat_sessions` row. A WRITE.

  `ChatHosts.Context.get_host/2` is fail-closed and CORRECT; like the tickets
  case it was merely fed the wrong workspace, and is deliberately NOT touched.

  The fake runtime is enabled in EVERY test: `ChatLive.mount` refuses when no
  provider is enabled, and a mount refused for a MISSING RUNTIME would make
  every assertion below vacuously green for the wrong reason.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.ChatHosts
  alias Barkpark.Repo
  alias Barkpark.StudioChat.Session, as: StudioChatSession
  alias Barkpark.Tenancy

  @flat_path "/studio/chat"

  setup %{conn: conn} do
    {default_ws, _} = ensure_default!()

    {:ok, ws_b} =
      Tenancy.create_workspace(%{
        slug: "chatflat-b-#{System.unique_integer([:positive])}",
        name: "Chat Flat B"
      })

    {:ok, _proj_b} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

    # One registered execution host in EACH tenant, so an empty picker can never
    # pass vacuously — B's host MUST render and Default's MUST NOT.
    {:ok, _} =
      ChatHosts.issue_enrollment(default_ws.id, %{
        name: "DEFAULT-TENANT-HOST",
        approved_roots: [System.tmp_dir!()]
      })

    {:ok, _} =
      ChatHosts.issue_enrollment(ws_b.id, %{
        name: "WSB-OWN-HOST",
        approved_roots: [System.tmp_dir!()]
      })

    enable_fake_chat()

    %{conn: conn, default_ws: default_ws, ws_b: ws_b}
  end

  describe "POPULATION 1 — an admin token BOUND to workspace B" do
    setup %{conn: conn, ws_b: ws_b} do
      raw = "chatflat-bound-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(
          raw,
          "chat flat ws-b admin",
          "production",
          ["read", "write", "admin"],
          ws_b.id
        )

      %{conn: init_test_session(conn, %{"api_token" => raw})}
    end

    test "the execution-host picker shows B's host and NEVER Default's", %{conn: conn} do
      html = open_host_picker(conn)

      assert html =~ "WSB-OWN-HOST",
             "the ws-B admin should see their own workspace's registered execution host"

      refute html =~ "DEFAULT-TENANT-HOST",
             "flat /studio/chat leaked the Default workspace's registered execution hosts"
    end

    test "a session created from the flat socket is owned by B, not Default", %{
      conn: conn,
      ws_b: ws_b,
      default_ws: default_ws
    } do
      {:ok, view, _html} = live(conn, @flat_path)

      # `ensure_session/1` runs on the {:dispatch_send, …} path, so a real
      # submit is what exercises the WRITE. render/1 forces the round-trip that
      # lets the queued message be processed.
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hello"})
      _ = render(view)

      # Assert on THE SESSION THIS SOCKET CREATED, by id, not on
      # `Repo.all(chat_sessions)`. Every agent shares one Postgres and this table
      # carries rows owned by workspaces no test in this file created, so a
      # whole-table assertion is unsound — it passed by luck until a leftover row
      # happened to land in the query.
      session_id = :sys.get_state(view.pid).socket.assigns.store_session_id

      assert is_binary(session_id), "the send should have created a chat session"

      created = Repo.get!(StudioChatSession, session_id)

      assert created.owner_workspace_id == ws_b.id,
             "a ws-B admin's flat chat session was stamped with workspace " <>
               "#{inspect(created.owner_workspace_id)} instead of their own #{inspect(ws_b.id)}"

      refute created.owner_workspace_id == default_ws.id,
             "flat /studio/chat wrote a chat_sessions row owned by the Default workspace"
    end
  end

  describe "POPULATION 2 — an instance-wide admin token (no workspace of its own)" do
    setup %{conn: conn} do
      raw = "chatflat-instance-#{System.unique_integer([:positive])}"

      {:ok, _} =
        %ApiToken{}
        |> ApiToken.changeset(%{
          token_hash: ApiToken.hash_token(raw),
          label: "instance-wide chat operator",
          dataset: "production",
          permissions: ["read", "write", "admin"]
        })
        |> Repo.insert()

      %{conn: init_test_session(conn, %{"api_token" => raw})}
    end

    # CHARACTERIZATION, not an endorsement. This principal carries `workspace_id
    # = nil` and NO membership row anywhere, so `derive_scope_from_principal/1`
    # has nothing to bind and `default_scope_fallback/1` pins Default — and it
    # then reads Default's registered execution hosts despite holding no
    # authority there (`Tenancy.Auth.authorize/3` is `member?/2 and permits?/2`,
    # so a membership-less token is authorized in NO workspace, Default
    # included).
    #
    # This is deliberately NOT fixed here. It is not a ChatLive defect: the
    # producer is `StudioChrome.default_scope_fallback/1`, which every
    # resolver-less flat live_session shares, so patching it inside this one
    # LiveView would be exactly the sideways-carry that produced this defect
    # class. Tracked as its own row against the fallback itself.
    #
    # The test is here so the gap is VISIBLE and cannot rot silently: if a
    # future change starts refusing this principal, this test reds and whoever
    # made it must come back and delete it on purpose.
    test "CHARACTERIZED GAP: still mounts and reads Default's hosts", %{conn: conn} do
      html = open_host_picker(conn)

      assert html =~ "DEFAULT-TENANT-HOST",
             "a membership-less instance token still reads Default's execution hosts — " <>
               "if this now refuses, the fallback row landed and this test should be retired"

      refute html =~ "WSB-OWN-HOST",
             "it must never reach a workspace it has no relationship to"
    end
  end

  # The Chat TAB, not the chat surface. Lives here rather than in nav_test.exs
  # because it needs `enable_fake_chat/0` — `ClaudeChat.enabled?/0` gates the tab
  # and config/test.exs ships `claude_chat: [enabled: false]` with
  # `public_demo_studio: true`, so the tab is absent by default. nav_test.exs is
  # `async: true`, and swapping global Application env inside an async module is
  # exactly what `async_global_seam_guard_test.exs` forbids (those keys ARE read
  # by concurrent modules, so the `async-env-seam-allow` hatch would need a
  # reason that is not true). This module is already `async: false`.
  describe "the Chat NAV TAB is scope-truthful" do
    test "scope-prefixed on a scoped surface, like Settings and Connectors" do
      chat =
        BarkparkWeb.StudioComponents.Nav.default_top_menu_entries(
          "production",
          "/w/acme/p/site",
          true,
          "/w/acme/p/site/d/production/studio/media"
        )
        |> Enum.find(&(&1.label == "chat"))

      # Non-vacuous: nav-parity requires the tab on every studio-layout surface,
      # and without this guard both assertions below pass on a nil entry.
      assert chat, "the chat tab must be present on a scoped surface"

      assert String.starts_with?(chat.path, "/w/acme/p/site/studio/chat"),
             "the scoped Chat tab pointed at #{chat.path} — it must address the " <>
               "workspace the page is on, not the flat Default-bound surface"

      assert chat.active_when == "/w/acme/p/site/studio/chat",
             "active_when must track the prefixed path so the tab highlights on the scoped route"
    end

    test "stays flat on a flat surface" do
      chat =
        BarkparkWeb.StudioComponents.Nav.default_top_menu_entries("production", "", true, nil)
        |> Enum.find(&(&1.label == "chat"))

      assert chat, "the chat tab must be present on a flat surface too"
      assert chat.path == "/studio/chat"
      assert chat.active_when == "/studio/chat"
    end
  end

  # Reveal the registered-host <select>: it renders only when
  # `@execution_target == "registered_host"` and the default is "managed", so a
  # naive assertion on the mount HTML sees NEITHER tenant's host and a `refute`
  # passes for the wrong reason. `@execution_hosts` is still computed at MOUNT
  # (in `ChatLive.mount/3`, the `execution_hosts:` assign) from `current_workspace`;
  # this event only unhides it.
  defp open_host_picker(conn) do
    {:ok, view, _html} = live(conn, @flat_path)
    render_change(view, "set-execution-target", %{"execution_target" => "registered_host"})
  end

  # ── Fixtures ────────────────────────────────────────────────────────────────

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
          {:ok, p} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
          p

        p ->
          p
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
