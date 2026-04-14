defmodule BarkparkWeb.PageControllerTest do
  use BarkparkWeb.ConnCase, async: true

  test "GET /studio redirects to /studio/production", %{conn: conn} do
    conn = get(conn, "/studio")
    assert redirected_to(conn, 302) == "/studio/production"
  end

  test "GET / redirects to /studio/production", %{conn: conn} do
    conn = get(conn, "/")
    assert redirected_to(conn, 302) == "/studio/production"
  end
end
