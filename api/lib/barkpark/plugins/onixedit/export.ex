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

  alias Barkpark.Plugins.OnixEdit.Export.{
    CollateralDetail,
    DescriptiveDetail,
    Header,
    Message,
    PublishingDetail,
    ProductSupply,
    Validator
  }

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
    book_doc = sanitize_xml_text(book_doc)
    header = Header.build(opts)
    products = product(book_doc, opts)
    Message.wrap(header, products)
  end

  # XML 1.0 (which ONIX 3.0 uses) forbids the C0 control chars — 0x00–0x08,
  # 0x0B, 0x0C, 0x0E–0x1F — even when escaped; they cannot be represented at
  # all. XmlBuilder's escaper only handles `& < > " '` and passes every other
  # codepoint through verbatim, so a control char pasted into a title or blurb
  # (common from Word/PDF/InDesign) makes xmllint reject the whole export
  # ("PCDATA invalid Char value N") → `to_iodata` returns `{:xsd_invalid, …}` →
  # the document is permanently un-exportable (HTTP 500) and un-publishable
  # (Bokbasen never submits). Strip those chars from every string value in the
  # document before the builders run, keeping the XML-legal tab/newline/CR
  # (0x09/0x0A/0x0D). Control chars are never meaningful in any ONIX field, so a
  # blanket deep-strip is safe.
  @illegal_xml_chars ~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/u
  defp sanitize_xml_text(v) when is_binary(v), do: String.replace(v, @illegal_xml_chars, "")

  defp sanitize_xml_text(v) when is_map(v),
    do: Map.new(v, fn {k, val} -> {k, sanitize_xml_text(val)} end)

  defp sanitize_xml_text(v) when is_list(v), do: Enum.map(v, &sanitize_xml_text/1)
  defp sanitize_xml_text(v), do: v

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

  @doc """
  Build the `<CollateralDetail>` element. Returns the XmlBuilder element, or
  `nil` when the document carries no collateral content.
  """
  @spec collateral_detail(map(), keyword()) :: any() | nil
  def collateral_detail(book_doc, opts \\ []) when is_map(book_doc) do
    CollateralDetail.build(book_doc, opts)
  end

  @doc """
  Build the `<PublishingDetail>` element. Returns the XmlBuilder element, or
  `nil` when the document carries no publishing detail.
  """
  @spec publishing_detail(map(), keyword()) :: any() | nil
  def publishing_detail(book_doc, opts \\ []) when is_map(book_doc) do
    PublishingDetail.build(book_doc, opts)
  end

  @doc """
  Build a list of `<ProductSupply>` elements. Returns a list (one per
  productSupplies entry, or one synthesized default), or `nil` when no
  ProductSupply children should be emitted.
  """
  @spec product_supply(map(), keyword()) :: any() | [any()] | nil
  def product_supply(book_doc, opts \\ []) when is_map(book_doc) do
    ProductSupply.build(book_doc, opts)
  end

  @doc """
  Validate an exported ONIX iodata payload against the vendored EDItEUR ONIX
  3.0 XSD. Returns `:ok` on success or `{:error, [reason, ...]}` on failure.
  Thin wrapper over `Barkpark.Plugins.OnixEdit.Export.Validator.validate_xsd/2`;
  see that module for xmllint and CI integration notes.
  """
  @spec validate_against_xsd(iodata(), Path.t()) :: :ok | {:error, [String.t()]}
  def validate_against_xsd(xml_iodata, xsd_path \\ Validator.default_xsd_path()) do
    Validator.validate_xsd(xml_iodata, xsd_path)
  end

  # ---- WI6 file/string output API --------------------------------------------

  @doc """
  Render a book document to ONIX 3.0 XML iodata, gated on XSD validation.
  Returns `{:ok, iodata}` only when the rendered XML validates against the
  vendored EDItEUR ONIX 3.0 reference XSD. Returns
  `{:error, {:xsd_invalid, reasons}}` otherwise so callers can never emit
  schema-invalid XML downstream.
  """
  @spec to_iodata(map(), keyword()) ::
          {:ok, iodata()}
          | {:error, {:xsd_invalid, [String.t()]}}
          | {:error, {:invalid_code, map()}}
  def to_iodata(book_doc, opts \\ []) when is_map(book_doc) do
    # The codelist resolvers (`Codelists.contributor_role/1` etc.) `raise`
    # `ArgumentError` on a code that is not in their intentionally-small
    # representative maps — a valid-but-unseeded ONIX code (e.g. currency
    # `CAD`, an uncommon contributor role, most Thema codes) or a non-string
    # value. That raise would otherwise escape `to_iodata` and hit its three
    # callers RAW: the HTTP export controller (→ generic 500, no body), the
    # dryrun preview, and — worst — the Bokbasen publish worker, where it
    # escapes `perform/1` so Oban poison-retries with the doc stranded at
    # `"staging"`. Catch it here, at the single boundary all three share, and
    # convert to a sibling `{:error, {:invalid_code, …}}` envelope that plugs
    # into the same `case` those callers already run for `{:xsd_invalid, …}`.
    iodata = to_xml(book_doc, opts)
    binary = IO.iodata_to_binary(iodata)

    case Validator.validate_xsd(binary) do
      :ok -> {:ok, iodata}
      {:error, reasons} -> {:error, {:xsd_invalid, reasons}}
    end
  rescue
    e in [ArgumentError, FunctionClauseError] ->
      stack = __STACKTRACE__

      if codelist_raise?(stack) do
        {:error, {:invalid_code, invalid_code_detail(e)}}
      else
        reraise e, stack
      end
  end

  @codelists_module Barkpark.Plugins.OnixEdit.Export.Codelists

  # True only when the top stack frame is inside the Codelists resolver module,
  # so a genuine ArgumentError/FunctionClauseError bug elsewhere in the render
  # path is re-raised, never silently swallowed as an "invalid code".
  defp codelist_raise?([{@codelists_module, _fun, _arity, _loc} | _]), do: true
  defp codelist_raise?(_), do: false

  # Shape the caught resolver raise into a structured, JSON-safe diagnostic
  # carrying the offending codelist + code so all three callers can tell the
  # operator exactly which field is unrenderable.
  defp invalid_code_detail(%ArgumentError{message: msg}) when is_binary(msg) do
    case Regex.run(~r/^unknown_(.+)_code: (.+)$/, msg) do
      [_, codelist, inspected_code] ->
        %{"codelist" => codelist, "code" => strip_inspect(inspected_code), "message" => msg}

      _ ->
        %{"codelist" => nil, "code" => nil, "message" => msg}
    end
  end

  defp invalid_code_detail(%FunctionClauseError{function: fun} = e) do
    %{
      "codelist" => Atom.to_string(fun),
      "code" => nil,
      "message" => "non-string ONIX code passed to #{fun}: " <> Exception.message(e)
    }
  end

  defp invalid_code_detail(e) do
    %{"codelist" => nil, "code" => nil, "message" => Exception.message(e)}
  end

  # "\"CAD\"" (the inspected form embedded in the resolver's raise message) → "CAD".
  defp strip_inspect(<<?", rest::binary>>), do: String.trim_trailing(rest, "\"")
  defp strip_inspect(other), do: other

  @doc """
  Render a book document to a UTF-8 ONIX 3.0 XML binary, gated on XSD
  validation. Same error envelope as `to_iodata/1`.
  """
  @spec to_string(map(), keyword()) ::
          {:ok, binary()}
          | {:error, {:xsd_invalid, [String.t()]}}
          | {:error, {:invalid_code, map()}}
  def to_string(book_doc, opts \\ []) when is_map(book_doc) do
    case to_iodata(book_doc, opts) do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Render a book document and write the resulting ONIX 3.0 XML to `path`.
  Validation runs before the write, so a validation failure short-circuits
  and never touches the filesystem. Returns `:ok` on success,
  `{:error, {:xsd_invalid, reasons}}` on validation failure, or
  `{:error, posix_reason}` from `File.write/2`.
  """
  @spec to_file(map(), Path.t(), keyword()) ::
          :ok
          | {:error, {:xsd_invalid, [String.t()]}}
          | {:error, {:invalid_code, map()}}
          | {:error, File.posix()}
  def to_file(book_doc, path, opts \\ []) when is_map(book_doc) and is_binary(path) do
    with {:ok, binary} <- __MODULE__.to_string(book_doc, opts),
         :ok <- File.write(path, binary) do
      :ok
    else
      {:error, _} = err -> err
    end
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
        [
          descriptive_detail(book_doc, opts),
          collateral_detail(book_doc, opts),
          publishing_detail(book_doc, opts)
        ] ++
        List.wrap(product_supply(book_doc, opts))

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
