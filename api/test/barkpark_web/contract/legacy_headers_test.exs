defmodule BarkparkWeb.Contract.LegacyHeadersTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  @token "barkpark-dev-token"

  setup do
    # w1.5-E (Goal barkpark-qprk) token-gated the legacy `/api/documents/*` CRUD
    # surface (`:require_token` before `LegacyDeprecation`). The regate-fix kept
    # `GET /api/schemas` PUBLIC — it is schema discovery, Default-scoped via
    # AssignDefaultScope, no token required. The deprecation headers ride along
    # on both the authed and anonymous schema reads.
    Auth.create_token(@token, "dev", "legacy-headers", ["read", "admin"])
    :ok
  end

  test "GET /api/schemas (authed) carries Deprecation header", %{conn: conn} do
    resp =
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> get("/api/schemas")

    assert get_resp_header(resp, "deprecation") == ["true"]
    assert get_resp_header(resp, "sunset") == ["Wed, 31 Dec 2026 23:59:59 GMT"]
    refute get_resp_header(resp, "link") == []
  end

  test "GET /api/schemas without auth → 200 (public schema discovery)", %{conn: conn} do
    resp = get(conn, "/api/schemas")
    assert resp.status == 200
  end

  test "GET /api/schemas without auth still carries Deprecation header", %{conn: conn} do
    resp = get(conn, "/api/schemas")
    assert get_resp_header(resp, "deprecation") == ["true"]
  end
end
