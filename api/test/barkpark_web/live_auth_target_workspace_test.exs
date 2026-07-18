defmodule BarkparkWeb.LiveAuthTargetWorkspaceTest do
  @moduledoc """
  Connectors W26 (charter D219-D224) — the `LiveAuth.:scoped_admin` mount gate
  authorizes against the TARGET workspace (the one in the URL), not a flat /
  Default-pinned grant.

  THE VULN (W24's executed escalation probe): `on_mount(:admin, ...)` discards
  params. Its token arm authorizes on the FLAT global `admin` permission; its
  user arm pins `get_default_workspace()`. So a principal holding the flat
  global admin grant that is only a MEMBER of workspace B mounted B's
  scoped_admin LiveViews (ConnectorsLive, SettingsLive, ChatHostsLive, every
  scoped admin plugin LV) and could drive their writes.

  Four proof obligations, straight from the wave brief:

    (a) a TOKEN outsider (flat global admin perm, member-only of ws B) is
        REJECTED at mount of ConnectorsLive AND SettingsLive;
    (b) a USER-session outsider (Default-workspace admin, member-only of ws B)
        is REJECTED at mount;
    (c) a legit ws-B admin with NO Default/global admin grant MOUNTS both —
        the D207 over-tight lockout is fixed, not inverted;
    (d) the flat `/studio` admin surfaces (still on `:admin`) behave
        byte-identically.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup %{conn: conn} do
    {default_ws, _default_proj} = ensure_default_scope!()

    suffix = System.unique_integer([:positive])
    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "tgt-b-#{suffix}", name: "Target B"})
    {:ok, _proj} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

    {:ok,
     conn: conn,
     default_ws: default_ws,
     ws_b: ws_b,
     connectors_path: "/w/#{ws_b.slug}/p/default/studio/connectors",
     settings_path: "/w/#{ws_b.slug}/p/default/studio/settings"}
  end

  # The W24 escalation shape: a token minted with the flat global admin
  # permission (auto-bound as an admin of its Default home workspace) that is
  # only a MEMBER of the target workspace B.
  defp token_outsider!(ws_b) do
    raw = "tgt-outsider-#{System.unique_integer([:positive])}"
    {:ok, tok} = Auth.create_token(raw, "tgt outsider", @dataset, ["read", "write", "admin"])
    {:ok, _} = TenancyAuth.create_membership(ws_b.id, tok.id)
    {raw, tok}
  end

  # The legitimate operator the D207 lockout hit: an owner/admin OF THE TARGET
  # workspace with NO flat/global admin grant and NO Default-workspace role at
  # all. Inserted raw (not via `create_token/5`) so no Default membership is
  # auto-bound, and WITHOUT the "admin" permission string — the old flat gate
  # rejected exactly this principal.
  defp legit_target_admin_token!(ws_b) do
    raw = "tgt-legit-#{System.unique_integer([:positive])}"

    {:ok, tok} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "tgt legit ws-b admin",
        dataset: @dataset,
        permissions: ["read", "write"]
      })
      |> Repo.insert()

    {:ok, _} = TenancyAuth.create_membership(ws_b.id, tok.id, "admin")
    {raw, tok}
  end

  defp user_session!(conn, memberships) do
    email = "tgt-user-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    Enum.each(memberships, fn {ws, role} ->
      {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, role, "user")
    end)

    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  defp as_token(conn, raw), do: Plug.Test.init_test_session(conn, %{"api_token" => raw})

  # ── (a) token outsider: rejected at mount ─────────────────────────────────

  describe "token outsider — flat global admin, member-only of the target" do
    test "is REJECTED at mount of ConnectorsLive", %{
      conn: conn,
      ws_b: ws_b,
      default_ws: default_ws,
      connectors_path: path
    } do
      {raw, tok} = token_outsider!(ws_b)

      # The escalation shape is real: global admin perm + Default-admin role,
      # but NOT a workspace admin of the target.
      assert Auth.has_permission?(tok, "admin")
      assert TenancyAuth.workspace_admin?(tok, default_ws.id)
      refute TenancyAuth.workspace_admin?(tok, ws_b.id)

      assert {:error, {:redirect, %{to: "/studio"}}} = live(as_token(conn, raw), path)
    end

    test "is REJECTED at mount of SettingsLive — and writes nothing", %{
      conn: conn,
      ws_b: ws_b,
      settings_path: path
    } do
      {raw, _tok} = token_outsider!(ws_b)

      assert {:error, {:redirect, %{to: "/studio"}}} = live(as_token(conn, raw), path)

      # No view existed, so B's settings are untouched.
      assert Tenancy.workspace_chat_settings(Tenancy.get_workspace_by_id(ws_b.id)) == %{}
    end

    test "a NON-member with the flat global admin perm is also rejected (never falls back to the flat gate)",
         %{conn: conn, ws_b: ws_b, connectors_path: path} do
      raw = "tgt-nonmember-#{System.unique_integer([:positive])}"
      {:ok, tok} = Auth.create_token(raw, "tgt nonmember", @dataset, ["read", "write", "admin"])
      refute TenancyAuth.member?(tok, ws_b.id)

      assert {:error, {:redirect, %{to: "/studio"}}} = live(as_token(conn, raw), path)
    end
  end

  # ── (b) user-session outsider: rejected at mount ──────────────────────────

  describe "user-session outsider — Default-workspace admin, member-only of the target" do
    test "is REJECTED at mount of ConnectorsLive and SettingsLive", %{
      conn: conn,
      default_ws: default_ws,
      ws_b: ws_b,
      connectors_path: connectors_path,
      settings_path: settings_path
    } do
      {user, conn} = user_session!(conn, [{default_ws, "admin"}, {ws_b, "member"}])

      # The old user arm authorized THIS grant (Default admin) for EVERY
      # scoped URL — the mount hole. The target role is member-only.
      assert TenancyAuth.workspace_admin?(user, default_ws.id)
      refute TenancyAuth.workspace_admin?(user, ws_b.id)

      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, connectors_path)
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, settings_path)
    end
  end

  # ── (c) legit target-workspace admins still mount (D207 lockout fixed) ────

  describe "legit target-workspace admin — no Default/global admin grant" do
    test "a ws-B admin TOKEN without the flat admin permission MOUNTS both surfaces", %{
      conn: conn,
      ws_b: ws_b,
      connectors_path: connectors_path,
      settings_path: settings_path
    } do
      {raw, tok} = legit_target_admin_token!(ws_b)

      # No flat/global admin grant — the OLD gate rejected this operator.
      refute Auth.has_permission?(tok, "admin")
      assert TenancyAuth.workspace_admin?(tok, ws_b.id)

      assert {:ok, _view, html} = live(as_token(conn, raw), connectors_path)
      assert html =~ ~s(data-test-id="connector-card-telegram")

      assert {:ok, _view, html} = live(as_token(conn, raw), settings_path)
      assert html =~ "Workspace Settings"
    end

    test "a ws-B admin USER with no Default membership MOUNTS both surfaces", %{
      conn: conn,
      ws_b: ws_b,
      connectors_path: connectors_path,
      settings_path: settings_path
    } do
      {user, conn} = user_session!(conn, [{ws_b, "admin"}])

      refute TenancyAuth.member?(user, Tenancy.get_default_workspace().id)
      assert TenancyAuth.workspace_admin?(user, ws_b.id)

      assert {:ok, _view, html} = live(conn, connectors_path)
      assert html =~ ~s(data-test-id="connector-card-telegram")

      assert {:ok, _view, html} = live(conn, settings_path)
      assert html =~ "Workspace Settings"
    end
  end

  # ── (d) the flat surfaces are byte-identical (still on :admin) ────────────

  describe "flat /studio admin surfaces — unchanged" do
    test "a flat-global-admin token still mounts /studio/org-admin", %{conn: conn, ws_b: ws_b} do
      {raw, _tok} = token_outsider!(ws_b)
      assert {:ok, _view, _html} = live(as_token(conn, raw), "/studio/org-admin")
    end

    test "a token without the flat admin permission is still bounced off /studio/org-admin",
         %{conn: conn, ws_b: ws_b} do
      {raw, _tok} = legit_target_admin_token!(ws_b)

      assert {:error, {:redirect, %{to: "/studio"}}} =
               live(as_token(conn, raw), "/studio/org-admin")
    end

    test "flat /studio/settings still 302s to the session-resolved scoped canonical", %{
      conn: conn,
      ws_b: ws_b
    } do
      # The legit token's ONLY membership is ws B → deterministic resolution.
      {raw, _tok} = legit_target_admin_token!(ws_b)

      conn = as_token(conn, raw) |> get("/studio/settings")

      assert redirected_to(conn, 302) == "/w/#{ws_b.slug}/p/default/studio/settings"
    end
  end
end
