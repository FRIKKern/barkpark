defmodule BarkparkWeb.LegacyRedirectControllerTest do
  @moduledoc """
  Back-compat 301 smoke tests for the legacy URLs that moved during the
  plugin-highway umbrella (G1–G4). Each legacy path must 301 to the new
  path with query strings preserved.
  """
  use BarkparkWeb.ConnCase, async: true

  describe "onixedit_book — legacy /studio/:dataset/onixedit/book/..." do
    test "GET /studio/:ds/onixedit/book/:id redirects to /studio/:ds/book/:id",
         %{conn: conn} do
      conn = get(conn, "/studio/production/onixedit/book/p1")
      assert redirected_to(conn, 301) == "/studio/production/book/p1"
    end

    test "GET /studio/:ds/onixedit/book/:id/view redirects to /studio/:ds/book/:id",
         %{conn: conn} do
      conn = get(conn, "/studio/production/onixedit/book/p1/view")
      assert redirected_to(conn, 301) == "/studio/production/book/p1"
    end

    test "preserves query string (e.g. ?tab=subjects)", %{conn: conn} do
      conn = get(conn, "/studio/production/onixedit/book/p1?tab=subjects")
      assert redirected_to(conn, 301) == "/studio/production/book/p1?tab=subjects"
    end

    test "works for non-production datasets", %{conn: conn} do
      conn = get(conn, "/studio/staging/onixedit/book/x9")
      assert redirected_to(conn, 301) == "/studio/staging/book/x9"
    end

    test "handles draft doc ids verbatim", %{conn: conn} do
      conn = get(conn, "/studio/production/onixedit/book/drafts.p1/view")
      assert redirected_to(conn, 301) == "/studio/production/book/drafts.p1"
    end
  end

  describe "bokbasen — legacy /admin/bokbasen → /admin/onixedit/bokbasen (G3.s4)" do
    test "GET /admin/bokbasen redirects 301", %{conn: conn} do
      conn = get(conn, "/admin/bokbasen")
      assert redirected_to(conn, 301) == "/admin/onixedit/bokbasen"
    end
  end
end
