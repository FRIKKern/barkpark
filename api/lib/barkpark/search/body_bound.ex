defmodule Barkpark.Search.BodyBound do
  @moduledoc """
  Bound the PROSE payload a search hit ships, server-side.

  ## Why this exists

  `?fields=…,body,blocks` on `/v1/data/search/:dataset` projected the WHOLE
  block tree of every hit. Measured against guerrilla on 2026-09-19, the
  search-starter's SSR browse seed —

      GET /v1/data/search/production?q=%20&engine=pg&types=…&limit=100
          &fields=title,name,slug,excerpt,description,bio,body,publishedAt,
                  status,author,category,blocks

  — answered **14,648,762 bytes**. Its first consumer
  (`templates/search-starter/lib/find.ts` `deriveBody/1`) flattens that tree to
  prose and caps it at 1000 characters per hit, so at `limit=100` the app can
  use at most ~100 KB of the 14.65 MB it paid for. >99% of the payload is
  discarded by the only thing that reads it.

  A template cannot fix that: dropping `body`/`blocks` from the projection is
  not behaviour-preserving (the finder windows snippets and highlights matches
  out of the block text). The bound has to exist on the server, so this module
  is it: `?bodyChars=<n>` asks for **at most ~n characters of prose per hit**,
  and the projected `blocks` / `body` are cut to the smallest PREFIX of the
  block list that carries that much text.

  ## What the bound preserves

  * **Shape.** A bounded `blocks` is still a list of whole, well-formed blocks —
    a prefix of the original, never a half-serialised block. A consumer that
    walks the tree keeps working; it just runs out of tree sooner.
  * **Order.** The prefix is the DOCUMENT prefix, which is what a
    snippet-windowing consumer wants: the top of the document is where a
    near-top match lives, and `deriveBody/1` already throws the rest away.
  * **Honesty.** A hit whose tree was cut carries `"_bodyTruncated" => true`.
    The absence of that key is a positive statement that the hit is whole —
    without it a consumer cannot tell a short document from a cut one.
  * **Every prose-bearing key.** A paper `body` is `%{"blocks" => …,
    "html" => …}` — the block list and its rendered twin. Both are bounded:
    `blocks` to a whole-block prefix, `html` DROPPED when it exceeds the cap
    (see `bound_body_html/2` for why dropped rather than sliced). The invariant
    is per-HIT, not per-key: under `?bodyChars=n` no body key a consumer would
    read as prose carries more than ~n characters.

  ## What it does NOT do

  The bound is applied to the RENDERED envelope, after
  `Content.Envelope.project/2`. It bounds what crosses the wire, not what
  Postgres reads: the rows are still fetched whole (`DocumentsRetriever`'s
  `maybe_light_select/2` only drops heavy keys when the caller asks for NONE of
  them, and a `bodyChars` caller by definition asks for one). Cutting the tree
  in SQL would need a jsonb walk per row and is a separate change.

  There is **no default cap**: `nil` means "unbounded", exactly what every
  caller got before. A cap that arrived without being asked for would silently
  truncate documents for readers that want them whole.
  """

  # Structural/reference leaf keys that are not prose — mirrors the finder's
  # BODY_SKIP_KEYS and `Plugins.Indx.Indexer`'s `@body_skip_keys`, so the
  # character budget this module spends is measured over the SAME text the
  # consumer will flatten out of the tree. (Deliberately a copy, not a call:
  # the indexer's list lives in a plugin, and a search-surface wire contract
  # must not break when a plugin is disabled.)
  @skip_keys ~w(marks href src url id _id _type _rev type slug rev kind lang style)

  @doc """
  Parse a `?bodyChars=` parameter.

  `nil` / absent / blank → `nil` (unbounded — the pre-existing behaviour).
  A non-negative integer → itself, clamped to `0..1_000_000`.
  Anything else (`"abc"`, `"-5"`, `"1.5"`) → `:error`, so the caller can refuse
  the request instead of silently serving an unbounded 14 MB response to a
  caller who explicitly asked for a bound. A typo'd cap that reads as "no cap"
  is the one failure mode this parameter must not have.
  """
  @spec parse(term()) :: {:ok, nil | non_neg_integer()} | :error
  def parse(nil), do: {:ok, nil}

  def parse(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      trimmed ->
        case Integer.parse(trimmed) do
          {n, ""} when n >= 0 -> {:ok, min(n, 1_000_000)}
          _ -> :error
        end
    end
  end

  def parse(_), do: :error

  @doc """
  Bound every hit in `docs` to at most ~`max_chars` characters of prose.

  `nil` returns `docs` unchanged and untouched (identity, not a rebuild).
  """
  @spec apply_bound([map()], nil | non_neg_integer()) :: [map()]
  def apply_bound(docs, nil), do: docs

  def apply_bound(docs, max_chars) when is_integer(max_chars) and max_chars >= 0 do
    Enum.map(docs, &bound_doc(&1, max_chars))
  end

  defp bound_doc(doc, max) when is_map(doc) do
    {doc, cut_blocks?} = bound_key(doc, "blocks", max)
    {doc, cut_body?} = bound_body(doc, max)

    if cut_blocks? or cut_body? do
      Map.put(doc, "_bodyTruncated", true)
    else
      doc
    end
  end

  defp bound_doc(doc, _max), do: doc

  # Top-level `blocks`, or any list-valued key we were pointed at.
  defp bound_key(doc, key, max) do
    case Map.fetch(doc, key) do
      {:ok, blocks} when is_list(blocks) ->
        {kept, cut?} = prefix(blocks, max)
        {Map.put(doc, key, kept), cut?}

      _ ->
        {doc, false}
    end
  end

  # `body` is polymorphic across the types this surface serves: a paper body is
  # a map carrying its own `blocks`, a post body can be a plain string, and a
  # type that has neither is left alone.
  defp bound_body(doc, max) do
    case Map.fetch(doc, "body") do
      {:ok, body} when is_binary(body) ->
        if String.length(body) > max do
          {Map.put(doc, "body", slice(body, max)), true}
        else
          {doc, false}
        end

      {:ok, body} when is_map(body) ->
        bound_body_map(doc, body, max)

      {:ok, body} when is_list(body) ->
        {kept, cut?} = prefix(body, max)
        {Map.put(doc, "body", kept), cut?}

      _ ->
        {doc, false}
    end
  end

  # A paper body is `%{"blocks" => …, "html" => …}` (`PortableDoc.Projection`
  # `project_body/2` writes BOTH, off the same free-block list). Bounding only
  # `blocks` left the twin whole, so the bound was a fraction of what it claimed:
  # measured on guerrilla 50bc81f43, 2026-09-20, the `bodyChars=1000` seed
  # answered 6,129,873 B of which `body.html` was 5,565,150 B across 94 paper
  # hits — against `body.blocks` at 224,512 B. 91% of a BOUNDED response was the
  # key the bound never looked at.
  defp bound_body_map(doc, body, max) do
    {body, cut_blocks?} = bound_body_blocks(body, max)
    {body, cut_html?} = bound_body_html(body, max)

    {Map.put(doc, "body", body), cut_blocks? or cut_html?}
  end

  defp bound_body_blocks(body, max) do
    case Map.fetch(body, "blocks") do
      {:ok, blocks} when is_list(blocks) ->
        {kept, cut?} = prefix(blocks, max)
        {Map.put(body, "blocks", kept), cut?}

      _ ->
        {body, false}
    end
  end

  # `html` is DROPPED, not sliced, when it exceeds the bound. Three reasons, in
  # order:
  #
  #   1. It is a DERIVED TWIN of `blocks`, not an independent value. Once the
  #      block list is cut to a prefix, the full render is stale by definition;
  #      a prefix-consistent render would mean calling `PortableDoc.Render` per
  #      hit on the read path, which is a different (and much more expensive)
  #      change than a projection bound.
  #   2. A PREFIX OF HTML IS NOT HTML. Cutting mid-markup hands a consumer an
  #      unbalanced fragment; the one thing this module promises about what it
  #      returns is that the shape still parses. Absent is honest, truncated is
  #      a trap — and `_bodyTruncated` already exists to say "there was more".
  #   3. NO SEARCH CONSUMER READS IT. The finder
  #      (`templates/search-starter/lib/find.ts` `deriveBody/1`) walks
  #      `body.blocks` and a string body; every HTML-rendering surface in the
  #      repo (`web/components/document-detail.tsx`, the search-starter twin)
  #      reads the TOP-LEVEL `body_html` off a single-document fetch, never
  #      `body.html` off a search hit.
  #
  # The measure is the raw string length, not its prose: the rendered body
  # carries inline styles (a 10-character paragraph renders as ~200 characters
  # of markup), so a prose-only measure would keep hundreds of KB under a
  # 1000-character cap. For an opaque string the honest statement of how much it
  # carries is how long it is — and raw length >= prose length, so the prose
  # invariant holds a fortiori.
  #
  # A body whose `html` already fits the cap is kept WHOLE: a short paper under
  # a generous bound is not truncated, and must not be flagged as if it were.
  defp bound_body_html(body, max) do
    case Map.fetch(body, "html") do
      {:ok, html} when is_binary(html) ->
        if String.length(html) > max do
          {Map.delete(body, "html"), true}
        else
          {body, false}
        end

      _ ->
        {body, false}
    end
  end

  # The smallest PREFIX of `blocks` whose flattened prose reaches `max`
  # characters, plus whether anything was dropped. Whole blocks only: a block
  # is the unit a renderer can draw, and half of one is not a block.
  defp prefix(blocks, max) do
    {kept, _spent, dropped} =
      Enum.reduce(blocks, {[], 0, 0}, fn block, {kept, spent, dropped} ->
        cond do
          # Budget already reached — everything from here on is dropped. Note
          # this is `>=`, so a 0-char budget keeps nothing at all.
          spent >= max -> {kept, spent, dropped + 1}
          true -> {[block | kept], spent + text_length(block), dropped}
        end
      end)

    {Enum.reverse(kept), dropped > 0}
  end

  # Characters of human text under a block, counting only what a prose
  # flattener would collect.
  defp text_length(node) when is_binary(node), do: String.length(node)

  defp text_length(node) when is_list(node),
    do: Enum.reduce(node, 0, &(text_length(&1) + &2))

  defp text_length(node) when is_map(node) do
    Enum.reduce(node, 0, fn {k, v}, acc ->
      if k in @skip_keys, do: acc, else: acc + text_length(v)
    end)
  end

  defp text_length(_), do: 0

  defp slice(text, max), do: String.slice(text, 0, max)
end
