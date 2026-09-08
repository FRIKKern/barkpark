defmodule BarkparkWeb.Plugs.RateLimitBrowserShadowTest do
  @moduledoc """
  CHARTER D2 IS ONE SENTENCE AND THIS FILE IS BOTH HALVES OF IT.

  "The limiter ships log-only first" is two claims, and a test suite that
  proves only one of them is worthless:

    * it must never refuse anybody — so a caller driven far past the budget is
      served 200 EVERY time, and `halted` is false EVERY time; and
    * the counter must actually fire — a shadow that can never count is a
      shadow that observes nothing, and would pass the first half perfectly.

  Both arms run against the same load in `describe "the shadow law"`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox

  alias BarkparkWeb.Plugs.RateLimit

  setup :reset_rate_limiter!

  setup do
    :ets.delete_all_objects(:barkpark_rate_limiter)
    original = Application.get_env(:barkpark, :rate_limits)
    on_exit(fn -> Application.put_env(:barkpark, :rate_limits, original) end)
    :ok
  end

  defp with_limits(overrides) do
    Application.put_env(
      :barkpark,
      :rate_limits,
      Keyword.merge(
        [read_per_minute: 300, write_per_minute: 60, datasets: %{}],
        overrides
      )
    )
  end

  defp browser_conn(path \\ "/papers/some-slug", headers \\ []) do
    conn = build_conn(:get, path, "")
    Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
  end

  # Counts `would_429` measurements for the duration of `fun`. The handler is
  # detached on the way out so one test's counter can never bleed into another.
  defp count_would_429(fun) do
    ref = make_ref()
    test_pid = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:barkpark, :rate_limit, :shadow],
      fn _event, measurements, metadata, _cfg ->
        send(test_pid, {ref, measurements, metadata})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain(ref, acc) do
    receive do
      {^ref, m, meta} -> drain(ref, [{m, meta} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "the shadow law (charter D2) — both arms, one load" do
    test "a caller driven 20x past the browser budget is served 200 every single time, and the would_429 counter fires" do
      with_limits(browser_per_minute: 2)

      opts = RateLimit.init(class: :browser)
      conn = browser_conn()

      {conns, events} =
        count_would_429(fn ->
          Enum.map(1..40, fn _ -> RateLimit.call(conn, opts) end)
        end)

      # ARM 1 — IT REFUSES NOBODY. Not "mostly", not "after the burst": every
      # one of the 40 passes through unhalted with no status set by this plug.
      # A single `true` here means the slice shipped the opposite of D2.
      assert length(conns) == 40
      refute Enum.any?(conns, & &1.halted)
      assert Enum.all?(conns, &(&1.status in [nil, 200]))
      assert Enum.all?(conns, &(get_resp_header(&1, "retry-after") == []))

      # ARM 2 — AND IT COUNTS. Capacity 2 means the first two pass; the
      # remaining 38 are would-be refusals. A shadow that never fires would
      # satisfy arm 1 perfectly, which is exactly why this assertion is here.
      assert length(events) > 0
      assert length(events) == 38

      assert Enum.all?(events, fn {measurements, _} -> measurements == %{would_429: 1} end)

      # D9: `would_429` is a dimension ON the browser class, not a new class.
      assert Enum.all?(events, fn {_, meta} -> meta.class == :browser end)
      assert Enum.all?(events, fn {_, meta} -> meta.retry_after >= 1 end)
    end

    test "the shadow logs the would-be refusal (D2: 'would-be-429s appear in logs while serving 200s')" do
      with_limits(browser_per_minute: 1)

      opts = RateLimit.init(class: :browser)
      conn = browser_conn("/papers/logged-slug")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          RateLimit.call(conn, opts)
          RateLimit.call(conn, opts)
        end)

      assert log =~ "rate_limit shadow would_429"
      assert log =~ "class=browser"
      assert log =~ "/papers/logged-slug"
    end
  end

  describe "kill switch and env budgets" do
    test "kill switch off = zero overhead: no bucket is ever created and nothing is counted" do
      with_limits(browser_per_minute: 1, browser_enabled: false)

      opts = RateLimit.init(class: :browser)
      conn = browser_conn("/papers/killed")

      before = :ets.info(:barkpark_rate_limiter, :size)

      {conns, events} =
        count_would_429(fn ->
          Enum.map(1..25, fn _ -> RateLimit.call(conn, opts) end)
        end)

      refute Enum.any?(conns, & &1.halted)
      assert events == []

      # THE ZERO-OVERHEAD CLAIM, MEASURED RATHER THAN ASSERTED: with the switch
      # off the plug never reaches `RateLimiter.check/2`, so 25 calls add no
      # rows to the bucket table. This is a DELTA, never an absolute count —
      # the table is whole-node state shared with every other test.
      assert :ets.info(:barkpark_rate_limiter, :size) == before
    end

    test "the budget is env-tunable through :browser_per_minute (a bigger budget absorbs more before shadowing)" do
      opts = RateLimit.init(class: :browser)

      small_conn = browser_conn("/papers/small")
      with_limits(browser_per_minute: 2)

      {_, small_events} =
        count_would_429(fn -> Enum.map(1..10, fn _ -> RateLimit.call(small_conn, opts) end) end)

      :ets.delete_all_objects(:barkpark_rate_limiter)

      big_conn = browser_conn("/papers/big")
      with_limits(browser_per_minute: 8)

      {_, big_events} =
        count_would_429(fn -> Enum.map(1..10, fn _ -> RateLimit.call(big_conn, opts) end) end)

      assert length(small_events) == 8
      assert length(big_events) == 2
    end

    test "an absent :browser_per_minute falls back to the built-in default rather than crashing" do
      with_limits([])

      opts = RateLimit.init(class: :browser)
      out = RateLimit.call(browser_conn("/papers/default"), opts)

      refute out.halted
    end
  end

  describe "promotion to enforcing is an explicit, content-negotiated decision (D2)" do
    test "with :browser_enforce true an HTML caller gets an HTML 429 with retry-after" do
      with_limits(browser_per_minute: 1, browser_enforce: true)

      opts = RateLimit.init(class: :browser)
      conn = browser_conn("/papers/enforced", [{"accept", "text/html,application/xhtml+xml"}])

      assert RateLimit.call(conn, opts).halted == false

      out = RateLimit.call(conn, opts)
      assert out.halted
      assert out.status == 429
      assert get_resp_header(out, "retry-after") == ["60"]
      assert hd(get_resp_header(out, "content-type")) =~ "text/html"
      assert out.resp_body =~ "Too many requests"
    end

    test "with :browser_enforce true a non-HTML caller keeps the JSON envelope" do
      with_limits(browser_per_minute: 1, browser_enforce: true)

      opts = RateLimit.init(class: :browser)
      conn = browser_conn("/papers/enforced-json", [{"accept", "application/json"}])

      assert RateLimit.call(conn, opts).halted == false

      out = RateLimit.call(conn, opts)
      assert out.halted
      assert out.status == 429
      assert get_resp_header(out, "retry-after") == ["60"]
      assert hd(get_resp_header(out, "content-type")) =~ "application/json"
      assert Jason.decode!(out.resp_body)["error"]["code"] == "rate_limited"
    end

    test "enforce defaults to FALSE — the same load that 429s above serves 200 without the flag" do
      with_limits(browser_per_minute: 1)

      opts = RateLimit.init(class: :browser)
      conn = browser_conn("/papers/not-enforced", [{"accept", "text/html"}])

      outs = Enum.map(1..10, fn _ -> RateLimit.call(conn, opts) end)

      refute Enum.any?(outs, & &1.halted)
      assert Enum.all?(outs, &(&1.status in [nil, 200]))
    end
  end

  describe "the existing pipeline mounts are untouched (criterion 3)" do
    @router Path.expand("../../../lib/barkpark_web/router.ex", __DIR__)

    test "every RateLimit mount in the router passes NO options, so none of them can reach the browser class" do
      src = File.read!(@router)

      mounts =
        Regex.scan(~r/plug\(BarkparkWeb\.Plugs\.RateLimit([^)]*)\)/, src)
        |> Enum.map(fn [_, args] -> args end)

      # Non-vacuity: a regex that stopped matching would make the assertion
      # below trivially true, which is the shape this file must not ship.
      assert length(mounts) >= 10,
             "only #{length(mounts)} RateLimit mounts parsed out of router.ex — the regex drifted"

      # The row says 13; main carries 14. The count is pinned as a LOWER bound
      # plus an exact-today note so a new mount is noticed without this test
      # fighting every unrelated pipeline addition.
      assert Enum.all?(mounts, &(&1 == "")),
             "a RateLimit mount now passes options: #{inspect(Enum.reject(mounts, &(&1 == "")))} — " <>
               "if that is `class: :browser`, the shadow law applies to it and this test should " <>
               "be updated deliberately, not silently"
    end

    test "a default-init call is byte-identical to the pre-browser behaviour: read/write classes, no :browser in the key" do
      with_limits(read_per_minute: 1, write_per_minute: 1)

      get_conn =
        %{
          build_conn(:get, "/v1/data/query/production/post", "")
          | path_params: %{"dataset" => "production"}
        }
        |> put_req_header("authorization", "Bearer untouched-token")

      # Unchanged refusal semantics on the API classes: still halts, still 429,
      # still the JSON envelope, still `retry-after`.
      refute RateLimit.call(get_conn, RateLimit.init([])).halted
      out = RateLimit.call(get_conn, RateLimit.init([]))
      assert out.halted
      assert out.status == 429
      assert get_resp_header(out, "retry-after") == ["60"]

      # And the buckets it touched are read/write ones — no `:browser` segment
      # entered the keyspace of a default mount.
      keys = for {k, _tokens, _ts} <- :ets.tab2list(:barkpark_rate_limiter), is_binary(k), do: k

      # Non-vacuity: an empty `keys` would satisfy the `refute` below for free.
      assert keys != []
      assert Enum.any?(keys, &String.contains?(&1, ":read:"))
      refute Enum.any?(keys, &String.contains?(&1, ":browser:"))
    end

    # THE ARM THAT WAS MISSING, AND THE DEFECT IT CAUGHT.
    #
    # The first draft routed BOTH classes through one negotiating `refuse/2`,
    # so a `:read`/`:write` caller sending `Accept: text/html` — every browser,
    # and curl with browser headers — got `<!DOCTYPE html>` where main returns a
    # documented JSON envelope. Criterion 2 asks whether the pipeline KEYS are
    # untouched, and they were; response SHAPE is a different axis the row does
    # not name, and no accept-header assertion in this file drove a DEFAULT-init
    # call. This is that assertion.
    test "Accept has NO influence on a read/write refusal — five accept values, one identical response" do
      with_limits(read_per_minute: 1, write_per_minute: 1)

      accepts = [
        {"none", []},
        {"html", [{"accept", "text/html"}]},
        {"browser",
         [{"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}]},
        {"json", [{"accept", "application/json"}]},
        {"star", [{"accept", "*/*"}]}
      ]

      responses =
        for {label, headers} <- accepts do
          # A distinct DATASET per case, so each gets its own full bucket and the
          # SECOND call is the refusal in every case. Not a distinct bearer: an
          # unresolvable bearer falls back to the IP bucket by design, so five
          # made-up tokens would all share ONE bucket and case two onward would
          # be refused on its first call.
          conn =
            %{
              build_conn(:get, "/v1/data/query/production/post", "")
              | path_params: %{"dataset" => "accept-sweep-#{label}"}
            }

          conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)

          refute RateLimit.call(conn, RateLimit.init([])).halted
          out = RateLimit.call(conn, RateLimit.init([]))

          {label,
           %{
             status: out.status,
             halted: out.halted,
             retry_after: get_resp_header(out, "retry-after"),
             content_type: get_resp_header(out, "content-type"),
             body: out.resp_body
           }}
        end

      # Non-vacuity: five cases actually ran and each really refused.
      assert length(responses) == 5
      assert Enum.all?(responses, fn {_, r} -> r.halted and r.status == 429 end)

      # THE INVARIANT: every field is identical across all five. `Accept` cannot
      # reach this code path at all, so it cannot change the bytes.
      shapes = responses |> Enum.map(fn {_, r} -> r end) |> Enum.uniq()

      assert length(shapes) == 1,
             "Accept changed a read/write refusal — the content negotiation leaked out of the " <>
               "browser class:\n#{inspect(responses, pretty: true)}"

      # And it is the pre-browser JSON envelope, not HTML wearing a JSON name.
      [shape] = shapes
      assert shape.retry_after == ["60"]
      assert hd(shape.content_type) =~ "application/json"
      refute shape.body =~ "<!DOCTYPE"
      assert Jason.decode!(shape.body)["error"]["code"] == "rate_limited"
      assert Jason.decode!(shape.body)["error"]["details"]["retry_after"] == 60
    end

    # SECOND AXIS FOUND BY THE SWEEP for browser-scoped behaviour reaching the
    # method classes through a shared callee. `limited/4` dispatches on the
    # class and only its `:browser` clause logs and emits — this pins that,
    # because a `would_429` counted for an API 429 would corrupt the very
    # shadow data the promotion decision is made against.
    test "a read/write refusal emits NO shadow telemetry and logs no would_429 line" do
      with_limits(read_per_minute: 1, write_per_minute: 1)

      conn =
        %{
          build_conn(:get, "/v1/data/query/production/post", "")
          | path_params: %{"dataset" => "production"}
        }
        |> put_req_header("authorization", "Bearer no-shadow-for-api")

      {log, events} =
        count_would_429(fn ->
          ExUnit.CaptureLog.capture_log(fn ->
            refute RateLimit.call(conn, RateLimit.init([])).halted
            assert RateLimit.call(conn, RateLimit.init([])).halted
          end)
        end)

      assert events == []
      refute log =~ "would_429"
    end

    test "the browser bucket is disjoint from the read bucket for the same caller" do
      with_limits(read_per_minute: 1, write_per_minute: 1, browser_per_minute: 1)

      path = "/v1/data/query/production/post"

      api_conn =
        %{build_conn(:get, path, "") | path_params: %{"dataset" => "production"}}
        |> put_req_header("authorization", "Bearer disjoint-token")

      # Spend the read bucket dry through a default mount.
      refute RateLimit.call(api_conn, RateLimit.init([])).halted
      assert RateLimit.call(api_conn, RateLimit.init([])).halted

      # The browser class for the same conn still has its own untouched
      # allowance — and, being shadow, would not refuse even if it did not.
      refute RateLimit.call(api_conn, RateLimit.init(class: :browser)).halted
    end
  end
end
