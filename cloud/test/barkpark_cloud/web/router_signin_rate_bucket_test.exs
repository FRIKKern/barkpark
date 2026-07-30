defmodule BarkparkCloud.Web.RouterSigninRateBucketTest do
  @moduledoc """
  CCH-D5 — the sign-in rate bucket must be PER CLIENT, not per proxy peer.

  The defect: `POST /v1/auth/device/start` buckets on `peer_ip(conn)`, and behind
  the Caddy loopback front the raw peer is always the same hop — so every user
  behind the front door shared ONE bucket and a single noisy client locked out
  everyone. The root fix (`:trust_forwarded_ip` rewriting `conn.remote_ip` from
  X-Forwarded-For when, and only when, the actual peer is trusted) landed in
  8fd00b6afb; this file is the measurement it never had.

  WHAT IS ALREADY MEASURED ELSEWHERE, AND IS NOT WHAT THIS FILE OWNS:

    * `device_auth_test.exs` — "distinct keys have independent budgets" proves the
      ETS layer keys correctly. It calls `RateLimiter.check/1` directly, so it is
      blind to WHICH key the router hands it.
    * `router_test.exs` — the "front door" describe block proves
      `:trust_forwarded_ip` resolves `conn.remote_ip` from X-Forwarded-For for a
      trusted peer and ignores it for an untrusted one. It reads `conn.remote_ip`
      on `GET /up`; it never reaches a rate bucket.

  What NEITHER covers, and what is asserted here, is the COMPOSITION —
  `trust_forwarded_ip` → `conn.remote_ip` → `peer_ip/1` → `"start:" <> ip` →
  `RateLimiter.check/1` — observed through a real `Router.call/2` at the only
  place a user feels it: the HTTP status. Collapse the bucket key in the route to
  a constant and both halves above stay green while every user shares one budget
  again; the tests below are what goes red.

  `Plug.Test` defaults `remote_ip` to `{127,0,0,1}`, a trusted loopback peer, so
  X-Forwarded-For is honored here with no struct surgery — the same peer shape the
  app sees behind Caddy.

  `async: false` and `RateLimiter.reset/0` on both edges: the limiter's ETS table
  is node-global, so a concurrent test spending the same bucket would make these
  budgets non-deterministic.
  """
  use BarkparkCloud.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.DeviceAuth.RateLimiter
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  # The 10/60s `start:` budget, from RateLimiter's @limits. Read here as a literal
  # rather than from the module so a limit change has to face this test.
  @start_limit 10

  setup do
    RateLimiter.reset()
    on_exit(&RateLimiter.reset/0)
    :ok
  end

  # One sign-in start as it arrives behind the front door: a loopback peer
  # (Plug.Test's default) carrying the real client address in X-Forwarded-For.
  defp start_from(client_ip) do
    conn(:post, "http://localhost:4100/v1/auth/device/start", Jason.encode!(%{client_name: "bp"}))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-forwarded-for", client_ip)
    |> Router.call(@opts)
  end

  describe "sign-in rate bucket is keyed per forwarded client address" do
    test "one client exhausting its budget does not rate-limit a different client" do
      for i <- 1..@start_limit do
        conn = start_from("203.0.113.5")
        assert conn.status == 200, "start #{i} from 203.0.113.5 expected 200, got #{conn.status}"
      end

      tripped = start_from("203.0.113.5")
      assert tripped.status == 429
      assert Jason.decode!(tripped.resp_body)["error"] == "rate_limited"

      # THE CLAIM. A second client, arriving through the same loopback front at the
      # moment the first is locked out, is unaffected. Pre-fix (and under a
      # collapsed bucket key) this is a 429 for a client that has never called.
      other = start_from("198.51.100.7")

      assert other.status == 200,
             "a second client behind the same front got #{other.status} — the bucket is shared"
    end

    test "the second client keeps its OWN full budget, not the first client's remainder" do
      for _ <- 1..(@start_limit + 1), do: start_from("203.0.113.5")
      assert start_from("203.0.113.5").status == 429

      # Not merely "the next call is 200": a shared bucket that happened to have one
      # hit left would pass that. The second client must own the WHOLE window.
      for i <- 1..@start_limit do
        conn = start_from("198.51.100.7")
        assert conn.status == 200, "start #{i} from 198.51.100.7 expected 200, got #{conn.status}"
      end

      # …and its own budget is still enforced — separate buckets, not no bucket.
      tripped = start_from("198.51.100.7")
      assert tripped.status == 429
      assert Jason.decode!(tripped.resp_body)["error"] == "rate_limited"
    end
  end
end
