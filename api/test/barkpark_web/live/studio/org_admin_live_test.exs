defmodule BarkparkWeb.Studio.OrgAdminLiveTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Tenancy

  @admin_token "org-admin-test-token"
  @junior_token "org-junior-test-token"

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(@admin_token, "test admin", "production", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@junior_token, "test junior", "production", ["read"])
    {:ok, conn: conn}
  end

  describe "admin gate" do
    test "redirects to /studio when no session token", %{conn: conn} do
      conn = init_test_session(conn, %{})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/studio/org-admin")
    end

    test "redirects to /studio when token lacks admin permission", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @junior_token})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/studio/org-admin")
    end
  end

  describe "renders for an admin" do
    test "shows the shell, organizations, and the wave mount points", %{conn: conn} do
      {:ok, org} = Tenancy.create_organization(%{slug: "shellco", name: "Shell Co"})
      {:ok, ws} = Tenancy.create_workspace(%{slug: "shell-ws", name: "Shell WS"})
      {:ok, _} = Tenancy.assign_workspace_to_organization(ws, org.id)

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, "/studio/org-admin")

      assert html =~ "Organization Admin"
      assert html =~ "Shell Co"
      assert html =~ "Shell WS"
      # the four labelled mount points for later waves
      assert html =~ "Single Sign-On"
      assert html =~ "Directory Sync"
      assert html =~ "Members &amp; Roles"
      assert html =~ "Audit Log"
    end
  end
end
