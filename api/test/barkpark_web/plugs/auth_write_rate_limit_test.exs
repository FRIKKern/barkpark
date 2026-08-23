defmodule BarkparkWeb.Plugs.AuthWriteRateLimitTest do
  @moduledoc """
  Pins the register-specific per-IP throttle on `POST /v1/auth/register`.

  THE CLAIM UNDER TEST (wave 2, anon-register-unauth-write): register is an
  unauthenticated write that mails a THIRD PARTY on every call — a confirmation
  mail for a fresh address, a re-notification for an address that already exists.
  Before this plug it was metered only by the shared 60/min anonymous-write
  bucket, which is both the wrong order of magnitude for mail (60/min = 3600
  mails/hour) and shared, so a register flood 429'd every other anonymous write
  from the same IP.

  So it now bills its own per-IP, per-HOUR bucket at a default ceiling of
  **5/hour/IP** (`BARKPARK_AUTH_RATE_REGISTER`). This file proves the ceiling by
  MUTATION: it lowers the budget, drives the real route until it 429s, and shows
  the general write bucket on the same IP is untouched in BOTH directions.

  Gating registration BEYOND a throttle (invite codes, a domain allowlist,
  closing open signup) is the instance owner's policy call and is deliberately
  not implemented or asserted here.

  NOTE ON THE SUITE-WIDE VALUE: config/test.exs sets the register budget
  effectively-off, because the limiter's ETS bucket is process-global with an
  hourly refill and the whole suite's anonymous registers share the 127.0.0.1
  bucket. Every test here therefore sets its OWN budget and its OWN unique client
  IP — a test that forgot to would be measuring the 1_000_000 default and passing
  vacuously.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox

  # `:barkpark_rate_limiter` is a :named_table — WHOLE-NODE state no sandbox owns
  # and nothing used to reset, so a bucket one test spent stayed spent for the
  # rest of the run. Start from an unspent table.
  setup :reset_rate_limiter!

  alias BarkparkWeb.Plugs.{AuthWriteRateLimit, RateLimit}

  @password "correct-horse-battery"

  setup do
    original = Application.get_env(:barkpark, :auth_write_rate_limits)
    on_exit(fn -> Application.put_env(:barkpark, :auth_write_rate_limits, original) end)
    :ok
  end

  defp with_register_limit(n),
    do: Application.put_env(:barkpark, :auth_write_rate_limits, register: n)

  # The RateLimiter table is process-global and outlives each test, so every test
  # bills a UNIQUE client IP. These are 10.x addresses: NOT loopback, therefore
  # not a trusted proxy, so `client_ip/1` ignores x-forwarded-for and keys on the
  # peer — the address below is exactly the bucket identity.
  defp unique_ip do
    n = System.unique_integer([:positive])
    {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}
  end

  defp from(ip), do: %{build_conn() | remote_ip: ip}

  defp run(conn), do: AuthWriteRateLimit.call(conn, AuthWriteRateLimit.init([]))

  defp register(ip, email) do
    from(ip)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/auth/register", Jason.encode!(%{email: email, password: @password}))
  end

  describe "the ceiling" do
    test "the shipped default is 5 registers per hour per IP" do
      # Independent of config/test.exs's effectively-off override: with no config
      # row at all, the plug's own default is the number that ships.
      Application.put_env(:barkpark, :auth_write_rate_limits, [])
      assert AuthWriteRateLimit.limit_for(:register) == 5
    end

    test "the ceiling is config-driven, so BARKPARK_AUTH_RATE_REGISTER moves it" do
      with_register_limit(17)
      assert AuthWriteRateLimit.limit_for(:register) == 17
    end

    test "an unknown class falls back to the strictest known budget, never to unmetered" do
      Application.put_env(:barkpark, :auth_write_rate_limits, [])
      assert AuthWriteRateLimit.limit_for(:some_future_auth_write) == 5
    end
  end

  describe "the bucket" do
    test "the N+1th register from one IP is denied with the RateLimit envelope + Retry-After" do
      with_register_limit(3)
      ip = unique_ip()

      for _ <- 1..3, do: refute(run(from(ip)).halted)

      denied = run(from(ip))
      assert denied.halted
      assert denied.status == 429

      # ceil(3600 / 3) = 1200s to earn one token back from empty.
      assert Plug.Conn.get_resp_header(denied, "retry-after") == ["1200"]

      body = Jason.decode!(denied.resp_body)
      assert body["error"]["code"] == "rate_limited"
      assert body["error"]["details"]["retry_after"] == 1200
    end

    test "distinct IPs get distinct buckets" do
      with_register_limit(1)
      a = unique_ip()
      b = unique_ip()

      refute run(from(a)).halted
      assert run(from(a)).halted

      # b's budget is untouched by a's flood.
      refute run(from(b)).halted
    end

    test "the register bucket and the general anon-write bucket are independent" do
      with_register_limit(1)
      ip = unique_ip()

      # Exhaust the register bucket for this IP...
      refute run(from(ip)).halted
      assert run(from(ip)).halted

      # ...the general anon-write bucket for the SAME IP is unspent: a register
      # flood cannot starve the other anonymous writes.
      general = from(ip) |> Map.put(:method, "POST")
      refute RateLimit.call(general, RateLimit.init([])).halted
    end

    test "exhausting the general anon-write bucket does not spend the register bucket" do
      original = Application.get_env(:barkpark, :rate_limits)
      on_exit(fn -> Application.put_env(:barkpark, :rate_limits, original) end)

      Application.put_env(:barkpark, :rate_limits,
        read_per_minute: 300,
        write_per_minute: 1,
        datasets: %{}
      )

      with_register_limit(5)
      ip = unique_ip()

      general = fn -> from(ip) |> Map.put(:method, "POST") end
      refute RateLimit.call(general.(), RateLimit.init([])).halted
      assert RateLimit.call(general.(), RateLimit.init([])).halted

      # The register budget is a different key entirely — still full.
      refute run(from(ip)).halted
    end
  end

  describe "through the live route" do
    test "N successful registers, then the N+1th POST /v1/auth/register 429s" do
      with_register_limit(2)
      ip = unique_ip()

      assert json_response(register(ip, "rl-one@example.com"), 201)
      assert json_response(register(ip, "rl-two@example.com"), 201)

      denied = register(ip, "rl-three@example.com")
      body = json_response(denied, 429)

      assert body["error"]["code"] == "rate_limited"
      # ceil(3600 / 2) = 1800s.
      assert body["error"]["details"]["retry_after"] == 1800
      assert Plug.Conn.get_resp_header(denied, "retry-after") == ["1800"]

      # The throttled request never reached the controller: no user, and so no
      # confirmation mail — the mailbomb is bounded at the ceiling.
      refute Barkpark.Accounts.get_user_by_email("rl-three@example.com")
    end

    test "a tripped register bucket does not 429 the other anonymous auth writes" do
      with_register_limit(1)
      ip = unique_ip()

      assert json_response(register(ip, "rl-solo@example.com"), 201)
      assert json_response(register(ip, "rl-blocked@example.com"), 429)

      # Same IP, same `:user_auth` pipeline, a route that does NOT ride the
      # register throttle: it must still be served (401 for bad credentials —
      # anything but 429), proving the tighter bucket is register-only.
      login =
        from(ip)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/v1/auth/login",
          Jason.encode!(%{email: "rl-solo@example.com", password: "wrong-password"})
        )

      assert login.status != 429
    end
  end
end
