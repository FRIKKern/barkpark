defmodule BarkparkWeb.Studio.ChatLiveFlatDefaultScopeTest do
  @moduledoc """
  task-e9386e19bd7bb376, the SECOND of the two surfaces the row demands a
  RED-before on. `/studio/tickets` rides `:plugin_admin`; `/studio/chat` rides
  `:admin_studio`. They are DIFFERENT live_sessions, and a fix that reached only
  one would be the same one-door-fixed-siblings-missed shape all over again —
  which is exactly why this file exists alongside
  `flat_plugin_admin_scope_test.exs` rather than being folded into it.

  What the flat chat mount discloses is not chrome. `ChatLive.execution_hosts/1`
  reads `:current_workspace` and lists that workspace's REGISTERED EXECUTION
  HOSTS — the machines a Studio chat session can dispatch remote commands to. A
  principal handed the seeded Default by `StudioChrome.default_scope_fallback/1`
  therefore enumerates Default's remote command-execution targets.

  THE POPULATION. `LiveAuth :admin` gates on the workspace-BLIND global `admin`
  permission, so an api_token with `workspace_id == nil` and NO
  `workspace_memberships` row anywhere mounts. `Tenancy.Auth.authorize/3` is
  `member?(token, workspace_id) and permits?(token, action)` with no global
  bypass, so that token is authorized in NO workspace — the seeded Default
  INCLUDED. Pinning Default for it hands it a tenant it cannot act in.

  RED-BEFORE: on the unfixed tree the refusal test below FAILS — the host named
  DEFAULT-HOST-alpha renders in the registered-host picker for a principal
  authorized nowhere. It goes GREEN when `default_scope_fallback/1` becomes
  authority-checked, at which point `:current_workspace` is nil and
  `execution_hosts/1`'s `%{id: ws_id}` clause falls through to `[]`.

  `ChatHosts.get_host/2` is NOT touched by that change and is not touched here:
  it is already fail-closed on a nil workspace (a nil scope matches no host),
  and the row explicitly fences it off.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.AccountsFixtures, only: [register_user: 1]

  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.ChatHosts
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Session, as: StudioChatSession
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @flat_path "/studio/chat"
  @dataset "production"

  setup %{conn: conn} do
    default_ws = ensure_default!()

    {:ok, ws_b} =
      Tenancy.create_workspace(%{
        slug: "chat-flat-b-#{System.unique_integer([:positive])}",
        name: "Chat Flat B"
      })

    {:ok, _proj_b} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

    # A COLLIDING fixture: one registered host in EACH tenant. Without the
    # ws-B row a green refusal is also what "the picker renders nothing at all"
    # looks like; without the Default row there would be nothing to leak and the
    # refusal would be vacuous by construction.
    {:ok, %{host: default_host}} =
      ChatHosts.issue_enrollment(default_ws.id, %{
        name: "DEFAULT-HOST-alpha",
        approved_roots: [System.tmp_dir!()]
      })

    {:ok, %{host: _b_host}} =
      ChatHosts.issue_enrollment(ws_b.id, %{
        name: "WSB-HOST-beta",
        approved_roots: [System.tmp_dir!()]
      })

    enable_fake_chat()

    %{
      conn: conn,
      default_ws: default_ws,
      ws_b: ws_b,
      default_host: default_host
    }
  end

  describe "flat /studio/chat — a token authorized in NO workspace" do
    setup %{conn: conn} do
      # Inserted raw rather than through `Auth.create_token/5`, which defaults a
      # nil workspace_id to Default AND writes a membership row — i.e. it would
      # silently manufacture the authority this population is defined by NOT
      # having.
      raw = "chat-flat-instance-#{System.unique_integer([:positive])}"

      {:ok, token} =
        %ApiToken{}
        |> ApiToken.changeset(%{
          token_hash: ApiToken.hash_token(raw),
          label: "instance-wide operator",
          dataset: @dataset,
          permissions: ["read", "write", "admin"]
        })
        |> Repo.insert()

      %{conn: init_test_session(conn, %{"api_token" => raw}), instance_token: token}
    end

    # ASSERT THE SUBJECT EXISTS, on both sides: the principal really holds no
    # authority anywhere, AND the host it must not see really is there. Either
    # one drifting turns the refusal below into a test of nothing.
    test "fixture check: no authority anywhere, and Default really does own a host", %{
      instance_token: token,
      default_ws: default_ws,
      ws_b: ws_b
    } do
      assert is_nil(token.workspace_id)
      assert TenancyAuth.membership(token, default_ws.id) == nil
      assert TenancyAuth.membership(token, ws_b.id) == nil
      assert TenancyAuth.authorize(token, default_ws.id, :read) == {:error, :forbidden}

      assert "DEFAULT-HOST-alpha" in Enum.map(ChatHosts.list_hosts(default_ws.id), & &1.name),
             "the Default workspace holds no registered host — the leak assertion below " <>
               "would be vacuously green"
    end

    test "mounts, but the registered-host picker lists NONE of Default's hosts", %{conn: conn} do
      # The mount must still succeed. This row narrows the scope; it does not
      # lock the host operator out of `:admin_studio`, which also carries the
      # genuinely scope-free OrgAdmin / Styleguide / tmux surfaces.
      assert {:ok, view, _html} = live(conn, @flat_path)
      assert view.module == BarkparkWeb.Studio.ChatLive

      # The picker only renders once the target is flipped to registered_host,
      # so this drives the real UI path rather than reading an assign.
      html =
        render_change(view, "set-execution-target", %{"execution_target" => "registered_host"})

      # NON-VACUOUS: the picker itself must be on screen. Without this, an
      # absent host name is indistinguishable from an absent picker.
      assert html =~ ~s(aria-label="Registered host")
      assert html =~ "Choose local hardware…"

      refute html =~ "DEFAULT-HOST-alpha",
             "flat /studio/chat enumerated the Default workspace's registered execution " <>
               "hosts for a token authorized in NO workspace"

      refute html =~ "WSB-HOST-beta"
    end

    # ── THE CREATE SIDE (task-995f53ef7b7c4471) ──────────────────────────────
    #
    # The same principal, the same mount, the WRITE instead of the read.
    # `ensure_session/1` used to re-derive the seeded Default through
    # `Tenancy.get_default_workspace()` whenever `:current_workspace` was nil —
    # i.e. it recovered the exact workspace `default_scope_fallback/1` had just
    # refused to pin, and stamped it onto a durable `chat_sessions` row.
    #
    # RED BEFORE: on the unfixed tree this test FAILS with a created session
    # whose `owner_workspace_id` is the Default workspace id.
    test "the first send REFUSES rather than minting a session owned by Default", %{
      conn: conn,
      default_ws: default_ws
    } do
      {:ok, view, _html} = live(conn, @flat_path)

      # ASSERT THE SUBJECT EXISTS, both halves — a bound boolean assertion, not
      # a match-assert (ExUnit discards the message on `assert %S{} = x, "msg"`).
      # If the mount stopped producing a nil scope, or the Default row stopped
      # existing, this test would be green for a reason that is not the fix.
      assert is_nil(:sys.get_state(view.pid).socket.assigns[:current_workspace]),
             "the flat mount no longer leaves :current_workspace nil for a principal " <>
               "authorized nowhere — the branch under test is unreachable and every " <>
               "assertion below is vacuous"

      refute is_nil(Tenancy.get_default_workspace()),
             "no seeded Default workspace exists, so the old fallback had nothing to " <>
               "stamp and this refusal proves nothing"

      # `ensure_session/1` runs on the {:dispatch_send, …} path, so a real submit
      # is what exercises the WRITE; `render/1` forces the round-trip.
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hello"})
      html = render(view)

      session_id = :sys.get_state(view.pid).socket.assigns.store_session_id

      if is_binary(session_id) do
        created = Repo.get!(StudioChatSession, session_id)

        flunk(
          "the flat send minted chat session #{session_id} owned by " <>
            "#{inspect(created.owner_workspace_id)} (the seeded Default is " <>
            "#{inspect(default_ws.id)}) for a principal authorized in NO workspace"
        )
      end

      # The refusal must be HONEST, not silent: the operator sees a line and the
      # composer goes offline rather than pretending a session started.
      assert html =~ "isn&#39;t authorized in any workspace",
             "the create was refused without telling the operator why"
    end
  end

  describe "POSITIVE CONTROL — a token that HOLDS a Default membership still sees them" do
    # Acceptance 3, first arm. A refusal-only suite is equally consistent with a
    # fallback that now pins NOBODY, which would break the legitimate
    # instance-admin path. Same surface, same events, one fixture difference.
    setup %{conn: conn, default_ws: default_ws} do
      raw = "chat-flat-member-#{System.unique_integer([:positive])}"

      # workspace_id stays nil so `derive_scope_from_principal/1` cannot bind
      # it — Default must come from the FALLBACK, the code under test.
      {:ok, token} =
        %ApiToken{}
        |> ApiToken.changeset(%{
          token_hash: ApiToken.hash_token(raw),
          label: "default member operator",
          dataset: @dataset,
          permissions: ["read", "write", "admin"]
        })
        |> Repo.insert()

      {:ok, _membership} = TenancyAuth.create_membership(default_ws.id, token.id, "admin")

      %{conn: init_test_session(conn, %{"api_token" => raw}), member_token: token}
    end

    test "fixture check: this principal IS authorized in Default", %{
      member_token: token,
      default_ws: default_ws
    } do
      assert is_nil(token.workspace_id)
      assert TenancyAuth.authorize(token, default_ws.id, :read) == :ok
    end

    test "mounts and still lists Default's registered hosts", %{conn: conn} do
      assert {:ok, view, _html} = live(conn, @flat_path)

      html =
        render_change(view, "set-execution-target", %{"execution_target" => "registered_host"})

      assert html =~ "DEFAULT-HOST-alpha",
             "the Default-member operator lost the registered-host picker it is entitled to"

      refute html =~ "WSB-HOST-beta"
    end

    # A refusal-only suite is equally consistent with a create path that now
    # refuses EVERYONE. It also guards the two D43h/D58h consequences directly:
    # a non-NULL owner is what keeps the session visible to its creator's
    # workspace-scoped listing and eligible for a `chat_blocked` fire.
    test "a send from an AUTHORIZED principal still creates a Default-owned session", %{
      conn: conn,
      default_ws: default_ws
    } do
      {:ok, view, _html} = live(conn, @flat_path)

      refute is_nil(:sys.get_state(view.pid).socket.assigns[:current_workspace]),
             "the Default-member operator lost its :current_workspace — this control " <>
               "would then be testing the refusal branch, not the create branch"

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hello"})
      _ = render(view)

      session_id = :sys.get_state(view.pid).socket.assigns.store_session_id

      assert is_binary(session_id),
             "an authorized principal's send created no chat session at all"

      created = Repo.get!(StudioChatSession, session_id)

      refute is_nil(created.owner_workspace_id),
             "the create minted a NULL-owner session — BlockedSweeper filters " <>
               "`not is_nil(owner_workspace_id)` so it could never fire chat_blocked, " <>
               "and scope_sessions/2 would hide it from its own creator (D43h/D58h)"

      assert created.owner_workspace_id == default_ws.id,
             "a Default-member operator's session was stamped " <>
               "#{inspect(created.owner_workspace_id)} instead of Default " <>
               "#{inspect(default_ws.id)}"

      assert StudioChat.scope_match?(created.owner_workspace_id, default_ws.id),
             "the created session is invisible to its own creator's workspace scope"
    end
  end

  describe "POSITIVE CONTROL — the ACCOUNT-session arm keeps Default" do
    # Acceptance 3, second arm. `LiveAuth.authorize_user/3` refuses to continue
    # unless `Tenancy.Auth.authorize(user, default_ws_id, :admin) == :ok`, so
    # this principal holds a real Default membership. It also carries
    # `:current_user` and NO `:api_token` — so if the new authority check read
    # only the token assign, this test reds.
    setup %{conn: conn, default_ws: default_ws} do
      user = register_user("chat-flat-acct-#{System.unique_integer([:positive])}@example.test")
      {:ok, _} = TenancyAuth.create_membership(default_ws.id, user.id, "admin", "user")
      {:ok, session_raw} = Accounts.create_user_session_token(user)

      # `init_test_session/2` MERGES — without clearing it, the OUTER setup's
      # api_token survives, `LiveAuth.authorize/4` finds a token candidate
      # first, and this "account session" is quietly the token arm again.
      %{conn: init_test_session(conn, %{"api_token" => nil, "user_session" => session_raw})}
    end

    test "mounts and still lists Default's registered hosts", %{conn: conn} do
      assert {:ok, view, _html} = live(conn, @flat_path)

      html =
        render_change(view, "set-execution-target", %{"execution_target" => "registered_host"})

      assert html =~ "DEFAULT-HOST-alpha"
    end
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

    case Tenancy.get_default_project() do
      nil -> {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
      _proj -> :ok
    end

    ws
  end

  # A hermetic fake runtime: `cat` echoes NDJSON back, no real `claude`. Without
  # it `ChatLive.mount` refuses (no enabled provider) and redirects — which would
  # make every assertion here pass for the WRONG reason. Copied from
  # `chat_live_scoped_admin_test.exs`, which makes the same argument.
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
