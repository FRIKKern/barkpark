defmodule BarkparkWeb.Live.ScopeArchivedWorkspaceTest do
  @moduledoc """
  An archived workspace is frozen: ResolveWorkspace answers 409
  `workspace_archived` on every HTTP route. That plug runs only on the HTTP
  request, so a Studio socket that was open when the workspace was archived
  (or that reached it by push_navigate / reconnect) kept writing into it.
  `LiveScope` now refuses an archived workspace on every admission, and
  `Tenancy.archive_workspace/1` makes open sockets re-run admission
  (task-cce7b1940bca8241).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Tenancy}

  defp studio!(conn) do
    ws = create_workspace!("archived-live-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    {:ok, _} = Tenancy.get_or_create_dataset(proj, "production")

    email = "archived-live-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    conn = Plug.Test.init_test_session(conn, %{"user_session" => raw})

    {ws, conn, "/w/#{ws.slug}/p/default/d/production/studio"}
  end

  test "archiving a workspace closes an open Studio socket in it", %{conn: conn} do
    {ws, conn, path} = studio!(conn)
    {:ok, view, _} = live(conn, path)

    {:ok, _} = Tenancy.archive_workspace(ws)

    assert_redirect(view, "/studio", 2_000)
  end

  test "archiving ANOTHER workspace leaves the socket up (control)", %{conn: conn} do
    {_ws, conn, path} = studio!(conn)
    other = create_workspace!("archived-other-#{System.unique_integer([:positive])}")
    {:ok, view, _} = live(conn, path)

    {:ok, _} = Tenancy.archive_workspace(other)

    _ = :sys.get_state(view.pid)
    assert Process.alive?(view.pid)
  end
end
