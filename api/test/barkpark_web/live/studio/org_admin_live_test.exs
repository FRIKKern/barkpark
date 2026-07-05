defmodule BarkparkWeb.Studio.OrgAdminLiveTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Audit, Auth, Repo, Tenancy}
  alias Barkpark.Sso.Oidc
  alias Barkpark.Scim.Token
  import Ecto.Query

  @admin_token "org-admin-test-token"
  @junior_token "org-junior-test-token"

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(@admin_token, "test admin", "production", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@junior_token, "test junior", "production", ["read"])
    {:ok, conn: conn}
  end

  defp org_with_ws(slug) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug <> "-ws", name: "WS"})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {org, ws}
  end

  defp admin_conn(conn), do: init_test_session(conn, %{"api_token" => @admin_token})

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

  describe "the portal renders per-org config" do
    test "shows the org, its SSO status, member count, and SCIM tokens", %{conn: conn} do
      org_with_ws("shellco")

      {:ok, _view, html} = live(admin_conn(conn), "/studio/org-admin")

      assert html =~ "Organization Admin"
      assert html =~ "shellco"
      # no SSO configured yet
      assert html =~ ~s(data-oidc="false")
      assert html =~ ~s(data-saml="false")
      assert html =~ "SCIM tokens:"
    end

    test "reflects a configured OIDC connection", %{conn: conn} do
      {org, _ws} = org_with_ws("ssoco")

      {:ok, _} =
        Oidc.create_connection(%{
          organization_id: org.id,
          issuer: "https://idp",
          client_id: "c",
          client_secret: "s",
          authorization_endpoint: "https://idp/a",
          token_endpoint: "https://idp/t",
          jwks_uri: "https://idp/j"
        })

      {:ok, _view, html} = live(admin_conn(conn), "/studio/org-admin")
      assert html =~ ~s(data-oidc="true")
    end
  end

  describe "self-serve SCIM token minting" do
    test "clicking Mint SCIM token creates a token and shows the plaintext once", %{conn: conn} do
      {org, _ws} = org_with_ws("mintco")

      {:ok, view, _html} = live(admin_conn(conn), "/studio/org-admin")

      before = Repo.aggregate(from(t in Token, where: t.organization_id == ^org.id), :count)
      assert before == 0

      html = view |> element(~s([data-mint-scim="mintco"])) |> render_click()

      # the plaintext token is shown once, and a token now exists
      assert html =~ "shown again"
      assert html =~ "scim_"
      assert Repo.aggregate(from(t in Token, where: t.organization_id == ^org.id), :count) == 1
    end
  end

  describe "audit activity" do
    test "recent audit events are listed", %{conn: conn} do
      org_with_ws("auditco")
      {:ok, _} = Audit.emit(%{category: "auth", action: "sso_login", actor_id: "u1"})

      {:ok, _view, html} = live(admin_conn(conn), "/studio/org-admin")
      assert html =~ "Recent activity"
      assert html =~ "sso_login"
    end
  end
end
