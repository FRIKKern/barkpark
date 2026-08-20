defmodule BarkparkCloud.Azure.Pricing do
  @moduledoc """
  Real Azure compute prices for the provider-neutral catalog — a sibling of the
  per-credential `BarkparkCloud.Azure.Client` seam, NOT a callback on it. The
  Azure [Retail Prices API](https://prices.azure.com/api/retail/prices) is
  UNAUTHENTICATED and GLOBAL (one price sheet for the whole cloud, not
  per-subscription), so hanging it off the service-principal client would be a
  category error. This module owns its own injectable transport and its own ETS
  cache, and needs no tenant.

  ## What it produces

  `monthly_prices/0` returns a map of `armSkuName => cheapest monthly USD`:

      %{"Standard_D2s_v5" => 64.24, "Standard_B2ts_v2" => 6.13, …}

  `build_provider_catalog("azure", …)` stamps this onto each `vm_size` as
  `monthlyPriceUsd` BEFORE `Registry.AzureCatalog.normalize/2` (which already
  reads that key), so the normalized `server_types[].monthly_price` carries a
  REAL retail figure — parity with Hetzner's per-type price. `monthly` is
  `retailPrice × #{730}` (Azure quotes pay-as-you-go by the hour); per SKU we
  keep the CHEAPEST monthly across every region the SKU is offered in, mirroring
  Hetzner's `cheapest_monthly`.

  ## Honest states — fail closed, degrade to nil, NEVER a 502

  A pricing outage (transport down, no transport configured, malformed page)
  returns the last good cache if any, else `%{}`. `%{}` means enrichment stamps
  nothing, `monthly_price` stays `nil`, and the catalog STILL serves — the price
  cell renders "price unavailable", the menu never 502s. `monthly_prices/0`
  never raises.

  ## Decoys the fixtures MUST carry (or a Spot price silently poses as on-demand)

  The `$filter` restricts the sheet to `serviceName eq 'Virtual Machines' and
  priceType eq 'Consumption'`, but the sheet still mixes:

    * **Spot / Low-Priority** rows (a deep discount that is NOT a stable price) —
      excluded by `meterName`/`skuName` containing "Spot" or "Low Priority".
    * **Windows** rows (carry an OS licence surcharge) — excluded by
      `productName` containing "Windows".

  Both are filtered here defensively, and both live in the test fixtures
  alongside a `NextPageLink` second page so the pagination + exclusion is
  proven, not assumed.

  ## Cache — serve-stale-while-refreshing, demand-triggered (never a timer)

  A GenServer owns ONE public named ETS table, row `{:cache, prices, fetched_at}`,
  ~24h TTL. Reads run in the CALLING process against that public table and split
  three ways off the one row (no shape change — presence distinguishes
  stale-servable from absent):

    * **fresh** → serve the cached sheet, no network;
    * **absent** → nothing to serve, so fetch SYNCHRONOUSLY in the caller — the
      first-ever fetch, and the nil-degrade-on-first-failure contract (an outage
      with no cache is still `%{}`);
    * **stale** → serve the last good sheet IMMEDIATELY and hand ONE refresh to
      the GenServer. An in-flight guard in the GenServer state coalesces
      concurrent stale reads into a single background fetch — no thundering herd
      on the global sheet, and no caller ever waits on a refresh.

  The stale refresh runs the injected transport OUT of the caller (in a task
  under the GenServer), so the test transport is a cross-process collaborator,
  not a per-process stub. `flush/0` blocks until an in-flight refresh settles
  (test determinism); `reset/0` drains any refresh then clears the table.
  Started in every env (credential-free) as an application child.

  ## Transport seam — the third Azure config key

  Resolved at call time from `config :barkpark_cloud, BarkparkCloud.Azure.Pricing,
  http_client: fun/1` — a THIRD key beside `:azure_http_client` (the client-seam
  module) and `{BarkparkCloud.Azure, :http_client}` (the RealClient transport).
  Absent → fail closed (`:http_client_not_configured`), exactly like
  `RealClient.request/1`. Prod wires the same verified-TLS `:httpc` transport
  billing uses; dev/test leave it off (or program a fake) so no byte reaches
  `prices.azure.com` in the suite.
  """
  use GenServer

  @table __MODULE__
  @ttl_ms 24 * 60 * 60 * 1000
  @hours_per_month 730
  # A guard so a pathological (or merely huge) NextPageLink chain can never loop
  # forever. The global VM sheet is large and paginates 100 rows at a time;
  # reaching the cap yields BEST-EFFORT prices (the pages we did fetch), never a
  # hard failure — a slightly-less-optimal "from ~$X/mo" beats nil.
  @max_pages 500

  @base "https://prices.azure.com/api/retail/prices"
  # Pay-as-you-go VM consumption only. USD so the neutral catalog's `currency`
  # ("USD" for azure) is honest. api-version is pinned so `currencyCode` is
  # honoured (it is ignored on the oldest versions).
  @query [
    {"api-version", "2023-01-01-preview"},
    {"currencyCode", "USD"},
    {"$filter", "serviceName eq 'Virtual Machines' and priceType eq 'Consumption'"}
  ]

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    # `refreshing?` is the in-flight guard that coalesces concurrent stale reads
    # into ONE background fetch; `waiters` are `flush/0` callers parked until the
    # in-flight refresh settles.
    {:ok, %{refreshing?: false, waiters: []}}
  end

  @doc """
  Cheapest monthly USD per `armSkuName`, cached ~#{div(@ttl_ms, 3_600_000)}h.

  Serve-stale-while-refreshing, demand-triggered:

    * a FRESH cache is served without touching the network;
    * an ABSENT cache is fetched SYNCHRONOUSLY here (nothing to serve yet — this
      is the first-fetch latency and the nil-degrade-on-first-failure contract);
    * a STALE cache is served IMMEDIATELY and a single background refresh is
      handed to the GenServer (concurrent stale reads coalesce behind its
      in-flight guard).

  On any fetch failure the last good cache wins if present, else `%{}`. Never
  raises — a pricing outage degrades to nil prices, never a broken catalog.
  """
  @spec monthly_prices(integer()) :: %{optional(String.t()) => float()}
  def monthly_prices(now_ms \\ System.system_time(:millisecond)) when is_integer(now_ms) do
    case cached(now_ms) do
      {:fresh, prices} ->
        prices

      {:stale, prices} ->
        # Serve the last good sheet NOW; one demand-triggered refresh in the
        # GenServer freshens it for the next read. Never a timer, never a wait.
        GenServer.cast(__MODULE__, {:refresh, now_ms})
        prices

      :absent ->
        # Nothing cached — fetch synchronously in the caller.
        refresh(now_ms)
    end
  end

  @doc """
  Block until any in-flight background refresh has settled, then return `:ok`.
  Returns immediately when nothing is refreshing. A deterministic barrier for
  the serve-stale path: read across the TTL (serves stale + triggers the
  refresh), `flush/0`, then read again to observe the fresh sheet.
  """
  @spec flush() :: :ok
  def flush, do: GenServer.call(__MODULE__, :flush)

  @doc "Drain any in-flight refresh, then clear the price cache (test determinism only)."
  @spec reset() :: :ok
  def reset do
    if Process.whereis(__MODULE__), do: flush()
    if table?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  ## GenServer — background refresh + in-flight guard ──────────────────────────

  # A prior queued refresh may have already freshened the cache, or one is
  # already running: either way this stale read collapses into it (no thundering
  # herd on prices.azure.com). Otherwise fetch OUT of the GenServer so it stays
  # responsive, and reply to `flush/0` waiters once it settles.
  @impl true
  def handle_cast({:refresh, _now_ms}, %{refreshing?: true} = state), do: {:noreply, state}

  def handle_cast({:refresh, now_ms}, state) do
    case cached(now_ms) do
      {:fresh, _prices} ->
        {:noreply, state}

      _ ->
        server = self()

        # The spawn is unlinked and unmonitored, so if refresh/1 RAISES (inets
        # not started, a cacerts failure, an unforeseen return shape) the
        # completion signal would never fire and `refreshing?` would latch true
        # for the BEAM lifetime — every later stale read short-circuits on the
        # in-flight guard (cache frozen at last-good) and every flush/0 waiter
        # parks. `after` fires the signal on the raising path too; refresh/1 is
        # already fail-closed, so a crash-into-completion is correct here.
        spawn(fn ->
          try do
            _ = refresh(now_ms)
          after
            send(server, :refresh_done)
          end
        end)

        {:noreply, %{state | refreshing?: true}}
    end
  end

  @impl true
  def handle_info(:refresh_done, state) do
    Enum.each(state.waiters, &GenServer.reply(&1, :ok))
    {:noreply, %{state | refreshing?: false, waiters: []}}
  end

  @impl true
  def handle_call(:flush, _from, %{refreshing?: false} = state), do: {:reply, :ok, state}
  def handle_call(:flush, from, state), do: {:noreply, %{state | waiters: [from | state.waiters]}}

  ## Cache ─────────────────────────────────────────────────────────────────────

  defp cached(now_ms) do
    case lookup() do
      {prices, fetched_at} when now_ms - fetched_at < @ttl_ms -> {:fresh, prices}
      {prices, _fetched_at} -> {:stale, prices}
      nil -> :absent
    end
  end

  defp lookup do
    if table?() do
      case :ets.lookup(@table, :cache) do
        [{:cache, prices, fetched_at}] -> {prices, fetched_at}
        _ -> nil
      end
    end
  end

  defp store(prices, now_ms) do
    if table?(), do: :ets.insert(@table, {:cache, prices, now_ms})
    :ok
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  defp refresh(now_ms) do
    case fetch_all() do
      {:ok, items} ->
        prices = cheapest_by_sku(items)
        store(prices, now_ms)
        prices

      {:error, _reason} ->
        # Fail closed: last good cache (even if stale) beats nothing; else empty.
        case lookup() do
          {prices, _fetched_at} -> prices
          nil -> %{}
        end
    end
  end

  ## Fetch (paginated) ─────────────────────────────────────────────────────────

  defp fetch_all, do: fetch_all(initial_url(), [], 0)

  defp fetch_all(nil, acc, _depth), do: {:ok, acc}
  # Cap reached: keep the pages we have (best-effort) rather than throwing them
  # away — cheapest-so-far is a better catalog than a nil price.
  defp fetch_all(_url, acc, depth) when depth >= @max_pages, do: {:ok, acc}

  defp fetch_all(url, acc, depth) do
    case get_json(url) do
      {:ok, %{"Items" => items} = body} when is_list(items) ->
        fetch_all(blank_to_nil(Map.get(body, "NextPageLink")), acc ++ items, depth + 1)

      {:ok, _other} ->
        {:error, :bad_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp initial_url, do: @base <> "?" <> URI.encode_query(@query)

  # Resolve the transport at call time (runtime.exs override wins). Absent →
  # fail closed, exactly like RealClient.request/1 — a pricing fetch can NEVER
  # silently reach the wire without a configured client.
  defp get_json(url) do
    req = %{method: :get, url: url, headers: [{"Accept", "application/json"}], body: ""}

    case http_client() do
      fun when is_function(fun, 1) ->
        case fun.(req) do
          {:ok, %{status: status, body: body}} when status in 200..299 -> decode(body)
          {:ok, %{status: status}} -> {:error, {:http, status}}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :http_client_not_configured}
    end
  end

  defp http_client, do: Application.get_env(:barkpark_cloud, __MODULE__, [])[:http_client]

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :bad_payload}
    end
  end

  defp decode(_), do: {:error, :bad_payload}

  ## Reduce ────────────────────────────────────────────────────────────────────

  # Join is direct equality on `armSkuName` (== server_type slug); we keep the
  # cheapest monthly per SKU across every `armRegionName` it is offered in.
  defp cheapest_by_sku(items) do
    Enum.reduce(items, %{}, fn item, acc ->
      with true <- on_demand_linux_vm?(item),
           {:ok, slug} <- sku_slug(item),
           {:ok, monthly} <- monthly(item) do
        Map.update(acc, slug, monthly, &min(&1, monthly))
      else
        _ -> acc
      end
    end)
  end

  # Exclude the decoys the $filter can't: Spot/Low-Priority (a discount, not a
  # stable rate) and Windows (OS-licence surcharge). Require a positive
  # retailPrice so a zero-priced free meter can't pose as the cheapest.
  defp on_demand_linux_vm?(item) when is_map(item) do
    not spot_or_low?(Map.get(item, "meterName")) and
      not spot_or_low?(Map.get(item, "skuName")) and
      not windows?(Map.get(item, "productName"))
  end

  defp on_demand_linux_vm?(_), do: false

  defp spot_or_low?(s) when is_binary(s) do
    down = String.downcase(s)
    String.contains?(down, "spot") or String.contains?(down, "low priority")
  end

  defp spot_or_low?(_), do: false

  defp windows?(s) when is_binary(s), do: String.contains?(String.downcase(s), "windows")
  defp windows?(_), do: false

  defp sku_slug(%{"armSkuName" => slug}) when is_binary(slug) and slug != "", do: {:ok, slug}
  defp sku_slug(_), do: :error

  defp monthly(%{"retailPrice" => hourly}) when is_number(hourly) and hourly > 0 do
    {:ok, Float.round(hourly * @hours_per_month * 1.0, 2)}
  end

  defp monthly(_), do: :error

  defp blank_to_nil(s) when is_binary(s) and s != "", do: s
  defp blank_to_nil(_), do: nil
end
