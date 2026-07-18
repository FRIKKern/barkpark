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

  test "global admin without workspace-admin membership is REJECTED AT MOUNT (W26) — nothing enrolled, nothing revoked",
       %{
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

    # Pre-W26 this principal mounted (flat global admin perm) and the per-write
    # handlers refused it. The `:scoped_admin` mount gate now authorizes against
    # THIS workspace's membership role — a member-only outsider never mounts.
    assert {:error, {:redirect, %{to: "/studio"}}} = live(as(conn, raw), path)

    # The host list is byte-identical: nothing enrolled, nothing revoked.
    assert [host] = ChatHosts.list_hosts(workspace.id)
    assert host.id == issued.host.id
  end

  defp as(conn, raw), do: init_test_session(conn, %{"api_token" => raw})
end
