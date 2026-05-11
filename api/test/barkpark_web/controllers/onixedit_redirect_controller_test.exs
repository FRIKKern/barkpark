defmodule BarkparkWeb.OnixeditRedirectControllerTest do
  @moduledoc """
  Back-compat smoke tests for the old `/studio/:dataset/onixedit/book/...`
  deep links. Both `:doc_id` and `:doc_id/view` must 301 to the native
  Studio path `/studio/:dataset/book/:doc_id`. Query strings (e.g.
  `?tab=subjects` from the deleted BookEditor) are preserved so existing
  bookmarks land on the right tab inside StudioLive.
  """
  use BarkparkWeb.ConnCase, async: true

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
