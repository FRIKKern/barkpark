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

  ## Cache — the `TwoFactorRateLimiter` shape

  A GenServer whose only job is to own ONE public named ETS table; all logic
  runs in the CALLING process against that table (so the injected transport runs
  in the caller and a test can program it per-process). One row
  `{:cache, prices, fetched_at}` with a ~24h TTL. Started in every env
  (credential-free) as an application child. `reset/0` clears the table for test
  determinism.

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
    {:ok, %{}}
  end

  @doc """
  Cheapest monthly USD per `armSkuName`, cached ~#{div(@ttl_ms, 3_600_000)}h.
  Serves a fresh cache without touching the network; on a stale/absent cache it
  fetches (following `NextPageLink`), reduces to the cheapest monthly per SKU,
  caches, and returns. On ANY fetch failure it returns the last good cache if
  present, else `%{}`. Never raises — a pricing outage degrades to nil prices,
  never a broken catalog.
  """
  @spec monthly_prices(integer()) :: %{optional(String.t()) => float()}
  def monthly_prices(now_ms \\ System.system_time(:millisecond)) when is_integer(now_ms) do
    case cached(now_ms) do
      {:fresh, prices} -> prices
      :stale_or_missing -> refresh(now_ms)
    end
  end

  @doc "Clear the price cache (test determinism only)."
  @spec reset() :: :ok
  def reset do
    if table?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  ## Cache ─────────────────────────────────────────────────────────────────────

  defp cached(now_ms) do
    case lookup() do
      {prices, fetched_at} when now_ms - fetched_at < @ttl_ms -> {:fresh, prices}
      _ -> :stale_or_missing
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
