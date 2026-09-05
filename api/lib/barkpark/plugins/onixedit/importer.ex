defmodule Barkpark.Plugins.OnixEdit.Importer do
  @moduledoc """
  Import ONIX 3.0 XML into barkpark book document content maps.

  The inverse of `Barkpark.Plugins.OnixEdit.Export`. For each `<Product>` in
  the input XML, produces a content map that round-trips byte-stably back
  through the exporter (modulo `<SentDateTime>`).

  ## Mapping shape

  ONIX nests most book-level fields inside `<DescriptiveDetail>`. The
  exporter flattens them into top-level book.json fields
  (`productForm`, `productFormDetail`, `titleDetails`, `contributors`,
  `themaSubjectCategory`, `subjects`). This importer mirrors that flattening:
  `<DescriptiveDetail>` children become siblings of top-level Product fields,
  not a nested map.

  ## Limitations

  - Unknown ONIX elements are silently skipped. They re-emerge from the
    exporter only if they were in the mapping table to begin with.
  - `<Text language="...">` round-trips only the language present in the XML.
    A book.json with both `nob` and `eng` text will export `nob` (default
    chain), and the import will only know about `nob`. That's lossy on the
    JSON→XML→JSON axis but byte-stable on the XML→JSON→XML axis (which is
    what the round-trip test asserts).
  """

  import SweetXml

  # ONIX 3.0 reference messages declare `xmlns="http://ns.editeur.org/onix/3.0/reference"`
  # as the default namespace on `<ONIXMessage>`. Threading namespace bindings
  # through every SweetXml xpath is verbose and error-prone, so we strip the
  # default xmlns declaration before parsing and run plain xpaths. The
  # exporter emits a single default xmlns (no prefixes) so this is safe.
  @onix_xmlns_re ~r/\s+xmlns="http:\/\/ns\.editeur\.org\/onix\/3\.0\/reference"/

  # Security: publisher-supplied ONIX is untrusted. A `<!DOCTYPE …>` block is
  # the entry point for both the billion-laughs internal-entity memory DoS
  # (`<!ENTITY lol "&lol1;&lol1;…">`) and XXE external-entity/file disclosure
  # (`<!ENTITY x SYSTEM "file:///etc/passwd">`). Legitimate ONIX 3.0 reference
  # messages (and everything this exporter emits) carry NO DOCTYPE, so we
  # reject any document declaring one — fail closed before xmerl ever sees it.
  @doctype_re ~r/<!DOCTYPE/i

  @doc """
  Parse an ONIX 3.0 XML binary and return `{:ok, products}` where each
  product is a content map matching the shape of
  `test/fixtures/onix/full-book.json`. The map includes `_publishedId`
  (parsed from `<RecordReference>`, with the host prefix stripped) so the
  exporter can reconstruct the same `<RecordReference>` on re-export.
  """
  @spec parse(binary()) :: {:ok, [map()]} | {:error, term()}
  def parse(xml) when is_binary(xml) do
    if Regex.match?(@doctype_re, xml) do
      {:error, {:xml_parse_failed, "DOCTYPE/DTD is not permitted in ONIX input"}}
    else
      products =
        xml
        |> strip_default_namespace()
        # `dtd: :none` is SweetXml's entity-hardening switch: it installs a
        # `fetch_fun` that refuses external-entity fetches (blocks XXE) and a
        # rules write-fn that raises on any internal `<!ENTITY>` declaration
        # before it can be expanded (blocks the billion-laughs DoS). The
        # DOCTYPE guard above is the fail-closed first line; this is xmerl-level
        # defense-in-depth. `namespace_conformant: false` keeps the existing
        # default-xmlns strip + plain-xpath parsing working unchanged.
        |> SweetXml.parse(namespace_conformant: false, dtd: :none)
        |> xpath(~x"//Product"l)
        |> Enum.map(&parse_product/1)

      {:ok, products}
    end
  rescue
    error ->
      {:error, {:xml_parse_failed, Exception.message(error)}}
  end

  defp strip_default_namespace(xml) do
    Regex.replace(@onix_xmlns_re, xml, "")
  end

  @doc """
  Derive a document id from a parsed product map. Prefers the
  `_publishedId` field (set by `parse/1` from `<RecordReference>`),
  falls back to the first `productIdentifiers[].idValue`, and finally to a
  DETERMINISTIC `imported-<hash>` derived from the record's own content.

  The fallback used to be a random `imported-<n>` placeholder. A random id
  is a data-integrity bug in an import pipeline: a record with no
  `<RecordReference>` and no `<ProductIdentifier>` drew a fresh id on every
  re-sync, so it could never dedupe through the upsert path and instead
  accumulated one duplicate draft per import run. `imported-<hash>` maps the
  same record to the same id every time, which is what the upsert path needs.
  """
  @spec doc_id_for(map()) :: String.t()
  def doc_id_for(product) when is_map(product) do
    published_id = Map.get(product, "_publishedId")

    cond do
      is_binary(published_id) and String.trim(published_id) != "" ->
        published_id

      true ->
        case Map.get(product, "productIdentifiers", []) do
          [%{"idValue" => value} | _] when is_binary(value) and value != "" ->
            value

          _ ->
            "imported-#{fallback_hash(product)}"
        end
    end
  end

  # ── Deterministic fallback id ───────────────────────────────────────────
  #
  # Identity key, in order of preference:
  #
  #   1. The NARROW key — title + first contributor name + productForm.
  #      These three are the record's bibliographic identity: an ONIX
  #      record that keeps describing the same book keeps the same title,
  #      the same lead contributor and the same product form across
  #      re-syncs, while descriptive fields (blurbs, prices, availability,
  #      supply detail) churn constantly. Keying on the narrow set is what
  #      makes a re-sync a NO-OP rather than a duplicate — hashing the whole
  #      record would re-duplicate on every price change, i.e. it would
  #      re-introduce the very bug this replaces, only less often.
  #
  #   2. If all three are empty, the record carries no bibliographic
  #      identity at all, so we fall back to a canonical encoding of the
  #      WHOLE product map. That is still deterministic (same bytes in →
  #      same id out) and it keeps two genuinely different content-free
  #      records from colliding onto one id.
  #
  # Two id-less records that agree on title AND contributor AND product form
  # collide by design: with no `<RecordReference>` and no
  # `<ProductIdentifier>`, that is the same book as far as ONIX can say.
  defp fallback_hash(product) do
    key =
      case narrow_identity(product) do
        [] -> ["whole:", canonical_iodata(product)]
        parts -> parts
      end

    :sha256
    |> :crypto.hash(IO.iodata_to_binary(key))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp narrow_identity(product) do
    parts = [
      ["title:", to_string(title_for(product) || "")],
      ["contributor:", first_contributor_name(product)],
      ["productForm:", to_string(Map.get(product, "productForm") || "")]
    ]

    if Enum.all?(parts, fn [_label, value] -> value == "" end), do: [], else: parts
  end

  defp first_contributor_name(product) do
    with [contributor | _] <- Map.get(product, "contributors", []),
         %{} = person <- Map.get(contributor, "personName") do
      Map.get(person, "personNameInverted") || Map.get(person, "personName") || ""
    else
      _ ->
        case Map.get(product, "contributors", []) do
          [%{"corporateName" => %{} = corp} | _] ->
            Map.get(corp, "corporateNameInverted") || Map.get(corp, "corporateName") || ""

          _ ->
            ""
        end
    end
  end

  # Order-independent, type-tagged encoding. Elixir map iteration order is an
  # implementation detail, so keys are sorted before encoding; the type tags
  # (`m`/`l`/`s`) keep a map from hashing the same as a list that happens to
  # flatten to the same bytes.
  defp canonical_iodata(%{} = map) do
    inner =
      map
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map(fn {k, v} -> [to_string(k), "=", canonical_iodata(v), ";"] end)

    ["m(", inner, ")"]
  end

  defp canonical_iodata(list) when is_list(list) do
    ["l(", Enum.map(list, &[canonical_iodata(&1), ";"]), ")"]
  end

  defp canonical_iodata(value) when is_binary(value), do: ["s(", value, ")"]
  defp canonical_iodata(value), do: ["s(", inspect(value), ")"]

  @doc """
  Best-effort title extraction. Walks `titleDetails[0].titleElements[0].titleText`.
  Returns `nil` when no title is present.
  """
  @spec title_for(map()) :: String.t() | nil
  def title_for(product) when is_map(product) do
    with [td | _] <- Map.get(product, "titleDetails", []),
         elements when is_list(elements) <- Map.get(td, "titleElements", []),
         [te | _] <- elements,
         text when is_binary(text) <- Map.get(te, "titleText") do
      text
    else
      _ -> nil
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # Per-product walk
  # ────────────────────────────────────────────────────────────────────────

  defp parse_product(product_node) do
    %{}
    |> put_record_reference(product_node)
    |> put_scalar(product_node, "NotificationType", "notificationType")
    |> put_scalar(product_node, "DeletionText", "deletionText")
    |> put_scalar(product_node, "RecordSourceType", "recordSourceType")
    |> put_scalar(product_node, "RecordSourceName", "recordSourceName")
    |> put_product_identifiers(product_node)
    |> put_descriptive_detail(product_node)
    |> put_collateral_detail(product_node)
    |> put_publishing_detail(product_node)
    |> put_product_supplies(product_node)
    |> prune_empties()
  end

  # ── RecordReference → _publishedId (strip host:) ────────────────────────

  defp put_record_reference(acc, node) do
    case text_at(node, ~x"./RecordReference/text()"s) do
      "" ->
        acc

      raw ->
        Map.put(acc, "_publishedId", strip_host_prefix(raw))
    end
  end

  defp strip_host_prefix(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [_host, rest] -> rest
      [only] -> only
    end
  end

  # ── ProductIdentifiers ──────────────────────────────────────────────────

  defp put_product_identifiers(acc, node) do
    ids =
      node
      |> xpath(~x"./ProductIdentifier"l)
      |> Enum.map(&parse_product_identifier/1)
      |> Enum.reject(&(&1 == %{}))

    if ids == [], do: acc, else: Map.put(acc, "productIdentifiers", ids)
  end

  defp parse_product_identifier(node) do
    %{}
    |> put_scalar(node, "ProductIDType", "productIdType")
    |> put_scalar(node, "IDTypeName", "idTypeName")
    |> put_scalar(node, "IDValue", "idValue")
  end

  # ── DescriptiveDetail (flattened to top-level book fields) ──────────────

  defp put_descriptive_detail(acc, product_node) do
    case xpath(product_node, ~x"./DescriptiveDetail"o) do
      nil ->
        acc

      dd ->
        acc
        |> put_scalar(dd, "ProductForm", "productForm")
        |> put_product_form_detail(dd)
        |> put_title_details(dd)
        |> put_contributors(dd)
        |> put_subjects(dd)
    end
  end

  defp put_product_form_detail(acc, dd_node) do
    case xpath(dd_node, ~x"./ProductFormDetail/text()"ls) do
      [] -> acc
      [one] -> Map.put(acc, "productFormDetail", one)
      many -> Map.put(acc, "productFormDetail", many)
    end
  end

  defp put_title_details(acc, dd_node) do
    details =
      dd_node
      |> xpath(~x"./TitleDetail"l)
      |> Enum.map(&parse_title_detail/1)
      |> Enum.reject(&empty_map?/1)

    if details == [], do: acc, else: Map.put(acc, "titleDetails", details)
  end

  defp parse_title_detail(node) do
    elements =
      node
      |> xpath(~x"./TitleElement"l)
      |> Enum.map(&parse_title_element/1)
      |> Enum.reject(&empty_map?/1)

    %{}
    |> put_scalar(node, "TitleType", "titleType")
    |> maybe_put("titleElements", if(elements == [], do: nil, else: elements))
  end

  defp parse_title_element(node) do
    %{}
    |> put_scalar(node, "TitleElementLevel", "titleElementLevel")
    |> put_scalar(node, "TitleText", "titleText")
    |> put_scalar(node, "Subtitle", "subtitle")
  end

  defp put_contributors(acc, dd_node) do
    contributors =
      dd_node
      |> xpath(~x"./Contributor"l)
      |> Enum.map(&parse_contributor/1)
      |> Enum.reject(&empty_map?/1)

    if contributors == [], do: acc, else: Map.put(acc, "contributors", contributors)
  end

  defp parse_contributor(node) do
    person_name =
      %{}
      |> put_scalar(node, "PersonName", "personName")
      |> put_scalar(node, "PersonNameInverted", "personNameInverted")
      |> put_scalar(node, "TitlesBeforeNames", "titlesBeforeNames")
      |> put_scalar(node, "NamesBeforeKey", "namesBeforeKey")
      |> put_scalar(node, "PrefixToKey", "prefixToKey")
      |> put_scalar(node, "KeyNames", "keyNames")
      |> put_scalar(node, "NamesAfterKey", "namesAfterKey")
      |> put_scalar(node, "SuffixToKey", "suffixToKey")
      |> put_scalar(node, "LettersAfterNames", "lettersAfterNames")
      |> put_scalar(node, "TitlesAfterNames", "titlesAfterNames")

    corporate_name =
      %{}
      |> put_scalar(node, "CorporateName", "corporateName")
      |> put_scalar(node, "CorporateNameInverted", "corporateNameInverted")

    %{}
    |> put_scalar(node, "SequenceNumber", "sequenceNumber")
    |> put_scalar(node, "ContributorRole", "contributorRole")
    |> maybe_put("personName", if(empty_map?(person_name), do: nil, else: person_name))
    |> maybe_put("corporateName", if(empty_map?(corporate_name), do: nil, else: corporate_name))
  end

  # The exporter splits subjects into two top-level book fields:
  #   • `themaSubjectCategory` — array of Thema codes from `<Subject>` whose
  #     `<SubjectSchemeIdentifier>` is `93`. The MainSubject (the one with
  #     `<MainSubject/>` child) is hoisted to the head of the array — Boss
  #     Q3 convention.
  #   • `subjects` — everything else, with the composite shape preserved.
  defp put_subjects(acc, dd_node) do
    subjects =
      dd_node
      |> xpath(~x"./Subject"l)
      |> Enum.map(&parse_subject_node/1)

    {thema, other} =
      Enum.split_with(subjects, fn s ->
        Map.get(s, "subjectSchemeIdentifier") == "93" and
          is_binary(Map.get(s, "subjectCode")) and
          Map.get(s, "subjectCode") != ""
      end)

    thema_codes =
      thema
      |> hoist_main_subject_first()
      |> Enum.map(&Map.get(&1, "subjectCode"))

    other_compact = Enum.reject(other, &empty_map?/1)

    acc
    |> maybe_put("themaSubjectCategory", if(thema_codes == [], do: nil, else: thema_codes))
    |> maybe_put("subjects", if(other_compact == [], do: nil, else: other_compact))
  end

  defp hoist_main_subject_first(thema) do
    {mains, rest} = Enum.split_with(thema, &(Map.get(&1, "mainSubject") == true))
    mains ++ rest
  end

  defp parse_subject_node(node) do
    main =
      case xpath(node, ~x"./MainSubject"o) do
        nil -> false
        _ -> true
      end

    %{}
    |> maybe_put("mainSubject", if(main, do: true, else: nil))
    |> put_scalar(node, "SubjectSchemeIdentifier", "subjectSchemeIdentifier")
    |> put_scalar(node, "SubjectSchemeName", "subjectSchemeName")
    |> put_scalar(node, "SubjectSchemeVersion", "subjectSchemeVersion")
    |> put_scalar(node, "SubjectCode", "subjectCode")
    |> put_scalar(node, "SubjectHeadingText", "subjectHeadingText")
  end

  # ── CollateralDetail ────────────────────────────────────────────────────

  defp put_collateral_detail(acc, product_node) do
    case xpath(product_node, ~x"./CollateralDetail"o) do
      nil ->
        acc

      cd ->
        text_contents =
          cd
          |> xpath(~x"./TextContent"l)
          |> Enum.map(&parse_text_content/1)
          |> Enum.reject(&empty_map?/1)

        supporting_resources =
          cd
          |> xpath(~x"./SupportingResource"l)
          |> Enum.map(&parse_supporting_resource/1)
          |> Enum.reject(&empty_map?/1)

        block =
          %{}
          |> maybe_put("textContents", if(text_contents == [], do: nil, else: text_contents))
          |> maybe_put(
            "supportingResources",
            if(supporting_resources == [], do: nil, else: supporting_resources)
          )

        if empty_map?(block), do: acc, else: Map.put(acc, "collateralDetail", block)
    end
  end

  defp parse_text_content(node) do
    text_value = text_at(node, ~x"./Text/text()"s)
    text_lang = text_at(node, ~x"./Text/@language"s)

    text_map =
      cond do
        text_value == "" -> nil
        text_lang == "" -> %{"first-non-empty" => text_value}
        true -> %{text_lang => text_value}
      end

    %{}
    |> put_scalar(node, "TextType", "textType")
    |> put_scalar(node, "ContentAudience", "contentAudience")
    |> maybe_put("text", text_map)
    |> put_scalar(node, "TextAuthor", "textAuthor")
    |> put_scalar(node, "TextSourceCorporate", "textSourceCorporate")
    |> put_scalar(node, "TextSourceTitle", "textSourceTitle")
  end

  defp parse_supporting_resource(node) do
    versions =
      node
      |> xpath(~x"./ResourceVersion"l)
      |> Enum.map(&parse_resource_version/1)
      |> Enum.reject(&empty_map?/1)

    %{}
    |> put_scalar(node, "ResourceContentType", "resourceContentType")
    |> put_scalar(node, "ContentAudience", "contentAudience")
    |> put_scalar(node, "ResourceMode", "resourceMode")
    |> maybe_put("resourceVersions", if(versions == [], do: nil, else: versions))
  end

  defp parse_resource_version(node) do
    %{}
    |> put_scalar(node, "ResourceForm", "resourceForm")
    |> put_scalar(node, "ResourceLink", "resourceLink")
  end

  # ── PublishingDetail ────────────────────────────────────────────────────

  defp put_publishing_detail(acc, product_node) do
    case xpath(product_node, ~x"./PublishingDetail"o) do
      nil ->
        acc

      pd ->
        imprint = parse_imprint(xpath(pd, ~x"./Imprint"o))

        publishers =
          pd
          |> xpath(~x"./Publisher"l)
          |> Enum.map(&parse_publisher/1)
          |> Enum.reject(&empty_map?/1)

        publishing_dates =
          pd
          |> xpath(~x"./PublishingDate"l)
          |> Enum.map(&parse_publishing_date/1)
          |> Enum.reject(&empty_map?/1)

        block =
          %{}
          |> maybe_put("imprint", if(empty_map?(imprint), do: nil, else: imprint))
          |> maybe_put("publishers", if(publishers == [], do: nil, else: publishers))
          |> maybe_put(
            "publishingDates",
            if(publishing_dates == [], do: nil, else: publishing_dates)
          )

        if empty_map?(block), do: acc, else: Map.put(acc, "publishingDetail", block)
    end
  end

  defp parse_imprint(nil), do: %{}

  defp parse_imprint(node) do
    identifier =
      case xpath(node, ~x"./ImprintIdentifier"o) do
        nil ->
          nil

        id_node ->
          id =
            %{}
            |> put_scalar(id_node, "ImprintIDType", "imprintIDType")
            |> put_scalar(id_node, "IDValue", "idValue")

          if empty_map?(id), do: nil, else: id
      end

    %{}
    |> maybe_put("imprintIdentifier", identifier)
    |> put_scalar(node, "ImprintName", "imprintName")
  end

  defp parse_publisher(node) do
    identifier =
      case xpath(node, ~x"./PublisherIdentifier"o) do
        nil ->
          nil

        id_node ->
          id =
            %{}
            |> put_scalar(id_node, "PublisherIDType", "publisherIDType")
            |> put_scalar(id_node, "IDValue", "idValue")

          if empty_map?(id), do: nil, else: id
      end

    %{}
    |> put_scalar(node, "PublishingRole", "publishingRole")
    |> maybe_put("publisherIdentifier", identifier)
    |> put_scalar(node, "PublisherName", "publisherName")
  end

  # ONIX `<Date>` is compact `YYYYMMDD`. The exporter accepts ISO-8601
  # (`YYYY-MM-DD`) and strips dashes on the way out. To round-trip
  # byte-stably, the importer rehydrates compact → ISO so the exporter
  # produces the same compact form. (A book.json `date` of `"20260429"`
  # would also round-trip, but `"2026-04-29"` is the canonical form
  # in book.json fixtures.)
  defp parse_publishing_date(node) do
    role = text_at(node, ~x"./PublishingDateRole/text()"s)
    raw_date = text_at(node, ~x"./Date/text()"s)
    iso_date = compact_to_iso(raw_date)

    %{}
    |> maybe_put("publishingDateRole", presence(role))
    |> maybe_put("date", presence(iso_date))
  end

  defp compact_to_iso(""), do: ""

  defp compact_to_iso(<<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>) do
    "#{y}-#{m}-#{d}"
  end

  defp compact_to_iso(other), do: other

  # ── ProductSupply ───────────────────────────────────────────────────────

  defp put_product_supplies(acc, product_node) do
    supplies =
      product_node
      |> xpath(~x"./ProductSupply"l)
      |> Enum.map(&parse_product_supply/1)
      |> Enum.reject(&empty_map?/1)

    if supplies == [], do: acc, else: Map.put(acc, "productSupplies", supplies)
  end

  defp parse_product_supply(node) do
    market = parse_market(xpath(node, ~x"./Market"o))
    market_pub = parse_market_publishing(xpath(node, ~x"./MarketPublishingDetail"o))

    supply_details =
      node
      |> xpath(~x"./SupplyDetail"l)
      |> Enum.map(&parse_supply_detail/1)
      |> Enum.reject(&empty_map?/1)

    %{}
    |> maybe_put("market", if(empty_map?(market), do: nil, else: market))
    |> maybe_put(
      "marketPublishingDetail",
      if(empty_map?(market_pub), do: nil, else: market_pub)
    )
    |> maybe_put(
      "supplyDetails",
      if(supply_details == [], do: nil, else: supply_details)
    )
  end

  defp parse_market(nil), do: %{}

  defp parse_market(node) do
    territory = parse_territory(xpath(node, ~x"./Territory"o))
    maybe_put(%{}, "territory", if(empty_map?(territory), do: nil, else: territory))
  end

  defp parse_territory(nil), do: %{}

  defp parse_territory(node) do
    countries =
      case text_at(node, ~x"./CountriesIncluded/text()"s) do
        "" -> []
        joined -> String.split(joined, ~r/\s+/, trim: true)
      end

    maybe_put(%{}, "countries", if(countries == [], do: nil, else: countries))
  end

  defp parse_market_publishing(nil), do: %{}

  defp parse_market_publishing(node) do
    reps =
      node
      |> xpath(~x"./PublisherRepresentative"l)
      |> Enum.map(&parse_publisher_representative/1)
      |> Enum.reject(&empty_map?/1)

    maybe_put(
      %{},
      "publisherRepresentatives",
      if(reps == [], do: nil, else: reps)
    )
  end

  defp parse_publisher_representative(node) do
    %{}
    |> put_scalar(node, "AgentRole", "agentRole")
    |> put_scalar(node, "AgentName", "agentName")
  end

  defp parse_supply_detail(node) do
    supplier =
      case xpath(node, ~x"./Supplier"o) do
        nil -> %{}
        s -> parse_supplier(s)
      end

    prices =
      node
      |> xpath(~x"./Price"l)
      |> Enum.map(&parse_price/1)
      |> Enum.reject(&empty_map?/1)

    %{}
    |> maybe_put("supplier", if(empty_map?(supplier), do: nil, else: supplier))
    |> put_scalar(node, "ProductAvailability", "productAvailability")
    |> maybe_put("prices", if(prices == [], do: nil, else: prices))
    |> put_scalar(node, "UnpricedItemType", "unpricedItemType")
  end

  defp parse_supplier(node) do
    %{}
    |> put_scalar(node, "SupplierRole", "supplierRole")
    |> put_scalar(node, "SupplierName", "supplierName")
  end

  defp parse_price(node) do
    %{}
    |> put_scalar(node, "PriceType", "priceType")
    |> put_scalar(node, "PriceAmount", "priceAmount")
    |> put_scalar(node, "CurrencyCode", "currencyCode")
  end

  # ────────────────────────────────────────────────────────────────────────
  # Generic helpers
  # ────────────────────────────────────────────────────────────────────────

  # Pull the text content of a single child element (by ONIX local name)
  # and stamp it into the accumulator under `field` if present. Uses a
  # manually-built `%SweetXpath{}` because the `~x` sigil is a compile-time
  # macro and cannot interpolate the element name at runtime.
  defp put_scalar(acc, node, onix_name, field) do
    case text_at(node, build_text_xpath(onix_name)) do
      "" -> acc
      value -> Map.put(acc, field, value)
    end
  end

  defp build_text_xpath(local_name) when is_binary(local_name) do
    %SweetXpath{
      path: ~c"./" ++ String.to_charlist(local_name) ++ ~c"/text()",
      is_value: true,
      is_list: false,
      is_keyword: false,
      is_optional: false,
      cast_to: :string,
      namespaces: []
    }
  end

  defp text_at(node, xpath_spec) do
    case xpath(node, xpath_spec) do
      nil -> ""
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  defp maybe_put(acc, _key, nil), do: acc
  defp maybe_put(acc, _key, ""), do: acc
  defp maybe_put(acc, key, value), do: Map.put(acc, key, value)

  defp empty_map?(%{} = m), do: map_size(m) == 0
  defp empty_map?(_), do: false

  defp presence(""), do: nil
  defp presence(value), do: value

  # Drop top-level keys whose values came out empty after walking
  # (sub-blocks already handle their own emptiness).
  defp prune_empties(map) do
    Enum.reduce(map, %{}, fn
      {_k, ""}, acc -> acc
      {_k, nil}, acc -> acc
      {_k, []}, acc -> acc
      {k, v}, acc -> Map.put(acc, k, v)
    end)
  end
end
