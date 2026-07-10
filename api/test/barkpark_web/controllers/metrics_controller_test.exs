defmodule BarkparkWeb.MetricsControllerTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  @route "/v1/instance/metrics"

  defp authed_conn(conn) do
    raw = "metrics-test-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, _token} = Auth.create_token(raw, "metrics-test", "test", ["read"])
    put_req_header(conn, "authorization", "Bearer " <> raw)
  end

  test "401 without a token — the scrape endpoint is never anonymous", %{conn: conn} do
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

  test "200 text/plain Prometheus exposition with the agent token seam", %{conn: conn} do
    # Seed a sample so the exposition is non-empty.
    :telemetry.execute([:vm, :memory], %{total: 15_000_000}, %{})

    conn = conn |> authed_conn() |> get(@route)

    assert response(conn, 200)
    assert response_content_type(conn, :text) =~ "text/plain"
    body = response(conn, 200)
    # The named metric families are exposed for scraping.
    assert body =~ "vm_memory_total"
  end
end
