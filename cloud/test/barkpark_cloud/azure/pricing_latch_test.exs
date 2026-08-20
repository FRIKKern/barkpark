defmodule BarkparkCloud.Azure.PricingLatchTest do
  @moduledoc """
  Regression proof for the unmonitored background-refresh latch in
  `BarkparkCloud.Azure.Pricing` (ccpca-w1-pricing-spawn-latch).

  The demand-triggered stale refresh runs in an UNLINKED, UNMONITORED `spawn`.
  Before the fix its body was `_ = refresh(now_ms); send(server, :refresh_done)`:
  if `refresh/1` RAISES (inets not started, a cacerts failure, an unforeseen
  return shape), the completion signal never fires and the GenServer's
  `refreshing?` guard latches `true` for the whole BEAM lifetime —

    * `handle_info(:refresh_done)` never clears the guard;
    * every later stale read casts `{:refresh, _}`, hits the
      `%{refreshing?: true}` short-circuit clause, and the cache FREEZES at the
      last-good sheet;
    * every `flush/0` waiter parks forever (its `GenServer.call` times out).

  The fix wraps the spawned body in `try/after` so `:refresh_done` is sent even
  on the raising path (`refresh/1` is already fail-closed, so completing-through
  a crash is correct — this GenServer must not die on a fetch failure).

  MUTATION PROOF: with the `try/after` REVERTED to the bare
  `send(server, :refresh_done)`, the LATCH arm's `flush/0` never returns — the
  `GenServer.call` times out and the test fails. With the fix it returns `:ok`
  and the frozen cache thaws. Both arms drive the transport through the
  runtime config seam (`config :barkpark_cloud, Pricing, http_client: fun/1`),
  swapping the injected function to stage a good sheet, an ordinary transport
  error, and a RAISING transport in turn.

  `async: false` — it mutates the shared ETS price cache and the global
  transport config, and resets both around every test.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias BarkparkCloud.Azure.Pricing

  @ttl_ms 24 * 60 * 60 * 1000

  # One-page sheets, priced so the reduction is unambiguous: retailPrice × 730.
  #   0.096 → 70.08   (the primed "good" sheet)
  #   0.05  → 36.5    (the cheaper sheet a later refresh must pick up)
  defp sheet(price) do
    ~s({"Items":[
      {"armSkuName":"Standard_D2s_v5","armRegionName":"eastus","retailPrice":#{price},
       "meterName":"D2s v5","skuName":"D2s v5","productName":"Virtual Machines Dsv5 Series",
       "serviceName":"Virtual Machines","type":"Consumption","currencyCode":"USD"}]})
  end

  defp good_client, do: fn _req -> {:ok, %{status: 200, body: sheet(0.096)}} end
  defp cheaper_client, do: fn _req -> {:ok, %{status: 200, body: sheet(0.05)}} end
  defp error_client, do: fn _req -> {:error, :timeout} end

  # Announces the call to `pid` (deterministic proof the transport ran) THEN
  # raises, so the raise is on the demand-triggered refresh's code path.
  defp raising_client(pid) do
    fn _req ->
      send(pid, :transport_raised)
      raise "azure pricing transport exploded"
    end
  end

  defp put_client(fun), do: Application.put_env(:barkpark_cloud, Pricing, http_client: fun)

  setup do
    Pricing.reset()
    prev = Application.get_env(:barkpark_cloud, Pricing)

    on_exit(fn ->
      Application.put_env(:barkpark_cloud, Pricing, prev)
      Pricing.reset()
    end)

    :ok
  end

  describe "background refresh — completion signal always fires" do
    test "CONTROL: an ordinary {:error, _} refresh settles cleanly, flush returns :ok, and a later good sheet is picked up" do
      # Prime the cache synchronously (absent → fetch in the caller).
      put_client(good_client())
      assert Pricing.monthly_prices(0)["Standard_D2s_v5"] == 70.08

      # A stale read past the TTL serves stale NOW and hands ONE refresh to the
      # GenServer. That refresh hits an ordinary transport error — fail-closed,
      # keeps the last-good sheet, and settles the in-flight guard.
      put_client(error_client())
      assert Pricing.monthly_prices(@ttl_ms + 1)["Standard_D2s_v5"] == 70.08
      assert Pricing.flush() == :ok

      # The guard is clear, so a subsequent good refresh is NOT short-circuited:
      # a cheaper sheet lands and the next read serves it fresh.
      put_client(cheaper_client())
      assert Pricing.monthly_prices(@ttl_ms + 2)["Standard_D2s_v5"] == 70.08
      assert Pricing.flush() == :ok
      assert Pricing.monthly_prices(@ttl_ms + 3)["Standard_D2s_v5"] == 36.5
    end

    test "LATCH: a RAISING refresh no longer latches refreshing? — flush returns :ok and the cache thaws" do
      # Prime a good sheet.
      put_client(good_client())
      assert Pricing.monthly_prices(0)["Standard_D2s_v5"] == 70.08

      # The refresh RAISES. WITHOUT the fix, :refresh_done never fires and this
      # flush parks forever (GenServer.call times out → this test fails). WITH
      # the fix, the try/after sends :refresh_done on the raising path, so the
      # guard clears and flush returns :ok. The spawned process still dies (an
      # unlinked crash, harmless to the GenServer) — capture its log so the
      # green run stays quiet.
      test_pid = self()

      capture_log(fn ->
        put_client(raising_client(test_pid))
        assert Pricing.monthly_prices(@ttl_ms + 1)["Standard_D2s_v5"] == 70.08
        assert Pricing.flush() == :ok
      end)

      # The refresh really invoked the raising transport (proof is non-vacuous:
      # the flush above settled DESPITE a raise, not because none happened).
      assert_received :transport_raised

      # The cache is NOT frozen: a later good sheet is fetched and served fresh.
      put_client(cheaper_client())
      assert Pricing.monthly_prices(@ttl_ms + 2)["Standard_D2s_v5"] == 70.08
      assert Pricing.flush() == :ok
      assert Pricing.monthly_prices(@ttl_ms + 3)["Standard_D2s_v5"] == 36.5
    end
  end
end
