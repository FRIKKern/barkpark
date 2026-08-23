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

  import Barkpark.RateLimiterSandbox

  # `:barkpark_rate_limiter` is a :named_table — WHOLE-NODE state no sandbox owns
  # and nothing used to reset, so a bucket one test spent stayed spent for the
  # rest of the run. Start from an unspent table.
  setup :reset_rate_limiter!

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

  # Same revoke, but arriving THROUGH a proxy that names the original caller —
  # the shape every cloud-proxied revoke has now that the control plane relays
  # X-Forwarded-For (Registry.revoke_app_token/3).
  defp revoke_from(bearer, ip, body) do
    as(build_conn(), bearer)
    |> put_req_header("x-forwarded-for", ip)
    |> delete("/v1/auth/app-tokens", Jason.encode!(body))
  end

  # The same revoke arriving DIRECTLY from a public peer that forges the header —
  # the shape the trust boundary exists for (Barkpark.RateLimiter.client_ip/1).
  defp revoke_direct(bearer, peer, forged_ip, body) do
    as(build_conn(), bearer)
    |> Map.put(:remote_ip, peer)
    |> put_req_header("x-forwarded-for", forged_ip)
    |> delete("/v1/auth/app-tokens", Jason.encode!(body))
  end

  # A chain as our own front actually produces it: the control plane relayed the
  # phone's address, Caddy appended the control plane's egress on the right.
  defp revoke_relayed(bearer, phone_ip, relay_ip, body) do
    as(build_conn(), bearer)
    |> put_req_header("x-forwarded-for", "#{phone_ip}, #{relay_ip}")
    |> delete("/v1/auth/app-tokens", Jason.encode!(body))
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

      # pds w40: the receipt now descends from `Auth.revoke_token/1`'s returned
      # row (`revoked_at`, `id`) instead of a literal `true`; `revoked` is still
      # truthy, so the wire contract this test guards is unchanged.
      assert %{"revoked" => true, "revoked_at" => stamp} =
               self_revoke(raw) |> json_response(200)

      assert is_binary(stamp)

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

      assert %{"revoked" => true} = revoke(admin, %{token: raw}) |> json_response(200)
      assert Auth.verify_token(raw) == {:error, :unauthorized}

      # Idempotent: re-revoking the already-dead token is another 200, not a
      # 404 — a logout retry must never error.
      assert %{"revoked" => true} = revoke(admin, %{token: raw}) |> json_response(200)
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

    test ~s|an EMPTY "token" is a 422 naming the field, not a fall-through|, %{admin: admin} do
      body = revoke(admin, %{token: ""}) |> json_response(422)
      assert body["error"]["message"] =~ ~s("token")
      assert body["error"]["message"] =~ "non-empty"
    end

    test "a body carrying BOTH token and email → 422 (token no longer silently wins)",
         %{admin: admin} do
      ws = create_workspace!()
      email = unique_email()
      raw = mint_app_token(admin, email, ws)

      body = revoke(admin, %{token: raw, email: email}) |> json_response(422)
      assert body["error"]["message"] =~ "exactly one of"

      # NEITHER victim died — the ambiguous body revoked nothing at all.
      assert {:ok, _} = Auth.verify_token(raw)
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

    test "two DISTINCT proxied callers do not share a bucket: A exhausting its allowance leaves B untouched",
         %{admin: admin} do
      email = unique_email()
      caller_a = "203.0.113.7"
      caller_b = "198.51.100.9"

      # Caller A burns its whole 10/min…
      for _ <- 1..10 do
        assert revoke_from(admin, caller_a, %{email: email}) |> json_response(200)
      end

      assert revoke_from(admin, caller_a, %{email: email}) |> json_response(429)

      # …and caller B — a different phone behind the SAME control plane — is
      # completely unaffected. Before the Cloud proxy relayed X-Forwarded-For
      # every proxied revoke keyed on the single Cloud egress IP, so one busy
      # teammate spent the whole team's allowance and the 429 surfaced at the
      # proxy as a misleading 502 instance_unreachable.
      assert revoke_from(admin, caller_b, %{email: email}) |> json_response(200)
    end

    test "a DIRECT caller cannot forge its way out of the bucket: 11 hits, 11 forged IPs, still 429",
         %{admin: admin} do
      email = unique_email()
      # A public peer reaching the endpoint without passing our own front, so its
      # x-forwarded-for carries no authority at all.
      peer = {203, 0, 113, 66}

      for i <- 1..10 do
        assert revoke_direct(admin, peer, "9.9.9.#{i}", %{email: email}) |> json_response(200)
      end

      # A fresh forgery on the 11th hit does NOT buy a fresh allowance: the
      # bucket keyed on the verified peer, not on the header. Restore the old
      # first-hop read (RateLimiter.client_ip/1 → first hop unconditionally) and
      # this is a 200 — every request its own bucket, i.e. no limit at all.
      throttled = revoke_direct(admin, peer, "9.9.9.11", %{email: email}) |> json_response(429)
      assert throttled["error"]["code"] == "rate_limited"
    end

    test "behind a LISTED relay the per-phone bucketing still holds (the #6224 relay keeps working)",
         %{admin: admin} do
      email = unique_email()
      relay = "198.51.100.55"
      original = Application.get_env(:barkpark, :trusted_proxies)
      Application.put_env(:barkpark, :trusted_proxies, [{198, 51, 100, 55}])
      on_exit(fn -> Application.put_env(:barkpark, :trusted_proxies, original || []) end)

      # Phone A burns its whole 10/min through the relay…
      for _ <- 1..10 do
        assert revoke_relayed(admin, "203.0.113.7", relay, %{email: email}) |> json_response(200)
      end

      assert revoke_relayed(admin, "203.0.113.7", relay, %{email: email}) |> json_response(429)

      # …and its teammate on the SAME control plane is untouched: the ORIGINAL
      # first hop is still the bucket key once the relay's egress address is
      # listed. Drop the allowlist entry and both phones collapse onto the
      # relay's own address — the pre-#6224 one-bucket-per-team behaviour.
      assert revoke_relayed(admin, "198.51.100.9", relay, %{email: email}) |> json_response(200)
    end
  end
end
