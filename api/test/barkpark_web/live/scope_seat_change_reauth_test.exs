defmodule BarkparkWeb.Live.ScopeSeatChangeReauthTest do
  @moduledoc """
  Realtime authz sweep (r4a): removing a member did not reach an open Studio.

  `LiveScope` admits a socket at mount and on a scope-changing patch only.
  A member removed from the workspace (roster UI, members API, SCIM) kept an
  open Studio tab reading — panes, navigation, live pushes — until the browser
  reconnected; read-tier events never re-check the seat. Seat changes now
  publish on the workspace's seats topic and every open socket in that
  workspace re-runs its admission.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Tenancy}
  alias Barkpark.Tenancy.Members

  setup %{conn: conn} do
    ws = create_workspace!("seat-change-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    {:ok, _} = Tenancy.get_or_create_dataset(proj, "production")
    {:ok, conn: conn, ws: ws, path: "/w/#{ws.slug}/p/default/d/production/studio"}
  end

  defp user_conn!(conn, ws) do
    email = "seat-change-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  test "removing a USER member closes their open Studio socket", ctx do
    {user, conn} = user_conn!(ctx.conn, ctx.ws)
    # A second member keeps the workspace from losing its last seat-holder.
    {_other, _} = user_conn!(ctx.conn, ctx.ws)
    {:ok, view, _} = live(conn, ctx.path)

    {:ok, _} = Members.remove_member(ctx.ws.id, %{type: :user, id: user.id})

    assert_redirect(view, "/login", 2_000)
  end

  test "removing a TOKEN member closes its open Studio socket", ctx do
    raw = "seat-change-tok-" <> Ecto.UUID.generate()
    {:ok, tok} = Auth.create_token(raw, "seat-change", "production", ["read", "write"], ctx.ws.id)
    conn = Plug.Test.init_test_session(ctx.conn, %{"api_token" => raw})
    {:ok, view, _} = live(conn, ctx.path)

    {:ok, _} = Members.remove_member(ctx.ws.id, %{type: :api_token, id: tok.id})

    assert_redirect(view, "/login", 2_000)
  end

  test "another member's removal leaves a still-seated member's socket up (control)", ctx do
    {_user, conn} = user_conn!(ctx.conn, ctx.ws)
    {other, _} = user_conn!(ctx.conn, ctx.ws)
    {:ok, view, _} = live(conn, ctx.path)

    {:ok, _} = Members.remove_member(ctx.ws.id, %{type: :user, id: other.id})

    _ = :sys.get_state(view.pid)
    assert Process.alive?(view.pid)
    assert render(view) =~ "studio"
  end
end
