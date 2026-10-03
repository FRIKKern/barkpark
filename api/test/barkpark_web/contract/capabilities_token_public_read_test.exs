defmodule BarkparkWeb.Contract.CapabilitiesTokenPublicReadTest do
  @moduledoc """
  task-0cf611238d4ad597 JQ1 (owner ruling #36): `GET /v1/capabilities` gives a
  caller a way to tell a `public-read` token from a plain `read` token.

  Both rank `auth_tier: "read"`. Only the first is pinned to published, public
  types (`BarkparkWeb.Plugs.PublicRead`); a plain `read` token reads drafts.
  The search starters inline their token into a browser bundle and used to
  accept anything that answered "read". `?token=1` now adds a root
  `token.public_read` boolean, and the starters require it to be `true`.

  Opt-in like `?build=1`/`?bpml=1`: released `bp` binaries strict-decode the
  manifest root, so the default body must not carry the key.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth

  defp mint(perms) do
    raw = "jq1-#{Enum.join(perms, "-")}-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "jq1 #{Enum.join(perms, ",")}", "test", perms)
    raw
  end

  defp caps(conn, raw, query) do
    conn =
      if raw, do: put_req_header(conn, "authorization", "Bearer " <> raw), else: conn

    conn |> get("/v1/capabilities" <> query) |> json_response(200)
  end

  test "a public-read token: auth_tier read AND token.public_read true", %{conn: conn} do
    body = caps(conn, mint(["public-read"]), "?token=1")
    assert body["auth_tier"] == "read"
    assert body["token"] == %{"public_read" => true}
  end

  test "a plain read token: auth_tier read BUT token.public_read false", %{conn: conn} do
    body = caps(conn, mint(["read"]), "?token=1")
    assert body["auth_tier"] == "read"
    assert body["token"] == %{"public_read" => false}
  end

  test "a public-read + read token is still public-read (membership, not equality)",
       %{conn: conn} do
    body = caps(conn, mint(["public-read", "read"]), "?token=1")
    assert body["token"] == %{"public_read" => true}
  end

  test "an admin token: token.public_read false", %{conn: conn} do
    body = caps(conn, mint(["read", "write", "admin"]), "?token=1")
    assert body["auth_tier"] == "admin"
    assert body["token"] == %{"public_read" => false}
  end

  test "anonymous ?token=1 gets no token key (nothing to describe)", %{conn: conn} do
    body = caps(conn, nil, "?token=1")
    assert body["auth_tier"] == "none"
    refute Map.has_key?(body, "token")
  end

  test "without ?token=1 the root carries no token key (strict-decoding bp)", %{conn: conn} do
    body = caps(conn, mint(["public-read"]), "")
    refute Map.has_key?(body, "token")
  end

  test "the key feeds the etag: public-read and read bodies do not share one", %{conn: conn} do
    pr = caps(conn, mint(["public-read"]), "?token=1")
    rd = caps(build_conn(), mint(["read"]), "?token=1")
    refute pr["etag"] == rd["etag"]
  end
end
