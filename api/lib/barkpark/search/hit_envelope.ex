defmodule Barkpark.Search.HitEnvelope do
  @moduledoc """
  The ONE search hit-envelope builder shared by every document-search surface:
  `SearchController.search/2` (REST), `SearchController.search_local/2`
  (loopback fast-path), `SearchChannel.build_reply/…` (WS reply AND the P5
  live-push), and — via a thin re-keying adapter — the federated documents
  surface. These were four hand-rolled emitters of the same shape (three
  byte-identical); AXI R3 collapses them so the shape can only drift in one
  place.

  ## Views

  * `view: "brief"` — each hit becomes a brief card
    `%{id, type, title, slug, snippet, highlights}` instead of the full
    rendered document. Everything on the card is derived from SEALED sources:
    `id`/`type`/`title`/`slug` are read from the `Envelope.render_many_by_type`
    output (so a schema-`private` slug is already gone), and the snippet comes
    from `Highlighter.snippet_documents/5`, which routes every `content.*`
    field through the same `Envelope.field_readable?/3` visibility predicate
    the highlight path uses. A `nil` caller_context is coerced to the
    anonymous (fail-closed) principal — never a bypass.
  * any other value (`nil`, `"full"`, garbage) — the exact full envelope every
    surface served before this module existed. The server default stays FULL;
    brief is strictly caller opt-in.

  The envelope's key set is identical in both views (`documents`, `count`,
  `query`, `parsedQuery`, `highlights`, `recovery`, `correctedTo`, `facets`,
  `truncation`, `engineUsed`, `hasMore`) so shape-destructuring clients
  (`find-shape.ts`) never branch.
  Surface-specific extras (`ms`, `seq`, `searchEventId`) are `Map.put` by the
  call sites.

  ## `count` vs `hasMore`/`offset` (NOT repaired here, just named)

  On this builder's callers (REST/loopback/WS), `count` is the CORPUS TOTAL
  for the query — `result.total`, not the number of rows in `documents`. That
  collides in NAME (not in meaning — each endpoint is internally consistent)
  with `QueryController`'s `count`, which is the number of PAGE ROWS returned.
  A client reading both endpoints must already know which `count` it holds;
  `hasMore` below is additive sugar derived from the corpus-total `count`
  here, and does not resolve that naming collision.
  """

  alias Barkpark.Content.{CallerContext, Envelope}
  alias Barkpark.Search.Highlighter

  @brief "brief"

  @doc """
  Build the canonical search response envelope for `docs`/`count`/`meta` as
  returned by `Content.search_documents/3`.

  Options:

    * `:caller_context` (required) — the caller's `%CallerContext{}` (or nil ⇒
      anonymous fail-closed in the brief path; the full path renders with nil
      exactly as the legacy emitters did).
    * `:schema_resolver` (required) — `(type -> schema | nil)` for per-type
      field-visibility redaction. Memoised per distinct type here, so brief's
      second consumer (the snippet pass) does not re-query.
    * `:fields` — the `?fields=` projection allowlist (full view only; brief
      cards are already a fixed projection).
    * `:view` — `"brief"` for brief hit cards; anything else is full.
    * `:offset` — the page's starting offset into the corpus, as threaded by
      the caller's own `offset` param. Defaults to `0` when absent/nil so a
      caller written before `hasMore` existed (or a future caller that never
      paginates) keeps working unchanged — `hasMore` then reads `count >
      length(documents)`, i.e. "there is more than fits on this one page".
  """
  @spec build([struct()], non_neg_integer(), String.t() | nil, map(), keyword()) :: map()
  def build(docs, count, query, meta, opts) do
    caller_context = Keyword.fetch!(opts, :caller_context)
    schema_resolver = Keyword.fetch!(opts, :schema_resolver)
    fields = Keyword.get(opts, :fields)
    view = Keyword.get(opts, :view)
    offset = Keyword.get(opts, :offset) || 0

    # `highlightFields` is schema-configurable, so the top-level `highlights`
    # map (keyed by doc id) can echo a full `content.body` per hit. In the brief
    # view every field highlight is windowed (AXI b3) so neither the per-card
    # highlights NOR this top-level map can re-inflate a brief page. The full
    # view serves the complete markup unchanged. Bounding runs AFTER the
    # visibility filter that produced this map — never against raw content.
    highlights = top_highlights(meta[:highlights] || %{}, view)

    %{
      documents: documents(docs, meta, view, caller_context, schema_resolver, fields, highlights),
      count: count,
      query: query,
      parsedQuery: meta[:parsed],
      highlights: highlights,
      recovery: meta[:recovery],
      correctedTo: meta[:corrected_to],
      facets: meta[:facets],
      truncation: meta[:truncation],
      # Which retriever ACTUALLY served (query_pipeline.ex) — "postgres" even
      # when another engine was requested but silently substituted (zero-hit
      # recovery, tenant gate, unregistered engine). Additive: clients that
      # don't read it are unchanged; clients that do stop guessing.
      engineUsed: meta[:engine_used],
      # Additive pagination echo: `count` here is already the corpus total
      # (see moduledoc), so whether another page exists is derivable in-hand
      # — the server had the fact and simply wasn't saying it. A paging
      # client no longer has to guess from `length(documents) == limit`.
      hasMore: count > offset + length(docs)
    }
  end

  defp top_highlights(raw, @brief) do
    Map.new(raw, fn {id, field_highlights} ->
      {id, Highlighter.clamp_brief_highlights(field_highlights)}
    end)
  end

  defp top_highlights(raw, _full), do: raw

  @doc """
  Re-key a built envelope to the federated documents-surface payload shape:
  `documents`→`hits`, `count`→`total`; `query`/`correctedTo`/`facets`/
  `truncation` are dropped (the federated surface never carried them — query is
  echoed top-level, the rest are single-surface diagnostics).

  `hasMore` is DELIBERATELY dropped here too, not forwarded — the federated
  caller (`FederatedSearchController`, owned by a sibling task) never threads
  an `:offset` opt into `build/5` for this surface, so `hasMore` above is
  always computed against an assumed `offset` of `0`. Forwarding it would
  read as "this is page-aware" on a surface that is not yet, which is worse
  than silence. Revisit together with whoever wires federated pagination.
  """
  @spec rekey_federated(map()) :: map()
  def rekey_federated(envelope) do
    %{
      hits: envelope.documents,
      total: envelope.count,
      parsedQuery: envelope.parsedQuery,
      highlights: envelope.highlights,
      recovery: envelope.recovery
    }
  end

  defp documents(docs, meta, @brief, caller_context, schema_resolver, _fields, highlights) do
    # Fail closed: a nil caller is the anonymous principal, never a bypass —
    # both the Envelope render and the snippet visibility check see a real
    # (unprivileged) context. Mirrors Highlighter.visible_highlight_fields/3.
    ctx = caller_context || CallerContext.anonymous()

    # Resolve each distinct hit type's schema ONCE and share the memo between
    # the render pass and the snippet pass.
    resolver = memoised_resolver(docs, schema_resolver)

    snippets = Highlighter.snippet_documents(docs, meta[:parsed] || %{}, %{}, ctx, resolver)

    docs
    |> Envelope.render_many_by_type(resolver, ctx)
    |> Enum.map(fn rendered ->
      id = rendered["_id"]

      %{
        id: id,
        type: rendered["_type"],
        title: rendered["title"],
        slug: card_slug(rendered),
        snippet: Map.get(snippets, id),
        # `highlights` was already windowed by `top_highlights/2` (AXI b3) — the
        # per-card map cannot re-inflate to full-field size.
        highlights: Map.get(highlights, id) || %{}
      }
    end)
  end

  defp documents(docs, _meta, _full, caller_context, schema_resolver, fields, _highlights) do
    docs
    |> Envelope.render_many_by_type(schema_resolver, caller_context)
    |> Envelope.project(fields)
  end

  # The slug is read from the RENDERED document, not raw content, so a
  # schema-private slug has already been redacted by Envelope before the card
  # is cut.
  defp card_slug(%{"slug" => slug}) when is_binary(slug), do: slug
  defp card_slug(_rendered), do: nil

  defp memoised_resolver(docs, schema_resolver) do
    schema_by_type =
      docs
      |> Enum.map(& &1.type)
      |> Enum.uniq()
      |> Map.new(fn type -> {type, schema_resolver.(type)} end)

    fn type -> Map.get(schema_by_type, type) end
  end
end
