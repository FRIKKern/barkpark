defmodule BarkparkCloud.Web.RouterRegisterRateBucketTest do
  @moduledoc """
  arpss wave 3 — POST /v1/auth/register grows TWO defenses this file measures at
  the only place a client feels them: the HTTP status and, for the oracle, the
  exact response BYTES.

  1. PER-IP RATE BUCKET. The handler was an unauthenticated account-creation
     write with no limiter — a signup flood minted user→team→membership→trial
     rows unbounded. It now spends `"register:"<peer_ip>` (30/60s) through the
     shared `DeviceAuth.RateLimiter`, keyed on the forwarded client address.
     Asserted through a real `Router.call/2`: a burst from one client trips 429
     at the limit while a SECOND client (different X-Forwarded-For) keeps its own
     full budget. Collapse the bucket key to a constant, or delete the check, and
     the second-client assertion goes red. The bucket counts EVERY request (the
     check precedes body validation), so the burst below uses cheap invalid-
     password bodies — proving the meter brakes probes, not just successful
     signups, without 31 bcrypt hashes.

  2. THE 409 ENUMERATION ORACLE, CLOSED BY REORDER. A password-format 422 gate
     now runs BEFORE the duplicate-email lookup, so an EXISTING email + an INVALID
     password answers 422 byte-for-byte like a FRESH email + the same invalid
     password. Pre-fix, existing→409 and fresh→422 let a probe read account
     existence off the status code for free. The 409 email_taken is PRESERVED for
     the case a real signup needs it: a duplicate carrying a VALID password.

  `async: false` + `RateLimiter.reset/0` on both edges: the limiter's ETS table
  is node-global, so a concurrent test spending the same bucket would make these
  budgets non-deterministic. `Plug.Test` defaults `remote_ip` to `{127,0,0,1}`, a
  trusted loopback peer, so X-Forwarded-For is honored with no struct surgery —
  the same peer shape the app sees behind Caddy's `:trust_forwarded_ip` front.
  """
  use BarkparkCloud.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.DeviceAuth.RateLimiter
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  # The 30/60s `register:` budget, from RateLimiter's @limits. Read here as a
  # literal so a limit change has to face this test.
  @register_limit 30

  @valid_password "correct-horse-battery"
  @short_password "short"

  setup do
    RateLimiter.reset()
    on_exit(&RateLimiter.reset/0)
    :ok
  end

  # One register attempt arriving behind the front door: a loopback peer carrying
  # the real client address in X-Forwarded-For. `body` lets a caller send a cheap
  # invalid payload (to spend the bucket without a bcrypt) or a real signup.
  defp register_from(client_ip, body) do
    conn(:post, "http://localhost:4100/v1/auth/register", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-forwarded-for", client_ip)
    |> Router.call(@opts)
  end

  defp fresh_email, do: "reg-#{System.unique_integer([:positive])}@example.com"

  describe "register rate bucket is keyed per forwarded client address" do
    test "one client exhausting its budget does not rate-limit a different client" do
      # Cheap invalid-password bodies: each still spends the bucket (the check
      # runs before validation), so we exhaust 30 without 30 bcrypt hashes.
      for i <- 1..@register_limit do
        conn = register_from("203.0.113.5", %{email: fresh_email(), password: @short_password})
        assert conn.status != 429, "attempt #{i} from 203.0.113.5 tripped 429 early (#{conn.status})"
      end

      tripped = register_from("203.0.113.5", %{email: fresh_email(), password: @short_password})
      assert tripped.status == 429
      assert Jason.decode!(tripped.resp_body)["error"] == "rate_limited"

      # THE CLAIM. A second client, arriving through the same loopback front while
      # the first is locked out, is unaffected. Pre-fix (no bucket) or under a
      # collapsed key this is a 429 for a client that has never called.
      other = register_from("198.51.100.7", %{email: fresh_email(), password: @short_password})

      assert other.status != 429,
             "a second client behind the same front got 429 — the bucket is shared"
    end

    test "the second client keeps its OWN full budget, not the first client's remainder" do
      for _ <- 1..(@register_limit + 1),
          do: register_from("203.0.113.5", %{email: fresh_email(), password: @short_password})

      assert register_from("203.0.113.5", %{email: fresh_email(), password: @short_password}).status ==
               429

      # Not merely "the next call is not 429": a shared bucket with one hit left
      # would pass that. The second client must own the WHOLE window.
      for i <- 1..@register_limit do
        conn = register_from("198.51.100.7", %{email: fresh_email(), password: @short_password})
        assert conn.status != 429, "attempt #{i} from 198.51.100.7 tripped 429 (#{conn.status})"
      end

      # …and its own budget is still enforced — a separate bucket, not no bucket.
      tripped = register_from("198.51.100.7", %{email: fresh_email(), password: @short_password})
      assert tripped.status == 429
      assert Jason.decode!(tripped.resp_body)["error"] == "rate_limited"
    end
  end

  describe "the 409 email-enumeration oracle is closed" do
    test "existing email + invalid password is 422 byte-identical to fresh email + invalid password" do
      taken = fresh_email()
      {:ok, _user} = Accounts.register_user(%{email: taken, password: @valid_password})

      existing = register_from("203.0.113.10", %{email: taken, password: @short_password})
      fresh = register_from("203.0.113.11", %{email: fresh_email(), password: @short_password})

      # The seal: an attacker probing with an invalid password learns NOTHING —
      # same status AND same bytes whether or not the address is registered.
      assert existing.status == 422
      assert fresh.status == 422
      assert existing.resp_body == fresh.resp_body
      assert Jason.decode!(existing.resp_body)["error"] == "password_invalid"
    end

    test "a duplicate email carrying a VALID password still answers 409 email_taken" do
      taken = fresh_email()
      {:ok, _user} = Accounts.register_user(%{email: taken, password: @valid_password})

      conn = register_from("203.0.113.12", %{email: taken, password: @valid_password})

      # PRESERVED: the honest "this address is already registered" a real signup
      # needs. app.js maps {error:"email_taken"} → the friendly copy; the Go
      # client_test.go pins this body. Only reachable with a VALID password, so it
      # is not an existence oracle (a probe would need to guess the password too).
      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["error"] == "email_taken"
    end

    test "a fresh email + valid password still registers (201) — the gate is inert on good input" do
      conn = register_from("203.0.113.13", %{email: fresh_email(), password: @valid_password})
      assert conn.status == 201
      assert is_binary(Jason.decode!(conn.resp_body)["token"])
    end
  end

  describe "register bucket window rollover (clock-injected, RateLimiter.check/2)" do
    test "the window rolls over: the next 60s window starts a fresh register budget" do
      key = "register:203.0.113.20"
      w0 = 100 * 60_000
      w1 = 101 * 60_000

      for _ <- 1..@register_limit, do: assert(RateLimiter.check(key, w0) == :ok)
      assert {:error, :rate_limited} = RateLimiter.check(key, w0)

      # A timestamp in the NEXT window is a clean slate — this fails if the sweep
      # or the window key math regresses to a global rather than per-window count.
      for _ <- 1..@register_limit, do: assert(RateLimiter.check(key, w1) == :ok)
      assert {:error, :rate_limited} = RateLimiter.check(key, w1)
    end

    test "the register limit is 30, distinct from the push_register (10) bucket" do
      w = 200 * 60_000
      # 30 pass on register:…
      for _ <- 1..@register_limit, do: assert(RateLimiter.check("register:ip-a", w) == :ok)
      assert {:error, :rate_limited} = RateLimiter.check("register:ip-a", w)

      # push_register:… is a DIFFERENT bucket with the default-ish 10 budget — the
      # shared "register" substring must not collapse the two keys.
      for _ <- 1..10, do: assert(RateLimiter.check("push_register:user-a", w) == :ok)
      assert {:error, :rate_limited} = RateLimiter.check("push_register:user-a", w)
    end
  end
end
