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

  alias Barkpark.Auth

  @admin_token "wi5-auth-admin-token"
  @ops_token "wi5-auth-ops-token"
  @reader_token "wi5-auth-reader-token"

  setup %{conn: conn} do
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

  describe "/studio/settings — :admin on_mount hook (regression guard)" do
    test "ops alone is NOT enough for the admin-gated settings LV", %{conn: conn} do
      # Critical invariant: the WI5 `ops` role is *additive* and must not
      # leak into the admin gate. Settings exposes plugin-secret reveal
      # — operators must never reach it.
      conn = init_test_session(conn, %{"api_token" => @ops_token})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/studio/settings")
    end

    test "admin still grants /studio/settings", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      assert {:ok, _view, _html} = live(conn, "/studio/settings")
    end
  end
end
