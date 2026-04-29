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

  alias Barkpark.Plugins.OnixEdit.Export.{Header, Message}

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
  Serialize a single book document. WI2 ships an empty `<Product/>` placeholder;
  WI3 (DescriptiveDetail) and WI4 (Collateral/Publishing/Supply) fill it.
  """
  @spec to_xml(map(), keyword()) :: iodata()
  def to_xml(book_doc, opts \\ []) when is_map(book_doc) do
    header = Header.build(opts)
    products = empty_product_placeholder(book_doc, opts)
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

  @doc false
  def descriptive_detail(_book_doc, _opts) do
    raise RuntimeError,
          "Barkpark.Plugins.OnixEdit.Export.descriptive_detail/2 not implemented yet — landing in WI3 (DescriptiveDetail: title, contributors, Thema subjects, product form)"
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

  defp empty_product_placeholder(book_doc, opts) do
    published_id = Map.get(book_doc, "_publishedId") || Map.get(book_doc, :_publishedId) || ""

    host = Keyword.get(opts, :dataset_host, @default_dataset_host)

    XmlBuilder.element(:Product, [
      XmlBuilder.element(:RecordReference, record_reference(published_id, host)),
      XmlBuilder.element(:NotificationType, "03")
    ])
  end

  defp strip_drafts_prefix("drafts." <> rest), do: rest
  defp strip_drafts_prefix(id), do: id
end
