defmodule BarkparkWeb.OpenApiControllerTest do
  @moduledoc """
  Live-endpoint pins for `GET /v1/openapi.json` — the published, token-free
  OpenAPI 3.1 descriptor. Proves the route is actually mounted (a spec that only
  the mix task can reach is worthless), the body is valid JSON, and the
  ETag/`If-None-Match` → 304 short-circuit works like CapabilitiesController.
  """
  use BarkparkWeb.ConnCase, async: true

  test "GET /v1/openapi.json returns 200 with a valid OpenAPI 3.1 body (no token)", %{conn: conn} do
    conn = get(conn, "/v1/openapi.json")

    assert conn.status == 200
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")

    body = json_response(conn, 200)
    assert body["openapi"] == "3.1.0"
    assert is_map(body["paths"]) and map_size(body["paths"]) > 0
    assert body["components"]["securitySchemes"]["bearerAuth"]["type"] == "http"
  end

  test "response carries a weak ETag", %{conn: conn} do
    conn = get(conn, "/v1/openapi.json")
    assert [etag] = get_resp_header(conn, "etag")
    assert String.starts_with?(etag, "W/\"openapi-")
  end

  test "If-None-Match matching the ETag short-circuits to 304 with empty body", %{conn: conn} do
    etag =
      conn
      |> get("/v1/openapi.json")
      |> get_resp_header("etag")
      |> hd()

    conn304 =
      build_conn()
      |> put_req_header("if-none-match", etag)
      |> get("/v1/openapi.json")

    assert conn304.status == 304
    assert conn304.resp_body == ""
  end

  test "a stale If-None-Match still returns 200 with the body", %{conn: conn} do
    conn =
      conn
      |> put_req_header("if-none-match", "W/\"openapi-deadbeefdeadbeef\"")
      |> get("/v1/openapi.json")

    assert conn.status == 200
    assert json_response(conn, 200)["openapi"] == "3.1.0"
  end
end
