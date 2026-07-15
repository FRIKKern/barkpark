defmodule BarkparkWeb.Studio.ChatHostsLiveTest do
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  setup %{conn: conn} do
    ensure_default_scope!()
    suffix = System.unique_integer([:positive])
    {:ok, workspace} = Tenancy.create_workspace(%{slug: "chat-host-ui-#{suffix}", name: "Hosts"})
    {:ok, _project} = Tenancy.create_project(workspace, %{slug: "default", name: "Default"})

    admin_raw = "chat-host-admin-#{suffix}"
    {:ok, admin} = Auth.create_token(admin_raw, "admin", "production", ["read", "write", "admin"])
    {:ok, _membership} = TenancyAuth.create_membership(workspace.id, admin.id, "owner")

    outsider_raw = "chat-host-outsider-#{suffix}"

    {:ok, outsider} =
      Auth.create_token(outsider_raw, "outsider", "production", ["read", "write", "admin"])

    {:ok, _membership} = TenancyAuth.create_membership(workspace.id, outsider.id)

    {:ok,
     conn: conn,
     workspace: workspace,
     path: "/w/#{workspace.slug}/p/default/studio/chat-hosts",
     admin_raw: admin_raw,
     outsider_raw: outsider_raw}
  end

  test "workspace owner can issue an enrollment", %{
    conn: conn,
    workspace: workspace,
    path: path,
    admin_raw: raw
  } do
    {:ok, view, _html} = live(as(conn, raw), path)

    html =
      view
      |> form("form[phx-submit=enroll]", %{
        "host" => %{"name" => "laptop", "approved_roots" => [System.tmp_dir!()]}
      })
      |> render_submit()

    assert html =~ "One-time enrollment token"
    assert [%{name: "laptop"}] = ChatHosts.list_hosts(workspace.id)
  end

  test "global admin without workspace-admin membership cannot enroll or revoke", %{
    conn: conn,
    workspace: workspace,
    path: path,
    outsider_raw: raw
  } do
    {:ok, issued} =
      ChatHosts.issue_enrollment(workspace.id, %{
        name: "existing",
        approved_roots: [System.tmp_dir!()]
      })

    {:ok, view, _html} = live(as(conn, raw), path)

    html =
      view
      |> form("form[phx-submit=enroll]", %{
        "host" => %{"name" => "forged", "approved_roots" => ["/"]}
      })
      |> render_submit()

    assert html =~ "Only the workspace owner"
    assert [host] = ChatHosts.list_hosts(workspace.id)
    assert host.id == issued.host.id

    html = render_click(view, "revoke", %{"id" => host.id})
    assert html =~ "Only the workspace owner"
    assert [%{id: id}] = ChatHosts.list_hosts(workspace.id)
    assert id == host.id
  end

  defp as(conn, raw), do: init_test_session(conn, %{"api_token" => raw})
end
