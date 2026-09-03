defmodule BarkparkWeb.LiveAuthCustomRoleAdminTest do
  @moduledoc """
  `arpss-w10-bl-workspace-admin-denies-custom-role-admin` — the SURFACE half.

  `BarkparkWeb.LiveAuth`'s `:scoped_admin` mount gate bars on
  `Barkpark.Tenancy.Auth.workspace_admin?/2` (both the session-token arm and
  the user arm). While that predicate was a role-NAME check against
  `@admin_roles`, a member holding a workspace CUSTOM role that carries the
  `admin` action — admitted by `authorize/3` — was redirected off every scoped
  admin LiveView. This file mounts the real LiveViews and proves the lockout is
  gone WITHOUT touching `live_auth.ex`: the fix flows entirely through the
  predicate.

  It also re-proves, at the mount, the denial charter D9 ratifies: a
  global-admin token that is only a plain `member` of the target workspace is
  still bounced.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.{Role, RolePermission}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"
  @password "correct-horse-battery"

  setup %{conn: conn} do
    {default_ws, _default_proj} = ensure_default_scope!()

    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "cra-live-#{suffix}", name: "Custom Role WS"})
    {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

    {:ok,
     conn: conn,
     default_ws: default_ws,
     ws: ws,
     connectors_path: "/w/#{ws.slug}/p/default/studio/connectors",
     settings_path: "/w/#{ws.slug}/p/default/studio/settings"}
  end

  defp custom_role(ws_id, name, actions) do
    {:ok, role} = Repo.insert(Role.changeset(%Role{}, %{name: name, workspace_id: ws_id}))

    Enum.each(actions, fn a ->
      {:ok, _} =
        Repo.insert(RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: a}))
    end)

    role
  end

  defp user_with_role!(ws, role) do
    email = "cra-live-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, role, "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, raw}
  end

  defp as_user(conn, raw), do: Plug.Test.init_test_session(conn, %{"user_session" => raw})
  defp as_token(conn, raw), do: Plug.Test.init_test_session(conn, %{"api_token" => raw})

  describe "a custom-role admin MOUNTS the scoped-admin surfaces" do
    test "USER arm — 'content-lead' carrying the admin action mounts Connectors and Settings",
         %{conn: conn, ws: ws, connectors_path: connectors_path, settings_path: settings_path} do
      custom_role(ws.id, "content-lead", ["read", "write", "admin"])
      {user, raw} = user_with_role!(ws, "content-lead")

      # The shape: not a built-in admin by NAME, but an admin by ACTION.
      assert TenancyAuth.membership_role(user, ws.id) == "content-lead"
      assert TenancyAuth.authorize(user, ws.id, :admin) == :ok
      assert TenancyAuth.workspace_admin?(user, ws.id)

      assert {:ok, _view, html} = live(as_user(conn, raw), connectors_path)
      assert html =~ ~s(data-test-id="connector-card-telegram")

      assert {:ok, _view, html} = live(as_user(conn, raw), settings_path)
      assert html =~ "Workspace Settings"
    end

    test "TOKEN arm — a session token whose membership row carries the custom role mounts",
         %{conn: conn, ws: ws, connectors_path: connectors_path} do
      custom_role(ws.id, "content-lead", ["read", "write", "admin"])

      raw = "cra-live-tok-#{System.unique_integer([:positive])}"

      {:ok, tok} =
        %ApiToken{}
        |> ApiToken.changeset(%{
          token_hash: ApiToken.hash_token(raw),
          label: "custom role session token",
          dataset: @dataset,
          permissions: ["read", "write"]
        })
        |> Repo.insert()

      {:ok, _} = TenancyAuth.create_membership(ws.id, tok.id, "content-lead", "api_token")

      # No flat/global admin permission anywhere — the ONLY authority is the
      # workspace custom role's admin action.
      refute Barkpark.Auth.has_permission?(tok, "admin")

      assert {:ok, _view, html} = live(as_token(conn, raw), connectors_path)
      assert html =~ ~s(data-test-id="connector-card-telegram")
    end
  end

  describe "the denials the mount gate keeps" do
    test "a custom role WITHOUT the admin action is still bounced", %{
      conn: conn,
      ws: ws,
      connectors_path: path
    } do
      custom_role(ws.id, "editor", ["read", "write"])
      {user, raw} = user_with_role!(ws, "editor")

      assert TenancyAuth.authorize(user, ws.id, :write) == :ok
      refute TenancyAuth.workspace_admin?(user, ws.id)

      assert {:error, {:redirect, %{to: "/studio"}}} = live(as_user(conn, raw), path)
    end

    test "charter D9 — a global-admin TOKEN that is a plain member of the target is bounced", %{
      conn: conn,
      ws: ws,
      connectors_path: path
    } do
      raw = "cra-live-global-#{System.unique_integer([:positive])}"

      {:ok, tok} =
        Barkpark.Auth.create_token(raw, "cra live global", @dataset, ["read", "write", "admin"])

      {:ok, _} = TenancyAuth.create_membership(ws.id, tok.id)

      assert Barkpark.Auth.has_permission?(tok, "admin")
      refute TenancyAuth.workspace_admin?(tok, ws.id)

      assert {:error, {:redirect, %{to: "/studio"}}} = live(as_token(conn, raw), path)
    end

    test "shadowing — a workspace row NAMED 'member' carrying admin does not open the mount", %{
      conn: conn,
      ws: ws,
      connectors_path: path
    } do
      custom_role(ws.id, "member", ["read", "write", "admin"])
      {user, raw} = user_with_role!(ws, "member")

      refute TenancyAuth.workspace_admin?(user, ws.id)

      assert {:error, {:redirect, %{to: "/studio"}}} = live(as_user(conn, raw), path)
    end
  end
end
