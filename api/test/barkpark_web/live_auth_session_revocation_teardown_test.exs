defmodule BarkparkWeb.LiveAuthSessionRevocationTeardownTest do
  @moduledoc """
  task-807307d827255d7e: only API-token revocation reached an open LiveView.
  Revoking an ACCOUNT session (logout, "sign out everywhere", SAML single
  logout) broadcast nothing, so an open Studio tab mounted on that session kept
  reading and writing until it reconnected. The session revokers now broadcast
  on the session's topic and LiveAuth subscribes the socket to it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Tenancy}

  setup %{conn: conn} do
    ws = create_workspace!("lv-sess-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    {:ok, _} = Tenancy.get_or_create_dataset(proj, "production")

    email = "lv-sess-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")
    {:ok, raw} = Accounts.create_user_session_token(user)

    conn = Plug.Test.init_test_session(conn, %{"user_session" => raw})
    {:ok, conn: conn, ws: ws, user: user, raw: raw}
  end

  test "sign out everywhere closes an open Studio LiveView", ctx do
    {:ok, view, _} = live(ctx.conn, "/w/#{ctx.ws.slug}/p/default/d/production/studio")

    {:ok, 1} = Accounts.revoke_all_user_sessions(ctx.user)

    assert_redirect(view, "/login", 2_000)
  end

  test "logging this session out closes its open Studio LiveView", ctx do
    {:ok, view, _} = live(ctx.conn, "/w/#{ctx.ws.slug}/p/default/d/production/studio")

    {:ok, 1} = Accounts.revoke_user_session_token(ctx.raw)

    assert_redirect(view, "/login", 2_000)
  end

  test "CONTROL: revoking ANOTHER session of the same user leaves this tab up", ctx do
    {:ok, other} = Accounts.create_user_session_token(ctx.user)
    {:ok, view, _} = live(ctx.conn, "/w/#{ctx.ws.slug}/p/default/d/production/studio")

    {:ok, 1} = Accounts.revoke_user_session_token(other)

    assert render(view) =~ "studio"
    assert Process.alive?(view.pid)
  end
end
