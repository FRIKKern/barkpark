defmodule Barkpark.Plugins.OnixEdit.Export.DescriptiveDetail do
  @moduledoc """
  Builder for the ONIX 3.0 `<DescriptiveDetail>` block.

  WI3 covers six sub-blocks (the seventh — `<ProductIdentifier>` — sits at the
  Product level, not under DescriptiveDetail, and is built by
  `Barkpark.Plugins.OnixEdit.Export.product_identifiers/1`):

    1. `<ProductComposition>` — fixed `"00"` (single-item retail product) for
       v1; book.json does not surface this knob today.
    2. `<ProductForm>` — book.json `productForm` resolved through code list 150.
    3. `<ProductFormDetail>` — zero-or-more book.json `productFormDetail`
       (single value or list) resolved through list 175.
    4. `<TitleDetail>` — derived from the first entry of book.json
       `titleDetails[]`, which carries `titleStatement` + `titleElements[]`
       composites; v1 emits a single `<TitleDetail>` with `<TitleType>01</TitleType>`.
    5. `<Contributor>+` — one element per book.json `contributors[]` entry,
       carrying SequenceNumber, ContributorRole (list 17), the PersonName name
       parts (PersonName / NamesBeforeKey / KeyNames / NamesAfterKey).
    6. `<Subject>+` — Boss Q3 convention: first Thema in
       `themaSubjectCategory[]` → `<Subject>` with an empty `<MainSubject/>`
       flag as its first child, then `<SubjectSchemeIdentifier>93`. Remaining
       Thema codes → `<Subject>` without the MainSubject flag. ONIX 3.0 XSD
       models `MainSubject` as a child of `<Subject>`, not a sibling. Free-form
       `subjects[]` entries (book.json Subject composite) are passed through
       unchanged after the Thema set.

  Sub-blocks for which book.json declares no value are silently skipped — empty
  `<DescriptiveDetail/>` is preferable to a wall of empty tags. Unknown
  codelist values raise via `Barkpark.Plugins.OnixEdit.Export.Codelists`;
  silent fall-through is unsafe (XSD gate would catch it much later).
  """

  alias Barkpark.Plugins.OnixEdit.Export.Codelists

  @doc """
  Build the `<DescriptiveDetail>` element from a book document map.

  Returns an `XmlBuilder` element (not iodata). Returns `nil` if no
  child sub-block produced output — caller should filter nils so an empty
  block does not leak into Product.
  """
  @spec build(map(), keyword()) :: any() | nil
  def build(book_doc, _opts \\ []) when is_map(book_doc) do
    children =
      [
        product_composition(book_doc),
        product_form(book_doc),
        product_form_detail(book_doc),
        title_detail(book_doc),
        contributors(book_doc),
        subjects(book_doc)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    case children do
      [] -> nil
      _ -> XmlBuilder.element(:DescriptiveDetail, children)
    end
  end

  # ---- ProductComposition (list 2) -------------------------------------------

  @doc false
  def product_composition(_book_doc) do
    XmlBuilder.element(:ProductComposition, "00")
  end

  # ---- ProductForm (list 150) -----------------------------------------------

  @doc false
  def product_form(book_doc) do
    case Map.get(book_doc, "productForm") do
      blank when blank in [nil, ""] ->
        nil

      code when is_binary(code) ->
        {:ok, code} = Codelists.product_form(code)
        XmlBuilder.element(:ProductForm, code)
    end
  end

  # ---- ProductFormDetail (list 175) -----------------------------------------

  @doc false
  def product_form_detail(book_doc) do
    case Map.get(book_doc, "productFormDetail") do
      blank when blank in [nil, ""] ->
        nil

      code when is_binary(code) ->
        [build_product_form_detail(code)]

      codes when is_list(codes) ->
        codes
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.map(&build_product_form_detail/1)
    end
  end

  defp build_product_form_detail(code) when is_binary(code) do
    {:ok, code} = Codelists.product_form_detail(code)
    XmlBuilder.element(:ProductFormDetail, code)
  end

  # ---- TitleDetail ----------------------------------------------------------

  @doc false
  def title_detail(book_doc) do
    case Map.get(book_doc, "titleDetails") do
      list when is_list(list) and list != [] ->
        list
        |> Enum.reject(&(!is_map(&1)))
        |> Enum.map(&build_title_detail/1)

      _ ->
        nil
    end
  end

  defp build_title_detail(title_detail) when is_map(title_detail) do
    title_type = Map.get(title_detail, "titleType") || "01"
    elements = Map.get(title_detail, "titleElements") || []

    title_elements =
      elements
      |> Enum.filter(&is_map/1)
      |> Enum.map(&build_title_element/1)
      |> Enum.reject(&is_nil/1)

    if title_elements == [] do
      nil
    else
      XmlBuilder.element(
        :TitleDetail,
        [XmlBuilder.element(:TitleType, title_type) | title_elements]
      )
    end
  end

  defp build_title_element(element) when is_map(element) do
    level = Map.get(element, "titleElementLevel") || "01"
    title_text = Map.get(element, "titleText")
    subtitle = Map.get(element, "subtitle")

    children =
      [
        XmlBuilder.element(:TitleElementLevel, level),
        if(present?(title_text), do: XmlBuilder.element(:TitleText, title_text)),
        if(present?(subtitle), do: XmlBuilder.element(:Subtitle, subtitle))
      ]
      |> Enum.reject(&is_nil/1)

    if Enum.any?(children, &is_title_text_or_subtitle?/1) do
      XmlBuilder.element(:TitleElement, children)
    else
      nil
    end
  end

  defp is_title_text_or_subtitle?({:TitleText, _, _}), do: true
  defp is_title_text_or_subtitle?({:Subtitle, _, _}), do: true
  defp is_title_text_or_subtitle?(_), do: false

  # ---- Contributors (list 17) -----------------------------------------------

  @doc false
  def contributors(book_doc) do
    case Map.get(book_doc, "contributors") do
      list when is_list(list) and list != [] ->
        list
        |> Enum.with_index(1)
        |> Enum.map(fn {c, idx} -> build_contributor(c, idx) end)
        |> Enum.reject(&is_nil/1)

      _ ->
        nil
    end
  end

  defp build_contributor(contributor, default_seq) when is_map(contributor) do
    seq = Map.get(contributor, "sequenceNumber") || to_string(default_seq)
    role = Map.get(contributor, "contributorRole")

    role_element =
      case role do
        nil ->
          nil

        "" ->
          nil

        code when is_binary(code) ->
          {:ok, code} = Codelists.contributor_role(code)
          XmlBuilder.element(:ContributorRole, code)
      end

    name_elements = build_name_block(contributor)

    children =
      [
        XmlBuilder.element(:SequenceNumber, seq),
        role_element | name_elements
      ]
      |> Enum.reject(&is_nil/1)

    # A contributor with neither role nor any name block is meaningless — skip.
    if role_element == nil and name_elements == [] do
      nil
    else
      XmlBuilder.element(:Contributor, children)
    end
  end

  defp build_contributor(_, _), do: nil

  defp build_name_block(contributor) do
    person_name = Map.get(contributor, "personName")
    corporate = Map.get(contributor, "corporateName")

    cond do
      is_map(person_name) ->
        person_name_elements(person_name)

      is_map(corporate) ->
        corporate_name_elements(corporate)

      true ->
        []
    end
  end

  defp person_name_elements(map) do
    [
      maybe_element(:PersonName, Map.get(map, "personName")),
      maybe_element(:PersonNameInverted, Map.get(map, "personNameInverted")),
      maybe_element(:TitlesBeforeNames, Map.get(map, "titlesBeforeNames")),
      maybe_element(:NamesBeforeKey, Map.get(map, "namesBeforeKey")),
      maybe_element(:PrefixToKey, Map.get(map, "prefixToKey")),
      maybe_element(:KeyNames, Map.get(map, "keyNames")),
      maybe_element(:NamesAfterKey, Map.get(map, "namesAfterKey")),
      maybe_element(:SuffixToKey, Map.get(map, "suffixToKey")),
      maybe_element(:LettersAfterNames, Map.get(map, "lettersAfterNames")),
      maybe_element(:TitlesAfterNames, Map.get(map, "titlesAfterNames"))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp corporate_name_elements(map) do
    [
      maybe_element(:CorporateName, Map.get(map, "corporateName")),
      maybe_element(:CorporateNameInverted, Map.get(map, "corporateNameInverted"))
    ]
    |> Enum.reject(&is_nil/1)
  end

  # ---- Subjects (Thema list 93 + free-form Subject) -------------------------

  @doc false
  def subjects(book_doc) do
    thema_codes =
      book_doc
      |> Map.get("themaSubjectCategory", [])
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    free_subjects = Map.get(book_doc, "subjects", [])

    thema_elements =
      case thema_codes do
        [] ->
          []

        [first | rest] ->
          {:ok, first_code} = Codelists.thema(first)

          main =
            XmlBuilder.element(:Subject, [
              XmlBuilder.element(:MainSubject),
              XmlBuilder.element(:SubjectSchemeIdentifier, "93"),
              XmlBuilder.element(:SubjectSchemeVersion, "1.6"),
              XmlBuilder.element(:SubjectCode, first_code)
            ])

          rest_elems =
            Enum.map(rest, fn code ->
              {:ok, c} = Codelists.thema(code)

              XmlBuilder.element(:Subject, [
                XmlBuilder.element(:SubjectSchemeIdentifier, "93"),
                XmlBuilder.element(:SubjectSchemeVersion, "1.6"),
                XmlBuilder.element(:SubjectCode, c)
              ])
            end)

          [main | rest_elems]
      end

    free_elements =
      free_subjects
      |> Enum.filter(&is_map/1)
      |> Enum.map(&build_free_subject/1)
      |> Enum.reject(&is_nil/1)

    case thema_elements ++ free_elements do
      [] -> nil
      list -> list
    end
  end

  defp build_free_subject(subject) when is_map(subject) do
    children =
      [
        if(Map.get(subject, "mainSubject") == true,
          do: XmlBuilder.element(:MainSubject)
        ),
        maybe_element(:SubjectSchemeIdentifier, Map.get(subject, "subjectSchemeIdentifier")),
        maybe_element(:SubjectSchemeName, Map.get(subject, "subjectSchemeName")),
        maybe_element(:SubjectSchemeVersion, Map.get(subject, "subjectSchemeVersion")),
        maybe_element(:SubjectCode, Map.get(subject, "subjectCode")),
        maybe_element(:SubjectHeadingText, Map.get(subject, "subjectHeadingText"))
      ]
      |> Enum.reject(&is_nil/1)

    case children do
      [] -> nil
      _ -> XmlBuilder.element(:Subject, children)
    end
  end

  # ---- Helpers --------------------------------------------------------------

  defp maybe_element(_tag, blank) when blank in [nil, ""], do: nil
  defp maybe_element(tag, value) when is_binary(value), do: XmlBuilder.element(tag, value)
  defp maybe_element(tag, value), do: XmlBuilder.element(tag, to_string(value))

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: true
end
