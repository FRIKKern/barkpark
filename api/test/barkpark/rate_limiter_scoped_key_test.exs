defmodule Barkpark.RateLimiterScopedKeyTest do
  @moduledoc """
  `RateLimiter.scoped_key/2` — the ONE place a bucket key learns the per-test
  scope, and the fix for a suite that throttled itself.

  Two properties, and BOTH have to hold or the change is not shippable:

    * PRODUCTION IS UNTOUCHED. No request outside `test/` ever carries
      `:barkpark_rate_limit_scope`, so the helper must return the key it was
      handed, byte-identical, whenever no scope is set. Asserted on the exact
      key shapes all eight `check/2` call sites build.
    * TWO TEST PROCESSES NO LONGER SHARE A BUCKET. The revoke bucket
      (`{:app_token_revoke, ip}`) was keyed on `127.0.0.1` in every test, so
      under `--max-cases 8` parallel cases billed one 10/min budget and the
      eleventh request anywhere in the run 429'd — the random red on the
      required Elixir gate.

  The second property is proven three ways so a green here cannot be vacuous:
  the SAME scope still shares (the limiter still limits), a DIFFERENT scope does
  not (the fix), and `ConnCase.scoped_conn/0` really does mint a different scope
  in a different process (the premise the first two rest on).
  """
  use ExUnit.Case, async: false

  import Barkpark.RateLimiterSandbox

  setup :reset_rate_limiter!

  alias Barkpark.RateLimiter

  @scope_key :barkpark_rate_limit_scope

  defp conn_with(scope) do
    conn = Phoenix.ConnTest.build_conn()
    if scope, do: Plug.Conn.put_private(conn, @scope_key, scope), else: conn
  end

  # Every key shape in the tree, so "unchanged in production" is asserted over
  # the real inputs and not a stand-in.
  @call_site_keys [
    {:app_token_revoke, "203.0.113.7"},
    {:auth_write, :register, "203.0.113.7"},
    {:bulldocs_form, "203.0.113.7"},
    {:pulse, "203.0.113.7", "ops"},
    {:pulse_read, "203.0.113.7", "ops"},
    {:ticket, "key-abc", :create},
    "socket:connect:ip:203.0.113.7",
    "ip:203.0.113.7:write:global"
  ]

  describe "production behaviour is byte-identical when no scope is set" do
    test "an unscoped conn returns every call site's key unchanged" do
      conn = conn_with(nil)

      for key <- @call_site_keys do
        assert RateLimiter.scoped_key(conn, key) === key,
               "#{inspect(key)} was rewritten for a conn carrying no scope — that is a " <>
                 "PRODUCTION key change, not a test seam"
      end
    end

    test "a non-binary scope is ignored rather than trusted" do
      # Defence in depth: `conn.private` is ours, but a nil/atom/integer value
      # must degrade to the production key, never crash and never key on
      # `inspect/1` of whatever was there.
      for junk <- [nil, :not_a_scope, 7, %{}] do
        conn = Plug.Conn.put_private(Phoenix.ConnTest.build_conn(), @scope_key, junk)
        assert RateLimiter.scoped_key(conn, {:app_token_revoke, "1.2.3.4"}) ===
                 {:app_token_revoke, "1.2.3.4"}
      end
    end

    test "a source that is neither a conn nor a map returns the key unchanged" do
      assert RateLimiter.scoped_key(nil, {:pulse, "1.2.3.4", "ops"}) ===
               {:pulse, "1.2.3.4", "ops"}

      assert RateLimiter.scoped_key(%URI{}, "ip:1.2.3.4:read:global") ===
               "ip:1.2.3.4:read:global"
    end
  end

  describe "the suffix shape" do
    test "a string key keeps the exact suffix Plugs.RateLimit.bucket_key/3 appended" do
      # This is the shape that shipped before the helper existed. If it changed,
      # every already-scoped bucket on the :api surface would silently move.
      assert RateLimiter.scoped_key(conn_with("42"), "ip:1.2.3.4:write:global") ==
               "ip:1.2.3.4:write:global:test:42"
    end

    test "a tuple key grows a trailing {:test, scope} and stays a tuple" do
      assert RateLimiter.scoped_key(conn_with("42"), {:app_token_revoke, "1.2.3.4"}) ==
               {:app_token_revoke, "1.2.3.4", {:test, "42"}}
    end

    test "connect_info — the socket handshake, which has no conn at all" do
      info = %{@scope_key => "42", peer_data: %{address: {127, 0, 0, 1}}}

      assert RateLimiter.scoped_key(info, "socket:connect:ip:127.0.0.1") ==
               "socket:connect:ip:127.0.0.1:test:42"

      assert RateLimiter.scoped_key(%{peer_data: %{}}, "socket:connect:token:t1") ==
               "socket:connect:token:t1"
    end
  end

  describe "C3: a 429 inside an auth-verdict assertion names the limiter" do
    # The guard `media_flat_decayed_bearer_test.exs` and
    # `require_token_write_gate_test.exs` call before every status assertion. If
    # it went vacuous, a throttled response would resume arriving dressed as
    # "TENANT SWAP BY CREDENTIAL DECAY" or "OVER-REACH".
    test "it raises on a 429, naming the limiter and refusing the tempting fixes" do
      throttled = %{
        Phoenix.ConnTest.build_conn()
        | status: 429,
          resp_body: ~s({"error":{"code":"rate_limited","message":"slow down"}})
      }

      err =
        assert_raise RuntimeError, fn ->
          BarkparkWeb.ConnCase.refute_rate_limited!(throttled)
        end

      # The three things a reader needs and a bare `assert status == 401` hides.
      assert err.message =~ "429"
      assert err.message =~ "rate_limited"
      assert err.message =~ "Barkpark.RateLimiter"
      assert err.message =~ "scoped_conn/0"
      assert err.message =~ "NOT a tenant swap"
      assert err.message =~ "Do NOT raise a limit"
    end

    test "it reports an unparseable body rather than crashing on it" do
      throttled = %{Phoenix.ConnTest.build_conn() | status: 429, resp_body: "<html>429</html>"}

      err =
        assert_raise RuntimeError, fn ->
          BarkparkWeb.ConnCase.refute_rate_limited!(throttled)
        end

      assert err.message =~ "<unparseable body>"
    end

    test "it is a pass-through for every non-429 response" do
      # It must NOT swallow or rewrite the statuses the verdict assertions read.
      for status <- [200, 201, 401, 403, 404, 500] do
        conn = %{Phoenix.ConnTest.build_conn() | status: status, resp_body: "{}"}
        assert BarkparkWeb.ConnCase.refute_rate_limited!(conn) == conn
      end
    end
  end

  describe "MUTATION: two test processes no longer share the revoke bucket" do
    # The real bucket options from AppTokenController (@revoke_bucket_capacity).
    @revoke_opts [capacity: 10, refill_per_sec: 10 / 60]

    defp burn_revoke(conn, n) do
      for _ <- 1..n do
        RateLimiter.check(
          RateLimiter.scoped_key(conn, {:app_token_revoke, "127.0.0.1"}),
          @revoke_opts
        )
      end
    end

    test "the limiter STILL limits: two conns in ONE test process share their bucket" do
      # scoped_conn/0 is per test PROCESS, not per call — so a test can still
      # prove a limit binds. If this went green-by-separation the fix would have
      # disarmed every 429 assertion in the suite.
      a = conn_with("proc-a")
      b = conn_with("proc-a")

      assert Enum.all?(burn_revoke(a, 10), &(&1 == :ok))

      assert RateLimiter.check(
               RateLimiter.scoped_key(b, {:app_token_revoke, "127.0.0.1"}),
               @revoke_opts
             ) == :rate_limited
    end

    test "a DIFFERENT scope is untouched by a neighbour that spent its whole budget" do
      spender = conn_with("proc-a")
      neighbour = conn_with("proc-b")

      assert Enum.all?(burn_revoke(spender, 10), &(&1 == :ok))

      assert RateLimiter.check(
               RateLimiter.scoped_key(spender, {:app_token_revoke, "127.0.0.1"}),
               @revoke_opts
             ) == :rate_limited

      # RED WITHOUT THE FIX: on origin/main `revoke_rate_limited?/1` built
      # `{:app_token_revoke, client_ip(conn)}` with no scope at all, so both
      # conns produced the IDENTICAL key and this assertion returned
      # :rate_limited. That is the random main red, reproduced in one test.
      assert RateLimiter.check(
               RateLimiter.scoped_key(neighbour, {:app_token_revoke, "127.0.0.1"}),
               @revoke_opts
             ) == :ok
    end

    test "PREMISE: scoped_conn/0 mints a different scope in a different process" do
      # The two tests above model "another test process" as "another scope".
      # That model is only sound if ConnCase actually behaves this way.
      mine = BarkparkWeb.ConnCase.rate_limit_test_scope()
      theirs = Task.async(fn -> BarkparkWeb.ConnCase.rate_limit_test_scope() end) |> Task.await()

      assert is_binary(mine) and is_binary(theirs)
      refute mine == theirs

      # …and memoised WITHIN a process, which is what makes the 429 assertions
      # in app_token_revoke_test.exs and bulldocs_form_controller_test.exs
      # keep working.
      assert BarkparkWeb.ConnCase.rate_limit_test_scope() == mine
    end
  end
end
