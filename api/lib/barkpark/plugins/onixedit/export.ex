defmodule Barkpark.Plugins.OnixEdit.Export do
  @moduledoc """
  ONIX 3.0 export entry point for OnixEdit book documents.

  Phase 6 of the OnixEdit plugin: serialize book documents to EDItEUR-conformant
  ONIX 3.0 XML that downstream trading partners (Bokbasen first) can ingest.

  Public surface (this WI ships only the skeleton; WI3-WI5 fill the body):

    * `export/2`         — top-level book → `{:ok, iodata}` | `{:error, reason}`
    * `to_xml/2`         — single-document serializer
    * `record_reference/2` — RecordReference helper per Boss Q1

  Helper namespaces:

    * `Barkpark.Plugins.OnixEdit.Export.Header`  — Header builder (this WI)
    * `Barkpark.Plugins.OnixEdit.Export.Message` — ONIXMessage wrapper (this WI)
  """

  alias Barkpark.Plugins.OnixEdit.Export.{DescriptiveDetail, Header, Message}

  @default_dataset_host "barkpark.cloud"

  @doc """
  Top-level export. Returns iodata so callers can choose to write to file,
  upload, or stringify.
  """
  @spec export(map(), keyword()) :: {:ok, iodata()} | {:error, term()}
  def export(book_doc, opts \\ []) when is_map(book_doc) do
    {:ok, to_xml(book_doc, opts)}
  end

  @doc """
  Serialize a single book document. WI3 emits Product-level identifiers and
  `<DescriptiveDetail>` (title, contributors, Thema subjects, product form);
  WI4 (Collateral/Publishing/Supply) and beyond fill the remaining blocks.
  """
  @spec to_xml(map(), keyword()) :: iodata()
  def to_xml(book_doc, opts \\ []) when is_map(book_doc) do
    header = Header.build(opts)
    products = product(book_doc, opts)
    Message.wrap(header, products)
  end

  @doc """
  Build the ONIX `<RecordReference>` value per Boss Q1: `host:published_id`.
  Default host is `"barkpark.cloud"`. Pass an alternate host as the second argument.
  """
  @spec record_reference(String.t(), String.t()) :: String.t()
  def record_reference(published_id, dataset_host \\ @default_dataset_host)
      when is_binary(published_id) and is_binary(dataset_host) do
    dataset_host <> ":" <> strip_drafts_prefix(published_id)
  end

  # ---- WI3 + WI4 + WI5 stubs --------------------------------------------------

  @doc """
  Build the `<DescriptiveDetail>` element for a book document. Returns the
  XmlBuilder element, or `nil` when the document carries no DescriptiveDetail
  content (caller must filter nils so we never emit an empty block).
  """
  @spec descriptive_detail(map(), keyword()) :: any() | nil
  def descriptive_detail(book_doc, opts \\ []) when is_map(book_doc) do
    DescriptiveDetail.build(book_doc, opts)
  end

  @doc """
  Build Product-level `<ProductIdentifier>` elements from `productIdentifiers[]`.
  Returns a list of `XmlBuilder` elements; empty list when no identifiers
  declared. Per the mapping doc: `<ProductIDType>` carries the book.json
  `productIdType` verbatim (already the ONIX List 5 code, e.g. `"03"` GTIN-13,
  `"15"` ISBN-13).
  """
  @spec product_identifiers(map()) :: [any()]
  def product_identifiers(book_doc) when is_map(book_doc) do
    book_doc
    |> Map.get("productIdentifiers", [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(&build_product_identifier/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc false
  def collateral_detail(_book_doc, _opts) do
    raise RuntimeError,
          "Barkpark.Plugins.OnixEdit.Export.collateral_detail/2 not implemented yet — landing in WI4 (Collateral)"
  end

  @doc false
  def publishing_detail(_book_doc, _opts) do
    raise RuntimeError,
          "Barkpark.Plugins.OnixEdit.Export.publishing_detail/2 not implemented yet — landing in WI4 (Publishing)"
  end

  @doc false
  def product_supply(_book_doc, _opts) do
    raise RuntimeError,
          "Barkpark.Plugins.OnixEdit.Export.product_supply/2 not implemented yet — landing in WI4 (Supply)"
  end

  @doc false
  def validate_against_xsd(_xml_iodata, _opts) do
    raise RuntimeError,
          "Barkpark.Plugins.OnixEdit.Export.validate_against_xsd/2 not implemented yet — landing in WI5 (xmllint XSD validation gate)"
  end

  # ---- Internals --------------------------------------------------------------

  defp product(book_doc, opts) do
    published_id = Map.get(book_doc, "_publishedId") || Map.get(book_doc, :_publishedId) || ""

    host = Keyword.get(opts, :dataset_host, @default_dataset_host)
    notification_type = Map.get(book_doc, "notificationType") || "03"

    children =
      [
        XmlBuilder.element(:RecordReference, record_reference(published_id, host)),
        XmlBuilder.element(:NotificationType, notification_type)
      ] ++
        product_identifiers(book_doc) ++
        [descriptive_detail(book_doc, opts)]

    XmlBuilder.element(:Product, Enum.reject(children, &is_nil/1))
  end

  defp build_product_identifier(map) when is_map(map) do
    id_type = Map.get(map, "productIdType")
    id_value = Map.get(map, "idValue")

    cond do
      blank?(id_type) or blank?(id_value) ->
        nil

      true ->
        children =
          [
            XmlBuilder.element(:ProductIDType, id_type),
            if(present?(Map.get(map, "idTypeName")),
              do: XmlBuilder.element(:IDTypeName, Map.get(map, "idTypeName"))
            ),
            XmlBuilder.element(:IDValue, id_value)
          ]
          |> Enum.reject(&is_nil/1)

        XmlBuilder.element(:ProductIdentifier, children)
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp present?(value), do: not blank?(value)

  defp strip_drafts_prefix("drafts." <> rest), do: rest
  defp strip_drafts_prefix(id), do: id
end
