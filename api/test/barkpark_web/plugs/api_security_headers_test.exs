defmodule BarkparkWeb.Plugs.ApiSecurityHeadersTest do
  @moduledoc """
  Pins the baseline security headers the `:api` pipeline attaches to every
  `/v1/*` JSON response. `/v1/capabilities` runs the plain `:api` pipeline with
  no token required, so it exercises the pipeline end-to-end without DB setup.
  """
  use BarkparkWeb.ConnCase, async: true

  test "GET /v1/capabilities carries nosniff + referrer-policy", %{conn: conn} do
    conn = get(conn, "/v1/capabilities")

    assert conn.status == 200
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    assert get_resp_header(conn, "referrer-policy") == [
             "strict-origin-when-cross-origin"
           ]
  end

  test "the plug does not overwrite a header already present on the response" do
    # Build a conn that already carries a referrer-policy (as a controller or
    # CORS layer would), run the plug, then flush before_send via send_resp.
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_resp_header("referrer-policy", "no-referrer")
      |> BarkparkWeb.Plugs.ApiSecurityHeaders.call([])
      |> Plug.Conn.send_resp(200, "{}")

    # Pre-existing value is preserved (single value, not doubled)...
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    # ...and the absent header is still added.
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end
end
