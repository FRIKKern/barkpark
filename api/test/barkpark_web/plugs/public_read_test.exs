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

  test "public-read POST on allowed path (non-GET): 403 forbidden" do
    conn =
      build_conn(:post, "/v1/data/query/production/post")
      |> run(public_read_token())

    assert conn.halted
    assert conn.status == 403
    assert decode(conn)["error"]["code"] == "forbidden"
  end
end
