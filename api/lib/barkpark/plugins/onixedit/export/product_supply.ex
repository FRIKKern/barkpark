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
    * `<MarketPublishingDetail>` — emitted whenever the supply carries an
      explicit `marketPublishingDetail` map. Each `<PublisherRepresentative>`
      (per `publisherRepresentatives[]` entry) emits `<AgentRole>` (List 69,
      default `07` "Local publisher") FIRST, then `<AgentName>` — XSD enforces
      that ordering — followed by the MANDATORY `<MarketPublishingStatus>`
      (List 68, default `04` "Active", overridable via
      `marketPublishingStatus`). The status is required by the XSD content
      model; omitting it renders an XSD-invalid `<MarketPublishingDetail>`.
    * `<SupplyDetail>` — emitted once per `supplyDetails[]` entry, or a
      synthesized default when `supplyDetails` is empty. Carries
      `<Supplier>` (SupplierRole defaults to `09` "Publisher to retailers"),
      `<ProductAvailability>` (defaults to `20` "Available"), and
      `<Price>` for each `prices[]` entry. PriceType defaults to `02` (RRP
      including tax) and CurrencyCode defaults to `NOK` when omitted.

  ## Synthesized Supplier when `productSupplies` is absent

  When `book.json` carries no `productSupplies` (or the array is empty), a
  default Norwegian-locale ProductSupply is synthesized so Bokbasen ingestion
  always sees a valid envelope. The synthesized `<SupplyDetail>` carries:

    * `<Supplier>` with `<SupplierRole>09</SupplierRole>` (Publisher to
      end-customers) and `<SupplierName>` resolved from
      `book.publishingDetail.publishers[0].publisherName` (or
      `imprint.imprintName` as a final fallback).
    * `<ProductAvailability>20</ProductAvailability>` (Available).
    * `<UnpricedItemType>01</UnpricedItemType>` (Free of charge — placeholder
      until real `<Price>` data is added to book.json).

  Real Price/Supplier data should be added to book.json when known; the
  synthesis is a Bokbasen-friendly placeholder, not a permanent default.

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
  @default_agent_role "07"
  @default_unpriced_item_type "01"
  @default_market_publishing_status "04"

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

    ctx = %{
      publisher_name: derive_publisher_name(book_doc),
      synthesized: supplies == []
    }

    elements =
      case supplies do
        [] -> [build_supply(%{}, ctx)]
        _ -> Enum.map(supplies, &build_supply(&1, ctx))
      end
      |> Enum.reject(&is_nil/1)

    case elements do
      [] -> nil
      _ -> elements
    end
  end

  # Derive a SupplierName fallback from the book's publishing detail. Used by
  # the synthesized-Supplier path when `productSupplies` is absent. Returns
  # the first non-blank value from publishers[0].publisherName then
  # imprint.imprintName; nil if neither is present.
  defp derive_publisher_name(book_doc) do
    pd = Map.get(book_doc, "publishingDetail") || %{}

    pub_name =
      pd
      |> Map.get("publishers", [])
      |> List.wrap()
      |> Enum.find_value(fn p ->
        if is_map(p), do: presence(Map.get(p, "publisherName"))
      end)

    imprint_name = pd |> Map.get("imprint") |> imprint_name()

    pub_name || imprint_name
  end

  defp imprint_name(imprint) when is_map(imprint), do: presence(Map.get(imprint, "imprintName"))
  defp imprint_name(_), do: nil

  defp presence(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp presence(_), do: nil

  defp build_supply(supply, ctx) when is_map(supply) do
    market = build_market(Map.get(supply, "market"))
    market_publishing = build_market_publishing(Map.get(supply, "marketPublishingDetail"))
    supply_details = build_supply_details(Map.get(supply, "supplyDetails", []), ctx)

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

    # `<MarketPublishingStatus>` (List 68) is a MANDATORY child of
    # `<MarketPublishingDetail>` per the EDItEUR reference XSD — the content
    # model is `PublisherRepresentative*, ProductContact*, MarketPublishingStatus,
    # …`. Emitting only `<PublisherRepresentative>` (the pre-fix behaviour)
    # produced a `<MarketPublishingDetail>` missing that required element, so
    # xmllint rejected the WHOLE export → `to_iodata` returned `{:xsd_invalid}`
    # → HTTP export 500 + Bokbasen publish blocked. Inject the status (after the
    # optional representative run, as the sequence demands), defaulting to `04`
    # (Active): an exported book is, by definition, published and orderable in
    # its market. A document may override via `marketPublishingStatus`.
    status =
      mpd
      |> Map.get("marketPublishingStatus")
      |> presence()
      |> Kernel.||(@default_market_publishing_status)

    children = reps ++ [XmlBuilder.element(:MarketPublishingStatus, status)]

    XmlBuilder.element(:MarketPublishingDetail, children)
  end

  defp build_market_publishing(_), do: nil

  defp build_publisher_representative(rep) when is_map(rep) do
    name = Map.get(rep, "agentName")
    role = Map.get(rep, "agentRole") || @default_agent_role

    if blank?(name) do
      nil
    else
      {:ok, role_code} = Codelists.agent_role(role)

      XmlBuilder.element(:PublisherRepresentative, [
        XmlBuilder.element(:AgentRole, role_code),
        XmlBuilder.element(:AgentName, name)
      ])
    end
  end

  # ---- SupplyDetail ---------------------------------------------------------

  defp build_supply_details(list, ctx) when is_list(list) and list != [] do
    list
    |> Enum.filter(&is_map/1)
    |> Enum.map(&build_supply_detail(&1, ctx))
    |> Enum.reject(&is_nil/1)
  end

  defp build_supply_details(_, ctx), do: [build_supply_detail(%{}, ctx)]

  defp build_supply_detail(detail, ctx) when is_map(detail) do
    supplier = build_supplier(Map.get(detail, "supplier"), ctx)
    availability = build_product_availability(Map.get(detail, "productAvailability"))
    prices = build_prices(Map.get(detail, "prices", []))
    unpriced = build_unpriced(Map.get(detail, "unpricedItemType"), prices, ctx)

    children =
      ([supplier, availability] ++ prices ++ List.wrap(unpriced))
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    case children do
      [] -> nil
      _ -> XmlBuilder.element(:SupplyDetail, children)
    end
  end

  defp build_supplier(supplier, _ctx) when is_map(supplier) do
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

  defp build_supplier(_, %{synthesized: true, publisher_name: name}) do
    XmlBuilder.element(:Supplier, [
      XmlBuilder.element(:SupplierRole, @default_supplier_role),
      XmlBuilder.element(:SupplierName, name || "Unknown publisher")
    ])
  end

  defp build_supplier(_, _ctx) do
    XmlBuilder.element(:Supplier, [
      XmlBuilder.element(:SupplierRole, @default_supplier_role)
    ])
  end

  # Emit `<UnpricedItemType>` to satisfy ONIX 3.0's
  # `(UnpricedItemType | Price+)` content model on SupplyDetail. Three cases:
  #
  #   1. Document explicitly declares `unpricedItemType` AND has no prices →
  #      emit the declared value (round-trip preservation for documents
  #      imported from ONIX that came in with UnpricedItemType set).
  #   2. Synthesized SupplyDetail (no real supplyDetails entry) → emit the
  #      default `01` (Free of charge) placeholder.
  #   3. Real entry with prices, or with neither prices nor declared
  #      unpricedItemType → emit nothing; the publisher must add data.
  defp build_unpriced(declared, [], _ctx) when is_binary(declared) and declared != "" do
    XmlBuilder.element(:UnpricedItemType, declared)
  end

  defp build_unpriced(_declared, [], %{synthesized: true}) do
    XmlBuilder.element(:UnpricedItemType, @default_unpriced_item_type)
  end

  defp build_unpriced(_declared, _prices, _ctx), do: nil

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
        XmlBuilder.element(:PriceAmount, price_amount_string(amount)),
        XmlBuilder.element(:CurrencyCode, currency_code)
      ])
    end
  end

  # ---- Helpers --------------------------------------------------------------

  defp maybe_element(_tag, blank) when blank in [nil, ""], do: nil
  defp maybe_element(tag, value) when is_binary(value), do: XmlBuilder.element(tag, value)
  defp maybe_element(tag, value), do: XmlBuilder.element(tag, to_string(value))

  # ONIX <PriceAmount> is xs:decimal. `book.json` types priceAmount as a string,
  # but the ingest API is permissive, so a caller can store a JSON NUMBER
  # (`"priceAmount": 1000.0`). `to_string(1000.0)` yields "1.0e3" (scientific
  # notation), which is not a valid xs:decimal → xmllint rejects the WHOLE export
  # → to_iodata returns {:xsd_invalid} → HTTP export 500 + Bokbasen publish
  # blocked. Format a numeric amount as a plain fixed-point decimal string (no
  # exponent); a string (the canonical form) passes through unchanged.
  defp price_amount_string(v) when is_binary(v), do: v
  defp price_amount_string(v) when is_integer(v), do: Integer.to_string(v)

  defp price_amount_string(v) when is_float(v) do
    v
    |> :erlang.float_to_binary([{:decimals, 10}])
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp price_amount_string(v), do: to_string(v)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
