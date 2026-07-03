defmodule Barkpark.Plugins.OnixEdit.Export.CollateralDetail do
  @moduledoc """
  Builds the ONIX 3.0 `<CollateralDetail>` block.

  Two child shapes for WI4:

    * `<TextContent>` — marketing description (and any other text blurbs).
      Sourced from `book.collateralDetail.textContents[]`. Each item carries
      a `text` localizedText value resolved via `["nob", "eng", "first-non-empty"]`
      (chain declared in `text_content.json`). The xml `language` attribute
      uses ONIX List 74 / ISO 639-2/B 3-letter codes (`nob`, `nno`, `eng`).
      Internal locale tags (`nb-NO`, `nn-NO`, `en`, …) are mapped to ISO
      639-2/B via `bcp47_to_iso6392b/1`.
    * `<SupportingResource>` — cover and other supporting media.
      Sourced from `book.collateralDetail.supportingResources[]`. Each item
      carries `resourceContentType` (List 158), `contentAudience` (List 154),
      `resourceMode` (List 159) and an `arrayOf` `resourceVersions[]`
      (with `resourceForm` List 161 and `resourceLink` URI).

  ## Norwegian-locale contract

  Norwegian-first emission is the default for the export pipeline:

    * Prefer `nob` text. When resolved language is `nob` → `<Text language="nob">`.
    * Fall back to `eng` only when no Norwegian text exists. When the fallback
      fires, emit `<Text language="eng">` AND log `Logger.warning/2` so the
      operator sees the export degraded.
    * Any other resolved language is mapped to its ISO 639-2/B 3-letter code
      when known (`deu`, `fra`, `swe`, …) or `eng` as a final fallback (with
      the same `Logger.warning`) so the emitted attribute is always a valid
      ONIX List 74 value.

  Sub-blocks emit only when their data is present. Missing
  `supportingResources` → no `<SupportingResource>` children. Missing
  `textContents` → no `<TextContent>` children. If both are missing, the
  whole `<CollateralDetail>` is dropped (`build/2` returns `nil` so the
  Product orchestrator can filter it).
  """

  require Logger

  alias Barkpark.Content.LocalizedText
  alias Barkpark.Plugins.OnixEdit.Export.Codelists

  @text_content_chain ["nob", "eng", "first-non-empty"]

  # ONIX List 154 default. `<ContentAudience>` is XSD-mandatory (minOccurs=1)
  # inside both `<TextContent>` and `<SupportingResource>`. When a book omits it
  # we inject `00` (Unrestricted) — mirroring ProductSupply's default-injection
  # — so a normal-but-incomplete book still exports XSD-valid XML.
  @default_content_audience "00"

  @doc """
  Build the `<CollateralDetail>` element from a book document.

  Returns an `XmlBuilder` element tuple, or `nil` when no child sub-block
  produced output. The Product orchestrator must filter `nil` so an empty
  block does not leak into XSD-validated output.
  """
  @spec build(map(), keyword()) :: any() | nil
  def build(book_doc, _opts \\ []) when is_map(book_doc) do
    cd = Map.get(book_doc, "collateralDetail") || %{}

    text_contents =
      cd
      |> Map.get("textContents", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&build_text_content/1)
      |> Enum.reject(&is_nil/1)

    supporting_resources =
      cd
      |> Map.get("supportingResources", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&build_supporting_resource/1)
      |> Enum.reject(&is_nil/1)

    case text_contents ++ supporting_resources do
      [] -> nil
      children -> XmlBuilder.element(:CollateralDetail, children)
    end
  end

  # ---- TextContent ----------------------------------------------------------

  # ONIX `<TextContent>` content model mandates `<TextType>`, `<ContentAudience>`
  # and `<Text>` (XSD minOccurs=1). ContentAudience is defaulted to `00`, but
  # TextType and Text have no safe default — so when either is absent the whole
  # entry is dropped rather than emit XSD-invalid XML (as an empty `<Price>` is
  # already dropped in ProductSupply).
  defp build_text_content(item) when is_map(item) do
    text_type = Map.get(item, "textType")
    audience = content_audience_or_default(Map.get(item, "contentAudience"))
    text_element = build_text_element(Map.get(item, "text"))

    if present?(text_type) and not is_nil(text_element) do
      children =
        [
          XmlBuilder.element(:TextType, resolve_text_type(text_type)),
          XmlBuilder.element(:ContentAudience, resolve_content_audience(audience)),
          text_element,
          maybe_element(:TextAuthor, Map.get(item, "textAuthor")),
          maybe_element(:TextSourceCorporate, Map.get(item, "textSourceCorporate")),
          maybe_element(:TextSourceTitle, Map.get(item, "textSourceTitle"))
        ]
        |> Enum.reject(&is_nil/1)

      XmlBuilder.element(:TextContent, children)
    else
      nil
    end
  end

  defp build_text_element(value_map) when is_map(value_map) and map_size(value_map) > 0 do
    case LocalizedText.resolve(value_map, @text_content_chain) do
      {:ok, "nob", text} ->
        XmlBuilder.element(:Text, %{language: bcp47_to_iso6392b("nb-NO")}, text)

      {:ok, "eng", text} ->
        Logger.warning(
          "[onix-export] TextContent fell back to English; no Norwegian text supplied. Bokbasen ingestion may flag this as a locale degradation."
        )

        XmlBuilder.element(:Text, %{language: bcp47_to_iso6392b("en")}, text)

      {:ok, other_lang, text} ->
        iso = bcp47_to_iso6392b(other_lang)

        Logger.warning(
          "[onix-export] TextContent resolved to non-Norwegian, non-English language #{inspect(other_lang)} (ISO 639-2/B #{inspect(iso)}). No Norwegian text supplied."
        )

        XmlBuilder.element(:Text, %{language: iso}, text)

      {:error, :no_value} ->
        nil
    end
  end

  defp build_text_element(_), do: nil

  # ---- SupportingResource ---------------------------------------------------

  # ONIX `<SupportingResource>` content model mandates `<ResourceContentType>`,
  # `<ContentAudience>`, `<ResourceMode>` and at least one `<ResourceVersion>`
  # (XSD minOccurs=1). ContentAudience is defaulted to `00`; the others have no
  # safe default — so when any is absent the whole entry is dropped rather than
  # emit XSD-invalid XML.
  defp build_supporting_resource(item) when is_map(item) do
    content_type = Map.get(item, "resourceContentType")
    audience = content_audience_or_default(Map.get(item, "contentAudience"))
    mode = Map.get(item, "resourceMode")

    versions =
      item
      |> Map.get("resourceVersions", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&build_resource_version/1)
      |> Enum.reject(&is_nil/1)

    if present?(content_type) and present?(mode) and versions != [] do
      children =
        [
          XmlBuilder.element(:ResourceContentType, resolve_resource_content_type(content_type)),
          XmlBuilder.element(:ContentAudience, resolve_content_audience(audience)),
          XmlBuilder.element(:ResourceMode, resolve_resource_mode(mode))
        ]
        |> Enum.concat(versions)

      XmlBuilder.element(:SupportingResource, children)
    else
      nil
    end
  end

  # ONIX `<ResourceVersion>` mandates both `<ResourceForm>` and `<ResourceLink>`
  # (XSD minOccurs=1). Emitting one without the other is XSD-invalid, so drop the
  # version entirely unless both are present.
  defp build_resource_version(version) when is_map(version) do
    form = Map.get(version, "resourceForm")
    link = Map.get(version, "resourceLink")

    if present?(form) and present?(link) do
      XmlBuilder.element(:ResourceVersion, [
        XmlBuilder.element(:ResourceForm, resolve_resource_form(form)),
        XmlBuilder.element(:ResourceLink, link)
      ])
    else
      nil
    end
  end

  # ---- Codelist resolution helpers ------------------------------------------

  defp resolve_text_type(code) do
    {:ok, c} = Codelists.text_type(code)
    c
  end

  defp resolve_content_audience(code) do
    {:ok, c} = Codelists.content_audience(code)
    c
  end

  defp resolve_resource_content_type(code) do
    {:ok, c} = Codelists.resource_content_type(code)
    c
  end

  defp resolve_resource_mode(code) do
    {:ok, c} = Codelists.resource_mode(code)
    c
  end

  # `resource_form` (List 161) lookup — already declared by WI3? If not, this
  # delegates to a fall-through that simply passes the code through. WI3 did
  # not vendor List 161, but the values are well-known (e.g. `02 Downloadable
  # file`); for WI4 we accept any non-empty string verbatim and trust WI5's
  # XSD gate to flag invalid codes against the vendored List 161 enumeration.
  defp resolve_resource_form(code) when is_binary(code) and code != "", do: code

  # ---- Helpers --------------------------------------------------------------

  # Map BCP-47 (or pre-ISO inputs) to ONIX List 74 / ISO 639-2/B 3-letter codes.
  # ONIX 3.0 mandates the 3-letter code on `<Text language="…">` — emitting the
  # BCP-47 form fails XSD validation against List 74. Unknown inputs fall back
  # to `eng` so we never emit a non-enumerated value.
  defp bcp47_to_iso6392b("nb-NO"), do: "nob"
  defp bcp47_to_iso6392b("nb"), do: "nob"
  defp bcp47_to_iso6392b("nob"), do: "nob"
  defp bcp47_to_iso6392b("nn-NO"), do: "nno"
  defp bcp47_to_iso6392b("nn"), do: "nno"
  defp bcp47_to_iso6392b("nno"), do: "nno"
  defp bcp47_to_iso6392b("no"), do: "nor"
  defp bcp47_to_iso6392b("nor"), do: "nor"
  defp bcp47_to_iso6392b("en"), do: "eng"
  defp bcp47_to_iso6392b("eng"), do: "eng"
  defp bcp47_to_iso6392b("de"), do: "ger"
  defp bcp47_to_iso6392b("deu"), do: "ger"
  defp bcp47_to_iso6392b("ger"), do: "ger"
  defp bcp47_to_iso6392b("fr"), do: "fre"
  defp bcp47_to_iso6392b("fra"), do: "fre"
  defp bcp47_to_iso6392b("fre"), do: "fre"
  defp bcp47_to_iso6392b("es"), do: "spa"
  defp bcp47_to_iso6392b("spa"), do: "spa"
  defp bcp47_to_iso6392b("it"), do: "ita"
  defp bcp47_to_iso6392b("ita"), do: "ita"
  defp bcp47_to_iso6392b("sv"), do: "swe"
  defp bcp47_to_iso6392b("swe"), do: "swe"
  defp bcp47_to_iso6392b("da"), do: "dan"
  defp bcp47_to_iso6392b("dan"), do: "dan"
  defp bcp47_to_iso6392b(_other), do: "eng"

  defp content_audience_or_default(value) do
    if present?(value), do: value, else: @default_content_audience
  end

  defp maybe_element(_tag, blank) when blank in [nil, ""], do: nil
  defp maybe_element(tag, value) when is_binary(value), do: XmlBuilder.element(tag, value)
  defp maybe_element(tag, value), do: XmlBuilder.element(tag, to_string(value))

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: true
end
