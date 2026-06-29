defmodule Barkpark.Search.Highlighter do
  @moduledoc false

  alias Barkpark.Content.CallerContext

  @mark_open "<mark>"
  @mark_close "</mark>"

  @spec highlight_documents([struct()], map(), map(), CallerContext.t() | nil) :: map()
  def highlight_documents(docs, parsed, config, caller_context \\ nil) when is_list(docs) do
    needles = highlight_needles(parsed)

    fields =
      config
      |> Map.get("highlight_fields", ["title"])
      |> visible_highlight_fields(caller_context)

    Map.new(docs, fn doc ->
      key = doc.doc_id

      field_highlights =
        Map.new(fields, fn field ->
          text = document_field_text(doc, field)
          {field, highlight_text(text, needles)}
        end)
        |> Enum.reject(fn {_k, v} -> v == nil end)
        |> Map.new()

      {key, field_highlights}
    end)
  end

  @spec highlight_media([struct()], map(), map(), %{optional(String.t()) => struct()}) :: map()
  def highlight_media(files, parsed, config, docs_by_file_id) when is_list(files) do
    needles = highlight_needles(parsed)
    fields = Map.get(config, "highlight_fields", ["title", "original_name", "filename"])

    Map.new(files, fn file ->
      doc = Map.get(docs_by_file_id, file.id)

      field_highlights =
        Map.new(fields, fn field ->
          text = media_field_text(file, doc, field)
          {field, highlight_text(text, needles)}
        end)
        |> Enum.reject(fn {_k, v} -> v == nil end)
        |> Map.new()

      {to_string(file.id), field_highlights}
    end)
  end

  # WS-B LOW-11: `content.*` highlight fields (e.g. `content.slug`) emit raw
  # document content into the highlights map, bypassing the Envelope redaction
  # boundary. Only an admin caller keeps them; every other caller (anonymous,
  # non-admin, or a nil/internal context — fail closed) drops the `content.*`
  # highlight fields so a redacted field can never leak through a snippet.
  defp visible_highlight_fields(fields, %CallerContext{is_admin: true}), do: fields

  defp visible_highlight_fields(fields, _caller_context),
    do: Enum.reject(fields, &String.starts_with?(&1, "content."))

  defp highlight_needles(parsed) do
    (Map.get(parsed, :phrases, []) ++
       Map.get(parsed, :terms, []) ++ Map.get(parsed, :prefixes, []))
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp highlight_text(nil, _needles), do: nil
  defp highlight_text("", _needles), do: nil

  defp highlight_text(text, needles) when is_binary(text) do
    lowered = String.downcase(text)

    if Enum.any?(needles, &String.contains?(lowered, &1)) do
      Enum.reduce(needles, text, fn needle, acc ->
        replace_case_insensitive(acc, needle, @mark_open <> needle <> @mark_close)
      end)
    else
      nil
    end
  end

  defp replace_case_insensitive(haystack, needle, replacement) do
    regex = ~r/#{Regex.escape(needle)}/i
    Regex.replace(regex, haystack, replacement)
  end

  defp document_field_text(doc, "title"), do: doc.title

  defp document_field_text(doc, "content.slug") do
    case doc.content do
      %{"slug" => slug} when is_binary(slug) -> slug
      _ -> nil
    end
  end

  defp document_field_text(_doc, _field), do: nil

  defp media_field_text(file, _doc, "original_name"), do: file.original_name
  defp media_field_text(file, _doc, "filename"), do: file.filename
  defp media_field_text(_file, doc, "title"), do: doc && doc.title
  defp media_field_text(_file, _doc, "tags"), do: nil
end
