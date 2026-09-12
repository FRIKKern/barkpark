defmodule BarkparkWeb.Plugs.RateLimitEnvCeilingTest do
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox

  @moduledoc """
  THE READ CEILING IS DRIVEN BY `BARKPARK_RATE_LIMIT_READ`, END TO END.

  The remedy this pins is an OPS action, not a merge: raise the shared ledger
  read ceiling by setting one env var and restarting. That is only safe if the
  lever is real, so this file proves the whole chain in one run — and proves it
  on the REAL files, never on a re-implementation of their arithmetic.

  ## The chain, and why it needs two legs

      BARKPARK_RATE_LIMIT_READ
        --(leg A)--> config :barkpark, :rate_limits, read_per_minute: N
        --(leg B)--> bucket capacity N, refill N/60 per sec, 429 at N+1

  THE TRAP THAT MAKES A ONE-LEG TEST LIE. `api/config/runtime.exs` is a
  Config script evaluated at BOOT — by the release's config provider, or by
  `mix` before the application starts. `mix test` has already resolved it
  before the first test line runs. So a test that calls
  `System.put_env("BARKPARK_RATE_LIMIT_READ", ...)` and then issues a request
  observes NOTHING, and passing that test would prove the opposite of what it
  claims. Leg A therefore does not set an env var and hope: it re-runs the
  real boot evaluation, `Config.Reader.read!/2` on `config/runtime.exs` with
  `env: :prod`, which is the same module a release's `Config.Reader` provider
  uses on the same file. That is the mechanism, not a stand-in for it.

  THE SEAM BETWEEN THE LEGS IS NAMED, NOT PAPERED OVER. Leg A ends with the
  keyword list `runtime.exs` passes to `config :barkpark, :rate_limits`
  (runtime.exs, `rate_limits =` -> `config :barkpark, :rate_limits`). Leg B
  begins by putting THAT LIST, verbatim and unedited, into the application
  environment — which is precisely what the `config/2` call does at boot. The
  one thing this file cannot do in-process is re-run OTP's config application,
  and `Application.put_env/3` is its exact equivalent for a single key. Leg B
  then goes through the production plug, `BarkparkWeb.Plugs.RateLimit.call/2`,
  which re-reads that key on EVERY request
  (`limit_per_minute/2` -> `Application.get_env(:barkpark, :rate_limits, [])`),
  so no restart is simulated away.

  THE THIRD ARM IS THE POINT. A lever that moves the number but stops refusing
  anybody is worse than the cap it replaces. So every capacity assertion here
  is paired with a refusal at N+1, INCLUDING at the raised ceiling.
  """

  alias BarkparkWeb.Plugs.RateLimit

  setup :reset_rate_limiter!

  # The env `runtime.exs` needs before it reaches the rate-limit block at all.
  # Every one of these is a `raise` in the `config_env() == :prod` branch;
  # none of them is a secret, and none is read by anything this test asserts.
  # If runtime.exs grows another mandatory prod var, this list grows and the
  # failure names it verbatim — that is a feature, not a maintenance tax.
  @prod_env_stub %{
    "DATABASE_URL" => "ecto://u:p@localhost/barkpark_rate_limit_env_ceiling_test",
    "SECRET_KEY_BASE" => String.duplicate("k", 96),
    "PHX_HOST" => "rate-limit-env-ceiling.test.invalid",
    "PREVIEW_JWT_SECRET" => String.duplicate("p", 64),
    "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET" => String.duplicate("h", 64),
    "BARKPARK_CLOAK_KEY" => Base.encode64(String.duplicate("c", 32)),
    "BARKPARK_KEK" => Base.encode64(String.duplicate("k", 32))
  }

  @lever "BARKPARK_RATE_LIMIT_READ"

  setup do
    saved =
      Map.new([@lever, "BARKPARK_RATE_LIMIT_WRITE" | Map.keys(@prod_env_stub)], fn k ->
        {k, System.get_env(k)}
      end)

    saved_limits = Application.get_env(:barkpark, :rate_limits)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      Application.put_env(:barkpark, :rate_limits, saved_limits)
    end)

    Enum.each(@prod_env_stub, fn {k, v} -> System.put_env(k, v) end)
    System.delete_env(@lever)
    System.delete_env("BARKPARK_RATE_LIMIT_WRITE")
    :ok
  end

  # LEG A, the real boot evaluation. `Application.get_env(:barkpark,
  # :rate_limits, [])` is read INSIDE runtime.exs as its fallback base, and in
  # a release that read sees the compiled config. So the compiled base is
  # installed first — taken from `config/config.exs` itself, through the same
  # reader, rather than from whatever the running test VM happens to hold.
  defp compiled_base do
    Config.Reader.read!("config/config.exs", env: :prod, target: :host)[:barkpark][:rate_limits]
  end

  defp boot_rate_limits do
    Application.put_env(:barkpark, :rate_limits, compiled_base())

    Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)[:barkpark][:rate_limits]
  end

  # LEG B. The bucket key the plug builds for a `scoped_conn/0` GET with no
  # resolvable principal: `bucket_key/3` -> "ip:<client_ip>:read:global",
  # suffixed by `RateLimiter.scoped_key/2` with this test's own scope.
  defp read_bucket_key, do: "ip:127.0.0.1:read:global:test:" <> rate_limit_test_scope()

  defp get_conn do
    scoped_conn()
    |> Map.put(:method, "GET")
    |> Map.put(:path_params, %{})
  end

  defp admit?(conn), do: not RateLimit.call(conn, RateLimit.init([])).halted

  # How many consecutive GETs are admitted before the first refusal, bounded so
  # a broken limiter fails as a wrong NUMBER instead of hanging.
  defp admitted_before_refusal(conn, bound) do
    Enum.reduce_while(0..bound, 0, fn _, n ->
      if admit?(conn), do: {:cont, n + 1}, else: {:halt, n}
    end)
  end

  # Rewind the bucket's `last_ms` so the limiter credits exactly
  # `seconds * refill_per_sec` tokens on the next call — a DETERMINISTIC read
  # of the refill rate. Sleeping for real would make the refill assertion a
  # timing race; the ETS row {key, tokens, last_ms} is the limiter's whole
  # state (rate_limiter.ex, `debit/4`), and moving its clock back is the only
  # way to observe a rate without waiting for one.
  defp rewind_bucket!(key, seconds) do
    [{^key, tokens, last_ms}] = :ets.lookup(:barkpark_rate_limiter, key)
    true = :ets.insert(:barkpark_rate_limiter, {key, tokens, last_ms - seconds * 1000})
    :ok
  end

  describe "leg A — BARKPARK_RATE_LIMIT_READ drives config :barkpark, :rate_limits" do
    test "both arms in one run: unset is the compiled default, set is the set value" do
      base = compiled_base()
      compiled_read = Keyword.fetch!(base, :read_per_minute)
      compiled_write = Keyword.fetch!(base, :write_per_minute)

      # Guard against a vacuous run: if the compiled default already equalled
      # the raised value below, the two arms could not be told apart.
      raised = compiled_read * 4
      refute raised == compiled_read

      # ARM 1 — the lever is unset. The boot value IS the compiled default.
      assert System.get_env(@lever) == nil
      unset = boot_rate_limits()

      assert Keyword.fetch!(unset, :read_per_minute) == compiled_read,
             "with #{@lever} unset, runtime.exs must fall back to the compiled base"

      # ARM 2 — the lever is set to a DIFFERENT value. The boot value follows it.
      System.put_env(@lever, Integer.to_string(raised))
      set = boot_rate_limits()

      assert Keyword.fetch!(set, :read_per_minute) == raised,
             "#{@lever}=#{raised} must reach config :barkpark, :rate_limits"

      # The READ lever moves the READ ceiling only. If this ever reds, the two
      # env vars have been crossed and an ops raise of reads would silently
      # raise writes too.
      assert Keyword.fetch!(set, :write_per_minute) == compiled_write
    end
  end

  describe "leg B — the config value drives capacity, refill and the refusal" do
    test "capacity and refill track read_per_minute, and N+1 is still refused" do
      for per_minute <- [8, 24] do
        :ets.delete_all_objects(:barkpark_rate_limiter)

        Application.put_env(:barkpark, :rate_limits,
          read_per_minute: per_minute,
          write_per_minute: 60,
          datasets: %{}
        )

        conn = get_conn()

        # CAPACITY == read_per_minute: exactly N admitted, then refused.
        assert admitted_before_refusal(conn, per_minute + 5) == per_minute,
               "capacity must equal read_per_minute=#{per_minute}"

        denied = RateLimit.call(conn, RateLimit.init([]))
        assert denied.halted and denied.status == 429

        # REFILL == read_per_minute / 60 per second: crediting 30 seconds must
        # buy exactly half a minute's budget — no more, no less.
        rewind_bucket!(read_bucket_key(), 30)

        assert admitted_before_refusal(conn, per_minute) == div(per_minute, 2),
               "refill must be read_per_minute/60 per sec (30s buys #{div(per_minute, 2)})"
      end
    end
  end

  describe "the seam — env var to a live refusal, one run, no rebuild" do
    test "a caller over the RAISED ceiling is still refused" do
      base = compiled_base()
      compiled_read = Keyword.fetch!(base, :read_per_minute)
      raised = compiled_read * 4

      # LEG A produces the boot config...
      System.put_env(@lever, Integer.to_string(raised))
      boot = boot_rate_limits()
      assert Keyword.fetch!(boot, :read_per_minute) == raised

      # ...and LEG B consumes it VERBATIM. This put_env is the in-process
      # equivalent of runtime.exs's own `config :barkpark, :rate_limits, ...`;
      # nothing between the two lines edits the value.
      :ets.delete_all_objects(:barkpark_rate_limiter)
      Application.put_env(:barkpark, :rate_limits, boot)

      conn = get_conn()

      assert admitted_before_refusal(conn, raised + 5) == raised,
             "the raised ceiling must admit exactly #{raised} reads"

      denied = RateLimit.call(conn, RateLimit.init([]))

      assert denied.halted, "THE LEVER MUST STILL REFUSE: read ##{raised + 1} was admitted"
      assert denied.status == 429

      body = Jason.decode!(denied.resp_body)
      assert body["error"]["code"] == "rate_limited"

      # retry_after = ceil(60 / per_minute) (rate_limit.ex, retry_after_seconds/1),
      # so a raised ceiling still hands the caller a bounded, honest wait —
      # which is what every consumer's backoff is supposed to read.
      assert [retry_after] = Plug.Conn.get_resp_header(denied, "retry-after")
      assert retry_after == "1"
      assert body["error"]["details"]["retry_after"] == 1
    end

    test "the plug re-reads the ceiling per request — no restart is simulated away" do
      :ets.delete_all_objects(:barkpark_rate_limiter)
      Application.put_env(:barkpark, :rate_limits, read_per_minute: 2, write_per_minute: 60)
      conn = get_conn()

      assert admitted_before_refusal(conn, 8) == 2

      # A FULL MINUTE'S REFILL, UNDER THE OLD CEILING, BUYS THE OLD CEILING.
      # `debit/4` credits `min(capacity, tokens + elapsed * refill)`, so this is
      # the ceiling itself being read back out of the bucket.
      rewind_bucket!(read_bucket_key(), 60)
      assert admitted_before_refusal(conn, 8) == 2

      # Now raise it, with NO restart, NO new conn, NO new bucket. The same
      # minute of refill must now buy the NEW ceiling — which it can only do if
      # `limit_per_minute/2` re-read `config :barkpark, :rate_limits` on this
      # request rather than closing over the value at boot.
      Application.put_env(:barkpark, :rate_limits, read_per_minute: 10, write_per_minute: 60)
      rewind_bucket!(read_bucket_key(), 60)
      assert admitted_before_refusal(conn, 16) == 10

      # WORTH SAYING OUT LOUD FOR THE OPS ACTION: raising the ceiling does NOT
      # retroactively refill a bucket that is already drained — a drained
      # bucket holds 0 tokens and `capacity` only caps the refill, it does not
      # grant it. The caller waits out one refill interval either way. The
      # restart the env-var change requires empties the ETS table anyway, so
      # this costs an operator nothing in practice; it would matter to anyone
      # trying to raise the ceiling live without one.
      Application.put_env(:barkpark, :rate_limits, read_per_minute: 300, write_per_minute: 60)
      refute admit?(conn), "a drained bucket is not refilled by raising the ceiling alone"
    end
  end

  # A guard on the reader itself. `Config.Reader.read!/2` is only evidence if
  # it is actually evaluating the file that carries the lever; if runtime.exs
  # ever stops reading the env var, leg A above reds — and if this file ever
  # stops mentioning it, this reds first and says so.
  test "runtime.exs is the file under test and still reads the lever" do
    source = File.read!("config/runtime.exs")
    assert String.contains?(source, @lever)
    assert String.contains?(source, "config :barkpark, :rate_limits, rate_limits")
  end
end
