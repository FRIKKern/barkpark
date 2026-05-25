defmodule BarkparkWeb.Contract.LegacyHeadersTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  @token "barkpark-dev-token"

  setup do
    # w1.5-E (Goal barkpark-qprk): the legacy `/api/*` surface is now token-gated
    # (`:require_token` runs before `LegacyDeprecation`). The deprecation headers
    # are only emitted on an authenticated request — an anonymous call is halted
    # with 401 before the header plug runs.
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

  test "GET /api/schemas without auth → 401", %{conn: conn} do
    resp = get(conn, "/api/schemas")
    assert resp.status == 401
  end
end
