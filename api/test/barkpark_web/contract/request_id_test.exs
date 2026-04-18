defmodule BarkparkWeb.Contract.RequestIdTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    :ok
  end

  test "404 error body includes request_id matching x-request-id response header", %{conn: conn} do
    resp = get(conn, "/v1/data/doc/test/post/does-not-exist")

    [header_rid] = Plug.Conn.get_resp_header(resp, "x-request-id")
    assert is_binary(header_rid) and header_rid != ""

    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] == "not_found"
    assert body["error"]["request_id"] == header_rid
  end

  test "401 unauthorized body includes request_id matching the header", %{conn: conn} do
    resp = get(conn, "/v1/data/export/test")

    [header_rid] = Plug.Conn.get_resp_header(resp, "x-request-id")
    body = Jason.decode!(resp.resp_body)

    assert resp.status == 401
    assert body["error"]["code"] == "unauthorized"
    assert body["error"]["request_id"] == header_rid
  end
end
