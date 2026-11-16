defmodule BarkparkWeb.Studio.OrgAdminLiveAuditScopeTest do
  # task-fa907a54028f501c: the org-admin page listed the last 20 audit events
  # of the whole instance to any admin while the operator allowlist is unset.
  # It now lists only rows of workspaces the viewer administers; a listed
  # instance operator still sees every row. Who may open the page is unchanged.
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Audit, Auth, Tenancy}

  setup do
    prev =
      {Application.get_env(:barkpark, :operator_emails),
       Application.get_env(:barkpark, :operator_token_ids)}

    on_exit(fn ->
      {emails, ids} = prev
      restore(:operator_emails, emails)
      restore(:operator_token_ids, ids)
    end)

    Application.put_env(:barkpark, :operator_emails, [])
    Application.put_env(:barkpark, :operator_token_ids, [])

    n = System.unique_integer([:positive])
    {:ok, ws_a} = Tenancy.create_workspace(%{slug: "scope-a-#{n}", name: "A"})
    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "scope-b-#{n}", name: "B"})

    raw = "org-admin-scope-#{n}"

    {:ok, token} =
      Auth.create_token(raw, "admin of A", "production", ~w(read write admin), ws_a.id)

    emit("zz_scope.in_a", ws_a.id)
    emit("zz_scope.in_b", ws_b.id)
    emit("zz_scope.no_workspace", nil)

    %{raw: raw, token: token, ws_a: ws_a}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp emit(action, ws_id) do
    {:ok, _} =
      Audit.emit(%{
        category: "access",
        action: action,
        actor_id: "zz-actor",
        workspace_id: ws_id,
        metadata: %{"label" => "secret-label-zz"}
      })
  end

  defp open(conn, raw),
    do: live(init_test_session(conn, %{"api_token" => raw}), "/studio/org-admin")

  test "an admin of workspace A sees no audit event of workspace B or of no workspace on org-admin",
       %{conn: conn, raw: raw} do
    {:ok, _view, html} = open(conn, raw)

    refute html =~ "zz_scope.in_b"
    refute html =~ "zz_scope.no_workspace"
    refute html =~ "secret-label-zz"
  end

  test "the admin still sees A's own events, by token and by user session", %{
    conn: conn,
    raw: raw,
    ws_a: ws_a
  } do
    {:ok, _view, html} = open(conn, raw)
    assert html =~ "zz_scope.in_a"

    {:ok, user} =
      Barkpark.Accounts.register_user(%{
        email: "org-admin-scope-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, _} = Tenancy.Auth.create_membership(ws_a.id, user.id, "owner", "user")

    {:ok, _} =
      Tenancy.Auth.create_membership(Tenancy.get_default_workspace().id, user.id, "admin", "user")

    {:ok, session} = Barkpark.Accounts.create_user_session_token(user)

    {:ok, _view, html} =
      live(init_test_session(conn, %{"user_session" => session}), "/studio/org-admin")

    assert html =~ "zz_scope.in_a"
    refute html =~ "zz_scope.in_b"
    refute html =~ "zz_scope.no_workspace"
  end

  test "the page mounts for the same people with the allowlist unset and set", %{
    conn: conn,
    raw: raw,
    token: token
  } do
    # Unset: a seated admin and a flat admin token with no seat both mount.
    assert {:ok, _view, _html} = open(conn, raw)

    flat = "org-admin-scope-flat-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(flat, "flat admin", "production", ~w(read write admin))
    assert {:ok, _view, html} = open(conn, flat)
    refute html =~ "zz_scope."

    # Set and naming this token: it mounts, and as the listed operator it
    # still sees every row, including rows with no workspace.
    Application.put_env(:barkpark, :operator_token_ids, [token.id])
    assert {:ok, _view, html} = open(conn, raw)
    assert html =~ "zz_scope.in_b"
    assert html =~ "zz_scope.no_workspace"
    refute html =~ "secret-label-zz"

    # Set and not naming the flat token: refused, as before this change.
    assert {:error, {:redirect, %{to: "/studio"}}} = open(conn, flat)
  end
end
