defmodule Barkpark.Plugins.OnixEdit.Export.ProductSupply do
  @moduledoc """
  Builds the ONIX 3.0 `<ProductSupply>` block.

  WI4 emits one `<ProductSupply>` per entry in `book.productSupplies[]`. When
  the book carries no `productSupplies` (or the array is empty), a default
  Norwegian-locale supply is synthesized so Bokbasen ingestion always sees at
  least `<Market><Territory><CountriesIncluded>NO</CountriesIncluded>...</Market>`
  plus a `<SupplyDetail>` envelope.

  Children of each `<ProductSupply>`:

    * `<Market>` — `<Territory><CountriesIncluded>{codes}</CountriesIncluded></Territory>`.
      Defaults to `NO` when book.json lists no countries.
    * `<MarketPublishingDetail>` — `<PublisherRepresentative>` per
      `publisherRepresentatives[]` entry (only when present).
    * `<SupplyDetail>` — emitted once per `supplyDetails[]` entry, or a
      synthesized default when `supplyDetails` is empty. Carries
      `<Supplier>` (SupplierRole defaults to `09` "Publisher to retailers"),
      `<ProductAvailability>` (defaults to `20` "Available"), and
      `<Price>` for each `prices[]` entry. PriceType defaults to `02` (RRP
      including tax) and CurrencyCode defaults to `NOK` when omitted.

  Empty optional containers are never emitted (e.g. an empty `<Price>`
  block fails XSD validation in WI5). Codelist resolution raises
  `ArgumentError` on unknown codes via `Barkpark.Plugins.OnixEdit.Export.Codelists`.
  """

  alias Barkpark.Plugins.OnixEdit.Export.Codelists

  @default_country "NO"
  @default_currency "NOK"
  @default_supplier_role "09"
  @default_product_availability "20"
  @default_price_type "02"

  @doc """
  Build a list of `<ProductSupply>` elements (zero-or-more) from a book document.
  Returns `nil` when no productSupplies are emitted (caller filters nil from the
  Product children list).
  """
  @spec build(map(), keyword()) :: any() | [any()] | nil
  def build(book_doc, _opts \\ []) when is_map(book_doc) do
    supplies =
      book_doc
      |> Map.get("productSupplies", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    elements =
      case supplies do
        [] -> [build_supply(%{})]
        _ -> Enum.map(supplies, &build_supply/1)
      end
      |> Enum.reject(&is_nil/1)

    case elements do
      [] -> nil
      _ -> elements
    end
  end

  defp build_supply(supply) when is_map(supply) do
    market = build_market(Map.get(supply, "market"))
    market_publishing = build_market_publishing(Map.get(supply, "marketPublishingDetail"))
    supply_details = build_supply_details(Map.get(supply, "supplyDetails", []))

    children =
      ([market, market_publishing] ++ supply_details)
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    XmlBuilder.element(:ProductSupply, children)
  end

  # ---- Market ---------------------------------------------------------------

  defp build_market(market) when is_map(market) do
    territory = build_territory(Map.get(market, "territory"))
    XmlBuilder.element(:Market, List.wrap(territory))
  end

  defp build_market(_), do: build_market(%{})

  defp build_territory(territory) when is_map(territory) do
    countries =
      territory
      |> Map.get("countries", [])
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.map(&resolve_country/1)

    countries =
      case countries do
        [] -> [@default_country]
        list -> list
      end

    XmlBuilder.element(:Territory, [
      XmlBuilder.element(:CountriesIncluded, Enum.join(countries, " "))
    ])
  end

  defp build_territory(_), do: build_territory(%{})

  defp resolve_country(code) do
    {:ok, c} = Codelists.country_code(code)
    c
  end

  # ---- MarketPublishingDetail -----------------------------------------------

  defp build_market_publishing(mpd) when is_map(mpd) do
    reps =
      mpd
      |> Map.get("publisherRepresentatives", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&build_publisher_representative/1)
      |> Enum.reject(&is_nil/1)

    case reps do
      [] -> nil
      _ -> XmlBuilder.element(:MarketPublishingDetail, reps)
    end
  end

  defp build_market_publishing(_), do: nil

  defp build_publisher_representative(rep) when is_map(rep) do
    name = Map.get(rep, "agentName")

    if blank?(name) do
      nil
    else
      XmlBuilder.element(:PublisherRepresentative, [
        XmlBuilder.element(:AgentName, name)
      ])
    end
  end

  # ---- SupplyDetail ---------------------------------------------------------

  defp build_supply_details(list) when is_list(list) and list != [] do
    list
    |> Enum.filter(&is_map/1)
    |> Enum.map(&build_supply_detail/1)
    |> Enum.reject(&is_nil/1)
  end

  defp build_supply_details(_), do: [build_supply_detail(%{})]

  defp build_supply_detail(detail) when is_map(detail) do
    supplier = build_supplier(Map.get(detail, "supplier"))
    availability = build_product_availability(Map.get(detail, "productAvailability"))
    prices = build_prices(Map.get(detail, "prices", []))

    children =
      ([supplier, availability] ++ prices)
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    case children do
      [] -> nil
      _ -> XmlBuilder.element(:SupplyDetail, children)
    end
  end

  defp build_supplier(supplier) when is_map(supplier) do
    role = Map.get(supplier, "supplierRole") || @default_supplier_role
    name = Map.get(supplier, "supplierName")

    {:ok, role_code} = Codelists.supplier_role(role)

    children =
      [
        XmlBuilder.element(:SupplierRole, role_code),
        maybe_element(:SupplierName, name)
      ]
      |> Enum.reject(&is_nil/1)

    XmlBuilder.element(:Supplier, children)
  end

  defp build_supplier(_) do
    XmlBuilder.element(:Supplier, [
      XmlBuilder.element(:SupplierRole, @default_supplier_role)
    ])
  end

  defp build_product_availability(code) when is_binary(code) and code != "" do
    {:ok, c} = Codelists.product_availability(code)
    XmlBuilder.element(:ProductAvailability, c)
  end

  defp build_product_availability(_) do
    XmlBuilder.element(:ProductAvailability, @default_product_availability)
  end

  defp build_prices(list) when is_list(list) do
    list
    |> Enum.filter(&is_map/1)
    |> Enum.map(&build_price/1)
    |> Enum.reject(&is_nil/1)
  end

  defp build_prices(_), do: []

  defp build_price(price) when is_map(price) do
    type = Map.get(price, "priceType") || @default_price_type
    amount = Map.get(price, "priceAmount")
    currency = Map.get(price, "currencyCode") || @default_currency

    if blank?(amount) do
      nil
    else
      {:ok, type_code} = Codelists.price_type(type)
      {:ok, currency_code} = Codelists.currency_code(currency)

      XmlBuilder.element(:Price, [
        XmlBuilder.element(:PriceType, type_code),
        XmlBuilder.element(:PriceAmount, to_string(amount)),
        XmlBuilder.element(:CurrencyCode, currency_code)
      ])
    end
  end

  # ---- Helpers --------------------------------------------------------------

  defp maybe_element(_tag, blank) when blank in [nil, ""], do: nil
  defp maybe_element(tag, value) when is_binary(value), do: XmlBuilder.element(tag, value)
  defp maybe_element(tag, value), do: XmlBuilder.element(tag, to_string(value))

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
