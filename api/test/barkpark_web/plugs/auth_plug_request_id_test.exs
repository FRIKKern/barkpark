defmodule BarkparkWeb.Plugs.AuthPlugRequestIdTest do
  @moduledoc """
  Protective test for the "uncorrelatable auth failure" fix.

  A 401/403 emitted by a PRE-ROUTER auth plug MUST carry `error.request_id`
  matching the response's `x-request-id` header, so an operator can grep the
  server logs for exactly that rejection — the `internal_error` hint literally
  tells callers to "report the request_id to the API operator".

  Before the shared `BarkparkWeb.ErrorResponse` emitter, these plugs hand-built
  `%{error: %{code, message}}` and DROPPED request_id even though `Plug.RequestId`
  (endpoint) had already populated both the header and Logger metadata. This test
  FAILS on `main` (request_id absent) and passes once the plugs route through the
  one emitter.
  """
  use BarkparkWeb.ConnCase, async: false

  # Assert the response is a §9 error envelope whose request_id correlates to the
  # x-request-id header the endpoint stamped.
  defp assert_correlatable(conn, status, code) do
    assert conn.status == status
    body = json_response(conn, status)

    [xrid | _] = Plug.Conn.get_resp_header(conn, "x-request-id")
    assert is_binary(xrid) and xrid != "", "endpoint must stamp x-request-id"

    assert body["error"]["code"] == code

    assert is_binary(body["error"]["request_id"]) and body["error"]["request_id"] != "",
           "auth-plug error envelope must carry request_id"

    assert body["error"]["request_id"] == xrid,
           "request_id must match the x-request-id header for log correlation"
  end

  test "RequireIngestToken 401 carries request_id matching x-request-id", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer totally-bogus-ingest-token")
      |> post("/v1/paperflow/papers", %{})

    assert_correlatable(conn, 401, "unauthorized")
  end

  test "RequireUserSession 401 carries request_id matching x-request-id", %{conn: conn} do
    conn = get(conn, "/v1/auth/me")
    assert_correlatable(conn, 401, "unauthorized")
  end
end
