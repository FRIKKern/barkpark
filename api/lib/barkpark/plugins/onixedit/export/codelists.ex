defmodule Barkpark.Plugins.OnixEdit.Export.Codelists do
  @moduledoc """
  Static codelist resolver for the ONIX 3.0 export pipeline.

  WI3 starter maps for the four lists DescriptiveDetail emits against:

    * List 17  — `contributor_role/1`  (`A01 By (author)`, `B01 Edited by`, …)
    * List 93  — `thema/1`             (Thema subject codes; representative subset)
    * List 150 — `product_form/1`      (`BA Book`, `BB Hardback`, `EB Digital download…`)
    * List 175 — `product_form_detail/1` (Common product form detail codes)

  WI4 extends with the 10 lists CollateralDetail / PublishingDetail /
  ProductSupply emit against:

    * List 23  — `publishing_date_role/1`   (`01 Publication date`, …)
    * List 25  — `supplier_role/1`          (`09 Publisher to retailers`, …)
    * List 45  — `publishing_role/1`        (`01 Publisher`, `02 Co-publisher`, …)
    * List 58  — `price_type/1`             (`02 RRP including tax`, …)
    * List 65  — `product_availability/1`   (`20 Available`, `10 Not yet available`, …)
    * List 91  — `country_code/1`           (ISO 3166-1 alpha-2: `NO`, `SE`, …)
    * List 96  — `currency_code/1`          (ISO 4217: `NOK`, `SEK`, …)
    * List 153 — `text_type/1`              (`03 Description`, …)
    * List 154 — `content_audience/1`       (`00 Unrestricted`, …)
    * List 158 — `resource_content_type/1`  (`01 Front cover`, …)
    * List 159 — `resource_mode/1`          (`03 Image`, …)

  These maps are intentionally small — they cover the Norwegian-publisher
  primary use cases the test fixtures and seed data exercise. The full
  enumerations live in the vendored EDItEUR XSDs at
  `api/priv/onix/onix-3.0/ONIX_BookProduct_CodeLists.xsd`; WI4–WI5 will grow
  these maps as new fixtures demand it (and WI5's xmllint gate validates
  that whatever we emit matches the XSD enumerations exactly).

  Unknown codes raise `ArgumentError` with a clear `unknown_<list>_code`
  message — silent fall-through would risk emitting invalid ONIX that the
  XSD gate catches much later in the pipeline.
  """

  @type code :: String.t()

  @contributor_role %{
    "A01" => "By (author)",
    "A02" => "With",
    "A03" => "Screenplay by",
    "A04" => "Libretto by",
    "A05" => "Lyrics by",
    "A06" => "By (composer)",
    "A07" => "By (artist)",
    "A08" => "By (photographer)",
    "A09" => "Created by",
    "A12" => "Illustrated by",
    "A13" => "Photographs by",
    "A19" => "Afterword by",
    "A23" => "Foreword by",
    "A24" => "Introduction by",
    "B01" => "Edited by",
    "B02" => "Revised by",
    "B05" => "Adapted by",
    "B06" => "Translated by",
    "E07" => "Read by"
  }

  @product_form %{
    "AB" => "Audio cassette",
    "AC" => "CD-Audio",
    "AJ" => "Downloadable audio file",
    "AN" => "Downloadable and online / streamed audio file",
    "BA" => "Book",
    "BB" => "Hardback",
    "BC" => "Paperback / softback",
    "BE" => "Spiral bound",
    "BF" => "Pamphlet",
    "BG" => "Leather / fine binding",
    "BH" => "Board book",
    "EA" => "Digital (delivered electronically)",
    "EB" => "Digital download and online / streamed",
    "EC" => "Digital online / streamed",
    "ED" => "Digital download"
  }

  @product_form_detail %{
    "B102" => "Mass market (rack) paperback",
    "B104" => "Trade paperback",
    "B304" => "With dust jacket",
    "B305" => "Without dust jacket",
    "E101" => "EPUB",
    "E107" => "PDF",
    "E116" => "MOBI",
    "E117" => "AZW3"
  }

  @thema %{
    "F" => "Fiction & related items",
    "FB" => "General fiction",
    "FBA" => "Modern & contemporary fiction (post c 1945)",
    "FBC" => "Classic fiction (pre c 1945)",
    "Y" => "Children's, Teenage & Educational",
    "YF" => "Children's / Teenage fiction & true stories",
    "YN" => "Children's / Teenage: General non-fiction",
    "DN" => "Biography & non-fiction prose",
    "N" => "History & Archaeology",
    "P" => "Mathematics & Science"
  }

  # ---- WI4 lists -----------------------------------------------------------

  @publishing_date_role %{
    "01" => "Publication date",
    "11" => "Embargo date",
    "12" => "Public announcement date"
  }

  @supplier_role %{
    "02" => "Wholesaler",
    "09" => "Publisher to retailers"
  }

  @publishing_role %{
    "01" => "Publisher",
    "02" => "Co-publisher",
    "03" => "Sponsor",
    "04" => "Publisher of original-language version"
  }

  @agent_role %{
    "06" => "Non-exclusive sales agent",
    "07" => "Local publisher"
  }

  @price_type %{
    "02" => "RRP including tax",
    "04" => "RRP excluding tax",
    "41" => "Subscription price"
  }

  @product_availability %{
    "10" => "Not yet available",
    "20" => "Available",
    "22" => "Awaiting reprint",
    "50" => "Not available"
  }

  @country_code %{
    "NO" => "Norway",
    "SE" => "Sweden",
    "DK" => "Denmark",
    "FI" => "Finland",
    "IS" => "Iceland",
    "GB" => "United Kingdom",
    "US" => "United States",
    "DE" => "Germany"
  }

  @currency_code %{
    "NOK" => "Norwegian krone",
    "SEK" => "Swedish krona",
    "DKK" => "Danish krone",
    "EUR" => "Euro",
    "USD" => "US dollar",
    "GBP" => "Pound sterling"
  }

  @text_type %{
    "01" => "Sender's title",
    "02" => "Sender's title (alternative)",
    "03" => "Description"
  }

  @content_audience %{
    "00" => "Unrestricted",
    "01" => "Booktrade",
    "03" => "General readership"
  }

  @resource_content_type %{
    "01" => "Front cover",
    "03" => "Series image",
    "04" => "Contributor portrait",
    "17" => "Sample text"
  }

  @resource_mode %{
    "02" => "Audio",
    "03" => "Image",
    "04" => "Text",
    "05" => "Video",
    "06" => "Multi-mode"
  }

  @doc """
  Resolve a ContributorRole code (List 17). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_contributor_role_code` message on miss.
  """
  @spec contributor_role(code()) :: {:ok, code()}
  def contributor_role(code) when is_binary(code) do
    if Map.has_key?(@contributor_role, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_contributor_role_code: #{inspect(code)}"
    end
  end

  @doc """
  Resolve a ProductForm code (List 150). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_product_form_code` message on miss.
  """
  @spec product_form(code()) :: {:ok, code()}
  def product_form(code) when is_binary(code) do
    if Map.has_key?(@product_form, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_product_form_code: #{inspect(code)}"
    end
  end

  @doc """
  Resolve a ProductFormDetail code (List 175). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_product_form_detail_code` message on miss.
  """
  @spec product_form_detail(code()) :: {:ok, code()}
  def product_form_detail(code) when is_binary(code) do
    if Map.has_key?(@product_form_detail, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_product_form_detail_code: #{inspect(code)}"
    end
  end

  @doc """
  Resolve a Thema subject code (List 93 / Thema 1.6). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_thema_code` message on miss.

  WI3 ships only a small representative subset (top-level fiction and
  non-fiction categories). Full Thema is ~3000 codes and is not enumerated in
  the ONIX XSD — when a publisher needs broader coverage WI4/WI5 grow this map
  or wire to `Barkpark.Content.Codelists` for DB-backed lookup.
  """
  @spec thema(code()) :: {:ok, code()}
  def thema(code) when is_binary(code) do
    if Map.has_key?(@thema, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_thema_code: #{inspect(code)}"
    end
  end

  @doc false
  @spec contributor_role_label(code()) :: String.t() | nil
  def contributor_role_label(code), do: Map.get(@contributor_role, code)

  @doc false
  @spec product_form_label(code()) :: String.t() | nil
  def product_form_label(code), do: Map.get(@product_form, code)

  @doc false
  @spec thema_label(code()) :: String.t() | nil
  def thema_label(code), do: Map.get(@thema, code)

  # ---- WI4 resolvers --------------------------------------------------------

  @doc """
  Resolve a PublishingDateRole code (List 23). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_publishing_date_role_code` message on miss.
  """
  @spec publishing_date_role(code()) :: {:ok, code()}
  def publishing_date_role(code) when is_binary(code) do
    if Map.has_key?(@publishing_date_role, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_publishing_date_role_code: #{inspect(code)}"
    end
  end

  @doc """
  Resolve a SupplierRole code (List 25). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_supplier_role_code` message on miss.
  """
  @spec supplier_role(code()) :: {:ok, code()}
  def supplier_role(code) when is_binary(code) do
    if Map.has_key?(@supplier_role, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_supplier_role_code: #{inspect(code)}"
    end
  end

  @doc """
  Resolve a PublishingRole code (List 45). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_publishing_role_code` message on miss.
  """
  @spec publishing_role(code()) :: {:ok, code()}
  def publishing_role(code) when is_binary(code) do
    if Map.has_key?(@publishing_role, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_publishing_role_code: #{inspect(code)}"
    end
  end

  @doc """
  Resolve an AgentRole code (List 69). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_agent_role_code` message on miss.

  Minimal map — `"07"` (Local publisher) is the default `<AgentRole>` inside
  the synthesized `<PublisherRepresentative>` envelope. `"06"` (Non-exclusive
  sales agent) is also enumerated so book.json may pass it through. Add
  additional codes from List 69 only as new fixtures demand them.
  """
  @spec agent_role(code()) :: {:ok, code()}
  def agent_role(code) when is_binary(code) do
    if Map.has_key?(@agent_role, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_agent_role_code: #{inspect(code)}"
    end
  end

  @doc """
  Resolve a PriceType code (List 58). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_price_type_code` message on miss.
  """
  @spec price_type(code()) :: {:ok, code()}
  def price_type(code) when is_binary(code) do
    if Map.has_key?(@price_type, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_price_type_code: #{inspect(code)}"
    end
  end

  @doc """
  Resolve a ProductAvailability code (List 65). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_product_availability_code` message on miss.
  """
  @spec product_availability(code()) :: {:ok, code()}
  def product_availability(code) when is_binary(code) do
    if Map.has_key?(@product_availability, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_product_availability_code: #{inspect(code)}"
    end
  end

  @doc """
  Resolve a CountryCode (List 91, ISO 3166-1 alpha-2). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_country_code_code` message on miss.
  """
  @spec country_code(code()) :: {:ok, code()}
  def country_code(code) when is_binary(code) do
    if Map.has_key?(@country_code, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_country_code_code: #{inspect(code)}"
    end
  end

  @doc """
  Resolve a CurrencyCode (List 96, ISO 4217). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_currency_code_code` message on miss.
  """
  @spec currency_code(code()) :: {:ok, code()}
  def currency_code(code) when is_binary(code) do
    if Map.has_key?(@currency_code, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_currency_code_code: #{inspect(code)}"
    end
  end

  @doc """
  Resolve a TextType code (List 153). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_text_type_code` message on miss.
  """
  @spec text_type(code()) :: {:ok, code()}
  def text_type(code) when is_binary(code) do
    if Map.has_key?(@text_type, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_text_type_code: #{inspect(code)}"
    end
  end

  @doc """
  Resolve a ContentAudience code (List 154). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_content_audience_code` message on miss.
  """
  @spec content_audience(code()) :: {:ok, code()}
  def content_audience(code) when is_binary(code) do
    if Map.has_key?(@content_audience, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_content_audience_code: #{inspect(code)}"
    end
  end

  @doc """
  Resolve a ResourceContentType code (List 158). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_resource_content_type_code` message on miss.
  """
  @spec resource_content_type(code()) :: {:ok, code()}
  def resource_content_type(code) when is_binary(code) do
    if Map.has_key?(@resource_content_type, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_resource_content_type_code: #{inspect(code)}"
    end
  end

  @doc """
  Resolve a ResourceMode code (List 159). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_resource_mode_code` message on miss.
  """
  @spec resource_mode(code()) :: {:ok, code()}
  def resource_mode(code) when is_binary(code) do
    if Map.has_key?(@resource_mode, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_resource_mode_code: #{inspect(code)}"
    end
  end
end
