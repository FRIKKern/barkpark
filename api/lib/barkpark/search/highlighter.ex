defmodule Barkpark.Search.Highlighter do
  @moduledoc """
  Search highlighting + snippets, all app-level (in-memory over BEAM-held field
  text). No `ts_headline` anywhere — that is a MEASURED decision, not an
  oversight (AXI charter decision 20 / task `axi-b3-ts-headline-snippets`).

  ## Why not `ts_headline` (benchmark NO-GO, guerrilla prod, 2026-07-19)

  Postgres already indexes body text in the search tsvector
  (`20260614120000_search_vector_include_body.exs`), so `ts_headline` over the
  stored `content` was the obvious "server-side, ranked, stemming-aware"
  candidate. Forced-evaluation benchmarks (2705 docs; `count(*)` over an
  unreferenced `ts_headline` column is PRUNED by the planner and under-reports
  ~10x, so these are the forced numbers) killed it: ONE 1.3 MB body → a
  108-char snippet costs **477 ms**; per-field `ts_headline` over the top-200
  largest docs runs **2.8–3.1 s**; whole-`content` **4.5 s**. `ts_headline` has
  **no early-exit** — it scans the entire field to emit ~108 chars — and it
  re-scans, server-side, text the app already holds in memory. The in-memory
  windower below (first-match, ~#{160}-char window, early-exit on the first
  matching field) produces the same shape strictly cheaper and with zero extra
  I/O. Decision: snippets stay app-level; `ts_headline` is REJECTED for this
  workload. Do not re-litigate without a new benchmark.

  ## Bounding brief highlights (re-inflation guard)

  `highlight_text/2` marks up the ENTIRE field, and `highlight_fields` is
  schema-configurable (`highlightFields`) — a `content.body` config would echo a
  1.3 MB marked string per hit into a brief card. `clamp_brief_highlights/1`
  caps each already-sealed highlight to a window around the first `<mark>` so a
  brief hit card can never re-inflate to full-field size. It runs AFTER
  `visible_highlight_fields/3` (⇒ `Envelope.field_readable?/3`) has already
  produced the sealed highlights map — never against raw content or the search
  vector — so it cannot reopen the LOW-11 leak class. The FULL view is
  untouched: it serves the complete markup exactly as before.
  """

  alias Barkpark.Content.CallerContext
  alias Barkpark.Content.Envelope

  @mark_open "<mark>"
  @mark_close "</mark>"

  # Snippet (AXI R3): a bounded plain-text window (~160 chars) around the FIRST
  # needle match, scanned over these fields in order. `content.*` fields ride
  # the same sealed visibility predicate as highlights (visible_highlight_fields
  # → Envelope.field_readable?/3) — an unreadable field can never leak through a
  # snippet. No ts_headline: this is pure in-memory windowing over field text.
  @snippet_fields [
    "title",
    "content.description",
    "content.summary",
    "content.excerpt",
    "content.body"
  ]
  @snippet_window 160
  @snippet_lead 60

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

  @doc """
  Plain-text snippets for brief hit cards: `%{doc_id => snippet | nil}`.

  For each document, scan the snippet fields in order (`config`'s
  `"snippet_fields"`, defaulting to #{inspect(@snippet_fields)}) and return a
  ~#{@snippet_window}-char window around the FIRST needle match, with `…`
  ellipses marking truncation. `nil` when nothing readable matches.

  Visibility is the SAME sealed path highlights use: `content.*` fields pass
  through `visible_highlight_fields/3` (⇒ `Envelope.field_readable?/3`), which
  fails closed for a nil caller and for a type with no resolvable schema — an
  unreadable field never contributes a snippet. Output is raw field text (no
  `<mark>`, no HTML): consumers render it as text, unlike the highlights map
  whose strings carry real markup.
  """
  @spec snippet_documents([struct()], map(), map(), CallerContext.t() | nil, schema_fun()) ::
          %{optional(String.t()) => String.t() | nil}
  def snippet_documents(
        docs,
        parsed,
        config,
        caller_context \\ nil,
        schema_fun \\ fn _ -> nil end
      )
      when is_list(docs) do
    needles = highlight_needles(parsed)
    configured = Map.get(config, "snippet_fields", @snippet_fields)

    Map.new(docs, fn doc ->
      fields = visible_highlight_fields(configured, caller_context, schema_fun.(doc_type(doc)))
      {doc.doc_id, first_snippet(doc, fields, needles)}
    end)
  end

  defp first_snippet(_doc, _fields, []), do: nil

  defp first_snippet(doc, fields, needles) do
    Enum.find_value(fields, fn field ->
      doc |> document_field_text(field) |> snippet_text(needles)
    end)
  end

  defp snippet_text(nil, _needles), do: nil
  defp snippet_text("", _needles), do: nil

  defp snippet_text(text, needles) when is_binary(text) do
    lowered = String.downcase(text)

    case Enum.filter(needles, &String.contains?(lowered, &1)) do
      [] ->
        nil

      present ->
        # Same longest-first alternation as highlight_text/2, but we only need
        # the FIRST match's byte offsets (unicode-safe: PCRE offsets fall on
        # codepoint boundaries with the `u` flag).
        pattern =
          present
          |> Enum.sort_by(&(-String.length(&1)))
          |> Enum.map(&Regex.escape/1)
          |> Enum.join("|")

        regex = Regex.compile!("(" <> pattern <> ")", "iu")

        case Regex.run(regex, text, return: :index) do
          [{start, len} | _] ->
            prefix = binary_part(text, 0, start)
            match = binary_part(text, start, len)
            suffix = binary_part(text, start + len, byte_size(text) - start - len)
            snippet_window(prefix, match, suffix)

          _ ->
            nil
        end
    end
  end

  # Keep up to @snippet_lead trailing graphemes of context before the match and
  # fill the remaining budget after it, ellipsising whichever side was cut. The
  # result is ≤ @snippet_window graphemes unless the match itself is longer.
  defp snippet_window(prefix, match, suffix) do
    plen = String.length(prefix)
    lead_keep = min(plen, @snippet_lead)
    lead = String.slice(prefix, plen - lead_keep, lead_keep)
    tail_budget = max(@snippet_window - lead_keep - String.length(match), 0)
    tail = String.slice(suffix, 0, tail_budget)

    left = if lead_keep < plen, do: "…", else: ""
    right = if String.length(suffix) > tail_budget, do: "…", else: ""

    left <> lead <> match <> tail <> right
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

  @doc """
  Bound an already-sealed per-field highlights map for a brief hit card.

  Takes the `%{field => marked_string}` map the highlight path produced for ONE
  document (the value of `meta[:highlights][doc_id]`) and clamps each value to a
  window around its FIRST `<mark>` — at most ~#{@snippet_window} visible
  characters, with `…` ellipses marking either cut side. The full field can no
  longer echo into a brief card no matter how large `highlightFields` is
  configured.

  This is a pure post-filter over strings that ALREADY passed
  `visible_highlight_fields/3` — an unreadable field never reached this map, so
  bounding cannot reopen the LOW-11 leak class. `<mark>` tags stay balanced
  across the cut (a window that opens or closes inside a match is re-balanced),
  and HTML entities (`&lt;`, `&amp;`, …) are never split. Only used by the brief
  view; the full view serves the unbounded markup unchanged.
  """
  @spec clamp_brief_highlights(%{optional(String.t()) => String.t()}) :: %{
          optional(String.t()) => String.t()
        }
  def clamp_brief_highlights(field_highlights) when is_map(field_highlights) do
    Map.new(field_highlights, fn {field, marked} -> {field, clamp_marked(marked)} end)
  end

  # Tokenise the marked, HTML-escaped string into units that are safe to cut
  # BETWEEN: a `<mark>`/`</mark>` tag (zero visible width, always kept whole and
  # re-balanced), an HTML entity (one visible char, never split), or a single
  # visible codepoint. Then keep a window around the first `<mark>`.
  defp clamp_marked(marked) when is_binary(marked) do
    tokens =
      Regex.scan(~r/<mark>|<\/mark>|&amp;|&lt;|&gt;|&quot;|&#39;|./us, marked) |> List.flatten()

    case Enum.find_index(tokens, &(&1 == @mark_open)) do
      nil ->
        # No match tag (defensive — highlight_text always emits one). Keep a
        # leading window so an unexpected full-field string still can't inflate.
        {kept, right_cut?} = take_visible(tokens, @snippet_window)
        assemble("", kept, if(right_cut?, do: "…", else: ""))

      idx ->
        {lead_tokens, rest} = Enum.split(tokens, idx)
        {lead_kept, lead_visible, lead_cut?} = take_lead(lead_tokens, @snippet_lead)
        {rest_kept, right_cut?} = take_visible(rest, @snippet_window - lead_visible)

        left = if lead_cut?, do: "…", else: ""
        right = if right_cut?, do: "…", else: ""
        assemble(left, balance_marks(lead_kept ++ rest_kept), right)
    end
  end

  defp clamp_marked(other), do: other

  # Keep the TRAILING lead tokens up to `budget` visible chars; report whether
  # earlier lead was dropped and how many visible chars we kept.
  defp take_lead(lead_tokens, budget) do
    {kept_rev, visible, cut?} =
      lead_tokens
      |> Enum.reverse()
      |> Enum.reduce({[], 0, false}, fn token, {acc, vis, cut} ->
        cond do
          cut -> {acc, vis, true}
          tag?(token) -> {[token | acc], vis, false}
          vis < budget -> {[token | acc], vis + 1, false}
          true -> {acc, vis, true}
        end
      end)

    {kept_rev, visible, cut?}
  end

  # Keep leading tokens up to `budget` visible chars; report whether more remained.
  defp take_visible(_tokens, budget) when budget <= 0, do: {[], true}

  defp take_visible(tokens, budget) do
    {kept_rev, _vis, cut?} =
      Enum.reduce(tokens, {[], 0, false}, fn token, {acc, vis, cut} ->
        cond do
          cut -> {acc, vis, true}
          tag?(token) -> {[token | acc], vis, false}
          vis < budget -> {[token | acc], vis + 1, false}
          true -> {acc, vis, true}
        end
      end)

    {Enum.reverse(kept_rev), cut?}
  end

  defp tag?(@mark_open), do: true
  defp tag?(@mark_close), do: true
  defp tag?(_), do: false

  # `<mark>` never nests in highlight_text output, so a cut window opens or
  # closes at most one span: prepend `<mark>` if we start inside a match, append
  # `</mark>` if we end inside one.
  defp balance_marks(tokens) do
    {depth, min_depth} =
      Enum.reduce(tokens, {0, 0}, fn
        @mark_open, {d, m} ->
          {d + 1, m}

        @mark_close, {d, m} ->
          d2 = d - 1
          {d2, min(m, d2)}

        _, {d, m} ->
          {d, m}
      end)

    prefix = if min_depth < 0, do: @mark_open, else: ""
    suffix = if depth > 0, do: @mark_close, else: ""
    [prefix | tokens] ++ [suffix]
  end

  defp assemble(left, tokens, right) do
    left <> IO.iodata_to_binary(tokens) <> right
  end

  defp document_field_text(doc, "title"), do: doc.title

  # Any `content.*` field yields its text when the stored value is a plain
  # binary (blocks/maps/lists ⇒ nil — no PortableDoc flattening here). Callers
  # NEVER reach this for a field the caller may not read: every `content.*`
  # field name is filtered through `visible_highlight_fields/3` first.
  defp document_field_text(doc, "content." <> path) do
    case doc.content do
      %{} = content ->
        case Map.get(content, path) do
          value when is_binary(value) -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp document_field_text(_doc, _field), do: nil

  # task-5cf80a99ecd52bf2: the full set of names this function has a clause
  # for. `Barkpark.Search.SurfaceConfig.changeset/2` validates `highlightFields`
  # against this SAME list at write time — keep the two in lockstep (add a
  # name here ⇒ add it there too), or the write-time gate and this read-time
  # catch-all disagree about what counts as "valid".
  @media_highlight_fields ~w(original_name filename title tags)

  @doc false
  @spec media_highlight_field?(String.t()) :: boolean()
  def media_highlight_field?(field) when is_binary(field), do: field in @media_highlight_fields

  # Documents surface accepts "title" plus any `content.<path>` — open-ended
  # by design (searchable_fields/highlightFields can declare arbitrary schema
  # paths). `document_field_text/2` above already has a total catch-all
  # (`_, _ -> nil`), so an unknown documents field degrades silently instead
  # of crashing — this predicate is write-time hygiene, not a crash guard.
  @doc false
  @spec document_highlight_field?(String.t()) :: boolean()
  def document_highlight_field?("title"), do: true
  def document_highlight_field?("content." <> _rest), do: true
  def document_highlight_field?(_other), do: false

  defp media_field_text(file, _doc, "original_name"), do: file.original_name
  defp media_field_text(file, _doc, "filename"), do: file.filename
  defp media_field_text(_file, doc, "title"), do: doc && doc.title
  defp media_field_text(_file, _doc, "tags"), do: nil

  # task-5cf80a99ecd52bf2: a `highlightFields` value with no clause above used
  # to raise `FunctionClauseError` here — crashing the NEXT search request
  # after a bad value was stored (a stored-config denial of service; the
  # write that stored it was long over by the time this fired). Rows written
  # before `SurfaceConfig.changeset/2`'s write-time gate existed can still
  # carry a bad value, so this read-time catch-all stays even with that gate
  # in place: an unrecognized field degrades to "no highlight" instead of
  # crashing every caller until someone manually reverts the row.
  defp media_field_text(_file, _doc, _unknown_field), do: nil
end
