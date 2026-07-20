defmodule BarkparkWeb.LiveAuthTest do
  @moduledoc """
  Phase 8 WI5 — coverage for the dedicated `:ops` role.

  The Phase 7 WI6 admin LV was protected by the `:admin` `on_mount`
  hook, so non-admin operators could not reach the publish console.
  WI5 introduces an `:ops` permission that grants `/admin/onixedit/bokbasen`
  access without exposing the full admin surface (settings reveal,
  schema CRUD). Backwards-compat: existing `admin` tokens still pass.

  The Bokbasen LV moved from the host namespace (`/admin/bokbasen`) into
  the OnixEdit plugin namespace (`/admin/onixedit/bokbasen`, Goal G3.s4);
  the legacy path is now an auth-blind 301 redirect (LegacyRedirectController),
  so the `:ops` on_mount gate is asserted against the real LV path.

  Drives the gate through the real router (no direct on_mount call) so
  the assertions also pin the `live_session :admin_ops` wiring.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth

  @admin_token "wi5-auth-admin-token"
  @ops_token "wi5-auth-ops-token"
  @reader_token "wi5-auth-reader-token"

  # SettingsLive moved to `/w/:ws/p/:proj/studio/settings` (sdl-w1-admin-canonical).
  @settings_path "/w/default/p/default/studio/settings"

  setup %{conn: conn} do
    # Default must exist before the admin token is minted so `Auth.create_token`
    # auto-binds it as a Default member (the scoped route's LiveScope gate).
    ensure_default_scope!()

    {:ok, _} =
      Auth.create_token(@admin_token, "wi5 admin", "production", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@ops_token, "wi5 ops", "production", ["read", "ops"])
    {:ok, _} = Auth.create_token(@reader_token, "wi5 reader", "production", ["read"])

    {:ok, conn: conn}
  end

  describe "/admin/onixedit/bokbasen — :ops on_mount hook" do
    test "grants access to a token with the ops permission", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @ops_token})
      assert {:ok, _view, html} = live(conn, "/admin/onixedit/bokbasen")
      assert html =~ "Bokbasen Submissions"
    end

    test "grants access to an admin token (backwards-compat)", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      assert {:ok, _view, html} = live(conn, "/admin/onixedit/bokbasen")
      assert html =~ "Bokbasen Submissions"
    end

    test "redirects a token without ops or admin", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @reader_token})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/admin/onixedit/bokbasen")
    end

    test "redirects when no session token is present", %{conn: conn} do
      conn = init_test_session(conn, %{})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/admin/onixedit/bokbasen")
    end

    test "redirects when the session token is unknown to the DB", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => "no-such-token-anywhere"})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/admin/onixedit/bokbasen")
    end
  end

  describe "scoped /studio/settings — :admin on_mount hook (regression guard)" do
    test "ops alone is NOT enough for the admin-gated settings LV", %{conn: conn} do
      # Critical invariant: the WI5 `ops` role is *additive* and must not
      # leak into the admin gate. Settings exposes plugin-secret reveal
      # — operators must never reach it. LiveAuth.:admin (first in the scoped
      # on_mount chain) redirects to /studio before LiveScope runs.
      conn = init_test_session(conn, %{"api_token" => @ops_token})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, @settings_path)
    end

    test "admin still grants the scoped settings surface", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      assert {:ok, _view, _html} = live(conn, @settings_path)
    end
  end

  describe "chat deep-link return_to (charter D69 — the email-notification promise)" do
    test "an anonymous hit on /studio/chat/:id redirects to /login with the path preserved",
         %{conn: conn} do
      conn = init_test_session(conn, %{})
      sid = Ecto.UUID.generate()

      assert {:error, {:redirect, %{to: to}}} = live(conn, "/studio/chat/#{sid}")
      assert to =~ "/login?return_to="

      %URI{path: "/login", query: query} = URI.parse(to)
      assert URI.decode_query(query)["return_to"] == "/studio/chat/#{sid}"
    end

    test "the original query string survives into the return_to", %{conn: conn} do
      conn = init_test_session(conn, %{})
      sid = Ecto.UUID.generate()

      assert {:error, {:redirect, %{to: to}}} = live(conn, "/studio/chat/#{sid}?panel=diff")

      assert URI.decode_query(URI.parse(to).query)["return_to"] ==
               "/studio/chat/#{sid}?panel=diff"
    end

    test "signing in with the return_to lands back on the exact session", %{conn: conn} do
      sid = Ecto.UUID.generate()

      conn =
        post(conn, "/login", %{"token" => @admin_token, "return_to" => "/studio/chat/#{sid}"})

      assert redirected_to(conn) == "/studio/chat/#{sid}"
    end

    test "the bare /studio/chat new-chat landing keeps the /studio funnel", %{conn: conn} do
      conn = init_test_session(conn, %{})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/studio/chat")
    end

    test "an authenticated-but-insufficient token keeps the /studio funnel (no login loop)",
         %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @reader_token})
      sid = Ecto.UUID.generate()

      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/studio/chat/#{sid}")
    end
  end
end
