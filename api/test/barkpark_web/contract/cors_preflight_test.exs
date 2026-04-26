defmodule BarkparkWeb.Contract.CorsPreflightTest do
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "production"
    )

    :ok
  end

  defp preflight(conn, path, req_method, req_headers) do
    conn
    |> Plug.Conn.put_req_header("origin", "http://studio.example")
    |> Plug.Conn.put_req_header("access-control-request-method", req_method)
    |> Plug.Conn.put_req_header("access-control-request-headers", req_headers)
    |> options(path)
  end

  defp hdr(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  test "OPTIONS /v1/data/query/:ds/:type returns full preflight header set", %{conn: conn} do
    conn =
      preflight(
        conn,
        "/v1/data/query/production/post",
        "GET",
        "authorization,x-barkpark-api-version"
      )

    assert conn.status in [200, 204]
    assert hdr(conn, "access-control-allow-origin") != nil
    assert hdr(conn, "access-control-allow-methods") != nil
    assert hdr(conn, "access-control-allow-headers") != nil
    assert hdr(conn, "access-control-max-age") == "600"
  end

  test "OPTIONS /v1/data/doc/:ds/:type/:id returns full preflight header set", %{conn: conn} do
    conn =
      preflight(
        conn,
        "/v1/data/doc/production/post/p1",
        "GET",
        "authorization,x-barkpark-api-version"
      )

    assert conn.status in [200, 204]
    assert hdr(conn, "access-control-allow-origin") != nil
    assert hdr(conn, "access-control-allow-methods") != nil
    assert hdr(conn, "access-control-allow-headers") != nil
    assert hdr(conn, "access-control-max-age") == "600"
  end

  test "preflight allow-headers advertises authorization + x-barkpark-api-version", %{conn: conn} do
    conn =
      preflight(
        conn,
        "/v1/data/query/production/post",
        "GET",
        "authorization,x-barkpark-api-version"
      )

    allow_headers = hdr(conn, "access-control-allow-headers") || ""
    lowered = String.downcase(allow_headers)

    assert String.contains?(lowered, "authorization"),
           "expected 'authorization' in: #{inspect(allow_headers)}"

    assert String.contains?(lowered, "x-barkpark-api-version"),
           "expected 'x-barkpark-api-version' in: #{inspect(allow_headers)}"
  end

  test "non-preflight GET still carries access-control-allow-origin", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.put_req_header("origin", "http://studio.example")
      |> get("/v1/data/query/production/post")

    assert conn.status == 200
    assert hdr(conn, "access-control-allow-origin") != nil
  end

  test "non-preflight GET advertises key expose-headers", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.put_req_header("origin", "http://studio.example")
      |> get("/v1/data/query/production/post")

    expose = hdr(conn, "access-control-expose-headers") || ""
    lowered = String.downcase(expose)

    assert String.contains?(lowered, "etag")
    assert String.contains?(lowered, "x-request-id")
  end
end
