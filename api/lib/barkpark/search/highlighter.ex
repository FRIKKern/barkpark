defmodule Barkpark.Search.Highlighter do
  @moduledoc false

  alias Barkpark.Content.CallerContext
  alias Barkpark.Content.Envelope

  @mark_open "<mark>"
  @mark_close "</mark>"

  @type schema_fun :: (String.t() | nil -> term())

  @spec highlight_documents([struct()], map(), map(), CallerContext.t() | nil, schema_fun()) ::
          map()
  def highlight_documents(
        docs,
        parsed,
        config,
        caller_context \\ nil,
        schema_fun \\ fn _ -> nil end
      )
      when is_list(docs) do
    needles = highlight_needles(parsed)
    configured = Map.get(config, "highlight_fields", ["title"])

    Map.new(docs, fn doc ->
      key = doc.doc_id
      # Visibility is per-document — the hit set may span many types, each with
      # its own schema field visibility — so resolve the visible highlight fields
      # against THIS doc's schema.
      fields = visible_highlight_fields(configured, caller_context, schema_fun.(doc_type(doc)))

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

  defp doc_type(%{type: t}), do: t
  defp doc_type(_), do: nil

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
  # boundary. An admin keeps every configured highlight field. Every other
  # caller keeps a `content.*` highlight ONLY when the type's schema proves the
  # field is readable by this caller — reusing the SAME visibility predicate
  # `Envelope.render` uses (`Envelope.field_readable?/3`). A public / undeclared
  # field's highlight survives; a `private` / `owner_only` / `readable_by` field
  # is dropped so a redacted value can never leak through a snippet. Earlier this
  # dropped ALL `content.*` fields for every non-admin — over-redacting the
  # caller's own public fields (the LOW regression this fixes).
  defp visible_highlight_fields(fields, %CallerContext{is_admin: true}, _schema), do: fields

  defp visible_highlight_fields(fields, caller_context, schema) do
    # nil caller ⇒ anonymous (fail-closed) principal, never a bypass.
    ctx = caller_context || %CallerContext{}

    Enum.reject(fields, fn field ->
      String.starts_with?(field, "content.") and not content_field_visible?(schema, field, ctx)
    end)
  end

  # Fail closed: a `content.*` highlight is kept only when a schema is PRESENT
  # and `field_readable?/3` grants it. No schema ⇒ no proof the field is public
  # ⇒ drop (conservative; matches the prior all-drop behaviour when visibility
  # is unknown). A present schema lets a public / undeclared field survive while
  # a declared private / owner_only / readable_by field is dropped.
  defp content_field_visible?(nil, _field, _ctx), do: false

  defp content_field_visible?(schema, field, ctx),
    do: Envelope.field_readable?(schema, field, ctx)

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
    present = Enum.filter(needles, &String.contains?(lowered, &1))

    case present do
      [] ->
        nil

      _ ->
        # Split the ORIGINAL text into alternating unmatched/matched segments
        # (longest-first alternation, one capture group so include_captures
        # yields the match text at odd indices). EVERY segment is HTML-escaped
        # before it goes into the output — the emitted string contains literal
        # `<mark>` tags, so author-controlled field text like `<img onerror=…>`
        # MUST be escaped or a consumer rendering highlights as HTML is exposed
        # to stored XSS. Only the matched segments are wrapped in <mark> (after
        # escaping), preserving the existing downcased-term behaviour. Escaping
        # then downcasing is byte-identical to the old output for text with no
        # HTML metacharacters, so highlight snippets of ordinary titles are
        # unchanged. Splitting the original text (not re-scanning output) keeps
        # the no-nested-tags and verbatim-`\1`-needle guarantees.
        pattern =
          present
          |> Enum.sort_by(&(-String.length(&1)))
          |> Enum.map(&Regex.escape/1)
          |> Enum.join("|")

        regex = Regex.compile!("(" <> pattern <> ")", "i")

        regex
        |> Regex.split(text, include_captures: true, trim: false)
        |> Enum.with_index()
        |> Enum.map_join("", fn {segment, index} ->
          escaped = Plug.HTML.html_escape(segment)

          if rem(index, 2) == 1 do
            @mark_open <> String.downcase(escaped) <> @mark_close
          else
            escaped
          end
        end)
    end
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
