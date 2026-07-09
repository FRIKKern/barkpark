defmodule BarkparkCloud.AzurePricingTest do
  @moduledoc """
  The credential-free Azure Retail Prices client (S7a):

    * follows `NextPageLink`, reduces to the CHEAPEST monthly USD per SKU across
      every region it is offered in (`retailPrice × 730`)
    * excludes the decoys the OData `$filter` can't — Spot/Low-Priority (a
      discount) and Windows (an OS-licence surcharge) — proven with those rows
      in the fixtures, so a Spot price can never silently pose as on-demand
    * caches ~24h and re-fetches only once the window elapses
    * fails CLOSED — a transport error or an unconfigured client degrades to the
      last good cache, else `%{}`; it NEVER raises
    * enriches the neutral azure catalog IN `build_provider_catalog/2`: a real
      price lands on the matching server_type; a pricing OUTAGE leaves the
      catalog serving (200) with the price it already had — never the 502
      `catalog_unavailable`

  async: false — it mutates the shared ETS price cache and the global transport
  config, and resets both around every test.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Azure.Pricing
  alias BarkparkCloud.AzureRetailPricingFakeHttpClient, as: Fake
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # Two-page retail sheet. Page 1 carries the decoys (a Spot row and a Windows
  # row for D2s_v5) + a NextPageLink; page 2 carries the CHEAPER D2s_v5 region
  # and a Low-Priority B2ts_v2 decoy. Correct reduction:
  #   Standard_D2s_v5 → min(0.096, 0.088) × 730 = 64.24  (Spot 0.01 / Windows 0.20 excluded)
  #   Standard_B2ts_v2 → 0.0084 × 730 = 6.13             (Low-Priority 0.001 excluded)
  @page1 ~s({"Items":[
    {"armSkuName":"Standard_D2s_v5","armRegionName":"eastus","retailPrice":0.096,
     "meterName":"D2s v5","skuName":"D2s v5","productName":"Virtual Machines Dsv5 Series",
     "serviceName":"Virtual Machines","type":"Consumption","currencyCode":"USD"},
    {"armSkuName":"Standard_D2s_v5","armRegionName":"eastus","retailPrice":0.01,
     "meterName":"D2s v5 Spot","skuName":"D2s v5 Spot","productName":"Virtual Machines Dsv5 Series",
     "serviceName":"Virtual Machines","type":"Consumption","currencyCode":"USD"},
    {"armSkuName":"Standard_D2s_v5","armRegionName":"eastus","retailPrice":0.20,
     "meterName":"D2s v5","skuName":"D2s v5","productName":"Virtual Machines Dsv5 Series Windows",
     "serviceName":"Virtual Machines","type":"Consumption","currencyCode":"USD"},
    {"armSkuName":"Standard_B2ts_v2","armRegionName":"eastus","retailPrice":0.0084,
     "meterName":"B2ts v2","skuName":"B2ts v2","productName":"Virtual Machines B Series",
     "serviceName":"Virtual Machines","type":"Consumption","currencyCode":"USD"}
  ],"NextPageLink":"https://prices.azure.com/api/retail/prices?$skip=100"})

  @page2 ~s({"Items":[
    {"armSkuName":"Standard_D2s_v5","armRegionName":"westeurope","retailPrice":0.088,
     "meterName":"D2s v5","skuName":"D2s v5","productName":"Virtual Machines Dsv5 Series",
     "serviceName":"Virtual Machines","type":"Consumption","currencyCode":"USD"},
    {"armSkuName":"Standard_B2ts_v2","armRegionName":"westeurope","retailPrice":0.001,
     "meterName":"B2ts v2 Low Priority","skuName":"B2ts v2 Low Priority",
     "productName":"Virtual Machines B Series","serviceName":"Virtual Machines",
     "type":"Consumption","currencyCode":"USD"}
  ]})

  setup do
    Pricing.reset()
    prev = Application.get_env(:barkpark_cloud, Pricing)
    Application.put_env(:barkpark_cloud, Pricing, http_client: &Fake.request/1)

    on_exit(fn ->
      Application.put_env(:barkpark_cloud, Pricing, prev)
      Pricing.reset()
    end)

    :ok
  end

  defp ok200(body), do: {:ok, %{status: 200, body: body}}

  describe "monthly_prices/1 — paginate, reduce cheapest, exclude decoys" do
    test "follows NextPageLink and keeps the cheapest monthly per SKU across regions" do
      Fake.program([ok200(@page1), ok200(@page2)])

      assert Pricing.monthly_prices(0) == %{
               "Standard_D2s_v5" => 64.24,
               "Standard_B2ts_v2" => 6.13
             }

      # Both pages were fetched (the NextPageLink was followed).
      assert length(Fake.requests()) == 2
    end

    test "the first request carries the VM-consumption $filter and USD currency" do
      Fake.program([ok200(~s({"Items":[]}))])
      Pricing.monthly_prices(0)

      [%{url: url} | _] = Fake.requests()
      assert url =~ "prices.azure.com/api/retail/prices"
      assert url =~ URI.encode_www_form("serviceName eq 'Virtual Machines'")
      assert url =~ "priceType"
      assert url =~ "currencyCode=USD"
    end

    test "Spot / Low-Priority / Windows rows never win (decoys excluded)" do
      Fake.program([ok200(@page1), ok200(@page2)])
      prices = Pricing.monthly_prices(0)

      # Spot 0.01 → 7.3 and Windows 0.20 → 146.0 would both shift D2s_v5 if kept.
      assert prices["Standard_D2s_v5"] == 64.24
      # Low-Priority 0.001 → 0.73 would shift B2ts_v2 if kept.
      assert prices["Standard_B2ts_v2"] == 6.13
    end
  end

  describe "cache (~24h TTL)" do
    test "a second call inside the window serves the cache without re-fetching" do
      Fake.program([ok200(@page1), ok200(@page2)])
      first = Pricing.monthly_prices(0)

      # Re-arm with an EMPTY queue (also resets the request log). A cached read
      # must not touch the transport at all.
      Fake.program([])
      assert Pricing.monthly_prices(1_000) == first
      assert Fake.requests() == []
    end

    test "past the TTL, serve-stale: the stale value now, the fresh sheet on the next read" do
      Fake.program([ok200(@page1), ok200(@page2)])
      assert Pricing.monthly_prices(0)["Standard_D2s_v5"] == 64.24

      # A cheaper sheet, one page, that a background refresh will pick up.
      cheaper = ~s({"Items":[
        {"armSkuName":"Standard_D2s_v5","armRegionName":"eastus","retailPrice":0.05,
         "meterName":"D2s v5","skuName":"D2s v5","productName":"Virtual Machines Dsv5 Series",
         "serviceName":"Virtual Machines","type":"Consumption","currencyCode":"USD"}]})

      Fake.program([ok200(cheaper)])
      ttl_ms = 24 * 60 * 60 * 1000

      # The read that crosses the TTL serves the STALE value immediately and hands
      # ONE demand-triggered refresh to the GenServer — the caller never waits.
      assert Pricing.monthly_prices(ttl_ms + 1)["Standard_D2s_v5"] == 64.24

      # Drain that background refresh deterministically (no sleeps).
      assert Pricing.flush() == :ok

      # The next read now sees the freshly-fetched, cheaper sheet.
      assert Pricing.monthly_prices(ttl_ms + 2)["Standard_D2s_v5"] == 36.5
    end

    test "concurrent stale reads coalesce into ONE background refresh (in-flight guard)" do
      Fake.program([ok200(@page1), ok200(@page2)])
      assert Pricing.monthly_prices(0)["Standard_D2s_v5"] == 64.24

      # A single fresh one-page sheet for the refresh; the request log resets here.
      cheaper = ~s({"Items":[
        {"armSkuName":"Standard_D2s_v5","armRegionName":"eastus","retailPrice":0.05,
         "meterName":"D2s v5","skuName":"D2s v5","productName":"Virtual Machines Dsv5 Series",
         "serviceName":"Virtual Machines","type":"Consumption","currencyCode":"USD"}]})

      Fake.program([ok200(cheaper)])
      ttl_ms = 24 * 60 * 60 * 1000

      # Two stale reads at the same instant each serve stale and each hand a
      # refresh to the GenServer. The in-flight guard (and the cache re-check)
      # collapse them into a SINGLE fetch — no thundering herd. The GenServer is
      # SUSPENDED across the two reads so the refresh provably cannot land
      # between them (without this, a fast background fetch could freshen the
      # cache before the second read and flake the 64.24 assertion) — both casts
      # queue, and on resume the guard sees them back-to-back: the worst case
      # for coalescing.
      :ok = :sys.suspend(Pricing)
      assert Pricing.monthly_prices(ttl_ms + 1)["Standard_D2s_v5"] == 64.24
      assert Pricing.monthly_prices(ttl_ms + 1)["Standard_D2s_v5"] == 64.24
      :ok = :sys.resume(Pricing)
      assert Pricing.flush() == :ok

      # Exactly one page was fetched. A second refresh would pop the now-empty
      # queue and record a second request — so a count of 1 proves coalescing.
      assert length(Fake.requests()) == 1
      assert Pricing.monthly_prices(ttl_ms + 2)["Standard_D2s_v5"] == 36.5
    end
  end

  describe "fail closed — degrade to nil, never raise" do
    test "a transport error with no cache → %{}" do
      Fake.program([{:error, :timeout}])
      assert Pricing.monthly_prices(0) == %{}
    end

    test "an unconfigured client → %{} (never reaches the wire)" do
      Application.put_env(:barkpark_cloud, Pricing, http_client: nil)
      Pricing.reset()
      assert Pricing.monthly_prices(0) == %{}
    end

    test "a transport error AFTER a good fetch serves the last good (stale) cache" do
      Fake.program([ok200(@page1), ok200(@page2)])
      good = Pricing.monthly_prices(0)

      # Past the TTL the refresh runs, the transport errors → last good wins.
      Fake.program([{:error, :timeout}])
      ttl_ms = 24 * 60 * 60 * 1000
      assert Pricing.monthly_prices(ttl_ms + 1) == good
    end

    test "a malformed page (no Items) → %{}, no raise" do
      Fake.program([ok200(~s({"unexpected":true}))])
      assert Pricing.monthly_prices(0) == %{}
    end
  end

  describe "enrichment in build_provider_catalog/2 (through the router)" do
    setup do
      user = register_user()
      n = System.unique_integer([:positive])
      {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
      {:ok, _} = Accounts.add_member(team, user, "owner")

      {:ok, _} =
        Registry.connect_provider(team, "azure", Jason.encode!(azure_blob()), label: "az")

      {:ok, token} = Accounts.create_user_session_token(user)
      %{token: token}
    end

    test "a real retail price is stamped onto the matching server_type", %{token: token} do
      # Price ONLY the canned fake catalog's Standard_D2ps_v5 (its canned price
      # is 70.08); enrichment must overwrite it with the real retail figure.
      priced = ~s({"Items":[
        {"armSkuName":"Standard_D2ps_v5","armRegionName":"eastus","retailPrice":0.05,
         "meterName":"D2ps v5","skuName":"D2ps v5","productName":"Virtual Machines Dpsv5 Series",
         "serviceName":"Virtual Machines","type":"Consumption","currencyCode":"USD"}]})

      Fake.program([ok200(priced)])

      body = catalog(token)
      assert body["currency"] == "USD"
      st = Enum.find(body["server_types"], &(&1["slug"] == "Standard_D2ps_v5"))
      assert st["monthly_price"] == 36.5
    end

    test "a pricing OUTAGE still serves the catalog (200), never a 502", %{token: token} do
      Fake.program([{:error, :timeout}])

      conn = call_get(token)
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      # The catalog still lists sizes; enrichment simply stamped nothing new.
      assert is_list(body["server_types"]) and body["server_types"] != []
    end
  end

  ## helpers ────────────────────────────────────────────────────────────────

  defp register_user do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp azure_blob do
    %{
      "tenant_id" => "11111111-1111-1111-1111-111111111111",
      "client_id" => "22222222-2222-2222-2222-222222222222",
      "client_secret" => "good-secret",
      "subscription_id" => "33333333-3333-3333-3333-333333333333"
    }
  end

  defp call_get(token) do
    conn(:get, "/v1/providers/azure/catalog")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp catalog(token) do
    conn = call_get(token)
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end
end
