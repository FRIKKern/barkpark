defmodule BarkparkWeb.PageControllerTest do
  use BarkparkWeb.ConnCase, async: true

  test "GET /studio redirects to the scoped studio for the default dataset", %{conn: conn} do
    conn = get(conn, "/studio")
    assert redirected_to(conn, 302) =~ ~r{^/w/[^/]+/p/[^/]+/d/production/studio$}
  end

  test "GET / redirects to the scoped studio for the default dataset", %{conn: conn} do
    conn = get(conn, "/")
    assert redirected_to(conn, 302) =~ ~r{^/w/[^/]+/p/[^/]+/d/production/studio$}
  end
end
