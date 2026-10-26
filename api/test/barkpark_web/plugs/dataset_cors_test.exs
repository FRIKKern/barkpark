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
                  last-event-id x-sanity-project-id) do
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

    test "unmatched preflight on a /v1/plugins path passes through (plugin buckets own their CORS)" do
      # The anonymous :public_api bucket (Pulse) answers its own preflights via
      # PublicCors at the router — the endpoint plug must not swallow them.
      conn =
        build_conn(:options, "/v1/plugins/pulse/jarl-card/events")
        |> put_req_header("origin", "https://frikkern.github.io")
        |> put_req_header("access-control-request-method", "POST")
        |> call_plug()

      refute conn.halted
      assert conn.state == :unset
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

  describe ":always_allowed_origins (BARKPARK_ALWAYS_ALLOWED_ORIGINS)" do
    setup do
      put_schema("ds_always", "post", [])
      on_exit(fn -> Application.delete_env(:barkpark, :always_allowed_origins) end)
      :ok
    end

    defp acao_for(path, origin) do
      build_conn(:get, path)
      |> put_req_header("origin", origin)
      |> call_plug()
      |> send_resp(200, "ok")
      |> get_resp_header("access-control-allow-origin")
    end

    test "unset, the built-in list is allowed on dataset and no-dataset routes" do
      for origin <- ["https://www.barkpark.cloud", "https://x.vercel.app"],
          path <- ["/v1/data/query/ds_always/post", "/v1/meta"] do
        assert acao_for(path, origin) == [origin]
      end
    end

    test "set, it replaces the built-in list" do
      Application.put_env(:barkpark, :always_allowed_origins, ["https://pensum.example.no"])

      for path <- ["/v1/data/query/ds_always/post", "/v1/meta"] do
        assert acao_for(path, "https://www.barkpark.cloud") == []
        assert acao_for(path, "https://x.vercel.app") == []
        assert acao_for(path, "https://pensum.example.no") == ["https://pensum.example.no"]
      end
    end
  end

  describe "path-based tenancy prefix (/w/:ws/p/:project/…)" do
    # The /w/:ws/p/:project prefix shifts every positional path index; the plug
    # strips it before matching, so BOTH shapes must resolve the same dataset.
    test "resolves the SAME dataset for the flat and the /w/p-prefixed query path" do
      put_schema("ds_both", "post", ["https://both.example"])

      flat =
        build_conn(:get, "/v1/data/query/ds_both/post")
        |> put_req_header("origin", "https://both.example")
        |> call_plug()
        |> send_resp(200, "ok")

      prefixed =
        build_conn(:get, "/w/acme/p/site/v1/data/query/ds_both/post")
        |> put_req_header("origin", "https://both.example")
        |> call_plug()
        |> send_resp(200, "ok")

      # Both shapes reflect the dataset's allowed origin identically.
      assert get_resp_header(flat, "access-control-allow-origin") == ["https://both.example"]
      assert get_resp_header(prefixed, "access-control-allow-origin") == ["https://both.example"]
    end

    # @sanity/client pointed at Barkpark (useProjectHostname: false) sends
    # X-Sanity-Project-ID on every GROQ read; the preflight must allow it.
    # The GROQ path resolves no dataset here, so an always-allowed origin.
    test "a @sanity/client GROQ preflight allows authorization and x-sanity-project-id" do
      conn =
        build_conn(:options, "/w/acme/p/site/v2025-02-19/data/query/ds_sanity")
        |> put_req_header("origin", "https://barkpark.cloud")
        |> put_req_header("access-control-request-method", "GET")
        |> put_req_header("access-control-request-headers", "authorization,x-sanity-project-id")
        |> call_plug()

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["https://barkpark.cloud"]
      [allow_headers] = get_resp_header(conn, "access-control-allow-headers")
      allowed = allow_headers |> String.split(",") |> Enum.map(&String.trim/1)
      assert "authorization" in allowed
      assert "x-sanity-project-id" in allowed
    end

    test "prefixed path with a mismatched origin still fails closed (no ACAO)" do
      put_schema("ds_both2", "post", ["https://allowed.example"])

      prefixed =
        build_conn(:get, "/w/acme/p/site/v1/data/query/ds_both2/post")
        |> put_req_header("origin", "https://evil.example")
        |> call_plug()
        |> send_resp(200, "ok")

      assert get_resp_header(prefixed, "access-control-allow-origin") == []
    end

    test "prefixed preview + schemas + webhooks shapes resolve the dataset" do
      put_schema("ds_pfx", "post", ["https://pfx.example"])

      for path <- [
            "/w/acme/p/site/v1/preview/query/ds_pfx/post",
            "/w/acme/p/site/v1/schemas/ds_pfx",
            "/w/acme/p/site/v1/webhooks/ds_pfx"
          ] do
        conn =
          build_conn(:get, path)
          |> put_req_header("origin", "https://pfx.example")
          |> call_plug()
          |> send_resp(200, "ok")

        assert get_resp_header(conn, "access-control-allow-origin") == ["https://pfx.example"],
               "expected #{path} to resolve dataset ds_pfx"
      end
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

  # task-c2d1e40782ca8d69: the Sanity-shaped routes resolve their dataset, so
  # its cors_origins apply as on /v1/data, and keep the always-allowed and
  # :default_cors_origins they had when they resolved none.
  describe "Sanity-shaped GROQ paths (/v<ver>/data/query|doc|listen/<ds>)" do
    setup do
      prior = Application.get_env(:barkpark, :default_cors_origins)
      Application.put_env(:barkpark, :default_cors_origins, ["https://sdk.example"])
      on_exit(fn -> Application.put_env(:barkpark, :default_cors_origins, prior || []) end)
      put_schema("ds_g", "post", ["https://site.example"])
      put_schema("ds_h", "post", ["https://other.example"])
      :ok
    end

    defp preflight(path, origin) do
      build_conn(:options, path)
      |> put_req_header("origin", origin)
      |> put_req_header("access-control-request-method", "GET")
      |> put_req_header("access-control-request-headers", "authorization,x-sanity-project-id")
      |> call_plug()
    end

    defp acao(conn), do: get_resp_header(conn, "access-control-allow-origin")

    test "a listed origin is allowed, flat and prefixed, on query, doc and listen" do
      for path <- [
            "/v2025-02-19/data/query/ds_g",
            "/w/acme/p/site/v2025-02-19/data/query/ds_g",
            "/w/acme/p/site/v2021-06-07/data/doc/ds_g/a,b",
            "/w/acme/p/site/vX/data/listen/ds_g"
          ] do
        conn = preflight(path, "https://site.example")
        assert conn.status == 204, path
        assert acao(conn) == ["https://site.example"], path

        get =
          build_conn(:get, path)
          |> put_req_header("origin", "https://site.example")
          |> call_plug()
          |> send_resp(200, "ok")

        assert acao(get) == ["https://site.example"], path
      end
    end

    test "an origin not in the dataset's list is still refused" do
      conn = preflight("/w/acme/p/site/v2025-02-19/data/query/ds_g", "https://evil.example")
      assert conn.status == 204
      assert conn.halted
      assert acao(conn) == []
    end

    test "another dataset's list does not leak across" do
      assert acao(
               preflight("/w/acme/p/site/v2025-02-19/data/query/ds_g", "https://other.example")
             ) == []

      assert acao(
               preflight("/w/acme/p/site/v2025-02-19/data/query/ds_h", "https://other.example")
             ) ==
               ["https://other.example"]

      assert acao(preflight("/w/acme/p/site/v2025-02-19/data/query/ds_h", "https://site.example")) ==
               []
    end

    test "the always-allowed and default origins keep working" do
      for origin <- ["https://barkpark.cloud", "https://sdk.example"] do
        assert acao(preflight("/w/acme/p/site/v2025-02-19/data/query/ds_g", origin)) == [origin]

        assert acao(preflight("/w/acme/p/site/v2025-02-19/data/query/no_such_ds", origin)) == [
                 origin
               ]
      end
    end

    test "a non-data versioned path still resolves no dataset" do
      assert acao(
               preflight("/w/acme/p/site/v2025-02-19/data/mutate/ds_g", "https://site.example")
             ) == []
    end
  end
end
