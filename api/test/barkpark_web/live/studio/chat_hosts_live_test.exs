defmodule BarkparkWeb.Studio.ChatHostsLiveTest do
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.RegisteredHost
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @live_view "lib/barkpark_web/live/studio/chat_hosts_live.ex"

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

    # A workspace ADMIN — not the owner. Same global permissions as the owner
    # token above, so the only thing separating them is the membership ROLE.
    # It MOUNTS (the :scoped_admin gate admits owner AND admin) and is the
    # principal that makes the enroll/revoke split observable.
    ws_admin_raw = "chat-host-wsadmin-#{suffix}"

    {:ok, ws_admin} =
      Auth.create_token(ws_admin_raw, "wsadmin", "production", ["read", "write", "admin"])

    {:ok, _membership} = TenancyAuth.create_membership(workspace.id, ws_admin.id, "admin")

    {:ok,
     conn: conn,
     workspace: workspace,
     path: "/w/#{workspace.slug}/p/default/studio/chat-hosts",
     admin_raw: admin_raw,
     outsider_raw: outsider_raw,
     ws_admin_raw: ws_admin_raw,
     ws_admin: ws_admin}
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

  test "a workspace ADMIN mounts and may REVOKE, but the enroll seat is OWNER-only", %{
    conn: conn,
    workspace: workspace,
    path: path,
    ws_admin_raw: raw,
    ws_admin: ws_admin
  } do
    # The seat split, stated on the principal that can see it: this token is a
    # workspace admin but not the owner, so it passes the mount gate and the
    # :revoke arm and is refused by the :enroll arm alone.
    assert TenancyAuth.workspace_admin?(ws_admin, workspace.id)
    refute TenancyAuth.workspace_owner?(ws_admin, workspace.id)

    {:ok, seeded} =
      ChatHosts.issue_enrollment(workspace.id, %{
        name: "existing",
        approved_roots: [System.tmp_dir!()]
      })

    {:ok, view, _html} = live(as(conn, raw), path)

    html =
      view
      |> form("form[phx-submit=enroll]", %{
        "host" => %{"name" => "laptop", "approved_roots" => [System.tmp_dir!()]}
      })
      |> render_submit()

    # DENIED: the flash, and — the load-bearing half — nothing was enrolled.
    assert html =~ "Only the workspace owner can enroll a trusted machine"
    refute html =~ "One-time enrollment token"
    assert [%{id: only_id}] = ChatHosts.list_hosts(workspace.id)
    assert only_id == seeded.host.id

    # ALLOWED: the same principal revokes, so the denial above is the SEAT and
    # not a mount failure or a dead form. `list_hosts/1` filters revoked hosts
    # out, so the revocation shows as the seeded host LEAVING the listing.
    render_click(view, "revoke", %{"id" => seeded.host.id})
    assert ChatHosts.list_hosts(workspace.id) == []
    assert %DateTime{} = Barkpark.Repo.get!(RegisteredHost, seeded.host.id).revoked_at
  end

  test "the enroll seat is asked at the Tenancy.Auth chokepoint, never spelled as a role literal" do
    source = File.read!(@live_view)
    code = code_only(source)

    # NEGATIVE leg — the literal seat rule is gone and must not come back.
    refute code =~ ~r/membership_role\([^)]*\)\s*==\s*"owner"/,
           """
           #{@live_view} spells the owner seat as a literal
           `membership_role(...) == "owner"` again. That is the defect
           arpss-w10-bl-chat-hosts-owner-literal-seat-fork removed: the same
           rule then exists here AND in BarkparkWeb.ChatHostController with
           nothing tying them together — and the :revoke arm one line below
           already calls a named predicate, so the fork is visible side by side
           with the canonical. Call Barkpark.Tenancy.Auth.workspace_owner?/2.
           """

    # POSITIVE leg — the guard is not vacuous: the named predicate IS called.
    assert source =~ "TenancyAuth.workspace_owner?(principal, workspace.id)",
           "#{@live_view} must gate the :enroll arm on Tenancy.Auth.workspace_owner?/2"
  end

  # The rationale comments AT the fixed sites name the old literal on purpose —
  # so a whole-file refute would red on the fix's own prose, the classic
  # self-refuting guard. Match CODE only: drop full-line `#` comments (Elixir
  # has no block comments) before looking for the literal. A comment can never
  # authorize anyone, so nothing enforceable is lost.
  defp code_only(source) do
    source
    |> String.split("\n")
    |> Enum.reject(fn line -> String.starts_with?(String.trim_leading(line), "#") end)
    |> Enum.join("\n")
  end

  defp as(conn, raw), do: init_test_session(conn, %{"api_token" => raw})
end
