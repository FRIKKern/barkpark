defmodule BarkparkWeb.Studio.ChatLiveScopedAdminTest do
  @moduledoc """
  Wave 26, slice W26-2 — the scoped-mount rejection proof for ChatLive.

  ChatLive is the highest-severity untested scoped-admin surface: ~40 write
  handlers, including arm-bypass / bypass-confirm and set-execution-host /
  set-execution-target, and it is DUAL-MOUNTED — flat (`:admin_studio`,
  `/studio/chat`) and workspace-scoped (`:scoped_admin_studio`,
  `/w/:ws/p/:proj/studio/chat`). The scoped mount is the one W24 proved is a
  privilege-escalation hole: the mount gate was `{LiveAuth, :admin}`, a FLAT
  GLOBAL-permission gate, so an outsider holding the flat global `admin`
  permission but only a MEMBER of the target workspace mounted and could drive
  every one of those writes.

  W26-1 (connectors-liveauth-admin-target-workspace) closes it AT THE MOUNT by
  flipping the two scoped live_sessions to a new `{LiveAuth, :scoped_admin}`
  hook that resolves the TARGET workspace from `:workspace_slug` and authorizes
  the acting principal against THAT workspace's admin membership.

  This suite is ADDITIVE protective coverage (no production change of its own).
  It proves, against the W26-1 mount gate:

    * a TOKEN outsider (flat global `admin` + member-only of ws B) is REJECTED
      at mount of the SCOPED chat route (redirect, not `{:ok, view}`);
    * a USER-session outsider (admin of Default, member-only of ws B) is
      likewise REJECTED — the same escalation via the user principal arm;
    * a legit ws-B admin MOUNTS the scoped route (no over-tight lockout);
    * the FLAT `/studio/chat` route is UNCHANGED — a global-admin token still
      mounts it (dual-mount correctness: W26-1 touched only the scoped session).

  RED-FIRST: on origin/main the two rejection assertions FAIL — the outsiders
  mount the scoped chat surface (the live vuln). They go GREEN only on the
  W26-1 mount gate. The fake-runtime is enabled in EVERY test so the ONLY thing
  that can bounce a mount is the auth gate — a mount refused for a missing
  runtime would make the rejection assertion vacuously green.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.AccountsFixtures, only: [register_user: 1]

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  setup %{conn: conn} do
    # Default must exist first: `Auth.create_token` auto-binds new tokens to the
    # Default workspace, and the USER outsider needs a Default-admin row (the
    # exact grant that made the pre-fix user arm mount ANY workspace).
    {default_ws, _default_proj} = ensure_default!()

    # The TARGET workspace the scoped chat route operates on.
    {:ok, ws_b} =
      Tenancy.create_workspace(%{
        slug: "chat-wsb-#{System.unique_integer([:positive])}",
        name: "Chat WS B"
      })

    {:ok, _proj_b} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

    # ── TOKEN outsider: flat global admin perm (clears :admin), member-only of B.
    token_outsider_raw = "chat-tok-outsider-#{System.unique_integer([:positive])}"

    {:ok, token_outsider} =
      Auth.create_token(token_outsider_raw, "chat token outsider", "production", [
        "read",
        "write",
        "admin"
      ])

    {:ok, _} = TenancyAuth.create_membership(ws_b.id, token_outsider.id)

    # ── USER outsider: admin of DEFAULT (so the pre-fix user arm's
    # get_default_workspace() admin check passes → mounts anything), member-only
    # of B. A user with no Default-admin row is already bounced on main, so it
    # would prove nothing about the target-workspace hole.
    user_outsider =
      register_user("chat-user-outsider-#{System.unique_integer([:positive])}@example.test")

    {:ok, user_outsider_raw} = Accounts.create_user_session_token(user_outsider)
    {:ok, _} = TenancyAuth.create_membership(default_ws.id, user_outsider.id, "admin", "user")
    {:ok, _} = TenancyAuth.create_membership(ws_b.id, user_outsider.id, "member", "user")

    # ── Legit ws-B admin: global admin perm AND an admin membership row in B.
    admin_raw = "chat-wsb-admin-#{System.unique_integer([:positive])}"

    {:ok, admin} =
      Auth.create_token(admin_raw, "chat wsb admin", "production", ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws_b.id, admin.id, "admin")

    enable_fake_chat()

    {:ok,
     conn: conn,
     scoped_path: "/w/#{ws_b.slug}/p/default/studio/chat",
     token_outsider_raw: token_outsider_raw,
     user_outsider_raw: user_outsider_raw,
     admin_raw: admin_raw}
  end

  describe "scoped /w/:ws/p/:proj/studio/chat — rejected at mount (W26-1 gate)" do
    test "a TOKEN outsider (global admin perm, member-only of B) is redirected, never mounted", %{
      conn: conn,
      scoped_path: path,
      token_outsider_raw: raw
    } do
      conn = init_test_session(conn, %{"api_token" => raw})

      # RED on origin/main: the flat :admin mount gate + LiveScope's :read
      # membership let this outsider mount the scoped chat surface. GREEN on the
      # W26-1 :scoped_admin gate: workspace_admin?/2 sees member → halt.
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, path)
    end

    test "a USER outsider (Default admin, member-only of B) is redirected, never mounted", %{
      conn: conn,
      scoped_path: path,
      user_outsider_raw: raw
    } do
      conn = init_test_session(conn, %{"user_session" => raw})

      # RED on origin/main: the user arm authorized against get_default_workspace()
      # (where this user IS admin), never the URL workspace B. GREEN on W26-1:
      # the user arm authorizes workspace_admin?(user, ws_b.id) → member → halt.
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, path)
    end
  end

  describe "scoped + flat chat still mount for the right principals (no regression)" do
    test "a legit ws-B admin MOUNTS the scoped chat route", %{
      conn: conn,
      scoped_path: path,
      admin_raw: raw
    } do
      conn = init_test_session(conn, %{"api_token" => raw})

      assert {:ok, view, _html} = live(conn, path)
      assert view.module == BarkparkWeb.Studio.ChatLive
    end

    test "the FLAT /studio/chat route is unchanged — a global-admin token still mounts it", %{
      conn: conn,
      admin_raw: raw
    } do
      conn = init_test_session(conn, %{"api_token" => raw})

      # Dual-mount correctness: W26-1 flipped ONLY the two scoped live_sessions,
      # so the flat :admin_studio session still admits a global-admin token
      # exactly as before — the SAME ChatLive module the scoped route mounts.
      assert {:ok, view, _html} = live(conn, "/studio/chat")
      assert view.module == BarkparkWeb.Studio.ChatLive
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────────────────

  # The Default workspace/project must exist before tokens are minted.
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

  # A hermetic fake runtime: `cat` echoes NDJSON back, no real `claude`. Without
  # it ChatLive.mount refuses (no enabled provider) and redirects — which would
  # make the rejection assertions pass for the WRONG reason. Reaps any runtime
  # child at test end.
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
