defmodule BarkparkWeb.Studio.ChatHostsLiveTest do
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the studio_chat capability (ChatHosts enrollment under /studio chat hosts)
  @moduletag :requires_plugins

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

    # The command to run on the machine, the code on stdin (never in argv),
    # and a copy button: the code is shown here, once, to its owner.
    assert html =~ "| barkpark-chat-host enroll --url"
    assert html =~ "printf &#39;%s\\n&#39;"
    assert html =~ ~s(data-copied="Copied")
    refute html =~ "One-time enrollment token"
    assert [%{name: "laptop", enrolled: false}] = ChatHosts.list_hosts(workspace.id)
    assert html =~ "Waiting"
  end

  test "the code is not shown again after a reload; the page offers a new code instead", %{
    conn: conn,
    workspace: workspace,
    path: path,
    admin_raw: raw
  } do
    {:ok, %{enrollment_token: code}} =
      ChatHosts.issue_enrollment(workspace.id, %{name: "vm", approved_roots: [System.tmp_dir!()]})

    {:ok, _view, html} = live(as(conn, raw), path)

    refute html =~ code
    refute html =~ "| barkpark-chat-host enroll --url"
    assert html =~ "Waiting"
    assert html =~ "min left"
    assert html =~ "Make a new code"
  end

  test "Make a new code shows a fresh command and the old code is refused as replaced", %{
    conn: conn,
    workspace: workspace,
    path: path,
    admin_raw: raw
  } do
    {:ok, %{host: host, enrollment_token: old}} =
      ChatHosts.issue_enrollment(workspace.id, %{name: "vm", approved_roots: [System.tmp_dir!()]})

    {:ok, view, _html} = live(as(conn, raw), path)
    html = render_click(view, "new_code", %{"id" => host.id})

    assert html =~ "The old code no longer works"
    assert html =~ "| barkpark-chat-host enroll --url"
    refute html =~ old
    assert {:error, _} = ChatHosts.enroll(old, %{})
    assert Barkpark.ChatHosts.Enrollment.refusal(old) == :replaced
  end

  test "Revoke asks first, in the page, and only the confirm revokes", %{
    conn: conn,
    workspace: workspace,
    path: path,
    admin_raw: raw
  } do
    {:ok, %{host: host}} =
      ChatHosts.issue_enrollment(workspace.id, %{name: "vm", approved_roots: [System.tmp_dir!()]})

    {:ok, view, _html} = live(as(conn, raw), path)
    html = render_click(view, "ask_revoke", %{"id" => host.id})

    assert html =~ "Remove vm?"
    assert [%{id: id}] = ChatHosts.list_hosts(workspace.id)
    assert id == host.id

    html = render_click(view, "cancel_revoke", %{})
    refute html =~ "Remove vm?"
    assert [_] = ChatHosts.list_hosts(workspace.id)

    render_click(view, "ask_revoke", %{"id" => host.id})
    html = render_click(view, "revoke", %{})

    assert html =~ "Removed vm. Its code no longer works."
    assert ChatHosts.list_hosts(workspace.id) == []
  end

  test "Recently revoked lists each name once, and not a name that is registered again", %{
    conn: conn,
    workspace: workspace,
    path: path,
    admin_raw: raw
  } do
    enrolled_then_revoked = fn name ->
      {:ok, %{host: host, enrollment_token: code}} =
        ChatHosts.issue_enrollment(workspace.id, %{
          name: name,
          approved_roots: [System.tmp_dir!()]
        })

      {:ok, _} = ChatHosts.enroll(code)
      {:ok, _} = ChatHosts.revoke(workspace.id, host.id)
    end

    enrolled_then_revoked.("box")
    enrolled_then_revoked.("box")
    enrolled_then_revoked.("mac")

    {:ok, _} =
      ChatHosts.issue_enrollment(workspace.id, %{name: "mac", approved_roots: [System.tmp_dir!()]})

    {:ok, view, _html} = live(as(conn, raw), path)
    revoked = view |> element("#ch-revoked-title + ul") |> render()

    assert length(Regex.scan(~r/box · revoked/, revoked)) == 1
    refute revoked =~ "mac"
  end

  test "a non-owner is told to ask the owner, not to press a button it does not have", %{
    conn: conn,
    workspace: workspace,
    path: path,
    ws_admin_raw: raw
  } do
    {:ok, _} =
      ChatHosts.issue_enrollment(workspace.id, %{name: "vm", approved_roots: [System.tmp_dir!()]})

    {:ok, _view, html} = live(as(conn, raw), path)

    assert html =~ "ask the workspace owner for a new code"
    refute html =~ "Make a new code"
  end

  test "the command box survives the refresh (phx-update=ignore) and a new code is a new box", %{
    conn: conn,
    workspace: workspace,
    path: path,
    admin_raw: raw
  } do
    {:ok, %{host: host}} =
      ChatHosts.issue_enrollment(workspace.id, %{name: "vm", approved_roots: [System.tmp_dir!()]})

    {:ok, view, _html} = live(as(conn, raw), path)
    first = render_click(view, "new_code", %{"id" => host.id})

    [box_one] =
      Regex.run(~r/id="(chat-host-command-box-[^"]+)"[^>]*phx-update="ignore"/, first,
        capture: :all_but_first
      )

    send(view.pid, :refresh)
    assert render(view) =~ ~s(id="#{box_one}")

    [%{id: new_id}] = ChatHosts.list_hosts(workspace.id)
    second = render_click(view, "new_code", %{"id" => new_id})
    refute second =~ ~s(id="#{box_one}")
    assert second =~ "chat-host-command-box-"
  end

  test "an enrolled host reads as online or offline, with its providers in words", %{
    conn: conn,
    workspace: workspace,
    path: path,
    admin_raw: raw
  } do
    {:ok, %{host: host, enrollment_token: code}} =
      ChatHosts.issue_enrollment(workspace.id, %{name: "mac", approved_roots: [System.tmp_dir!()]})

    {:ok, _} = ChatHosts.enroll(code)
    seen = DateTime.add(DateTime.utc_now(), -3 * 3600)

    Barkpark.Repo.get!(RegisteredHost, host.id)
    |> Ecto.Changeset.change(
      last_seen_at: seen,
      capabilities: %{
        "providers" => %{
          "claude" => %{"installed" => true, "auth_ready" => true, "version" => "2.1.328"},
          "codex" => %{"installed" => true, "auth_ready" => false}
        }
      }
    )
    |> Barkpark.Repo.update!()

    {:ok, _view, html} = live(as(conn, raw), path)

    assert html =~ "Offline"
    assert html =~ "last seen 3 h ago"
    assert html =~ "signed in · 2.1.328"
    assert html =~ "installed, not signed in"
    refute html =~ "credential v"
    refute html =~ "auth true"
  end

  test "a second Create for a waiting machine's name says to make a new code for it", %{
    conn: conn,
    workspace: workspace,
    path: path,
    admin_raw: raw
  } do
    {:ok, _} =
      ChatHosts.issue_enrollment(workspace.id, %{name: "vm", approved_roots: [System.tmp_dir!()]})

    {:ok, view, _html} = live(as(conn, raw), path)

    html =
      view
      |> form("form[phx-submit=enroll]", %{
        "host" => %{"name" => "vm", "approved_roots" => [System.tmp_dir!()]}
      })
      |> render_submit()

    assert html =~ "A machine named vm is already waiting to enroll"
    refute html =~ "Could not create enrollment"
    assert [%{name: "vm"}] = ChatHosts.list_hosts(workspace.id)
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

    # The page shows an admin no register form, so the event is sent the way
    # a crafted client would: the seat check on the write is what refuses it.
    refute render(view) =~ ~s(phx-submit="enroll")

    html =
      render_submit(view, "enroll", %{
        "host" => %{"name" => "laptop", "approved_roots" => [System.tmp_dir!()]}
      })

    # DENIED: the flash, and — the load-bearing half — nothing was enrolled.
    assert html =~ "Only the workspace owner can enroll a trusted machine"
    refute html =~ "| barkpark-chat-host enroll --url"

    # Nor can it make a new code for the waiting host.
    html = render_click(view, "new_code", %{"id" => seeded.host.id})
    assert html =~ "Only the workspace owner can enroll a trusted machine"
    refute html =~ "| barkpark-chat-host enroll --url"
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
