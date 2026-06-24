defmodule Barkpark.Content.Backlinks do
  @moduledoc """
  Reverse-link index for papers — "what links TO this paper".

  A wikilink (`[[Other Paper]]`) is an inline node stored on the SOURCE paper's
  blocks (see `Barkpark.PortableDoc.Render.Inline` ~:89-107 for the node shape).
  Nothing on the TARGET paper records who points at it. `backlinks_for/3` closes
  that gap: given a target paper, it scans every OTHER paper in the dataset and
  returns the ones whose blocks carry a wikilink that resolves to the target.

  ## What counts as a backlink (two match modes)

  The id-pin work (#180) stamps the chosen paper's `doc_id` onto a wikilink when
  the author PICKED a paper from the `[[` autocomplete; a TYPED-not-picked
  wikilink carries only its raw `"target"` string. So a candidate paper is a
  backlink when ANY of its wikilinks matches the target via either:

    * **`:precise`** — the wikilink's `doc_id` / `docId` equals the target
      paper's `doc_id`. AUTHORITATIVE: the author explicitly bound this link to
      this exact paper, so it cannot be a false positive even across duplicate
      titles.

    * **`:fallback`** — the wikilink has NO id, and its `"target"` STRING
      resolves to the target paper by **slug** (`doc_id`) or **title**, both
      case-folded. BEST-EFFORT: a typed link that merely *names* this paper.
      It is genuinely fuzzy — two papers may share a title, and a typed
      `[[Overview]]` cannot say which "Overview" the author meant. We match
      title EXACTLY (case-folded), never a substring, so a link to a DIFFERENT
      paper that happens to share a title *word* is NOT a false positive; but a
      true title COLLISION (two papers literally titled "Overview") will report
      a typed link as a backlink of BOTH. The id-pin is the cure — precise
      matches never suffer this. Each context is tagged with its `match` mode so
      a caller (or a human) can weigh a fallback hit accordingly.

  The target paper is EXCLUDED from its own results (a paper linking to itself
  is not a backlink), keyed on `doc_id`.

  ## Result shape

      [%{slug: String.t(), title: String.t(),
         contexts: [%{text: String.t(), match: :precise | :fallback}]}]

  One entry per linking paper, even when it links multiple times — DEDUPED by
  slug, with one `contexts` element per linking wikilink occurrence (capped, see
  PERFORMANCE). `contexts` carry a short plain-text snippet of the block that
  held the wikilink, so the rendered section reads as "X mentions this in: …"
  rather than a bare list of titles. Results are title-ordered (then slug) for a
  stable, human-pleasant order.

  ## PERFORMANCE — on-demand scan (v1), NOT the durable design

  This is an O(papers × blocks × inline-nodes) full-corpus scan run ON EVERY
  reader request. That is acceptable for a moderate corpus (hundreds of papers)
  and is deliberately the v1 shape: it needs no migration, no write-path hook,
  and no index to maintain, so it cannot drift out of sync with the blocks (the
  blocks ARE the system of record).

  It WILL melt at scale — a corpus of thousands of papers re-scanned per pageview
  is the obvious cliff. The DURABLE design indexes wikilink EDGES at paper-save
  time: a denormalized edge list / backlink table (`from_slug, to_slug_or_id,
  match_mode, context`) written whenever a paper's blocks change, so a backlink
  read is a single indexed lookup keyed on the target. That is intentionally
  deferred here, not silently shipped as a scan that pretends to scale.

  Two cheap bounds keep the v1 scan honest in the meantime, both documented and
  enforced below: a candidate-paper cap (`@candidate_scan_limit`) and a
  per-paper context cap (`@max_contexts_per_paper`). Both are stated rather than
  silent — a corpus over the cap returns a correct-but-partial answer, never a
  runaway scan.

  Pure-ish: the impure work is the candidate `list_documents` read, plus a
  `get_paper` read for the target's identity ONLY when a slug string is passed —
  when an already-loaded `%Content.Document{}` is passed, its identity is read
  directly with no DB call. The walk, the match logic, and the snippet
  extraction are pure over maps + lists.
  """

  alias Barkpark.Content
  alias Barkpark.Content.DraftId
  require Logger

  # PERFORMANCE bound (1/2): cap the candidate set the v1 scan walks. A corpus
  # larger than this returns a correct-but-partial answer (the most-recently
  # updated papers, per `list_documents`' default `:updated_at_desc` order)
  # rather than an unbounded scan. The durable edge index removes this ceiling.
  @candidate_scan_limit 500

  # PERFORMANCE bound (2/2): cap contexts carried per linking paper. A paper that
  # links the target 50 times contributes at most this many snippets — the
  # section stays readable and the result stays small. The link still counts as
  # ONE backlink entry; only the snippet list is capped.
  @max_contexts_per_paper 3

  # Snippet length cap — a context is the linking block's plain text, trimmed +
  # collapsed, truncated to this many characters (with an ellipsis) so a long
  # paragraph does not bloat the section.
  @snippet_max_chars 200

  @type match_mode :: :precise | :fallback
  @type context :: %{text: String.t(), match: match_mode()}
  @type backlink :: %{slug: String.t(), title: String.t(), contexts: [context()]}

  @doc """
  Backlinks for `target` — every OTHER paper in `dataset` whose blocks carry a
  wikilink that resolves to `target` (precise id-pin OR fallback string match).

  `target` may be a `%Content.Document{}` (the already-loaded paper) or a slug
  string (resolved here via `Content.get_paper/2`). Returns `[]` when the target
  cannot be resolved or nothing links to it. `opts` are threaded onto the
  candidate `list_documents` read (tenant scope, etc.), mirroring `get_paper/3`.

  See the moduledoc for the precise/fallback match contract, self-exclusion,
  dedup, the context shape, and the v1 performance caveat.
  """
  @spec backlinks_for(Content.Document.t() | String.t(), String.t(), keyword()) :: [backlink()]
  def backlinks_for(target, dataset \\ Content.paper_default_dataset(), opts \\ [])

  def backlinks_for(slug, dataset, opts) when is_binary(slug) do
    case Content.get_paper(slug, dataset, opts) do
      nil -> []
      %Content.Document{} = doc -> backlinks_for(doc, dataset, opts)
    end
  end

  def backlinks_for(%Content.Document{doc_id: target_id} = target, dataset, opts)
      when is_binary(target_id) do
    # Normalize to the published id so self-exclusion + precise match are robust
    # when the target is read as a draft ("drafts.p-x") but candidates/wikilinks
    # carry the published id ("p-x"), or vice versa — otherwise a paper could list
    # itself as a backlink, or a real id-pin could miss across the draft/published twin.
    target_base = DraftId.published_id(target_id)
    target_title = down(target.title)
    target_slug = down(target_base)

    candidates = Content.list_documents("paper", dataset, scan_opts(opts))

    if length(candidates) >= @candidate_scan_limit do
      Logger.warning(
        "Backlinks scan hit the #{@candidate_scan_limit}-paper cap for #{target_base}; " <>
          "the result is correct-but-partial. Index wikilink edges on save for full coverage."
      )
    end

    candidates
    |> Enum.reject(&(DraftId.published_id(&1.doc_id) == target_base))
    |> Enum.flat_map(fn candidate ->
      case candidate_contexts(candidate, target_base, target_title, target_slug) do
        [] -> []
        contexts -> [%{slug: candidate.doc_id, title: candidate.title, contexts: contexts}]
      end
    end)
    |> Enum.sort_by(&{down(&1.title), down(&1.slug)})
  end

  def backlinks_for(_target, _dataset, _opts), do: []

  # Force the candidate cap + a published perspective onto the caller's opts. The
  # caller's tenant scope (workspace/project) passes through untouched.
  defp scan_opts(opts) do
    opts
    |> Keyword.put_new(:limit, @candidate_scan_limit)
    |> Keyword.put_new(:perspective, :published)
  end

  # Walk ONE candidate paper's blocks, collecting a context per wikilink that
  # matches the target. Returns `[]` (the not-a-backlink signal) when none match.
  # Dedup is implicit: this runs once per candidate, so a candidate yields at
  # most one backlink entry regardless of how many times it links.
  defp candidate_contexts(%Content.Document{content: content}, target_id, target_title, target_slug)
       when is_map(content) do
    case Map.get(content, "blocks") do
      blocks when is_list(blocks) ->
        blocks
        |> Enum.flat_map(&block_contexts(&1, target_id, target_title, target_slug))
        |> Enum.take(@max_contexts_per_paper)

      _ ->
        []
    end
  end

  defp candidate_contexts(_doc, _id, _title, _slug), do: []

  # For one block: find every wikilink anywhere in its inline tree that matches
  # the target, and pair each with the block's plain-text snippet. The snippet is
  # computed ONCE per block (cheap) and reused for every matching wikilink in it.
  defp block_contexts(block, target_id, target_title, target_slug) when is_map(block) do
    matches = collect_matching_wikilinks(block, target_id, target_title, target_slug, [])

    case matches do
      [] ->
        []

      modes ->
        snippet = block_snippet(block)
        Enum.map(modes, fn mode -> %{text: snippet, match: mode} end)
    end
  end

  defp block_contexts(_block, _id, _title, _slug), do: []

  # Deep walk (mirrors `Papers.collect_link_targets/2`): descend arbitrarily
  # nested maps + lists, accumulating a `:precise` / `:fallback` mode for every
  # wikilink NODE that matches the target. A wikilink that matches NEITHER mode
  # is skipped (e.g. a link to a different paper). Both the camelCase JS spelling
  # (`docId`) and the snake_case (`doc_id`) id key are accepted, exactly as
  # `Inline.compose_inline/2` does.
  defp collect_matching_wikilinks(
         %{"type" => "wikilink"} = node,
         target_id,
         target_title,
         target_slug,
         acc
       ) do
    acc =
      case wikilink_match(node, target_id, target_title, target_slug) do
        nil -> acc
        mode -> [mode | acc]
      end

    # Keep descending — a wikilink may (pathologically) nest children, and we
    # must not stop the walk at it.
    Enum.reduce(Map.values(node), acc, fn v, a ->
      collect_matching_wikilinks(v, target_id, target_title, target_slug, a)
    end)
  end

  defp collect_matching_wikilinks(node, target_id, target_title, target_slug, acc)
       when is_map(node) do
    Enum.reduce(Map.values(node), acc, fn v, a ->
      collect_matching_wikilinks(v, target_id, target_title, target_slug, a)
    end)
  end

  defp collect_matching_wikilinks(list, target_id, target_title, target_slug, acc)
       when is_list(list) do
    Enum.reduce(list, acc, fn v, a ->
      collect_matching_wikilinks(v, target_id, target_title, target_slug, a)
    end)
  end

  defp collect_matching_wikilinks(_other, _id, _title, _slug, acc), do: acc

  # Classify ONE wikilink node against the target. PRECISE wins when an id is
  # present and equal (the id-pin is authoritative); otherwise, ONLY when no id
  # is present, try the FALLBACK string match. A wikilink with a NON-matching id
  # is NOT a fallback candidate — the author bound it to a different paper, so we
  # honour that and report no match (no false positive from an id-pinned link to
  # someone else).
  defp wikilink_match(node, target_id, target_title, target_slug) do
    case wikilink_doc_id(node) do
      id when is_binary(id) and id != "" ->
        # target_id is already the published-normalized base; normalize the pinned
        # wikilink id the same way so a draft/published twin still matches precisely.
        if DraftId.published_id(id) == target_id, do: :precise, else: nil

      _ ->
        if fallback_match?(node, target_title, target_slug), do: :fallback, else: nil
    end
  end

  # Accept both id spellings (JS `docId`, Elixir `doc_id`), mirroring Inline.
  defp wikilink_doc_id(node), do: Map.get(node, "doc_id") || Map.get(node, "docId")

  # FALLBACK: the typed `"target"` string == the target paper's slug OR title,
  # case-folded. EXACT (not substring) so "Design Patterns" does not backlink a
  # paper titled "Design" — a shared *word* is not a match; only the whole
  # string resolving to this paper is.
  defp fallback_match?(node, target_title, target_slug) do
    case Map.get(node, "target") do
      t when is_binary(t) ->
        folded = down(t)
        folded != "" and (folded == target_title or folded == target_slug)

      _ ->
        false
    end
  end

  # ── plain-text snippet extraction (pure) ───────────────────────────────────
  # A block's snippet = the concatenated text of its inline content, whitespace-
  # collapsed + trimmed + truncated. Self-contained (no render-engine call): it
  # reads the same inline `"value"` / `"children"` shape `Inline` folds, plus the
  # list-item `"items"` shape, so it works for paragraphs, headings, list items,
  # callouts, etc. uniformly.

  defp block_snippet(block) do
    block
    |> inline_text()
    |> collapse_ws()
    |> truncate(@snippet_max_chars)
  end

  # Deep text harvest: a node's visible text is its own `"value"` plus the text
  # of its `"content"` / `"children"` / `"items"` subtrees, in document order.
  # Bare strings (the scalar-cell tolerance Inline also honours) contribute
  # themselves.
  defp inline_text(s) when is_binary(s), do: s
  defp inline_text(n) when is_number(n), do: to_string(n)

  defp inline_text(%{} = node) do
    own = node |> Map.get("value") |> text_or_empty()

    children =
      ["content", "children", "items"]
      |> Enum.map(&Map.get(node, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(" ", &inline_text/1)

    [own, children]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp inline_text(list) when is_list(list), do: Enum.map_join(list, " ", &inline_text/1)
  defp inline_text(_), do: ""

  defp text_or_empty(s) when is_binary(s), do: s
  defp text_or_empty(_), do: ""

  defp collapse_ws(s) do
    s
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp truncate(s, max) when byte_size(s) <= max, do: s

  defp truncate(s, max) do
    # Truncate on a grapheme boundary (don't split a multi-byte char), then
    # append an ellipsis. `max` is a soft char budget, not a hard byte cap.
    s
    |> String.slice(0, max)
    |> String.trim_trailing()
    |> Kernel.<>("…")
  end

  defp down(nil), do: ""
  defp down(s) when is_binary(s), do: s |> String.trim() |> String.downcase()
  defp down(other), do: other |> to_string() |> String.downcase()
end
