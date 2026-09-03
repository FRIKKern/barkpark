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

  # This route emits `W/"openapi-…"` and used to compare it BYTE-EXACTLY.
  # RFC 9110 §13.1.2 mandates the WEAK comparison function for If-None-Match.
  # PIN: reds on the pre-delegation matcher (exact compare answered 200).
  test "the STRONG form of the weak ETag 304s (D11 weak compare)", %{conn: conn} do
    weak = conn |> get("/v1/openapi.json") |> get_resp_header("etag") |> hd()
    "W/" <> strong = weak

    resp =
      build_conn()
      |> put_req_header("if-none-match", strong)
      |> get("/v1/openapi.json")

    assert resp.status == 304
    assert resp.resp_body == ""
  end

  test "a match on the SECOND If-None-Match line 304s", %{conn: conn} do
    etag = conn |> get("/v1/openapi.json") |> get_resp_header("etag") |> hd()

    resp =
      build_conn()
      |> then(fn c ->
        %{
          c
          | req_headers: c.req_headers ++ [{"if-none-match", ~s("nope")}, {"if-none-match", etag}]
        }
      end)
      |> get("/v1/openapi.json")

    assert resp.status == 304
  end

  # NEGATIVE CONTROL — an UNQUOTED bare token is not an entity-tag we ever
  # emitted, so it must never buy a 304.
  test "an unquoted bare token does not 304", %{conn: conn} do
    weak = conn |> get("/v1/openapi.json") |> get_resp_header("etag") |> hd()
    bare = weak |> String.replace_prefix("W/", "") |> String.trim("\"")

    resp =
      build_conn()
      |> put_req_header("if-none-match", bare)
      |> get("/v1/openapi.json")

    assert resp.status == 200
  end
end
