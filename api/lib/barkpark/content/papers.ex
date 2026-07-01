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
  alias Barkpark.Content.{Broadcast, Document, SchemaDefinition}
  alias Barkpark.Content.Papers.BlockOps
  alias Barkpark.PortableDoc.BodyWalk
  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Synthesis

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
  Resolve a wikilink `target` (a human title or alias) to the linked paper.

  Returns `%{id, title}` for the single best match (title beats alias on a
  collision; see `Content.Query.resolve_doc_by_title_or_alias/4`), or `nil`
  when nothing matches or `target` is blank. Pinned to `type:"paper"` — papers
  are the wikilink corpus.

  This is the AUTHORITY that turns ANY stored `target` string (typed or picked
  by the `[[` autocomplete) into a link. Resolution is RENDER-TIME and
  scope-bound: `opts` may carry `:workspace_id` / `:project_id`, mirroring
  `get_paper/3`. The stored node keeps the raw `target`; the resolved id appears
  only in emitted HTML.
  """
  @spec resolve_wikilink(String.t(), String.t(), keyword()) ::
          %{id: String.t(), title: String.t()} | nil
  def resolve_wikilink(target, dataset \\ @paper_default_dataset, opts \\ [])
      when is_binary(target) do
    case String.trim(target) do
      "" ->
        nil

      trimmed ->
        case Content.resolve_doc_by_title_or_alias(trimmed, @paper_type, dataset, opts) do
          %Document{doc_id: id, title: title} -> %{id: id, title: title}
          nil -> nil
        end
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
  `%{raw_target => %{id, title}}` that `Render.render_html/2` threads onto the
  palette (so `walk/3` emits a navigable `<a>` for resolved targets).

  Collects every distinct `target` from any inline `wikilink` node anywhere in
  `blocks` (deep walk — paragraph content, list items, nested marks), resolves
  each ONCE via `resolve_wikilink/3`, and keeps only the hits. Unresolved
  targets are simply absent (they degrade to the dotted broken-link span).
  """
  @spec resolve_wikilinks_in_blocks(list(), String.t(), keyword()) :: %{
          optional(String.t()) => %{id: String.t(), title: String.t()}
        }
  def resolve_wikilinks_in_blocks(blocks, dataset \\ @paper_default_dataset, opts \\ [])
      when is_list(blocks) do
    blocks
    |> collect_link_targets()
    |> Enum.reduce(%{}, fn target, acc ->
      case resolve_wikilink(target, dataset, opts) do
        nil -> acc
        hit -> Map.put(acc, target, hit)
      end
    end)
  end

  # Deep walk (via the ONE shared `BodyWalk` walker — wire §7.3): collect the
  # `target` of every internal-link inline node. BOTH `wikilink` and `blockref`
  # resolve their `target` by title/alias (a blockref adds an `anchor` for the
  # in-doc block, but the doc itself resolves the same way), so they share one
  # resolution map. Distinct, document-ordered.
  defp collect_link_targets(blocks) do
    blocks
    |> BodyWalk.collect_nodes(["wikilink", "blockref"])
    |> Enum.map(&Map.get(&1, "target"))
    |> Enum.uniq()
  end

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

  Returns the `%Document{}` or `nil`.
  """
  def get_public_document(type, slug, dataset \\ @paper_default_dataset)
      when is_binary(type) and is_binary(slug) do
    case Barkpark.Tenancy.get_default_workspace() do
      %{id: ws_id} when is_binary(ws_id) ->
        case Content.get_document(slug, type, dataset, workspace_id: ws_id) do
          {:ok, doc} -> doc
          {:error, :not_found} -> nil
        end

      _ ->
        nil
    end
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
  broadcast a **whole-HTML** frame on the per-doc topic. See
  `Barkpark.Content.Papers.BlockOps.upsert_paper/1`.
  """
  defdelegate upsert_paper(attrs), to: BlockOps

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
end
