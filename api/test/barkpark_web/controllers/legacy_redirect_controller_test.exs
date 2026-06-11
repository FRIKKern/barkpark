defmodule BarkparkWeb.LegacyRedirectControllerTest do
  @moduledoc """
  Back-compat redirect smoke tests for the legacy URLs that moved during the
  plugin-highway umbrella (G1–G4). `bokbasen` stays a 301 to its static
  target; `onixedit_book` is a 302 (P3 cutover) single-hop to the SCOPED
  Studio editor — session-resolved, so never browser-cacheable. Query
  strings are preserved either way.
  """
  use BarkparkWeb.ConnCase, async: true

  describe "onixedit_book — legacy /studio/:dataset/onixedit/book/..." do
    test "GET /studio/:ds/onixedit/book/:id 302s single-hop to the scoped /studio/:ds/book/:id",
         %{conn: conn} do
      expected = scoped_studio("/d/production/studio/book/p1")
      conn = get(conn, "/studio/production/onixedit/book/p1")
      assert redirected_to(conn, 302) == expected
    end

    test "GET /studio/:ds/onixedit/book/:id/view 302s to the scoped /studio/:ds/book/:id",
         %{conn: conn} do
      expected = scoped_studio("/d/production/studio/book/p1")
      conn = get(conn, "/studio/production/onixedit/book/p1/view")
      assert redirected_to(conn, 302) == expected
    end

    test "preserves query string (e.g. ?tab=subjects)", %{conn: conn} do
      expected = scoped_studio("/d/production/studio/book/p1?tab=subjects")
      conn = get(conn, "/studio/production/onixedit/book/p1?tab=subjects")
      assert redirected_to(conn, 302) == expected
    end

    test "works for non-production datasets", %{conn: conn} do
      # The scoped resolver only keeps a dataset segment the resolved project
      # actually has (unknown slugs coerce to "production"), so give the
      # Default project a real "staging" dataset before following the link.
      {_ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
      {:ok, _} = Barkpark.Tenancy.create_dataset(project, %{slug: "staging", name: "staging"})

      expected = scoped_studio("/d/staging/studio/book/x9")
      conn = get(conn, "/studio/staging/onixedit/book/x9")
      assert redirected_to(conn, 302) == expected
    end

    test "handles draft doc ids verbatim", %{conn: conn} do
      expected = scoped_studio("/d/production/studio/book/drafts.p1")
      conn = get(conn, "/studio/production/onixedit/book/drafts.p1/view")
      assert redirected_to(conn, 302) == expected
    end
  end

  describe "bokbasen — legacy /admin/bokbasen → /admin/onixedit/bokbasen (G3.s4)" do
    test "GET /admin/bokbasen redirects 301", %{conn: conn} do
      conn = get(conn, "/admin/bokbasen")
      assert redirected_to(conn, 301) == "/admin/onixedit/bokbasen"
    end
  end
end
