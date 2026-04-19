defmodule BarkparkWeb.Plugs.DatasetCorsTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias BarkparkWeb.Plugs.DatasetCors

  defp put_schema(dataset, name, cors_origins) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => name, "title" => name, "cors_origins" => cors_origins},
        dataset
      )
  end

  defp call_plug(conn), do: DatasetCors.call(conn, DatasetCors.init([]))

  describe "simple (non-preflight) requests" do
    test "reflects matching origin on /v1/data/query/:ds/:type" do
      put_schema("ds_match", "post", ["https://a.example"])

      conn =
        build_conn(:get, "/v1/data/query/ds_match/post")
        |> put_req_header("origin", "https://a.example")
        |> call_plug()
        |> send_resp(200, "ok")

      assert get_resp_header(conn, "access-control-allow-origin") == ["https://a.example"]
      assert "Origin" in get_resp_header(conn, "vary")

      [expose] = get_resp_header(conn, "access-control-expose-headers")

      for h <- ~w(x-total-count x-page x-per-page etag x-request-id retry-after
                  x-barkpark-signature x-barkpark-timestamp x-barkpark-event-id) do
        assert expose =~ h
      end

      refute conn.halted
    end

    test "omits ACAO for non-matching origin" do
      put_schema("ds_match", "post", ["https://a.example"])

      conn =
        build_conn(:get, "/v1/data/query/ds_match/post")
        |> put_req_header("origin", "https://evil.example")
        |> call_plug()
        |> send_resp(200, "ok")

      assert get_resp_header(conn, "access-control-allow-origin") == []
      refute conn.halted
    end

    test "no Origin header → passthrough (no CORS headers)" do
      put_schema("ds_none", "post", ["https://only.example"])

      conn =
        build_conn(:get, "/v1/data/query/ds_none/post")
        |> call_plug()
        |> send_resp(200, "ok")

      assert get_resp_header(conn, "access-control-allow-origin") == []
      refute conn.halted
    end

    test "normalizes trailing slash on both sides when comparing" do
      put_schema("ds_trail", "post", ["https://foo.example/"])

      conn =
        build_conn(:get, "/v1/data/query/ds_trail/post")
        |> put_req_header("origin", "https://foo.example")
        |> call_plug()
        |> send_resp(200, "ok")

      assert get_resp_header(conn, "access-control-allow-origin") == ["https://foo.example"]
    end
  end

  describe "preflight OPTIONS" do
    test "matching origin → 204 with full CORS headers + halted" do
      put_schema("ds_match", "post", ["https://a.example"])

      conn =
        build_conn(:options, "/v1/data/mutate/ds_match")
        |> put_req_header("origin", "https://a.example")
        |> put_req_header("access-control-request-method", "POST")
        |> call_plug()

      assert conn.status == 204
      assert conn.halted
      assert get_resp_header(conn, "access-control-allow-origin") == ["https://a.example"]

      [methods] = get_resp_header(conn, "access-control-allow-methods")
      for m <- ~w(GET POST PUT PATCH DELETE OPTIONS), do: assert(methods =~ m)

      [allow_headers] = get_resp_header(conn, "access-control-allow-headers")

      for h <- ~w(authorization content-type x-requested-with x-barkpark-preview-token
                  accept if-match if-none-match idempotency-key x-barkpark-api-version
                  last-event-id) do
        assert allow_headers =~ h
      end

      assert get_resp_header(conn, "access-control-max-age") == ["600"]
      assert "Origin" in get_resp_header(conn, "vary")
    end

    test "non-matching origin → 204 with NO CORS headers" do
      put_schema("ds_match", "post", ["https://a.example"])

      conn =
        build_conn(:options, "/v1/data/mutate/ds_match")
        |> put_req_header("origin", "https://evil.example")
        |> put_req_header("access-control-request-method", "POST")
        |> call_plug()

      assert conn.status == 204
      assert conn.halted
      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert get_resp_header(conn, "access-control-allow-methods") == []
    end
  end

  describe "per-dataset isolation" do
    test "origin allowed for ds_b is rejected for ds_a" do
      put_schema("ds_a", "post", ["https://a.example"])
      put_schema("ds_b", "post", ["https://b.example"])

      conn_a =
        build_conn(:get, "/v1/data/query/ds_a/post")
        |> put_req_header("origin", "https://b.example")
        |> call_plug()
        |> send_resp(200, "ok")

      conn_b =
        build_conn(:get, "/v1/data/query/ds_b/post")
        |> put_req_header("origin", "https://b.example")
        |> call_plug()
        |> send_resp(200, "ok")

      assert get_resp_header(conn_a, "access-control-allow-origin") == []
      assert get_resp_header(conn_b, "access-control-allow-origin") == ["https://b.example"]
    end
  end

  describe "no-dataset routes use :default_cors_origins" do
    setup do
      prior = Application.get_env(:barkpark, :default_cors_origins)
      on_exit(fn -> Application.put_env(:barkpark, :default_cors_origins, prior || []) end)
      :ok
    end

    test "reflects when default allowlist contains the origin" do
      Application.put_env(:barkpark, :default_cors_origins, ["https://sdk.example"])

      conn =
        build_conn(:get, "/v1/meta")
        |> put_req_header("origin", "https://sdk.example")
        |> call_plug()
        |> send_resp(200, "ok")

      assert get_resp_header(conn, "access-control-allow-origin") == ["https://sdk.example"]
    end

    test "empty default + mismatched origin → no ACAO" do
      Application.put_env(:barkpark, :default_cors_origins, [])

      conn =
        build_conn(:get, "/v1/meta")
        |> put_req_header("origin", "https://sdk.example")
        |> call_plug()
        |> send_resp(200, "ok")

      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end

  describe "unknown dataset" do
    test "never emits a wildcard ACAO, and never reflects" do
      # No schemas seeded for ds_ghost.
      conn =
        build_conn(:get, "/v1/data/query/ds_ghost/post")
        |> put_req_header("origin", "https://anywhere.example")
        |> call_plug()
        |> send_resp(200, "ok")

      acao = get_resp_header(conn, "access-control-allow-origin")
      refute "*" in acao
      assert acao == []
    end
  end
end
