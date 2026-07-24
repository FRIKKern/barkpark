defmodule BarkparkWeb.AppTokenRevokeTest do
  @moduledoc """
  Mobile wave 2 (mob-w2-app-token-revoke) — the app-token revoke path,
  instance half. The mint's lifecycle twin in `AppTokenController`.

  `DELETE /v1/auth/app-tokens` is admin-bearer-gated: `{"token": raw}` revokes
  exactly that row; `{"email": e}` revokes every LIVE `app:<e>`-labelled token
  (logout-everywhere). `DELETE /v1/auth/app-tokens/current` is self-revoke —
  possession IS the authorization. Every leg proves the fail-closed contract:
  revocation only SETS `revoked_at`, and `Auth.verify_token/1`'s WHERE clause
  (which already filters `revoked_at IS NOT NULL`) rejects the token on its
  next use with ZERO read-path changes — proven both at the verifier and at
  the HTTP layer (a repeat call with the dead bearer 401s in `:require_token`).

  async: false — the instance-side revoke bucket ({:app_token_revoke, ip})
  lives in the shared `Barkpark.RateLimiter` ETS table keyed by the constant
  test IP, so buckets are reset per test and never raced by a sibling file.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth

  @dataset "production"

  setup do
    if :ets.whereis(:barkpark_rate_limiter) != :undefined do
      :ets.delete_all_objects(:barkpark_rate_limiter)
    end

    admin = "revoke-admin-#{System.unique_integer([:positive])}"
    reader = "revoke-reader-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(admin, "revoke-admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(reader, "revoke-reader", @dataset, ["read"])

    %{admin: admin, reader: reader}
  end

  defp as(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp unique_email, do: "revoke-#{System.unique_integer([:positive])}@example.com"

  # Mint through the REAL endpoint — the revoke path must kill exactly what the
  # exchange mints, so no fixture shortcut.
  defp mint_app_token(admin, email, ws) do
    as(build_conn(), admin)
    |> post("/v1/auth/app-tokens", Jason.encode!(%{email: email, workspace: ws.slug}))
    |> json_response(201)
    |> Map.fetch!("token")
  end

  defp revoke(bearer, body) do
    as(build_conn(), bearer) |> delete("/v1/auth/app-tokens", Jason.encode!(body))
  end

  defp self_revoke(bearer) do
    as(build_conn(), bearer) |> delete("/v1/auth/app-tokens/current")
  end

  describe "DELETE /v1/auth/app-tokens/current (self-revoke)" do
    test "the bearer kills itself: valid before, 401 on the next HTTP use after", %{admin: admin} do
      ws = create_workspace!()
      raw = mint_app_token(admin, unique_email(), ws)

      # Alive before: the verifier resolves it.
      assert {:ok, _} = Auth.verify_token(raw)

      assert self_revoke(raw) |> json_response(200) == %{"revoked" => true}

      # Fail-closed at the single choke point (WHERE clause, no read-path edit)…
      assert Auth.verify_token(raw) == {:error, :unauthorized}

      # …and at the HTTP layer: the SAME bearer is now rejected by
      # :require_token before the controller — the repeat call 401s.
      assert self_revoke(raw) |> json_response(401)
    end

    test "an admin bearer is refused (422) — the custody credential cannot self-destruct",
         %{admin: admin} do
      assert self_revoke(admin) |> json_response(422)

      # The admin token is untouched and still authenticates.
      assert {:ok, _} = Auth.verify_token(admin)
    end

    test "no bearer → 401" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> delete("/v1/auth/app-tokens/current")

      assert json_response(conn, 401)
    end
  end

  describe "DELETE /v1/auth/app-tokens with {token} (admin-gated)" do
    test "revokes the presented token: valid before, 401 after; idempotent on repeat",
         %{admin: admin} do
      ws = create_workspace!()
      raw = mint_app_token(admin, unique_email(), ws)

      assert {:ok, _} = Auth.verify_token(raw)

      assert revoke(admin, %{token: raw}) |> json_response(200) == %{"revoked" => true}
      assert Auth.verify_token(raw) == {:error, :unauthorized}

      # Idempotent: re-revoking the already-dead token is another 200, not a
      # 404 — a logout retry must never error.
      assert revoke(admin, %{token: raw}) |> json_response(200) == %{"revoked" => true}
    end

    test "a non-admin bearer gets the SAME generic unauthorized as an invalid one (no tier oracle)",
         %{reader: reader} do
      lesser = revoke(reader, %{token: "whatever"}) |> json_response(401)
      invalid = revoke("not-a-real-token", %{token: "whatever"}) |> json_response(401)

      assert lesser["error"]["code"] == invalid["error"]["code"]
    end

    test "nonexistent tokens join ONE canonical not-found oracle (same-shaped 404)",
         %{admin: admin} do
      garbage = revoke(admin, %{token: "garbage"}) |> json_response(404)

      unknown_raw =
        "bpapp_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      well_formed_unknown = revoke(admin, %{token: unknown_raw}) |> json_response(404)

      assert garbage["error"]["code"] == "not_found"

      # Identical shape modulo the per-request correlation id.
      assert Map.delete(garbage["error"], "request_id") ==
               Map.delete(well_formed_unknown["error"], "request_id")
    end

    test "an admin token presented in the body is refused (422), never revoked", %{admin: admin} do
      assert revoke(admin, %{token: admin}) |> json_response(422)
      assert {:ok, _} = Auth.verify_token(admin)
    end

    test "a body with neither token nor email → 422", %{admin: admin} do
      assert revoke(admin, %{}) |> json_response(422)
    end
  end

  describe "DELETE /v1/auth/app-tokens with {email} (logout everywhere)" do
    test "revokes every live app:<email> token; count relayed; idempotently 0 on repeat",
         %{admin: admin} do
      ws = create_workspace!()
      email = unique_email()
      raw_a = mint_app_token(admin, email, ws)
      raw_b = mint_app_token(admin, email, ws)

      assert {:ok, _} = Auth.verify_token(raw_a)
      assert {:ok, _} = Auth.verify_token(raw_b)

      assert revoke(admin, %{email: email}) |> json_response(200) == %{"revoked_count" => 2}

      assert Auth.verify_token(raw_a) == {:error, :unauthorized}
      assert Auth.verify_token(raw_b) == {:error, :unauthorized}

      # The admin bearer itself (different label) is untouched.
      assert {:ok, _} = Auth.verify_token(admin)

      # Logout-everywhere is idempotent: nothing left to kill → 0, still 200.
      assert revoke(admin, %{email: email}) |> json_response(200) == %{"revoked_count" => 0}
    end

    test "an admin-carrying token behind a colliding app:<email> label is NEVER batch-revoked",
         %{admin: admin} do
      email = unique_email()
      colliding = "colliding-admin-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(colliding, "app:" <> email, @dataset, ["read", "admin"])

      assert revoke(admin, %{email: email}) |> json_response(200) == %{"revoked_count" => 0}
      assert {:ok, _} = Auth.verify_token(colliding)
    end
  end

  describe "rate bucket ({:app_token_revoke, ip}, 10/min — D7)" do
    test "the 11th hit from one IP is braked with 429", %{admin: admin} do
      email = unique_email()

      for _ <- 1..10 do
        assert revoke(admin, %{email: email}) |> json_response(200)
      end

      throttled = revoke(admin, %{email: email}) |> json_response(429)
      assert throttled["error"]["code"] == "rate_limited"
    end
  end
end
