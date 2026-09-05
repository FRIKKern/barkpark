defmodule BarkparkWeb.Plugs.PublicReadTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content
  alias BarkparkWeb.Plugs.PublicRead

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        "production"
      )

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "secret", "title" => "Secret", "visibility" => "private", "fields" => []},
        "production"
      )

    :ok
  end

  defp public_read_token, do: %ApiToken{permissions: ["public-read"]}
  defp admin_token, do: %ApiToken{permissions: ["read", "write", "admin"]}
  # What TokenController's PUBLIC mint route hands out when the caller asks for
  # both allowlisted permissions — the list-equality bypass.
  defp mixed_token, do: %ApiToken{permissions: ["read", "public-read"]}

  defp run(conn, nil), do: PublicRead.call(conn, PublicRead.init([]))

  defp run(conn, token) do
    conn
    |> assign(:api_token, token)
    |> PublicRead.call(PublicRead.init([]))
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  test "no token: pass-through" do
    conn = build_conn(:get, "/v1/data/query/production/post") |> run(nil)
    refute conn.halted
  end

  test "non-public-read token: pass-through on any route" do
    conn = build_conn(:post, "/v1/data/mutate/production") |> run(admin_token())
    refute conn.halted

    conn = build_conn(:get, "/v1/data/query/production/secret") |> run(admin_token())
    refute conn.halted
  end

  test "MEMBERSHIP: a read + public-read token is clamped, not exempted" do
    # `== ["public-read"]` let this token through on every pipeline. The gate is
    # `"public-read" in perms` (AnonPerspective.anon_pinned?/1's rule).
    conn = build_conn(:get, "/v1/data/export/production") |> run(mixed_token())
    assert conn.halted
    assert conn.status == 403

    conn =
      build_conn(:get, "/v1/data/query/production/post?perspective=drafts") |> run(mixed_token())

    assert conn.halted
    assert conn.status == 403
  end

  test "MEMBERSHIP: a token struct without :permissions is NOT clamped" do
    conn = build_conn(:get, "/v1/data/export/production") |> run(%{tier: :member})
    refute conn.halted
  end

  test "public-read on query public schema, no perspective: allowed" do
    conn = build_conn(:get, "/v1/data/query/production/post") |> run(public_read_token())
    refute conn.halted
  end

  test "public-read on query public schema, perspective=published: allowed" do
    conn =
      build_conn(:get, "/v1/data/query/production/post?perspective=published")
      |> run(public_read_token())

    refute conn.halted
  end

  test "public-read on doc path public schema: allowed" do
    conn =
      build_conn(:get, "/v1/data/doc/production/post/p1")
      |> run(public_read_token())

    refute conn.halted
  end

  test "public-read perspective=drafts: 403 perspective not allowed" do
    conn =
      build_conn(:get, "/v1/data/query/production/post?perspective=drafts")
      |> run(public_read_token())

    assert conn.halted
    assert conn.status == 403
    assert decode(conn)["error"]["code"] == "forbidden"
    assert decode(conn)["error"]["message"] == "perspective not allowed"
  end

  test "public-read perspective=raw: 403 perspective not allowed" do
    conn =
      build_conn(:get, "/v1/data/query/production/post?perspective=raw")
      |> run(public_read_token())

    assert conn.halted
    assert conn.status == 403
    assert decode(conn)["error"]["code"] == "forbidden"
    assert decode(conn)["error"]["message"] == "perspective not allowed"
  end

  test "public-read on private schema via query: 404 not found" do
    conn =
      build_conn(:get, "/v1/data/query/production/secret")
      |> run(public_read_token())

    assert conn.halted
    assert conn.status == 404
    assert decode(conn)["error"]["code"] == "not_found"
  end

  test "public-read on private schema via doc: 404 not found" do
    conn =
      build_conn(:get, "/v1/data/doc/production/secret/p1")
      |> run(public_read_token())

    assert conn.halted
    assert conn.status == 404
    assert decode(conn)["error"]["code"] == "not_found"
  end

  test "public-read on unknown schema: 404 not found" do
    conn =
      build_conn(:get, "/v1/data/query/production/nonesuch")
      |> run(public_read_token())

    assert conn.halted
    assert conn.status == 404
  end

  test "public-read POST /v1/data/mutate: 403 forbidden" do
    conn =
      build_conn(:post, "/v1/data/mutate/production")
      |> run(public_read_token())

    assert conn.halted
    assert conn.status == 403
    assert decode(conn)["error"]["code"] == "forbidden"
  end

  # The `/v1/data/listen` and `/v1/schemas` cases that used to live here called
  # the plug DIRECTLY on a hand-built conn, for routes the router did not send
  # through the plug at all — a green that certified a live 200. They now run
  # through the REAL endpoint in
  # `BarkparkWeb.Integration.PublicReadEnforcementTest`, where the listen case
  # fails before the `plug(PublicRead)` line in `pipeline :require_token`.

  # ── /v1/graph: admitted by name, and the admission must not crash ─────────
  #
  # WITHOUT the `type_gate/1` clause for a path with no `:type` segment, this
  # test does not fail with a wrong status — it RAISES `FunctionClauseError`
  # from the old two-clause `extract_ds_type/1`, i.e. a 500 in production. That
  # is precisely why a bare allowlist entry would have been a worse bug than the
  # 403 it replaced.
  test "public-read GET /v1/graph: admitted (no crash on the missing :type segment)" do
    conn = build_conn(:get, "/v1/graph") |> run(public_read_token())
    refute conn.halted
    refute conn.status == 500
  end

  test "public-read GET /v1/graph?dataset=production: admitted" do
    conn = build_conn(:get, "/v1/graph?dataset=production") |> run(public_read_token())
    refute conn.halted
  end

  test "public-read GET /v1/graph on the SCOPED mirror shape: admitted" do
    conn = build_conn(:get, "/w/acme/p/site/v1/graph") |> run(public_read_token())
    refute conn.halted
  end

  test "public-read GET /v1/graph?perspective=drafts: still 403 (the perspective clamp holds)" do
    conn = build_conn(:get, "/v1/graph?perspective=drafts") |> run(public_read_token())
    assert conn.halted
    assert conn.status == 403
    assert decode(conn)["error"]["message"] == "perspective not allowed"
  end

  test "public-read POST /v1/graph: 403 (GET-only admission)" do
    conn = build_conn(:post, "/v1/graph") |> run(public_read_token())
    assert conn.halted
    assert conn.status == 403
  end

  # LEAK-STILL-CLOSED. Admitting one route must not widen the surface by prefix:
  # the graph siblings each leak something the corpus does not (a draft-only
  # title at the default perspective; an unpaginated full-corpus dump), and the
  # non-graph `:require_token` reads are the live leak this plug's mount closed
  # (a public-read token read a 52MB export including 129 drafts).
  test "the graph SIBLINGS remain unadmitted: 403" do
    for path <- [
          "/v1/graph/gh-9531",
          "/v1/graph/gh-9531/tasks",
          "/v1/graph/orphans",
          "/v1/graph/dangling",
          "/w/acme/p/site/v1/graph/orphans"
        ] do
      conn = build_conn(:get, path) |> run(public_read_token())

      assert conn.halted, "#{path} was admitted for a public-read token"
      assert conn.status == 403, "#{path} returned #{conn.status}, expected 403"
      assert decode(conn)["error"]["code"] == "forbidden"
    end
  end

  test "the non-graph :require_token reads remain 403" do
    for path <- [
          "/v1/data/export/production",
          "/v1/data/listen/production",
          "/v1/data/revision/production/p1",
          "/v1/data/analytics/production",
          "/v1/data/history/production/post/p1"
        ] do
      conn = build_conn(:get, path) |> run(public_read_token())

      assert conn.halted, "#{path} was admitted for a public-read token"
      assert conn.status == 403, "#{path} returned #{conn.status}, expected 403"

      assert decode(conn)["error"]["message"] ==
               "public-read tokens may only read published public documents"
    end
  end

  test "the data routes are unchanged by the readmit: public 200-path, private 404" do
    refute run(build_conn(:get, "/v1/data/query/production/post"), public_read_token()).halted

    denied = run(build_conn(:get, "/v1/data/query/production/secret"), public_read_token())
    assert denied.halted
    assert denied.status == 404
  end

  test "public-read POST on allowed path (non-GET): 403 forbidden" do
    conn =
      build_conn(:post, "/v1/data/query/production/post")
      |> run(public_read_token())

    assert conn.halted
    assert conn.status == 403
    assert decode(conn)["error"]["code"] == "forbidden"
  end

  describe "the ?drafts alias cannot slip past the perspective gate (C1)" do
    # THE BYPASS: `allowed_perspective?/1` read ONLY `conn.params["perspective"]`,
    # while `TasksController.Params.parse_perspective/1` — the parser the graph
    # surface actually honours — ALSO maps `?drafts=true|1` to `:drafts`. One
    # gate, two parsers: a caller that spelled the request `?drafts=true` was
    # measured as `:published` by the plug and as `:drafts` by the controller.
    #
    # MUTATION PROOF: drop the `Params.parse_perspective(...) == :published`
    # conjunct from `allowed_perspective?/1` and the arms below red; the
    # `?perspective=raw` arm above stays green, which is why BOTH conjuncts are
    # kept (`raw` parses to `:published`, so only the literal check refuses it).
    for value <- ["true", "1"] do
      test "public-read ?drafts=#{value} is refused exactly like ?perspective=drafts" do
        conn =
          build_conn(:get, "/v1/data/query/production/post?drafts=#{unquote(value)}")
          |> run(public_read_token())

        assert conn.halted
        assert conn.status == 403

        assert decode(conn)["error"]["message"] == "perspective not allowed",
               "the ?drafts alias was refused for the WRONG reason — the perspective " <>
                 "gate must be what stops it, not a downstream schema check"
      end
    end

    test "the alias is refused on the graph corpus route too (the one graph path public-read reaches)" do
      conn = build_conn(:get, "/v1/graph?drafts=true") |> run(public_read_token())

      assert conn.halted
      assert conn.status == 403
      assert decode(conn)["error"]["message"] == "perspective not allowed"
    end

    test "a MIXED read+public-read token is clamped by the alias gate as well" do
      conn =
        build_conn(:get, "/v1/data/query/production/post?drafts=true") |> run(mixed_token())

      assert conn.halted
      assert conn.status == 403
    end

    test "a NON-truthy ?drafts value is not over-clamped — the corpus read still passes" do
      # `parse_perspective/1` only honours "true"/"1"; anything else is
      # `:published`, and the gate must agree rather than refusing on the mere
      # PRESENCE of the key.
      for value <- ["false", "0", "yes", ""] do
        conn = build_conn(:get, "/v1/graph?drafts=#{value}") |> run(public_read_token())

        refute conn.halted,
               "?drafts=#{value} was refused — the gate is keyed on the key's PRESENCE, " <>
                 "not on what the controller's parser actually reads"
      end
    end

    test "a non-public-read token is UNAFFECTED by the alias gate (the plug only clamps that tier)" do
      conn = build_conn(:get, "/v1/graph?drafts=true") |> run(admin_token())
      refute conn.halted
    end
  end
end
