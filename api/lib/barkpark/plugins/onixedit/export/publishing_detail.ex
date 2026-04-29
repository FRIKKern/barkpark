defmodule Barkpark.Plugins.OnixEdit.Export.PublishingDetail do
  @moduledoc """
  Builds the ONIX 3.0 `<PublishingDetail>` block.

  Children for WI4 (subset of the ONIX 3.0 PublishingDetail content model;
  remaining fields — countryOfPublication, copyrightStatement, salesRights —
  are deferred to later WIs / Phase 8):

    * `<Imprint>` — from `book.publishingDetail.imprint`. Carries the
      imprint identifier (NameCodeType + IDValue, when present) followed by
      `<ImprintName>`.
    * `<Publisher>` — one element per `book.publishingDetail.publishers[]`
      entry. Includes `<PublishingRole>` (List 45, defaults to `01`
      "Publisher" when book.json omits it) and `<PublisherName>`.
    * `<PublishingDate>` — one element per `book.publishingDetail.publishingDates[]`
      entry. `<PublishingDateRole>` defaults to `01` (Publication date) when
      book.json omits it. The `<Date>` element is emitted in compact ONIX
      `YYYYMMDD` format — ISO-8601 inputs (`YYYY-MM-DD`, `YYYY-MM-DDTHH:MM:SSZ`)
      are stripped of dashes / time component before emission.

  Returns `nil` when none of the children produce output, so the Product
  orchestrator can drop the empty wrapper rather than emit `<PublishingDetail/>`
  (XSD-invalid).
  """

  alias Barkpark.Plugins.OnixEdit.Export.Codelists

  @doc """
  Build a `<PublishingDetail>` element from a book document.
  """
  @spec build(map(), keyword()) :: any() | nil
  def build(book_doc, _opts \\ []) when is_map(book_doc) do
    pd = Map.get(book_doc, "publishingDetail") || %{}

    children =
      [
        build_imprint(Map.get(pd, "imprint")),
        build_publishers(Map.get(pd, "publishers", [])),
        build_publishing_dates(Map.get(pd, "publishingDates", []))
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    case children do
      [] -> nil
      _ -> XmlBuilder.element(:PublishingDetail, children)
    end
  end

  # ---- Imprint --------------------------------------------------------------

  defp build_imprint(imprint) when is_map(imprint) do
    name = Map.get(imprint, "imprintName")
    id_block = build_imprint_identifier(Map.get(imprint, "imprintIdentifier"))

    children =
      (List.wrap(id_block) ++ [maybe_element(:ImprintName, name)])
      |> Enum.reject(&is_nil/1)

    case children do
      [] -> nil
      _ -> XmlBuilder.element(:Imprint, children)
    end
  end

  defp build_imprint(_), do: nil

  defp build_imprint_identifier(id) when is_map(id) do
    type = Map.get(id, "imprintIDType")
    value = Map.get(id, "idValue")

    cond do
      blank?(type) and blank?(value) ->
        nil

      true ->
        children =
          [
            if(present?(type), do: XmlBuilder.element(:ImprintIDType, type)),
            maybe_element(:IDValue, value)
          ]
          |> Enum.reject(&is_nil/1)

        XmlBuilder.element(:ImprintIdentifier, children)
    end
  end

  defp build_imprint_identifier(_), do: nil

  # ---- Publishers (list 45) -------------------------------------------------

  defp build_publishers(list) when is_list(list) do
    list
    |> Enum.filter(&is_map/1)
    |> Enum.map(&build_publisher/1)
    |> Enum.reject(&is_nil/1)
  end

  defp build_publishers(_), do: []

  defp build_publisher(publisher) when is_map(publisher) do
    role = Map.get(publisher, "publishingRole") || "01"
    name = Map.get(publisher, "publisherName")
    id_block = build_publisher_identifier(Map.get(publisher, "publisherIdentifier"))

    role_element =
      case role do
        code when is_binary(code) and code != "" ->
          {:ok, c} = Codelists.publishing_role(code)
          XmlBuilder.element(:PublishingRole, c)

        _ ->
          nil
      end

    children =
      [role_element, id_block, maybe_element(:PublisherName, name)]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    if blank?(name) and is_nil(id_block) do
      nil
    else
      XmlBuilder.element(:Publisher, children)
    end
  end

  defp build_publisher_identifier(id) when is_map(id) do
    type = Map.get(id, "publisherIDType")
    value = Map.get(id, "idValue")

    cond do
      blank?(type) and blank?(value) ->
        nil

      true ->
        children =
          [
            if(present?(type), do: XmlBuilder.element(:PublisherIDType, type)),
            maybe_element(:IDValue, value)
          ]
          |> Enum.reject(&is_nil/1)

        XmlBuilder.element(:PublisherIdentifier, children)
    end
  end

  defp build_publisher_identifier(_), do: nil

  # ---- PublishingDate (list 163) --------------------------------------------

  defp build_publishing_dates(list) when is_list(list) do
    list
    |> Enum.filter(&is_map/1)
    |> Enum.map(&build_publishing_date/1)
    |> Enum.reject(&is_nil/1)
  end

  defp build_publishing_dates(_), do: []

  defp build_publishing_date(item) when is_map(item) do
    role = Map.get(item, "publishingDateRole") || "01"
    date = Map.get(item, "date")

    case format_compact_date(date) do
      nil ->
        nil

      compact ->
        {:ok, role_code} = Codelists.publishing_date_role(role)

        XmlBuilder.element(:PublishingDate, [
          XmlBuilder.element(:PublishingDateRole, role_code),
          XmlBuilder.element(:Date, compact)
        ])
    end
  end

  # Strip dashes / time component from ISO `YYYY-MM-DD[THH:MM:SS]` to ONIX
  # compact `YYYYMMDD`. Returns `nil` for blanks/non-strings.
  defp format_compact_date(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        nil

      true ->
        date_part = trimmed |> String.split("T", parts: 2) |> List.first()
        compact = String.replace(date_part, "-", "")
        if compact == "", do: nil, else: compact
    end
  end

  defp format_compact_date(_), do: nil

  # ---- Helpers --------------------------------------------------------------

  defp maybe_element(_tag, blank) when blank in [nil, ""], do: nil
  defp maybe_element(tag, value) when is_binary(value), do: XmlBuilder.element(tag, value)
  defp maybe_element(tag, value), do: XmlBuilder.element(tag, to_string(value))

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp present?(value), do: not blank?(value)
end
