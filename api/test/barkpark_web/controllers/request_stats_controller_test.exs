defmodule BarkparkWeb.RequestStatsControllerTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  @route "/v1/instance/request-stats"

  defp authed_conn(conn) do
    raw = "reqstats-test-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, _token} = Auth.create_token(raw, "reqstats-test", "test", ["read"])

    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("accept", "application/json")
  end

  test "401 without a token — never an unauthenticated stats endpoint", %{conn: conn} do
    conn = get(conn, @route)
    assert json_response(conn, 401)
  end

  test "401 with a bogus token", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer not-a-real-token")
      |> get(@route)

    assert json_response(conn, 401)
  end

  test "200 with the agent token seam; contract shape {req_per_s, p95_ms, err_5xx_per_s, window_s}",
       %{
         conn: conn
       } do
    body =
      conn
      |> authed_conn()
      |> get(@route)
      |> json_response(200)

    assert Map.keys(body) |> Enum.sort() ==
             ["err_5xx_per_s", "p95_ms", "req_per_s", "window_s"]

    assert body["window_s"] == 60
    assert is_float(body["req_per_s"])
    assert body["req_per_s"] >= 0.0
    # Honesty: p95_ms is null (no samples) or a real integer — never a fake 0ms
    # standing in for "no data".
    assert is_nil(body["p95_ms"]) or is_integer(body["p95_ms"])
    # Same law for the error rate: an empty window is null, not a reassuring 0.0
    # standing in for "this box is serving no errors".
    assert is_nil(body["err_5xx_per_s"]) or is_float(body["err_5xx_per_s"])
    assert is_nil(body["err_5xx_per_s"]) or body["err_5xx_per_s"] >= 0.0
  end
end
