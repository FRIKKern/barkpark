defmodule Barkpark.Content.Papers do
  @moduledoc """
  Papers — the `type:"paper"` document feature (the Bulldocs surface).

  A paper is a `documents` row of type "paper" (doc_id = the slug). Its
  portable-doc block list is the source of truth, stored under
  `content["blocks"]`; `content["body_html"]` is the derived HTML cache
  rendered by `Barkpark.PortableDoc.Render`. The monotonic integer streaming
  rev — distinct from the document's opaque string `rev` used by the mutation
  spine — lives at `content["rev"]`. `content["source_doc"]`, `["goal_id"]`,
  and `["event_type"]` carry paper-ingest provenance.

  Papers ride the SAME per-doc PubSub topic shape used in Wave 4 —
  `doc:<dataset>:paper:<slug>` — and broadcast the SAME two frames
  (`{:paper_updated, …}` whole-HTML, `{:paper_block, …}` delta) so
  `BarkparkWeb.BulldocsLive` keeps working with minimal change.

  These operate on `documents` rows of type "paper". They preserve the Wave 4
  streaming protocol exactly — only the storage moved from the dedicated
  `papers` table into the unified `documents` table. The logic below is the
  port of the former `Barkpark.Papers` context.

  Extracted from `Barkpark.Content` (decomposition Step 10, concern P).
  `Barkpark.Content` keeps facade delegations so every external caller is
  unchanged; the write path (`upsert_document`), schema lookups, and scope
  helpers are called back through `Barkpark.Content.*`.
  """

  alias Barkpark.Content

  alias Barkpark.Content.{
    Broadcast,
    CallerContext,
    Document,
    DraftId,
    Envelope,
    Labels,
    SchemaDefinition
  }

  alias Barkpark.Content.Papers.{BlockOps, Hollow}
  alias Barkpark.PortableDoc.{BodyWalk, HtmlSanitizer, Projection, Render, Synthesis}
  alias Barkpark.Repo

  @paper_type "paper"
  @paper_default_dataset "production"

  @doc """
  The default dataset papers live under. Convergence: papers are now
  first-class documents in the `production` dataset, so they surface
  in the Studio desk at `/studio/production`.
  """
  def paper_default_dataset, do: @paper_default_dataset

  @doc "The document type discriminator for papers."
  def paper_type, do: @paper_type

  # The closed blocks-type whitelist (session-handoff Task 2): every document
  # type whose write path rides the generalized `upsert_blocks_doc/3` /
  # `BlockOps.upsert_blocks_doc/3` machinery (blocks body + metadata fields).
  # Deliberately closed and hand-maintained, mirroring `AuthoringWall`'s
  # `@walled_types` pattern — widening it is a reviewed one-line decision.
  #
  # SOLE SOURCE OF TRUTH lives in `BlockOps` (a compile-time module attribute
  # there, required so its `upsert_blocks_doc/3` guard clause can pattern
  # against it) — both delegates below defer to it rather than keeping an
  # independent literal, so there is exactly one list to widen.
  @doc "The closed whitelist of document types that ride the blocks-doc write path."
  defdelegate blocks_types(), to: BlockOps

  @doc "Whether `type` is in the blocks-doc whitelist (`blocks_types/0`)."
  defdelegate blocks_type?(type), to: BlockOps

  @doc """
  Fetch a blocks-doc (a document whose type rides `upsert_blocks_doc/3`) by
  `{slug, type, dataset}`. Generalizes `get_paper/3` off the hardcoded
  `"paper"` type — same shape, `%Document{} | nil`.
  """
  def get_blocks_doc(slug, type, dataset \\ @paper_default_dataset, opts \\ [])
      when is_binary(slug) and is_binary(type) do
    case Content.get_document(slug, type, dataset, opts) do
      {:ok, doc} -> doc
      {:error, :not_found} -> nil
    end
  end

  @doc "Return one visibility-safe canonical source for any historical Paper shape."
  def reader_source(paper, dataset, scope_opts \\ [])

  def reader_source(%Document{} = paper, dataset, scope_opts) do
    scope_opts = reader_schema_scope(paper, scope_opts || [])
    had_structured_source? = is_list(Projection.read_blocks(paper.content || %{}))

    schema =
      case Content.Schema.get_schema_for_redaction(@paper_type, dataset, scope_opts) do
        {:ok, value} -> value
        :error -> nil
      end

    envelope = Envelope.render(paper, schema, CallerContext.anonymous())

    # Envelope promotes every historical block shape to the canonical top-level
    # key *before* redaction. Read only that destination: falling back through a
    # redacted legacy `body` here would bypass a private `blocks` field.
    case Map.get(envelope, "blocks") do
      blocks when is_list(blocks) ->
        classify_reader_blocks(paper, blocks, envelope, dataset)

      _ when had_structured_source? ->
        # A structured source existed but disappeared at the Envelope boundary,
        # so visibility redaction removed it. `body_html` is a derived cache of
        # that same prose; falling through would disclose what was just hidden.
        {:error, :redacted_source}

      _ ->
        case envelope["body_html"] do
          html when is_binary(html) ->
            sanitized = HtmlSanitizer.sanitize(html)

            if semantic_html?(sanitized),
              do: {:html, sanitized},
              else: {:error, :semantic_empty}

          _ ->
            {:error, :semantic_empty}
        end
    end
  end

  def reader_source(_, _dataset, _scope_opts), do: {:error, :not_found}

  defp classify_reader_blocks(paper, blocks, envelope, dataset) do
    cond do
      not valid_reader_blocks?(blocks) ->
        {:error, :invalid_blocks}

      Hollow.hollow?(blocks) ->
        {:error, :semantic_empty}

      true ->
        case cache_provenance(paper, blocks, envelope["body_html"], dataset) do
          :coherent ->
            {:blocks, blocks}

          {:stale, rendered} ->
            refresh_html_cache(paper, blocks, rendered)
            {:blocks, blocks}

          :divergent ->
            {:error, :ambiguous_source}
        end
    end
  end

  defp valid_reader_blocks?(blocks) do
    Enum.all?(blocks, fn
      %{"type" => type} when is_binary(type) -> String.trim(type) != ""
      _ -> false
    end)
  end

  # Classify a byte mismatch between the stored `body_html` cache and a fresh
  # render of the selected blocks. A bare `rendered != html` cannot do this: it
  # conflates two populations with OPPOSITE correct handling, and answering
  # "ambiguous" to both is what made honest drift a hard 422.
  #
  #   :coherent        — no cache, or the cache IS this render. Serve blocks.
  #   {:stale, html}   — the cache was rendered from THESE blocks by a renderer
  #                      that is no longer ours (or its resolved externals have
  #                      since moved). Blocks are canonical, so serve them and
  #                      rewrite the derived cache. No 422.
  #   :divergent       — the stamp IS the current renderer's digest, so the row
  #                      claims this renderer emitted these bytes from these
  #                      blocks; the byte compare says otherwise and nothing
  #                      external can explain the gap. The cache carries content
  #                      the blocks do not. This is the population the 422 was
  #                      built for; it keeps it, and ONLY it.
  #
  # Provenance comes from `content["body_html_sv"]` — a sha256 digest of the
  # renderer's own source, stamped at every fresh block→HTML render. Compare it
  # with `==` ONLY: a content hash has no total order, so "older/newer" is not a
  # question it can answer. Anything that is not that digest — an old digest,
  # the honest pre-digest integer, or nothing — is a LAGGING stamp, i.e. stale.
  defp cache_provenance(_paper, _blocks, html, _dataset)
       when not is_binary(html) or html == "",
       do: :coherent

  defp cache_provenance(paper, blocks, html, dataset) do
    content = paper.content || %{}
    style = get_in(content, ["style"])
    scope = [workspace_id: paper.workspace_id, project_id: paper.project_id]
    rendered = Render.render_blocks(blocks, Labels.paper_render_opts(dataset, style, scope))

    cond do
      rendered == html ->
        :coherent

      # EXTERNAL REFERENT DRIFT — a third class the drift/divergence split does
      # not name, and the rule above is UNSOUND without it. `paper_render_opts`
      # injects ref/codelist resolver closures that run LIVE queries, and the
      # resolved value reaches the emitted bytes. So renaming a REFERENCED
      # document moves this render while the blocks, the cache, the stamp AND
      # the renderer are all untouched — a byte gap with a current stamp that is
      # emphatically NOT divergence. For a block list that resolves externals,
      # the byte-compare cannot prove divergence AT ALL, with or without a
      # stamp, so it must not be the thing that 422s. This narrows the
      # detector's INPUT; every other document keeps the full safety property.
      #
      # Deliberately NOT fixed by freezing the resolved label into provenance:
      # a frozen label makes "stamp matches" true while the correct rendering
      # legitimately differs, so the reader would serve the OLD title behind a
      # matching stamp — trading a loud false 422 for a silent wrong value.
      resolver_dependent?(blocks) ->
        {:stale, rendered}

      true ->
        # DIVERGENCE IS THE NARROW CASE: only a stamp that IS the current
        # renderer's digest can carry the claim "this renderer, fed these
        # blocks, emitted these bytes" — and only that claim, contradicted by
        # the byte compare, is divergence. Every other stamp state is a LAGGING
        # stamp: an old hex digest, the renderer's own honest pre-digest integer
        # (`@body_html_render_version 1..3`, before it became a sha256 hex), or
        # no stamp at all. None of them claims this renderer, so none of them
        # can contradict it, and blocks stay canonical: re-render, serve,
        # restamp.
        #
        # Measured (guerrilla, 2026-08-17 — recipe in
        # tooling/grip/ledger/pe-w2-guerrilla-live-writes-2026-08-17.md): the
        # old `_ -> :divergent` catch-all sent 119 papers stamped with the
        # integer 3 into this branch, and 59 of them answered 422 to every
        # reader for ~4 weeks. The remaining 60 served only via the
        # `rendered == html` short-circuit above, so any renderer change would
        # have gone dark too; 42 null-stamped papers carried the same hazard.
        # Fail-closed on an unverifiable stamp is not a safety property — it is
        # a reader outage with no upper bound.
        #
        # PROD REPAIR (ops, after this merges — the reader self-heals each row on
        # first read via `refresh_html_cache/3`, this just does it in bulk):
        #
        #     mix barkpark.rehydrate_body_html --type paper --published-only
        #     mix barkpark.rehydrate_body_html --type paper --published-only --write
        #
        # The first line is the DRY-RUN TALLY (dry run is that task's default —
        # it reports and writes nothing). An integer stamp reads as "stamp
        # foreign" there, so it lands on the rewrite arm; only `is_nil(sv)` rows
        # with drifted bytes are report-only, and those are exactly the ones the
        # reader now heals itself.
        if Map.get(content, "body_html_sv") == Render.body_html_render_version(),
          do: :divergent,
          else: {:stale, rendered}
    end
  end

  # Does any block in the list resolve an EXTERNAL referent at render time?
  # The guards mirror `Render.resolve_ref_title/2` and `resolve_code_label/2`
  # exactly — same types, same non-empty binary `"value"` condition — so this
  # predicate is true precisely when a resolver closure can move the bytes.
  # Descends into nested block lists: a reference inside a column or callout
  # resolves the same way one at the top level does.
  defp resolver_dependent?(blocks) when is_list(blocks),
    do: Enum.any?(blocks, &resolver_dependent?/1)

  defp resolver_dependent?(%{"type" => type, "value" => value})
       when type in ["field-reference", "codelist"] and is_binary(value) and value != "",
       do: true

  defp resolver_dependent?(block) when is_map(block),
    do: block |> Map.values() |> Enum.any?(&resolver_dependent?/1)

  defp resolver_dependent?(_), do: false

  # Rewrite the derived HTML cache with the render we just proved canonical, so
  # the next read takes the `:coherent` path instead of re-rendering.
  #
  # Two conditions, each load-bearing. The paper must be a persisted row (a
  # bare in-memory %Document{} has no id — the pure unit seam must never touch
  # the Repo). And the blocks we rendered from must be byte-identical to the
  # STORED blocks: `blocks` arrives from the Envelope, i.e. post-redaction, and
  # persisting a cache rendered from a redacted view would destroy content.
  #
  # Best-effort by construction: this runs inside a READ. A concurrent write, a
  # stale rev, or no database at all must never turn a servable paper into an
  # error, so every failure is swallowed and the blocks are served regardless.
  defp refresh_html_cache(%Document{id: id} = paper, blocks, rendered) when not is_nil(id) do
    content = paper.content || %{}

    if Projection.read_blocks(content) == blocks do
      new_content =
        content
        |> Map.put("body_html", rendered)
        |> Map.put("body_html_sv", Render.body_html_render_version())

      try do
        paper
        |> Document.changeset(%{"content" => new_content})
        |> Ecto.Changeset.optimistic_lock(:rev, fn _ ->
          :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
        end)
        |> Repo.update()
      rescue
        _ -> :error
      catch
        _, _ -> :error
      end
    end

    :ok
  end

  defp refresh_html_cache(_paper, _blocks, _rendered), do: :ok

  # Semantic validity mirrors the reader audit: hidden nodes and non-image
  # accessibility metadata are not authored visible content; visible text and
  # image alt text are. Numeric entities are decoded, and common named entities
  # are normalized before applying the shared letter/number/symbol predicate.
  defp semantic_html?(html) do
    visible_html = strip_hidden_html(html)

    text =
      visible_html
      |> then(
        &Regex.replace(
          ~r/<img\b[^>]*\balt\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>/i,
          &1,
          fn _full, double, single, bare -> " " <> (double <> single <> bare) <> " " end
        )
      )
      |> String.replace(~r/<[^>]*>/s, " ")
      |> decode_visible_entities()
      |> String.trim()

    Hollow.semantic_text?(text)
  end

  defp strip_hidden_html(html) do
    {_stack, visible} =
      ~r/<[^>]*>|[^<]+/s
      |> Regex.scan(html)
      |> List.flatten()
      |> Enum.reduce({[], []}, &strip_hidden_token/2)

    visible
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  @html_void_elements ~w(area base br col embed hr img input link meta param source track wbr)

  defp strip_hidden_token(token, {stack, visible}) do
    cond do
      closing_html_tag?(token) ->
        [_, tag] = Regex.run(~r/^<\s*\/\s*([a-z][a-z0-9:-]*)[^>]*>$/is, token)
        hidden? = hidden_stack?(stack)
        next_stack = close_html_tag(stack, String.downcase(tag))
        {next_stack, if(hidden?, do: visible, else: [token | visible])}

      opening_html_tag?(token) ->
        [_, tag, attrs] = Regex.run(~r/^<\s*([a-z][a-z0-9:-]*)\b(.*)>$/is, token)
        tag = String.downcase(tag)
        hidden? = hidden_stack?(stack) or hidden_html_attrs?(attrs)
        void? = tag in @html_void_elements or Regex.match?(~r/\/\s*>$/, token)
        next_stack = if void?, do: stack, else: [{tag, hidden?} | stack]
        {next_stack, if(hidden?, do: visible, else: [token | visible])}

      hidden_stack?(stack) ->
        {stack, visible}

      true ->
        {stack, [token | visible]}
    end
  end

  defp closing_html_tag?(token),
    do: Regex.match?(~r/^<\s*\/\s*[a-z][a-z0-9:-]*[^>]*>$/is, token)

  defp opening_html_tag?(token),
    do: Regex.match?(~r/^<\s*[a-z][a-z0-9:-]*\b.*>$/is, token)

  defp hidden_stack?([{_tag, hidden?} | _]), do: hidden?
  defp hidden_stack?([]), do: false

  defp hidden_html_attrs?(attrs) do
    Regex.match?(~r/(?:^|\s)hidden(?:\s|=|$)/i, attrs) or
      Regex.match?(~r/(?:^|\s)aria-hidden\s*=\s*(?:"true"|'true'|true)(?:\s|$)/i, attrs)
  end

  defp close_html_tag(stack, tag) do
    case Enum.split_while(stack, fn {open_tag, _hidden?} -> open_tag != tag end) do
      {_unclosed, []} -> stack
      {_unclosed, [_matched | rest]} -> rest
    end
  end

  defp decode_visible_entities(text) do
    text
    |> then(
      &Regex.replace(~r/&#x([0-9a-f]+);?/i, &1, fn _full, hex ->
        html_codepoint(hex, 16)
      end)
    )
    |> then(&Regex.replace(~r/&#([0-9]+);?/, &1, fn _full, dec -> html_codepoint(dec, 10) end))
    |> String.replace(~r/&(?:amp|lt|gt|quot|apos);/i, fn entity ->
      case String.downcase(entity) do
        "&amp;" -> "&"
        "&lt;" -> "<"
        "&gt;" -> ">"
        "&quot;" -> "\""
        "&apos;" -> "'"
      end
    end)
    |> String.replace(~r/&(?:nbsp|ensp|emsp|thinsp|zwnj|zwj|lrm|rlm|shy);/i, " ")
    |> String.replace(~r/&(?:mdash|ndash|hellip|middot|bull|laquo|raquo);/i, " — ")
    # Remaining named entities represent a visible authored glyph. A semantic
    # marker preserves that fact without pretending to implement an HTML parser.
    |> String.replace(~r/&[a-z][a-z0-9]+;/i, " ∑ ")
  end

  defp html_codepoint(digits, base) do
    case Integer.parse(digits, base) do
      {cp, ""} when cp in 0..0xD7FF or cp in 0xE000..0x10FFFF -> <<cp::utf8>>
      _ -> ""
    end
  end

  defp reader_schema_scope(paper, scope_opts) do
    scope_opts
    |> Keyword.put_new(:workspace_id, paper.workspace_id)
    |> Keyword.put_new(:project_id, paper.project_id)
  end

  @doc """
  The paper map `Bpml.print_paper/1` is handed — the ONE builder for it.

  Two call sites print a paper as BPML: the source route (`bp paper pull`) and
  the ingest route's post-write canonical echo (`bp paper push`). They MUST
  agree — `bp paper push` compares the echo against the next pull, so any drift
  between them shows up as a working copy that changes under an author who
  edited nothing.

  They drifted: both built the map inline as slug/title/blocks, omitting the
  label spine. `print_paper/1` has emitted `<meta><description>`/`<tag>` and the
  parser has read it back since #11640, so the metadata was dropped on the way
  IN, not on the way out. The visible symptom was a FALSE publish-wall verdict —
  an UNEDITED pull fed to `bp paper push --check` failed `label_spine` "a
  published document requires a description" on the 1002 of 1015 published
  papers that have one.

  Blocks are passed separately because the two callers resolve them
  differently (the reader resolves tasks/wikilinks; the echo reads what was
  just persisted) — the label spine is the part that must not vary.
  """
  @spec bpml_paper_map(Document.t(), list()) :: map()
  def bpml_paper_map(%Document{} = paper, blocks) when is_list(blocks) do
    content = paper.content || %{}

    %{
      "slug" => paper.doc_id,
      "title" => paper.title,
      "description" => Map.get(content, "description"),
      "tags" => Map.get(content, "tags", []),
      "blocks" => blocks
    }
  end

  @doc """
  Per-doc PubSub topic for a paper, SCOPED to the owning workspace:
  `doc:ws:<workspace_id>:<dataset>:paper:<slug>`.

  WORKSPACE SCOPE (barkpark-n56v, P0): paper slugs are PER-WORKSPACE (the
  Wave-2 uniqueness flip), so workspace A's `intro` and B's `intro` are
  DISTINCT papers. The old topic `doc:<dataset>:paper:<slug>` had NO workspace
  component, so both papers collapsed onto ONE topic — a write in B leaked its
  rendered body to A's public viewer. The `ws:<workspace_id>` segment keeps the
  topics distinct so a broadcast only reaches subscribers of the SAME workspace.

  Broadcaster and subscriber MUST agree on `workspace_id` for the legitimate
  same-tenant case, or live updates silently stop. Both sides resolve the id
  through `normalize_topic_ws/1`: a present id passes through; a `nil` (legacy
  NULL-workspace row) normalizes to the seeded Default workspace id — the same
  tenant `get_public_paper/2` resolves a public paper into — so the public
  viewer and the broadcaster land on the identical topic. With no seeded
  Default, both sides fall back to the literal `"global"` token, so they still
  agree.

  BulldocsLive subscribes to this; writes broadcast to it. The topic shape is
  owned by `Content.Broadcast` — this is a thin facade so the `\\` default arg
  stays explicit for callers.
  """
  def paper_topic(slug, workspace_id, dataset \\ @paper_default_dataset),
    do: Broadcast.paper_topic(slug, workspace_id, dataset)

  @doc """
  Fetch a paper (a type-"paper" document) by slug (and dataset). Returns the
  `%Document{}` or `nil`. Papers are always published (no draft prefix).

  SCOPE: `opts` may carry `:workspace_id` / `:project_id`; the read is then
  scoped to that tenant. With NO scope opts the read is an EXPLICIT global read
  (`get_document` routes nil through `scope_to_workspace_or_global/3`, which
  returns the query untouched) — that is the INTERNAL, already-tenant-resolved
  caller path (e.g. `upsert_paper`'s pre-write lookup, which keys on
  `{dataset, slug}` and stamps the resolved scope itself). It is NOT the public
  read path: a public, unauthenticated request MUST go through
  `get_public_paper/2`, which closes the cross-workspace leak (barkpark-w9dg) by
  resolving the slug ONLY within the seeded Default (public) workspace. See that
  function's doc for why.
  """
  def get_paper(slug, dataset \\ @paper_default_dataset, opts \\ []) when is_binary(slug) do
    case Content.get_document(slug, @paper_type, dataset, opts) do
      {:ok, doc} -> doc
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Resolve a wikilink `target` (a human title or alias) to the linked document.

  TYPE-DISPATCHED (lvw-t7): papers stay the primary wikilink corpus — a paper
  match wins outright — but a target that resolves to NO paper falls through to
  `type:"task"`, so a wikilink whose target is a task renders the live task
  CHIP instead of a dead link.

  Returns the single best match (title beats alias on a collision; see
  `Content.Query.resolve_doc_by_title_or_alias/4`), or `nil` when nothing
  matches or `target` is blank:

    * paper → `%{id, title, kind: "paper"}` (the pre-chip shape plus `:kind`)
    * task  → `%{id, title, kind: "task", status, priority, criteria}` where
      `status` is `content["lifecycle_status"]` (nil-tolerant), `priority` the
      0..4 integer (0 HIGHEST) or nil, and `criteria` a `%{met, total}` count
      over `acceptance_criteria` or nil when absent (renderers then OMIT the
      m/n segment — never "0/0").

  This is the AUTHORITY that turns ANY stored `target` string (typed or picked
  by the `[[` autocomplete) into a link. Resolution is RENDER-TIME and
  scope-bound: `opts` may carry `:workspace_id` / `:project_id`, mirroring
  `get_paper/3`. The stored node keeps the raw `target`; the resolved id appears
  only in emitted HTML.

  D5: pass `published_only: true` for any resolution feeding an ANONYMOUS /
  public surface — rich task state (and the title) then resolves only from
  PUBLISHED rows; a draft-only task simply does not resolve and the wikilink
  degrades to its alias/children.
  """
  @spec resolve_wikilink(String.t(), String.t(), keyword()) :: map() | nil
  # @canonical capability:task-chip-resolve aka:task-chip,taskref doc:docs/contracts/portable-doc-inline.md
  def resolve_wikilink(target, dataset \\ @paper_default_dataset, opts \\ [])
      when is_binary(target) do
    case String.trim(target) do
      "" ->
        nil

      trimmed ->
        resolve_targets_map([trimmed], [], dataset, opts) |> Map.get(trimmed)
    end
  end

  @doc """
  Every paper carrying `tag` — the tag-index read for the `#tag` pane /
  navigation. Returns `[%{id, title}]` (title-ordered), pinned to `type:"paper"`.
  A blank tag yields `[]`.
  """
  @spec papers_with_tag(String.t(), String.t(), keyword()) :: [
          %{id: String.t(), title: String.t()}
        ]
  def papers_with_tag(tag, dataset \\ @paper_default_dataset, opts \\ []) when is_binary(tag) do
    case String.trim(tag) do
      "" ->
        []

      trimmed ->
        trimmed
        |> Content.docs_with_tag(@paper_type, dataset, opts)
        |> Enum.map(&%{id: &1.doc_id, title: &1.title})
    end
  end

  @doc """
  Papers whose title matches `query` (case-insensitive substring) — the
  typeahead candidate read for the `[[` autocomplete and the quick-switcher.
  Returns `[%{id, title}]` (title-ordered), capped at 20. Blank → [].
  """
  @spec search_papers(String.t(), String.t(), keyword()) :: [
          %{id: String.t(), title: String.t()}
        ]
  def search_papers(query, dataset \\ @paper_default_dataset, opts \\ []) when is_binary(query) do
    query
    |> Content.search_documents_by_title(@paper_type, dataset, opts)
    |> Enum.map(&%{id: &1.doc_id, title: &1.title})
  end

  @doc """
  DISTINCT tag NAMES across papers in `dataset` whose name matches `query`
  (case-insensitive substring) — the typeahead candidate read for the `#tag`
  autocomplete. Returns plain strings (name-ordered), capped at 20. Blank
  query → the top distinct tags. The inverse of `papers_with_tag/3`.
  """
  @spec search_tags(String.t(), String.t(), keyword()) :: [String.t()]
  def search_tags(query, dataset \\ @paper_default_dataset, opts \\ []) when is_binary(query) do
    Content.search_tags_for_type(query, @paper_type, dataset, opts)
  end

  @doc """
  Pre-resolve every wikilink target in a block list into the render-opts map
  `%{raw_target => hit}` that `Render.render_html/2` threads onto the palette
  (so `walk/3` emits a navigable `<a>` for resolved paper targets and the live
  TASK CHIP for task targets — see `resolve_wikilink/3` for the hit shapes).

  Collects every distinct `target` from any inline `wikilink` node anywhere in
  `blocks` (deep walk — paragraph content, list items, nested marks) PLUS every
  id-pinned `docId`/`doc_id`, and resolves them in ONE batched query per type
  (`Content.resolve_docs_by_titles_or_aliases/5` — N targets never cost N
  queries; this map can feed the body_html / delta-frame render path).
  Unresolved targets are simply absent (they degrade to the dotted broken-link
  span / the alias fallback).

  Id-pinned entries ride the SAME map under `{:id, pinned_id}` TUPLE keys
  (collision-proof against string targets), so `walk/3`'s id-pin fast path can
  branch by `:kind` — without this a picker-stamped TASK link would render a
  dead `/papers/<task-id>` 404.

  D5: thread `published_only: true` when the palette feeds an anonymous /
  public render (see `resolve_wikilink/3`).
  """
  @spec resolve_wikilinks_in_blocks(list(), String.t(), keyword()) :: %{
          optional(String.t() | {:id, String.t()}) => map()
        }
  def resolve_wikilinks_in_blocks(blocks, dataset \\ @paper_default_dataset, opts \\ [])
      when is_list(blocks) do
    {targets, pinned_ids} = collect_link_refs(blocks)
    resolve_targets_map(targets, pinned_ids, dataset, opts)
  end

  # The shared resolution core behind `resolve_wikilink/3` (one target) and
  # `resolve_wikilinks_in_blocks/3` (the whole palette): ONE candidate query per
  # type — papers first, tasks only for what papers left unresolved — then a
  # pure per-target pick mirroring `resolve_doc_by_title_or_alias/4`'s
  # precedence (case-insensitive title beats exact alias; `doc_id` asc
  # tie-break). Batching is per TYPE (not across types) because tenant/owner
  # scoping is type-keyed — see `Content.Query.resolve_docs_by_titles_or_aliases/5`.
  defp resolve_targets_map(targets, pinned_ids, dataset, opts) do
    # Pinned ids may arrive in either the published or the `drafts.` spelling;
    # fetch both twins so the pick can prefer the exact row.
    pinned_all =
      pinned_ids
      |> Enum.flat_map(fn id ->
        pub = DraftId.published_id(id)
        [id, pub, DraftId.draft_id(pub)]
      end)
      |> Enum.uniq()

    paper_rows =
      Content.resolve_docs_by_titles_or_aliases(targets, pinned_all, @paper_type, dataset, opts)

    # The task fallback query runs ONLY for what papers left unresolved — the
    # common all-paper page keeps its historical single-query cost.
    open_targets = Enum.reject(targets, &pick_row_for_target(&1, paper_rows))
    open_pins = Enum.reject(pinned_ids, &pick_row_for_id(&1, paper_rows))

    task_rows =
      if open_targets == [] and open_pins == [] do
        []
      else
        open_pin_twins =
          open_pins
          |> Enum.flat_map(fn id ->
            pub = DraftId.published_id(id)
            [id, pub, DraftId.draft_id(pub)]
          end)
          |> Enum.uniq()

        Content.resolve_docs_by_titles_or_aliases(
          open_targets,
          open_pin_twins,
          "task",
          dataset,
          opts
        )
      end

    by_target =
      Enum.reduce(targets, %{}, fn target, acc ->
        case pick_row_for_target(target, paper_rows) || pick_row_for_target(target, task_rows) do
          nil -> acc
          row -> Map.put(acc, target, wikilink_hit(row))
        end
      end)

    Enum.reduce(pinned_ids, by_target, fn id, acc ->
      case pick_row_for_id(id, paper_rows) || pick_row_for_id(id, task_rows) do
        nil -> acc
        row -> Map.put(acc, {:id, id}, wikilink_hit(row))
      end
    end)
  end

  # Best row for a title/alias target within one type's candidate rows,
  # mirroring resolve_doc_by_title_or_alias/4: title match (case-insensitive)
  # outranks alias-only (exact); ties break by doc_id asc (rows arrive
  # doc_id-ordered, so `Enum.find` keeps that tie-break).
  defp pick_row_for_target(target, rows) do
    down = String.downcase(target)

    Enum.find(rows, fn row -> String.downcase(row.title || "") == down end) ||
      Enum.find(rows, fn row ->
        case get_in(row.content || %{}, ["aliases"]) do
          aliases when is_list(aliases) -> target in aliases
          _ -> false
        end
      end)
  end

  # Best row for an id-pinned wikilink: the exact doc_id spelling first, then
  # the published/draft twin (mirrors `Labels.reference_title/4`'s
  # published-before-draft preference via the asc doc_id order — "drafts.x"
  # sorts before "x", so prefer the exact match explicitly).
  defp pick_row_for_id(id, rows) do
    pub = DraftId.published_id(id)

    Enum.find(rows, fn row -> row.doc_id == id end) ||
      Enum.find(rows, fn row -> DraftId.published_id(row.doc_id) == pub end)
  end

  # Palette hit for one resolved row. Papers keep the historical `%{id, title}`
  # shape plus `:kind`; tasks grow the LIVE-CHIP state (lvw-t7, wire §4): the
  # id is normalized to the published spelling (chips are not /papers/ links —
  # the id only feeds data-* attrs), `status`/`priority` are read nil-tolerant,
  # and `criteria` is the `%{met, total}` count or nil when absent.
  defp wikilink_hit(%Document{type: "task"} = doc) do
    content = doc.content || %{}

    %{
      id: DraftId.published_id(doc.doc_id),
      title: doc.title,
      kind: "task",
      status: task_chip_status(content),
      # {met,total} semantics owned by Barkpark.Tasks.Criteria (lvw-t6; the
      # canonical task-criteria-progress impl): met === true only,
      # garbage-tolerant, nil when absent → renderers omit the segment.
      priority: task_chip_priority(content),
      criteria: Barkpark.Tasks.criteria_progress(content)
    }
  end

  defp wikilink_hit(%Document{doc_id: id, title: title}),
    do: %{id: id, title: title, kind: "paper"}

  defp task_chip_status(content) do
    case Map.get(content, "lifecycle_status") do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  defp task_chip_priority(content) do
    case Map.get(content, "priority") do
      p when is_integer(p) and p >= 0 -> p
      _ -> nil
    end
  end

  # Deep walk (via the ONE shared `BodyWalk` walker — wire §7.3): collect the
  # `target` of every internal-link inline node AND the pinned `docId`/`doc_id`
  # of id-pinned wikilinks. BOTH `wikilink` and `blockref` resolve their
  # `target` by title/alias (a blockref adds an `anchor` for the in-doc block,
  # but the doc itself resolves the same way), so they share one resolution
  # map. Distinct, document-ordered.
  defp collect_link_refs(blocks) do
    nodes = BodyWalk.collect_nodes(blocks, ["wikilink", "blockref"])

    targets = nodes |> Enum.map(&Map.get(&1, "target")) |> Enum.uniq()

    pinned_ids =
      nodes
      |> Enum.map(fn n -> Map.get(n, "docId") || Map.get(n, "doc_id") end)
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    {targets, pinned_ids}
  end

  @doc """
  Pre-resolve every inline `valueref` (target, field) pair in a block list into
  the render-opts map `%{{target, field} => rendered_string}` that
  `Render.render_html/2` threads onto the palette (`walk/3`'s `valueref/2` then
  renders the CURRENT canonical value; an absent pair degrades to the node's
  pinned `fallback` literal — wire §3/§6: NEVER raise, NEVER blank).

  Mirrors `resolve_wikilinks_in_blocks/3`: deep-walks `blocks` (the ONE shared
  `BodyWalk` walker), collects every distinct `(target, field)` pair, and
  resolves all targets in ONE batched, TYPELESS query
  (`Content.resolve_docs_by_ids/3`) with the published-row preference of the
  canonical slug-resolve (D3) — N pairs never cost N queries (this map can feed
  the body_html / delta-frame render path).

  ## Security (non-negotiable, wire §3/§5)

    * The target loads TENANT-SCOPED to the host paper's workspace/project/
      dataset (thread `:workspace_id` / `:project_id`); an out-of-scope target
      simply does not resolve.
    * RENDER-THEN-READ: each resolved doc is passed through
      `Envelope.render(doc, schema, caller_context)` and the field is read off
      the REDACTED envelope — never `field_readable?` alone (a caller-less call
      returns true by design; that would be an active bypass). A redacted /
      undeclared-invisible field is simply absent → fallback.
    * `:caller_context` DEFAULTS to the anonymous principal `%CallerContext{}`
      (fail closed). Any palette feeding body_html or broadcast delta frames
      MUST keep that default; Studio may pass its editor's context for its own
      live view only — never into shared caches.
    * FieldCipher `_bpenc` envelopes stay redacted (dropped by the envelope for
      non-admin callers; a map value never stringifies — see below).
    * D5: pass `published_only: true` on any anonymous/public surface so a
      draft-only target does not resolve (the deliberate `drafts.`-twin
      fallback of `Labels.reference_title/4` is NOT copied here — it would
      leak unpublished values into anonymous prose).

  `field` must be a single top-level declared field name — dot-paths and the
  `content.` prefix are rejected at collection time (the Envelope gates
  visibility on the top segment; resolver and gate must agree). Only scalar
  values (binary / number / boolean) resolve; a non-empty string wins, maps/
  lists/nil degrade to the fallback.
  """
  @spec resolve_values_in_blocks(list(), String.t(), keyword()) :: %{
          optional({String.t(), String.t()}) => String.t()
        }
  # @canonical capability:valueref-resolve aka:valueref,live-value,value_resolver doc:docs/contracts/portable-doc-inline.md
  def resolve_values_in_blocks(blocks, dataset \\ @paper_default_dataset, opts \\ [])
      when is_list(blocks) do
    pairs = collect_value_refs(blocks)

    if pairs == [] do
      %{}
    else
      caller = Keyword.get(opts, :caller_context, %CallerContext{})
      published_only = Keyword.get(opts, :published_only, false)
      targets = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      # Each target slug is queried in its published spelling — plus the
      # `drafts.` twin ONLY off the published_only path (the authorized Studio
      # perspective), matching the canonical slug-resolve's twin expansion.
      id_candidates =
        targets
        |> Enum.flat_map(fn t ->
          pub = DraftId.published_id(t)
          if published_only, do: [pub], else: [pub, DraftId.draft_id(pub)]
        end)
        |> Enum.uniq()

      rows =
        Content.resolve_docs_by_ids(
          id_candidates,
          dataset,
          Keyword.put(opts, :caller_context, caller)
        )

      # Envelope-render each resolved target ONCE under the caller's authority
      # (schema memoised per type — `render_many_by_type` precedent) and read
      # every requested field off the REDACTED envelope. NO schema → NO
      # resolution for that target (fail closed): a schema-free render drops
      # only encrypted ciphertext, so rendering without the schema would leak
      # non-encrypted `private`/`owner_only` fields into public prose — and
      # wire §3 requires a DECLARED field anyway.
      {envelopes, _cache} =
        Enum.map_reduce(targets, %{}, fn target, cache ->
          case pick_value_doc(target, rows) do
            nil ->
              {{target, nil}, cache}

            doc ->
              {schema, cache} = value_schema_cached(cache, doc.type, dataset, opts)

              case schema do
                nil -> {{target, nil}, cache}
                schema -> {{target, Envelope.render(doc, schema, caller)}, cache}
              end
          end
        end)

      envelopes = Map.new(envelopes)

      Enum.reduce(pairs, %{}, fn {target, field} = pair, acc ->
        with %{} = env <- Map.get(envelopes, target),
             {:ok, rendered} <- value_to_string(Map.get(env, field)) do
          Map.put(acc, pair, rendered)
        else
          _ -> acc
        end
      end)
    end
  end

  # Deep walk (the ONE shared `BodyWalk` walker): every inline `valueref`'s
  # `(target, field)` pair, distinct, document-ordered. A malformed node
  # (blank/missing field, dot-path, `content.` prefix) is dropped here → it
  # renders its fallback (never an error).
  defp collect_value_refs(blocks) do
    blocks
    |> BodyWalk.collect_nodes(["valueref"])
    |> Enum.flat_map(fn node ->
      target = Map.get(node, "target")
      field = Map.get(node, "field")

      if is_binary(field) and field != "" and not String.contains?(field, ".") do
        [{target, field}]
      else
        []
      end
    end)
    |> Enum.uniq()
  end

  # Published-row preference (D3): the exact published spelling wins; the
  # `drafts.` twin resolves only when no published row matched (and only on
  # the non-published_only path, which is the only one that fetched twins).
  defp pick_value_doc(target, rows) do
    pub = DraftId.published_id(target)
    draft = DraftId.draft_id(pub)

    Enum.find(rows, &(&1.doc_id == pub)) || Enum.find(rows, &(&1.doc_id == draft))
  end

  # Per-type schema memo for the envelope render — the redaction contract
  # NEEDS the schema (only encrypted ciphertext drops schema-free; the caller
  # above skips the target entirely on nil). Lookup order mirrors the desk's
  # include_global semantic: the tenant's own schema first, then the SHARED
  # base layer — a retry without tenant scope that is trusted ONLY when the
  # row is genuinely global (nil workspace); another workspace's same-named
  # schema is never used to gate this tenant's visibility.
  defp value_schema_cached(cache, type, dataset, opts) do
    case Map.fetch(cache, type) do
      {:ok, schema} ->
        {schema, cache}

      :error ->
        schema = value_schema(type, dataset, opts)
        {schema, Map.put(cache, type, schema)}
    end
  end

  # The two-step scoped→global lookup lives in ONE place now:
  # `Content.Schema.get_schema_for_redaction/3` (@canonical
  # capability:schema-resolution-for-redaction).
  defp value_schema(type, dataset, opts) do
    case Content.Schema.get_schema_for_redaction(type, dataset, opts) do
      {:ok, schema} -> schema
      :error -> nil
    end
  end

  # Only scalars resolve; the empty string counts as UNRESOLVED (the Go
  # ValueResolver's `"" = unresolved` convention — keeps all three surfaces
  # agreeing that a blank canonical value shows the fallback, never a blank).
  # Maps (incl. a FieldCipher `_bpenc` envelope that survived an admin render)
  # and lists never stringify — fallback.
  defp value_to_string(v) when is_binary(v) and v != "", do: {:ok, v}
  defp value_to_string(v) when is_number(v) or is_boolean(v), do: {:ok, to_string(v)}
  defp value_to_string(_), do: :error

  @doc """
  ACCEPT-BASELINE (lvw-t2, wire §8, D4 ratified): re-pin a DRIFTED valueref's
  `fallback` literal to the value it currently resolves to — the sanctioned
  path for "the canonical value legitimately changed; adopt it as the new
  baseline" (without it, every legitimate canonical change permanently flags
  every mention).

  The rewrite touches ONLY the pinned literal: every valueref node in the
  hosting paper matching `(target, field)` whose pinned `fallback` equals
  `fallback` gets `fallback` set to the resolved value — plus its D6
  dual-written text child re-synced to match (old renderers show the child;
  it must track the new baseline). Nothing else on the node (`as`/`label`
  round-trip untouched) and nothing on the canonical TARGET is written —
  edit-through is lvw-t10, not this.

  Mechanics — never hand-rolled writes:

    * Drift is re-checked server-side against the SAME pre-resolve pass the
      view rendered from (`resolve_values_in_blocks/3` under the caller's
      `opts`); a stale click degrades to `{:error, :not_drifted}` /
      `{:error, :dangling}` (dangling = unresolvable ⇒ drift uncomputable ⇒
      nothing to accept).
    * The rewrite lands as `patch-block` ops through the atomic
      `apply_paper_block_ops/4` — patch-block shallow-merges per key, so each
      affected block resends its WHOLE changed key (`content` / `children` /
      `items` array) — with the caller's `:if_rev` enforced by that path's
      CAS (`{:error, :precondition_failed}` on a rev race; the Studio caller
      surfaces it as retry-able).
    * Provenance: the batch write records a revision with action
      `"valueref-accept-baseline"` and the caller's `:actor_user_id`, so
      history shows WHO accepted WHAT baseline (D4: the CAS already ships; no
      parallel ack store).

  AUTHORIZATION is write access to the HOSTING paper (this mutates the
  paper's own pinned literal, never the canonical target): the load + apply
  run under the caller's `opts` scope exactly like every other paper block
  op.
  """
  @spec accept_valueref_baseline(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def accept_valueref_baseline(
        slug,
        target,
        field,
        fallback,
        dataset \\ @paper_default_dataset,
        opts \\ []
      )
      when is_binary(slug) and is_binary(target) and is_binary(field) and is_binary(fallback) do
    case get_paper(slug, dataset, opts) do
      nil ->
        {:error, :not_found}

      %Document{} = doc ->
        blocks = get_in(doc.content || %{}, ["blocks"]) || []
        values = resolve_values_in_blocks(blocks, dataset, opts)

        case Map.get(values, {target, field}) do
          nil ->
            {:error, :dangling}

          resolved when resolved == fallback or fallback == "" ->
            # Not drifted: the pin already matches — or nothing is pinned
            # (fallback ""), in which case there is no baseline to accept.
            {:error, :not_drifted}

          resolved when is_binary(resolved) ->
            case accept_baseline_ops(blocks, target, field, fallback, resolved) do
              [] ->
                # The paper changed under the view: no addressable node still
                # carries that pinned literal. Same retry-able treatment as a
                # rev race.
                {:error, :precondition_failed}

              ops ->
                BlockOps.apply_paper_block_ops(
                  slug,
                  ops,
                  dataset,
                  Keyword.put(opts, :revision_action, "valueref-accept-baseline")
                )
            end
        end
    end
  end

  # One patch-block op per TOP-LEVEL block whose subtree carries a matching
  # drifted valueref — the patch resends every changed top-level key whole
  # (patch-block shallow-merges per key; `id`/`type` stay immutable and
  # untouched). Id-less blocks cannot be addressed by patch-block and are
  # skipped (they only occur on legacy hand-ingested papers; the op appliers
  # mint ids on every write since ensure_block_ids).
  defp accept_baseline_ops(blocks, target, field, fallback, resolved) do
    Enum.flat_map(blocks, fn block ->
      id = is_map(block) && Map.get(block, "id")
      updated = rewrite_valueref_fallback(block, target, field, fallback, resolved)

      if updated == block or not is_binary(id) or id == "" do
        []
      else
        patch =
          updated
          |> Enum.filter(fn {k, v} -> Map.get(block, k) != v end)
          |> Map.new()

        [%{"op" => "patch-block", "id" => id, "patch" => patch}]
      end
    end)
  end

  # Deep rewrite (mirrors BodyWalk's descend shape): a valueref node matching
  # (target, field, pinned-fallback) gets its `fallback` re-pinned to
  # `resolved` and its D6 dual-written text child re-synced; everything else
  # passes through structurally unchanged. A matched node is NOT descended
  # into — its children are the D6 fallback subtree being replaced. The
  # stored form is always the NODE form (the editor's save path rebuilds
  # nodes from leaf marks), so the transient mark form needs no arm here.
  defp rewrite_valueref_fallback(
         %{"type" => "valueref"} = node,
         target,
         field,
         fallback,
         resolved
       ) do
    if Map.get(node, "target") == target and Map.get(node, "field") == field and
         pinned_fallback(node) == fallback do
      node
      |> Map.put("fallback", resolved)
      |> sync_d6_fallback_child(resolved)
    else
      node
    end
  end

  defp rewrite_valueref_fallback(node, target, field, fallback, resolved)
       when is_map(node) and not is_struct(node) do
    Map.new(node, fn {k, v} ->
      {k, rewrite_valueref_fallback(v, target, field, fallback, resolved)}
    end)
  end

  defp rewrite_valueref_fallback(list, target, field, fallback, resolved) when is_list(list) do
    Enum.map(list, &rewrite_valueref_fallback(&1, target, field, fallback, resolved))
  end

  defp rewrite_valueref_fallback(other, _target, _field, _fallback, _resolved), do: other

  # The node's pinned literal, normalized EXACTLY like the walker's
  # `valueref_fallback/1` (render/walk.ex) — the two must agree or the accept
  # click (which carries the walker's normalization) misses the stored node.
  defp pinned_fallback(node) do
    case Map.get(node, "fallback") do
      f when is_binary(f) -> f
      f when is_number(f) -> to_string(f)
      _ -> ""
    end
  end

  # D6: authoring dual-writes the fallback as a `{type:"text", value:<fb>}`
  # child so old renderers degrade to visible text. When the child subtree is
  # present it must track the NEW baseline (old binaries would otherwise keep
  # showing the stale literal); when absent it stays absent.
  defp sync_d6_fallback_child(node, resolved) do
    case Map.get(node, "children") do
      children when is_list(children) and children != [] ->
        Map.put(node, "children", [%{"type" => "text", "value" => resolved}])

      _ ->
        node
    end
  end

  @doc """
  Resolve every query-carrying task block in `blocks` into a snapshot-carrying
  one — the entry point that makes a paper show LIVE `bp` tasks. Thin: it hands
  `Barkpark.PortableDoc.TaskResolver.resolve/2` a fetcher that runs each block's
  `query` against the task substrate under `scope` (`[workspace_id:,
  project_id:]`, fail-closed). Call it in the render path, and re-call it on a
  `task.*` mutation event to refresh a live plan. Returns the transformed
  blocks (unlike the embeds resolver's target→html map — task blocks carry
  their own snapshot, so the transform is in-place).
  """
  @spec resolve_tasks_in_blocks(list(), keyword(), String.t()) :: list()
  def resolve_tasks_in_blocks(blocks, scope, dataset \\ @paper_default_dataset)

  def resolve_tasks_in_blocks(blocks, scope, dataset) when is_list(blocks) do
    # Thread the RESOLVING dataset so the aggregate's field-visibility
    # cross-check loads the task schema under the same dataset+tenancy the rows
    # come from. The schema is loaded lazily inside `agg_for_query` and ONLY for
    # a non-count (sum/avg/min/max) block, so a count-only / rows-only paper pays
    # no schema query.
    Barkpark.PortableDoc.TaskResolver.resolve(
      blocks,
      fn query ->
        query
        |> task_query_dataset(dataset)
        |> Barkpark.Tasks.Query.rows_for_query(scope, dataset: dataset)
      end,
      fn query ->
        query
        |> task_query_dataset(dataset)
        |> Barkpark.Tasks.Query.agg_for_query(scope, dataset: dataset)
      end
    )
  end

  def resolve_tasks_in_blocks(blocks, _scope, _dataset), do: blocks

  # A reader's dataset is the implicit task-query dataset. Explicit authoring
  # stays authoritative: row queries keep a top-level `dataset`, while
  # aggregate queries keep `filter.dataset`. Stamping both harmlessly lets the
  # two closed query shapes share one fail-closed defaulting seam.
  defp task_query_dataset(query, dataset) when is_map(query) and is_binary(dataset) do
    query
    |> Map.put_new("dataset", dataset)
    |> Map.update("filter", %{"dataset" => dataset}, fn
      filter when is_map(filter) -> Map.put_new(filter, "dataset", dataset)
      other -> other
    end)
  end

  defp task_query_dataset(query, _dataset), do: query

  @doc """
  Pre-resolve every note-embed (`![[note]]`) target in a block list into the
  render-opts map `%{raw_target => prerendered_html_string}` that
  `Render.render_html/2` threads onto the palette (so `walk/3`'s `embed/2`
  INJECTS the transcluded note's HTML for resolved targets).

  Mirrors `resolve_wikilinks_in_blocks/3` exactly: deep-walks `blocks` to
  collect every distinct `target` from a top-level `"type" => "embed"` BLOCK
  (not an inline wikilink/blockref), resolves each ONCE via the SAME
  title-or-alias authority wikilinks use, fetches that target paper's full
  blocks, and RENDERS them to a single HTML string. Unresolved (or render-
  failing) targets are simply absent from the map — the walker then shows the
  broken-embed fallback for them.

  ## One-level + cycle safety

  Each target paper is rendered with render opts `:embeds = %{}` (EMPTY), so any
  NESTED embed inside a transcluded note degrades to the unresolved fallback
  instead of recursing. This bounds transclusion depth to ONE level and makes an
  `A → B → A` cycle impossible by construction (B is rendered with no embed map,
  so B's embed of A is a fallback, never a re-render of A).

  ## Render mode

  Targets render in `:article` mode (`style: :article`) — the SAME mode the
  Studio view-mode host uses in `paper_stream_items/3` — so a transcluded note
  reads with the same article typography as the host page. Width is left to the
  palette default (the host's per-block width is not threaded here for v1; the
  article palette's default width is used). A single unresolvable or oversized
  target cannot crash the whole map: each per-target render is wrapped in a
  rescue and a failure simply drops that target (it falls back like a miss).

  ## Resolution narrowing (v1)

  A transcluded note is rendered with ONLY `style: :article` + `embeds: %{}` —
  the host's `:wikilinks`, `:ref_resolver`, and `:codelist_resolver` closures are
  NOT threaded into it. So inside an embed, a wikilink degrades to its dotted
  span, and field-reference / codelist labels fall back to raw values. The host
  page itself still resolves all of these; only the *transcluded* content is
  narrowed. Threading those resolvers (each with `embeds: %{}`) so an embedded
  note's links stay live is the planned follow-up.
  """
  @spec resolve_embeds_in_blocks(list(), String.t(), keyword()) :: %{
          optional(String.t()) => String.t()
        }
  def resolve_embeds_in_blocks(blocks, dataset \\ @paper_default_dataset, opts \\ [])
      when is_list(blocks) do
    blocks
    |> collect_embed_targets()
    |> Enum.reduce(%{}, fn target, acc ->
      case render_embed_target(target, dataset, opts) do
        nil -> acc
        html -> Map.put(acc, target, html)
      end
    end)
  end

  # Resolve ONE embed target (a human title / alias) to its transcluded HTML, or
  # nil when it does not resolve / has no blocks / fails to render. Resolution
  # reuses `resolve_wikilink/3`'s title-or-alias authority (via the shared
  # `resolve_doc_by_title_or_alias`) so an embed target resolves IDENTICALLY to a
  # wikilink target. The resolved paper's `content["blocks"]` is rendered to a
  # single HTML string with `:embeds = %{}` (one-level + cycle-proof — see the
  # public doc). Per-target rescue: a single bad target cannot crash the map.
  defp render_embed_target(target, dataset, opts) do
    with trimmed when trimmed != "" <- String.trim(target),
         %Document{content: %{"blocks" => blocks}} when is_list(blocks) <-
           Content.resolve_doc_by_title_or_alias(trimmed, @paper_type, dataset, opts) do
      # `:embeds = %{}` bounds depth to one level (a nested embed in the target
      # falls back rather than recursing) — an A→B→A cycle is impossible here.
      Render.render_blocks(blocks, %{style: :article, embeds: %{}})
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Deep walk (via the ONE shared `BodyWalk` walker — wire §7.3): collect the
  # `target` of every note-embed BLOCK (`"type" => "embed"`). The host stores
  # embeds as TOP-LEVEL blocks (authoring is deferred to the continuous-canvas
  # phase), but the deep walk finds a future nested embed block too. Distinct
  # from `collect_link_targets/1`, which matches the INLINE wikilink/blockref
  # node. Distinct, document-ordered.
  defp collect_embed_targets(blocks) do
    blocks
    |> BodyWalk.collect_nodes(["embed"])
    |> Enum.map(&Map.get(&1, "target"))
    |> Enum.uniq()
  end

  @doc """
  Resolve a paper for the PUBLIC, unauthenticated `/papers/:slug` surface.

  Papers are stamped `workspace_id` on write and slugs are PER-WORKSPACE (the
  Wave-2 uniqueness flip lifted the old global `(doc_id, type, dataset)` unique
  index to a per-workspace `(doc_id, type, dataset_id)` one, so two workspaces
  may each own a paper with the same slug). A bare `get_paper(slug)` runs as an
  EXPLICIT global read (`get_document` routes the nil workspace through
  `scope_to_workspace_or_global/3`) — so `Repo.one` resolves over EVERY tenant's
  rows. That is the cross-workspace read leak: any visitor could read any
  workspace's paper by slug, and on a same-slug collision the resolved row was
  non-deterministic (barkpark-w9dg, P0).

  The public paper surface is intentionally the seeded **Default** workspace —
  that is where the flat, unauthenticated paper ingest lands by Default
  fallback (`upsert_paper`'s scope contract), so it is the one deterministic
  public tenant. This function resolves the Default workspace id and scopes the
  read to it, so:

    * a paper in ANY non-Default workspace is NEVER exposed here, and
    * a slug resolves to AT MOST ONE row (the Default-workspace paper), never
      "whatever row matched across all tenants."

  Fail-closed (aligns with the s6t1 nil-scope direction): if the Default
  workspace is not seeded, there IS no public tenant — we return `nil` rather
  than fall back to an unscoped read. We never rely on an explicit-global read
  for a public request.

  Returns the `%Document{}` or `nil`.
  """
  def get_public_paper(slug, dataset \\ @paper_default_dataset) when is_binary(slug) do
    get_public_document(@paper_type, slug, dataset)
  end

  @doc """
  Resolve a document of `type` by `slug` for a PUBLIC, unauthenticated surface.

  This is `get_public_paper/2` generalized over the document type: identical
  workspace/tenant scoping, identical nil-handling, identical return shape — it
  simply filters on the passed `type` instead of the hardcoded `"paper"`.

  As with `get_public_paper/2`, the read is pinned to the seeded **Default**
  (public) workspace so a same-slug document in any non-Default workspace is
  NEVER exposed, and a slug resolves to AT MOST ONE row (barkpark-w9dg). Fails
  closed: if no Default workspace is seeded there is no public tenant, so it
  returns `nil` rather than fall back to an unscoped read.

  **Published perspective, unconditionally.** `slug` is a raw caller-supplied
  doc_id, so a `drafts.`-prefixed id addresses the draft row directly; the
  resolve is clamped with `published_only: true` so an unpublished row is
  invisible on every public surface regardless of how it is spelled. See
  `BarkparkWeb.Integration.PublicReaderDraftsIdLeakTest`.

  Returns the `%Document{}` or `nil`.
  """
  def get_public_document(type, slug, dataset \\ @paper_default_dataset)
      when is_binary(type) and is_binary(slug) do
    case get_public_document_with_workspace(type, slug, dataset) do
      {doc, _workspace} -> doc
      nil -> nil
    end
  end

  @doc """
  `get_public_document/3` that ALSO returns the resolved Default `%Workspace{}`
  — `{doc, workspace}` or `nil`. The am-w1-s3 reader dedupe seam: the public
  reader needs the workspace row again after the read (theme identity), and
  re-fetching what this resolve already loaded was a measured per-mount
  statement. Same pinned-Default scoping, same fail-closed posture.
  """
  def get_public_document_with_workspace(type, slug, dataset \\ @paper_default_dataset)
      when is_binary(type) and is_binary(slug) do
    case Barkpark.Tenancy.get_default_workspace() do
      %{id: ws_id} = workspace when is_binary(ws_id) ->
        # Typeless batched read + type pick, NOT `get_document/4`: the typed
        # read pays an `owner_scoped?` schema round-trip on every call, pure
        # overhead on this public pinned-tenant resolve (am-w1-s3). The scoping
        # stack is the documented typeless-read precedent
        # (`Query.resolve_docs_by_ids/3` — dataset + workspace_or_global +
        # unconditional `scope_to_owner(nil)`, byte-identical for
        # non-owner_scoped types whose rows carry a NULL `owner_id`, and the
        # same unowned-rows-only posture `get_document/4` reaches for an
        # anonymous caller when the type IS owner-scoped). The list return
        # makes the type pick exact — a same-slug document of another type can
        # never shadow the requested one.
        #
        # `published_only: true` is HARD-CODED, not an opt: this resolver serves
        # ONLY anonymous public surfaces (every caller is a `get_public_*` entry
        # point), and leaving the perspective opt-in is exactly what opened the
        # leak. `slug` is a caller-supplied doc_id, so the bare spelling AND the
        # `drafts.` spelling are both addressable here; the clamp's prefix
        # conjunct (`Query.maybe_published_only/2`) is what makes
        # `GET /papers/drafts.<slug>` a 404 instead of the unpublished body.
        # Anything that legitimately reads a draft (the Studio, an authorized
        # scope) goes through `get_paper/3` / `get_document/4`, never here.
        doc =
          [slug]
          |> Content.resolve_docs_by_ids(dataset, workspace_id: ws_id, published_only: true)
          |> Enum.find(&(&1.type == type))

        doc && {doc, workspace}

      _ ->
        nil
    end
  end

  @doc """
  `get_public_paper/2` that also returns the resolved Default `%Workspace{}` —
  see `get_public_document_with_workspace/3`.
  """
  def get_public_paper_with_workspace(slug, dataset \\ @paper_default_dataset)
      when is_binary(slug) do
    get_public_document_with_workspace(@paper_type, slug, dataset)
  end

  @doc """
  The paper's block list, or `nil` for an HTML-only (legacy) paper.
  """
  def paper_blocks(slug, dataset \\ @paper_default_dataset) when is_binary(slug) do
    case get_paper(slug, dataset) do
      nil -> nil
      doc -> get_in(doc.content || %{}, ["blocks"])
    end
  end

  @doc """
  Resolve the block list for editing a document — the stored
  `content["blocks"]` when present, else a LAZILY SYNTHESIZED in-memory list
  (Exp-P2, step 2.5) built from the schema's Expectation layout + the doc's
  existing `content[fieldName]` values + body.

  Returns `{blocks, synthesized?}`. When `synthesized?` is `true` the list was
  built in memory and the stored row is UNTOUCHED — nothing is persisted until
  the first op lands (the caller's first `apply_paper_block_op`/`upsert_paper`
  write persists it). When `false`, `content["blocks"]` already existed and is
  returned verbatim.

  The synthesis round-trip is byte-equal: feeding the synthesized blocks back
  through `Projection.project/3` reproduces the original `content[fieldName]`
  values exactly (see `Barkpark.PortableDoc.Synthesis`).
  """
  @spec resolve_blocks_for_edit(map() | nil, String.t(), String.t()) :: {[map()], boolean()}
  def resolve_blocks_for_edit(nil, _type, _dataset), do: {[], false}

  def resolve_blocks_for_edit(%Document{} = doc, type, dataset) do
    content = doc.content || %{}

    case Map.get(content, "blocks") do
      blocks when is_list(blocks) ->
        {blocks, false}

      _ ->
        {synthesize_blocks(doc, type, dataset), true}
    end
  end

  # Build the in-memory synthesized block list: resolve the Expectation layout
  # for the doc's schema, fold the row `title` into the content map under
  # "title" (so a bound title block picks it up — `title` lives on the row, not
  # under content), and delegate to the pure Synthesis module.
  defp synthesize_blocks(%Document{} = doc, type, dataset) do
    {layout, fields} =
      case Content.get_schema(type, dataset) do
        {:ok, schema} -> {Content.resolve_expectation(schema).layout, schema.fields || []}
        _ -> {SchemaDefinition.default_layout(%{}), []}
      end

    content_with_title = Map.put(doc.content || %{}, "title", doc.title)
    Synthesis.synthesize(layout, content_with_title, fields)
  end

  # ── EX1 — Expectation-aware slash menu (barkpark-q39y) ────────────────────
  #
  # An Expectation layout's `field` entries carry optional CARDINALITY:
  # `"max"` (integer cap, nil/absent = unlimited) and `"enforce"` (boolean,
  # default false — see SchemaDefinition layout doc). These two pure helpers
  # let the slash menu reason about which expected fields are STILL
  # recommendable for a given document, and whether a HARD cap blocks a 2nd
  # insert.

  @doc """
  The expected fields that are STILL recommendable for a document's block list.

  Given a document's `blocks` list and the resolved Expectation (`%{layout:,
  prefill:}` from `resolve_expectation/1`) plus the schema (for per-field type
  and human label), returns the layout `field` entries whose current bound-block
  count is BELOW their `max` cap — i.e. `count < max`, or always when `max` is
  nil/absent (unlimited). Fields at or over `max` are EXCLUDED (hide-at-cap),
  regardless of `enforce`.

  Each returned entry is a map the slash menu can render + insert:

      %{
        name:    "title",          # the layout field name
        type:    "field-string",   # the bound block's type (schema-type → block-type)
        label:   "Title",          # the schema field's human title (falls back to name)
        count:   0,                # bound blocks in `blocks` with fieldName == name
        max:     1,                # the layout entry's cap (nil = unlimited)
        enforce: true              # the layout entry's hard/soft flag
      }

  Region entries are ignored (they carry no cardinality). A `field` entry whose
  `name` is missing/blank is skipped. Pure: no Repo access.
  """
  @spec available_expected_fields([map()], %{
          required(:layout) => [map()],
          optional(:prefill) => map()
        }) :: [map()]
  @spec available_expected_fields(
          [map()],
          %{
            required(:layout) => [map()],
            optional(:prefill) => map()
          },
          SchemaDefinition.t() | map() | nil
        ) :: [map()]
  def available_expected_fields(blocks, expectation, schema \\ nil)

  def available_expected_fields(blocks, expectation, schema),
    do: blocks |> all_expected_fields(expectation, schema) |> Enum.reject(&field_at_cap?/1)

  @doc """
  EVERY expected `field` descriptor for a document's block list — the unfiltered
  sibling of `available_expected_fields/3`. Runs the identical pipeline but OMITS
  the trailing hide-at-cap reject, so the returned list includes bound-and-at-cap
  fields. Each entry is the full `%{name, type, label, count, max, enforce}` map;
  the Properties panel derives its `count/max` badge and at-cap styling from it.
  Pure: no Repo access.
  """
  def all_expected_fields(blocks, expectation, schema \\ nil)

  def all_expected_fields(blocks, %{layout: layout}, schema)
      when is_list(blocks) and is_list(layout) do
    type_by_name = expected_field_type_index(schema)
    label_by_name = expected_field_label_index(schema)

    layout
    |> Enum.filter(&match?(%{"kind" => "field"}, &1))
    |> Enum.map(&expected_field_descriptor(&1, blocks, type_by_name, label_by_name))
    |> Enum.reject(&is_nil/1)
  end

  def all_expected_fields(_blocks, _expectation, _schema), do: []

  @doc """
  True when a HARD cap blocks inserting another bound block for `field_name`.

  Blocks the insert when the field's current bound-block count is at or over its
  `max` AND the layout entry is `enforce: true`. A SOFT cap (`enforce: false`)
  returns `false` even at the cap — the slash menu hides the field there, but a
  programmatic insert is still allowed. Unlimited (`max` nil/absent) is never
  blocked. An unknown `field_name` (no matching layout `field` entry) is never
  blocked. Pure: no Repo access.
  """
  @spec expected_field_blocked?([map()], %{required(:layout) => [map()]}, String.t()) ::
          boolean()
  def expected_field_blocked?(blocks, %{layout: layout}, field_name)
      when is_list(blocks) and is_list(layout) and is_binary(field_name) do
    case Enum.find(layout, &match?(%{"kind" => "field", "name" => ^field_name}, &1)) do
      nil ->
        false

      entry ->
        max = layout_entry_max(entry)
        enforce = layout_entry_enforce(entry)
        count = bound_field_count(blocks, field_name)

        enforce and is_integer(max) and count >= max
    end
  end

  def expected_field_blocked?(_blocks, _expectation, _field_name), do: false

  # One slash-menu descriptor for a layout `field` entry (or nil when the entry
  # has no usable string name). Cap filtering happens in the caller.
  defp expected_field_descriptor(entry, blocks, type_by_name, label_by_name) do
    case Map.get(entry, "name") do
      name when is_binary(name) and name != "" ->
        field_type = Map.get(type_by_name, name)

        %{
          name: name,
          type: Synthesis.field_block_type(field_type),
          label: Map.get(label_by_name, name) || name,
          count: bound_field_count(blocks, name),
          max: layout_entry_max(entry),
          enforce: layout_entry_enforce(entry)
        }

      _ ->
        nil
    end
  end

  # A descriptor is at-cap (excluded from the available list) when it has an
  # integer max and the current count has reached it. nil max = unlimited =
  # never at cap. enforce is irrelevant to hide-at-cap — both soft and hard
  # caps hide the field once full.
  defp field_at_cap?(%{count: count, max: max}) when is_integer(max), do: count >= max
  defp field_at_cap?(_), do: false

  # Number of BOUND blocks (fieldName == name) for a field, top-level only —
  # bound blocks are never nested (Projection bound?/1 reads top-level
  # fieldName). Matches Projection's bound-field semantics.
  defp bound_field_count(blocks, name) do
    Enum.count(blocks, fn b -> is_map(b) and Map.get(b, "fieldName") == name end)
  end

  # The layout entry's max cap: an integer, or nil for unlimited (absent or any
  # non-integer value — e.g. an explicit JSON null — is treated as unlimited).
  defp layout_entry_max(entry) do
    case Map.get(entry, "max") do
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  # The layout entry's enforce flag: only an explicit boolean `true` enforces;
  # absent/any other value is soft (false).
  defp layout_entry_enforce(%{"enforce" => true}), do: true
  defp layout_entry_enforce(_), do: false

  # field name → declared schema type, for picking each field's block type.
  defp expected_field_type_index(%SchemaDefinition{fields: fields}) when is_list(fields),
    do: expected_field_type_index(fields)

  defp expected_field_type_index(%{fields: fields}) when is_list(fields),
    do: expected_field_type_index(fields)

  defp expected_field_type_index(fields) when is_list(fields) do
    Enum.reduce(fields, %{}, fn f, acc ->
      name = f["name"] || f[:name]
      type = f["type"] || f[:type]
      if is_binary(name), do: Map.put(acc, name, type), else: acc
    end)
  end

  defp expected_field_type_index(_), do: %{}

  # field name → human title (label), for the slash-menu label.
  defp expected_field_label_index(%SchemaDefinition{fields: fields}) when is_list(fields),
    do: expected_field_label_index(fields)

  defp expected_field_label_index(%{fields: fields}) when is_list(fields),
    do: expected_field_label_index(fields)

  defp expected_field_label_index(fields) when is_list(fields) do
    Enum.reduce(fields, %{}, fn f, acc ->
      name = f["name"] || f[:name]
      title = f["title"] || f[:title]
      if is_binary(name) and is_binary(title), do: Map.put(acc, name, title), else: acc
    end)
  end

  defp expected_field_label_index(_), do: %{}

  # ── Block-ops / write path — delegated to Barkpark.Content.Papers.BlockOps ──
  #
  # The four public write functions live in the sibling `BlockOps` module (the
  # god-module decomposition). These delegations keep this module's public API
  # byte-identical — same names, arities, and default args — so every external
  # caller (and the `Barkpark.Content` facade) is unchanged.

  @doc """
  Upsert a paper keyed by `{dataset, slug}` (as a type-"paper" document) and
  broadcast a **whole-HTML** frame on the per-doc topic. Runs the publish
  wall by default (charter D26); `opts` accepts the audited `bypass_wall:
  true` escape. See `Barkpark.Content.Papers.BlockOps.upsert_paper/2`.
  """
  defdelegate upsert_paper(attrs, opts \\ []), to: BlockOps

  @doc """
  Upsert a blocks-doc keyed by `{dataset, slug}` for any type in the
  `blocks_types/0` whitelist (`upsert_paper/2` generalized off the hardcoded
  `"paper"` type — session-handoff Task 2). See
  `Barkpark.Content.Papers.BlockOps.upsert_blocks_doc/3`.
  """
  defdelegate upsert_blocks_doc(type, attrs, opts \\ []), to: BlockOps

  @doc """
  Apply a single portable-doc `op` (a DocPatchOp map) to a paper's block list,
  persist + broadcast a **delta** frame. See
  `Barkpark.Content.Papers.BlockOps.apply_paper_block_op/4`.
  """
  defdelegate apply_paper_block_op(slug, op, dataset \\ @paper_default_dataset, opts \\ []),
    to: BlockOps

  @doc """
  Apply a LIST of portable-doc ops to a paper's block list **atomically** — the
  batch twin of `apply_paper_block_op/4`. See
  `Barkpark.Content.Papers.BlockOps.apply_paper_block_ops/4`.
  """
  defdelegate apply_paper_block_ops(slug, ops, dataset \\ @paper_default_dataset, opts \\ []),
    to: BlockOps

  @doc """
  Apply a single portable-doc `op` to ANY Expectation-bearing document's block
  list (Exp-P3.2 — the generalization off the hardcoded `"paper"` type). See
  `Barkpark.Content.Papers.BlockOps.apply_document_block_op/5`.
  """
  defdelegate apply_document_block_op(doc_id, type, op, dataset, opts \\ []), to: BlockOps

  defdelegate apply_document_block_op_once(
                doc_id,
                type,
                op,
                dataset,
                request_id,
                principal_key,
                opts \\ []
              ),
              to: BlockOps

  @doc "Field-scoped block ops — `Barkpark.Content.Papers.BlockOps.apply_field_block_ops/6`."
  defdelegate apply_field_block_ops(doc_id, type, field, ops, dataset, opts \\ []), to: BlockOps

  @doc "The block array behind a field value — `Barkpark.Content.Papers.BlockOps.field_blocks/1`."
  defdelegate field_blocks(value), to: BlockOps

  @doc """
  The AI-proposes loop (lvw-t4): apply INSERT-ONLY block ops to the paper's
  `drafts.` twin with mandatory provenance (a `proposal-source` edge + a
  `content["proposals"]` sidecar), never touching the published row. See
  `Barkpark.Content.Papers.Proposals.propose_paper_blocks/5`.
  """
  defdelegate propose_paper_blocks(
                slug,
                ops,
                source,
                dataset \\ @paper_default_dataset,
                opts \\ []
              ),
              to: Barkpark.Content.Papers.Proposals
end
