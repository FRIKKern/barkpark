defmodule Barkpark.Plugins.OnixEdit.Export.Codelists do
  @moduledoc """
  Codelist resolver for the ONIX 3.0 export pipeline.

  Every code the exporter emits is checked against the FULL EDItEUR
  enumeration, loaded at COMPILE TIME by
  `Barkpark.Plugins.OnixEdit.Export.CodelistSource` from the two snapshots
  this repo already vendors:

    * the 15 numeric ONIX lists come from
      `priv/onix/onix-3.0/ONIX_BookProduct_CodeLists.xsd` — the same file
      `Export.Validator` hands to `xmllint`, so what we emit against and what
      we are validated against are one enumeration, not two that can drift;
    * Thema (9,187 codes) comes from
      `priv/codelists/thema-1.6/thema-v1.6-en.json` — the same file
      `Barkpark.Codelists.EDItEUR.seed_thema/1` registers into the DB
      codelist registry that backs the Studio dropdown, so a code a publisher
      can PICK is a code the exporter can EMIT.

  There is no static starter map any more. Until 2026-09 this module held ~10
  hand-written Thema codes (and 6 currencies, 8 countries, 19 contributor
  roles), so a publisher who picked any of the other 9,177 Thema codes in
  Studio got a valid document that could not export. The maps below are
  generated, not curated.

  ## Why compile time and not a `Content.Codelists` query

  The DB registry and these snapshots carry the SAME code sets — the bundled
  registry source `priv/codelists/onix-issue-73.xml` and the XSD agree code
  for code on all 15 lists, and Thema is literally the same JSON file. So a
  runtime query would buy no extra code, and would cost two things: the
  render path stops being pure, and `Export.to_iodata/2`'s `rescue` boundary
  — which converts a resolver raise into `{:error, {:invalid_code, …}}` —
  would start reporting a DB outage as an invalid publisher code.

  ## Unknown codes

  A code absent from the enumeration raises `ArgumentError` with an
  `unknown_<list>_code: <inspected code>` message. `Export.to_iodata/2`
  catches it at the single boundary its three callers share and returns
  `{:error, {:invalid_code, %{"codelist" => …, "code" => …}}}`. The export
  REFUSES; it never drops the code and never emits a placeholder.
  """

  alias Barkpark.Plugins.OnixEdit.Export.CodelistSource

  @external_resource CodelistSource.xsd_path()
  @external_resource CodelistSource.thema_path()

  @type code :: String.t()

  onix_lists = CodelistSource.onix_lists([17, 150, 175, 23, 25, 45, 69, 58, 65, 91, 96, 153, 154, 158, 159])

  @contributor_role Map.fetch!(onix_lists, 17)
  @product_form Map.fetch!(onix_lists, 150)
  @product_form_detail Map.fetch!(onix_lists, 175)
  @publishing_date_role Map.fetch!(onix_lists, 23)
  @supplier_role Map.fetch!(onix_lists, 25)
  @publishing_role Map.fetch!(onix_lists, 45)
  @agent_role Map.fetch!(onix_lists, 69)
  @price_type Map.fetch!(onix_lists, 58)
  @product_availability Map.fetch!(onix_lists, 65)
  @country_code Map.fetch!(onix_lists, 91)
  @currency_code Map.fetch!(onix_lists, 96)
  @text_type Map.fetch!(onix_lists, 153)
  @content_audience Map.fetch!(onix_lists, 154)
  @resource_content_type Map.fetch!(onix_lists, 158)
  @resource_mode Map.fetch!(onix_lists, 159)

  @thema CodelistSource.thema()

  @doc """
  Number of codes enumerated for a list. Exposed so tests and operators can
  assert the generated maps are the FULL enumeration rather than a starter
  subset — a resolver that silently degraded to a handful of codes is the
  failure this module was rebuilt to retire.
  """
  @spec size(atom()) :: non_neg_integer()
  def size(:contributor_role), do: map_size(@contributor_role)
  def size(:product_form), do: map_size(@product_form)
  def size(:product_form_detail), do: map_size(@product_form_detail)
  def size(:publishing_date_role), do: map_size(@publishing_date_role)
  def size(:supplier_role), do: map_size(@supplier_role)
  def size(:publishing_role), do: map_size(@publishing_role)
  def size(:agent_role), do: map_size(@agent_role)
  def size(:price_type), do: map_size(@price_type)
  def size(:product_availability), do: map_size(@product_availability)
  def size(:country_code), do: map_size(@country_code)
  def size(:currency_code), do: map_size(@currency_code)
  def size(:text_type), do: map_size(@text_type)
  def size(:content_audience), do: map_size(@content_audience)
  def size(:resource_content_type), do: map_size(@resource_content_type)
  def size(:resource_mode), do: map_size(@resource_mode)
  def size(:thema), do: map_size(@thema)

  @doc """
  Resolve a ContributorRole code (List 17). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_contributor_role_code` message on miss.
  """
  @spec contributor_role(code()) :: {:ok, code()}
  def contributor_role(code) when is_binary(code), do: resolve(@contributor_role, code, "contributor_role")

  @doc false
  @spec contributor_role_label(code()) :: String.t() | nil
  def contributor_role_label(code), do: Map.get(@contributor_role, code)

  @doc """
  Resolve a ProductForm code (List 150). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_product_form_code` message on miss.
  """
  @spec product_form(code()) :: {:ok, code()}
  def product_form(code) when is_binary(code), do: resolve(@product_form, code, "product_form")

  @doc false
  @spec product_form_label(code()) :: String.t() | nil
  def product_form_label(code), do: Map.get(@product_form, code)

  @doc """
  Resolve a ProductFormDetail code (List 175). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_product_form_detail_code` message on miss.
  """
  @spec product_form_detail(code()) :: {:ok, code()}
  def product_form_detail(code) when is_binary(code), do: resolve(@product_form_detail, code, "product_form_detail")

  @doc false
  @spec product_form_detail_label(code()) :: String.t() | nil
  def product_form_detail_label(code), do: Map.get(@product_form_detail, code)

  @doc """
  Resolve a PublishingDateRole code (List 23). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_publishing_date_role_code` message on miss.
  """
  @spec publishing_date_role(code()) :: {:ok, code()}
  def publishing_date_role(code) when is_binary(code), do: resolve(@publishing_date_role, code, "publishing_date_role")

  @doc false
  @spec publishing_date_role_label(code()) :: String.t() | nil
  def publishing_date_role_label(code), do: Map.get(@publishing_date_role, code)

  @doc """
  Resolve a SupplierRole code (List 25). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_supplier_role_code` message on miss.
  """
  @spec supplier_role(code()) :: {:ok, code()}
  def supplier_role(code) when is_binary(code), do: resolve(@supplier_role, code, "supplier_role")

  @doc false
  @spec supplier_role_label(code()) :: String.t() | nil
  def supplier_role_label(code), do: Map.get(@supplier_role, code)

  @doc """
  Resolve a PublishingRole code (List 45). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_publishing_role_code` message on miss.
  """
  @spec publishing_role(code()) :: {:ok, code()}
  def publishing_role(code) when is_binary(code), do: resolve(@publishing_role, code, "publishing_role")

  @doc false
  @spec publishing_role_label(code()) :: String.t() | nil
  def publishing_role_label(code), do: Map.get(@publishing_role, code)

  @doc """
  Resolve a AgentRole code (List 69). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_agent_role_code` message on miss.
  """
  @spec agent_role(code()) :: {:ok, code()}
  def agent_role(code) when is_binary(code), do: resolve(@agent_role, code, "agent_role")

  @doc false
  @spec agent_role_label(code()) :: String.t() | nil
  def agent_role_label(code), do: Map.get(@agent_role, code)

  @doc """
  Resolve a PriceType code (List 58). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_price_type_code` message on miss.
  """
  @spec price_type(code()) :: {:ok, code()}
  def price_type(code) when is_binary(code), do: resolve(@price_type, code, "price_type")

  @doc false
  @spec price_type_label(code()) :: String.t() | nil
  def price_type_label(code), do: Map.get(@price_type, code)

  @doc """
  Resolve a ProductAvailability code (List 65). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_product_availability_code` message on miss.
  """
  @spec product_availability(code()) :: {:ok, code()}
  def product_availability(code) when is_binary(code), do: resolve(@product_availability, code, "product_availability")

  @doc false
  @spec product_availability_label(code()) :: String.t() | nil
  def product_availability_label(code), do: Map.get(@product_availability, code)

  @doc """
  Resolve a CountryCode code (List 91, ISO 3166-1 alpha-2). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_country_code_code` message on miss.
  """
  @spec country_code(code()) :: {:ok, code()}
  def country_code(code) when is_binary(code), do: resolve(@country_code, code, "country_code")

  @doc false
  @spec country_code_label(code()) :: String.t() | nil
  def country_code_label(code), do: Map.get(@country_code, code)

  @doc """
  Resolve a CurrencyCode code (List 96, ISO 4217). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_currency_code_code` message on miss.
  """
  @spec currency_code(code()) :: {:ok, code()}
  def currency_code(code) when is_binary(code), do: resolve(@currency_code, code, "currency_code")

  @doc false
  @spec currency_code_label(code()) :: String.t() | nil
  def currency_code_label(code), do: Map.get(@currency_code, code)

  @doc """
  Resolve a TextType code (List 153). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_text_type_code` message on miss.
  """
  @spec text_type(code()) :: {:ok, code()}
  def text_type(code) when is_binary(code), do: resolve(@text_type, code, "text_type")

  @doc false
  @spec text_type_label(code()) :: String.t() | nil
  def text_type_label(code), do: Map.get(@text_type, code)

  @doc """
  Resolve a ContentAudience code (List 154). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_content_audience_code` message on miss.
  """
  @spec content_audience(code()) :: {:ok, code()}
  def content_audience(code) when is_binary(code), do: resolve(@content_audience, code, "content_audience")

  @doc false
  @spec content_audience_label(code()) :: String.t() | nil
  def content_audience_label(code), do: Map.get(@content_audience, code)

  @doc """
  Resolve a ResourceContentType code (List 158). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_resource_content_type_code` message on miss.
  """
  @spec resource_content_type(code()) :: {:ok, code()}
  def resource_content_type(code) when is_binary(code), do: resolve(@resource_content_type, code, "resource_content_type")

  @doc false
  @spec resource_content_type_label(code()) :: String.t() | nil
  def resource_content_type_label(code), do: Map.get(@resource_content_type, code)

  @doc """
  Resolve a ResourceMode code (List 159). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_resource_mode_code` message on miss.
  """
  @spec resource_mode(code()) :: {:ok, code()}
  def resource_mode(code) when is_binary(code), do: resolve(@resource_mode, code, "resource_mode")

  @doc false
  @spec resource_mode_label(code()) :: String.t() | nil
  def resource_mode_label(code), do: Map.get(@resource_mode, code)

  @doc """
  Resolve a Thema subject code (Thema 1.6, the full 9,187-code enumeration).
  Returns `{:ok, code}` on hit; raises `ArgumentError` with an
  `unknown_thema_code` message on miss.
  """
  @spec thema(code()) :: {:ok, code()}
  def thema(code) when is_binary(code), do: resolve(@thema, code, "thema")

  @doc false
  @spec thema_label(code()) :: String.t() | nil
  def thema_label(code), do: Map.get(@thema, code)

  # The raise must originate INSIDE this module: `Export.to_iodata/2` decides
  # whether to convert an ArgumentError into `{:error, {:invalid_code, …}}` by
  # checking that the top stack frame belongs to this module, and re-raises
  # anything else. Keep this helper private and keep it here.
  @spec resolve(map(), code(), String.t()) :: {:ok, code()}
  defp resolve(enumeration, code, list_name) do
    if Map.has_key?(enumeration, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_#{list_name}_code: #{inspect(code)}"
    end
  end
end
