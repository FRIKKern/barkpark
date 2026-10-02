defmodule BarkparkWeb.LiveAuthRevocationTeardownTest do
  @moduledoc """
  Realtime authz sweep (r4a): an open LiveView ignored token revocation.

  `Auth.revoke_token/1` broadcasts "disconnect" on the token's
  `UserSocket.disconnect_topic/1`, which only the search WebSocket listened
  to. A Studio LiveView verified the bearer once at mount, so after a revoke
  the open socket kept reading (pane navigation, live document pushes) until
  the browser reconnected. LiveAuth now subscribes a connected socket to that
  topic and redirects it to /login on the broadcast.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Tenancy}

  setup %{conn: conn} do
    ws = create_workspace!("lv-revoke-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    {:ok, _} = Tenancy.get_or_create_dataset(proj, "production")
    {:ok, conn: conn, ws: ws}
  end

  defp token!(ws, perms, role) do
    raw = "lv-revoke-" <> Ecto.UUID.generate()
    {:ok, tok} = Auth.create_token(raw, "lv-revoke", "production", perms, ws.id)

    case Tenancy.Auth.membership(tok, ws.id) do
      nil -> {:ok, _} = Tenancy.Auth.create_membership(ws.id, tok.id, role)
      _ -> :ok
    end

    {raw, tok}
  end

  test "revoking the token closes an open Studio LiveView", %{conn: conn, ws: ws} do
    {raw, tok} = token!(ws, ["read", "write"], "member")
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, view, _} = live(conn, "/w/#{ws.slug}/p/default/d/production/studio")

    {:ok, _} = Auth.revoke_token(tok)

    assert_redirect(view, "/login", 2_000)
  end

  test "revoking the token closes an open scoped admin LiveView", %{conn: conn, ws: ws} do
    {raw, tok} = token!(ws, ["read", "write", "admin"], "admin")
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, view, _} = live(conn, "/w/#{ws.slug}/p/default/studio/settings")

    {:ok, _} = Auth.revoke_token(tok)

    assert_redirect(view, "/login", 2_000)
  end

  test "a live token's Studio socket stays up (control)", %{conn: conn, ws: ws} do
    {raw, _tok} = token!(ws, ["read", "write"], "member")
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, view, _} = live(conn, "/w/#{ws.slug}/p/default/d/production/studio")

    assert render(view) =~ "studio"
    assert Process.alive?(view.pid)
  end
end
