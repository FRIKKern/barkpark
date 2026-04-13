defmodule BarkparkWeb.Contract.LegacyHeadersTest do
  use BarkparkWeb.ConnCase, async: false

  test "GET /api/schemas carries Deprecation header", %{conn: conn} do
    resp = get(conn, "/api/schemas")
    assert get_resp_header(resp, "deprecation") == ["true"]
    assert get_resp_header(resp, "sunset") == ["Wed, 31 Dec 2026 23:59:59 GMT"]
    refute get_resp_header(resp, "link") == []
  end
end
