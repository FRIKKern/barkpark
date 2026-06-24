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

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.{Broadcast, Document, DraftId, Labels, SchemaDefinition, Sheets}
  alias Barkpark.PortableDoc.{Patch, Projection, Render, Synthesis}

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
    |> collect_link_targets([])
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn target, acc ->
      case resolve_wikilink(target, dataset, opts) do
        nil -> acc
        hit -> Map.put(acc, target, hit)
      end
    end)
  end

  # Deep walk: collect the `target` of every internal-link inline node. BOTH
  # `wikilink` and `blockref` resolve their `target` by title/alias (a blockref
  # adds an `anchor` for the in-doc block, but the doc itself resolves the same
  # way), so they share one resolution map. Recurses arbitrarily-nested structure
  # (marks carry `children`; list items are nested lists). Pure over maps + lists.
  defp collect_link_targets(%{"type" => type, "target" => t} = node, acc)
       when type in ["wikilink", "blockref"] and is_binary(t) and t != "" do
    Enum.reduce(Map.values(node), [t | acc], &collect_link_targets/2)
  end

  defp collect_link_targets(node, acc) when is_map(node),
    do: Enum.reduce(Map.values(node), acc, &collect_link_targets/2)

  defp collect_link_targets(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_link_targets/2)

  defp collect_link_targets(_other, acc), do: acc

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

  @doc """
  Upsert a paper keyed by `{dataset, slug}` (as a type-"paper" document) and
  broadcast a **whole-HTML** frame on the per-doc topic.

  `attrs` accepts string or atom keys: `slug` (required), and either
  `body_html` OR `blocks`. When `blocks` is given, `body_html` is (re)rendered
  from it as the derived cache. Optionally `dataset`, `source_doc`, `goal_id`,
  `event_type`. The monotonic integer streaming rev (`content["rev"]`) is
  bumped on every write.

  On success, broadcasts `{:paper_updated, %{slug, dataset, html, rev, …}}` to
  `paper_topic(slug, dataset)` and returns `{:ok, %Document{}}`. Returns
  `{:error, changeset}` on validation/constraint failure.
  """
  def upsert_paper(attrs) when is_map(attrs) do
    attrs = normalize_paper_attrs(attrs)
    slug = attrs["slug"]
    dataset = attrs["dataset"] || @paper_default_dataset

    # The pre-write lookup MUST be scoped to THIS write's tenant, not unscoped.
    # An unscoped `get_paper(slug, dataset)` resolves the slug across EVERY
    # workspace (slugs are per-workspace), so a same-slug write in workspace B
    # would find workspace A's row and UPDATE it — re-stamping A's row with B's
    # scope and hijacking A's paper. Scoping the lookup to the write's resolved
    # workspace keeps the two papers DISTINCT, matching the per-workspace
    # uniqueness the Wave-2 index flip established (barkpark-w9dg). The scope is
    # the explicit one in attrs, else the seeded Default — identical to the
    # write-stamp fallback below, so the lookup sees exactly the row the write
    # would update.
    existing = slug && get_existing_paper_for_write(slug, dataset, attrs)

    # Tenancy scope for the row stamp, resolved BEFORE the content build so
    # the sheet-embed hydration below can fetch same-scope sheets (M0a). Same
    # contract as the stamp it feeds (W1.5-C, below): an explicit caller
    # scope ALWAYS wins; a brand-new row falls back to the seeded Default; an
    # UPDATE without an explicit scope resolves to `%{}` (nothing stamped, the
    # existing row's scope preserved) and hydration scopes by the existing row.
    scope_opts = paper_scope_opts(attrs)

    scope_attrs =
      cond do
        scope_opts != [] ->
          Map.delete(Content.put_scope_attrs(%{"dataset" => dataset}, scope_opts), "dataset")

        existing ->
          %{}

        true ->
          Map.delete(Content.put_scope_attrs(%{"dataset" => dataset}, []), "dataset")
      end

    embed_scope =
      if scope_attrs == %{} and existing do
        %{
          "dataset" => dataset,
          "dataset_id" => existing.dataset_id,
          "workspace_id" => existing.workspace_id
        }
      else
        Map.put(scope_attrs, "dataset", dataset)
      end

    # R2 fix (Option A): assign a stable per-block id at INGEST so every block
    # has a UNIQUE "id" before storage/render. Id-less blocks otherwise all
    # collapse to the same LiveView stream/DOM id (`blocks-`), so Phoenix's
    # stream dedupes them and only the LAST block renders in the live <article>.
    # `ensure_block_ids/1` ONLY fills a missing/blank id (positional `block-N`,
    # recursing into sections) — it NEVER overwrites an author/op-supplied id, so
    # DocPatchOp block-addressing (ops target blocks by id) stays stable across
    # ops and re-ingests of the same structure.
    #
    # M0a: hydrate `"sheet"` block snapshots from their referenced sheets at
    # ingest, BEFORE the body_html render below — a paper embedding an
    # EXISTING sheet shows its values on the first read.
    blocks =
      case attrs["blocks"] do
        list when is_list(list) ->
          list |> ensure_block_ids() |> Sheets.hydrate_sheet_blocks(embed_scope, slug)

        other ->
          other
      end

    # Per-doc article marker. An ingest/POST may set `style: "article"` in
    # attrs; otherwise it sticks at whatever the existing doc already carries
    # (so a partial update never silently demotes an article paper). Threaded
    # into render_opts so the body_html cache is rendered in the article palette.
    style = Labels.paper_style(attrs, existing)
    render_opts = Labels.paper_render_opts(dataset, style)

    body_html =
      cond do
        is_list(blocks) -> Render.render_blocks(blocks, render_opts)
        is_binary(attrs["body_html"]) -> attrs["body_html"]
        true -> (existing && get_in(existing.content || %{}, ["body_html"])) || ""
      end

    next_rev = paper_next_rev(existing)

    content =
      ((existing && existing.content) || %{})
      |> Map.put("body_html", body_html)
      |> maybe_put_paper("blocks", if(is_list(blocks), do: blocks))
      |> maybe_put_paper("style", style)
      |> maybe_put_paper("source_doc", attrs["source_doc"])
      |> maybe_put_paper("goal_id", attrs["goal_id"])
      |> maybe_put_paper("event_type", attrs["event_type"])
      |> Map.put("rev", next_rev)
      # Project-on-write (Exp-P2): when this write carries a block list, project
      # the bound-field index + content["body"] from it. The SOLE writer of
      # content[fieldName]/content["body"], alongside apply_paper_block_op/3.
      # An HTML-only (legacy) write with no blocks skips projection untouched.
      |> maybe_project(blocks, dataset)

    title = paper_title(content, slug)

    doc_attrs = %{
      "doc_id" => slug,
      "type" => @paper_type,
      "dataset" => dataset,
      "title" => title,
      "status" => "published",
      "content" => content,
      "rev" => generate_rev()
    }

    # Stamp tenancy scope on the paper row. W1.5-C: an ingest/Studio caller MAY
    # thread an explicit workspace/project (via `attrs["workspace_id"]` /
    # `["project_id"]`) — when present it ALWAYS wins, so the surface is ready
    # the moment paper ingest starts sending the goal's scope. Absent it, this
    # falls back to the seeded Default workspace/project (same contract as
    # create_document/4) — without that a NULL-workspace paper is invisible to
    # the now-scoped Studio desk (B8/qucz). An UPDATE only re-stamps when the
    # caller asserted an explicit scope; otherwise `scope_attrs` resolved to
    # `%{}` above and the existing row's scope is preserved.
    doc_attrs = Map.merge(doc_attrs, scope_attrs)

    changeset =
      Document.changeset(existing || %Document{}, doc_attrs)

    result =
      if existing do
        Repo.update(changeset)
      else
        Repo.insert(changeset)
      end

    case result do
      {:ok, doc} ->
        broadcast_paper_update(doc)
        # P6.U1: append a goal-path lifecycle event ALONGSIDE the paper save,
        # gated strictly on a present `event_type` so ordinary streaming saves
        # never create events. The paper save is the source of truth — an
        # event-insert failure is logged and swallowed, never propagated.
        #
        # W1.5-C: the event FOLLOWS the paper's (goal's) scope — stamp it with
        # the saved doc's resolved workspace/project (Default fallback already
        # applied to the doc above) so a goal's events share the goal's scope.
        maybe_append_paper_event(attrs, slug, doc)
        {:ok, doc}

      error ->
        error
    end
  end

  # Append a `paper_events` row when this upsert carries a non-empty
  # `event_type`. Decoupled from Beads/W7 — pure Postgres via
  # `Barkpark.Plugins.Bulldocs.Events`. Failures are logged, never raised.
  #
  # W1.5-C: the event inherits the saved paper document's workspace/project —
  # the paper already resolved Default-fallback (new rows) or kept its existing
  # scope (updates), so the event always lands in the paper/goal's workspace.
  defp maybe_append_paper_event(attrs, slug, %Document{} = doc) do
    event_type = attrs["event_type"]

    if is_binary(event_type) and event_type != "" do
      event_attrs = %{
        "goal_id" => attrs["goal_id"],
        "paper_slug" => slug,
        "event_type" => event_type,
        "source_doc" => attrs["source_doc"],
        "payload_html" => attrs["payload_html"],
        "branch" => attrs["branch"] || "main",
        "workspace_id" => doc.workspace_id,
        "project_id" => doc.project_id
      }

      case Barkpark.Plugins.Bulldocs.Events.create_event(event_attrs) do
        {:ok, _event} ->
          :ok

        {:error, reason} ->
          require Logger
          Logger.warning("paper_events append failed for #{inspect(slug)}: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Apply a single portable-doc `op` (a DocPatchOp map) to a paper's block list,
  persist the new block list + a refreshed `body_html` cache + a bumped
  streaming rev, then broadcast a **delta** frame.

  Flow mirrors the former `Barkpark.Papers.apply_block_op/3`:

    1. Load the paper. Unknown slug ⇒ `{:error, :not_found}`. An HTML-only
       paper seeds an empty block list so the first op can append into it.
    2. Apply via `Barkpark.PortableDoc.Patch.apply_patch/2`.
    3. Render the affected block + refresh the whole `content["body_html"]`.
    4. Persist `content["blocks"]` + `content["body_html"]` + bumped
       `content["rev"]`.
    5. Broadcast `{:paper_block, %{op_kind, block_id, fragment_html, position,
       rev}}` on the per-doc topic.

  Returns `{:ok, %{block:, fragment_html:, op_kind:, block_id:, position:,
  rev:}}` on success.
  """
  def apply_paper_block_op(slug, op, dataset \\ @paper_default_dataset, opts \\ [])
      when is_binary(slug) and is_map(op) do
    with %Document{} = doc <- get_block_op_paper(slug, dataset, opts),
         blocks = get_in(doc.content || %{}, ["blocks"]) || [],
         {:ok, new_blocks} <- Patch.apply_patch(blocks, op),
         {:ok, affected} <- locate_paper_affected(op, new_blocks) do
      op_kind = Map.get(op, "op")
      rev = paper_next_rev(doc)
      # Carry the doc's stored article marker into the render so both the
      # body_html cache and the delta fragment match the article palette.
      style = get_in(doc.content || %{}, ["style"])
      render_opts = Labels.paper_render_opts(dataset, style)
      body_html = Render.render_blocks(new_blocks, render_opts)

      fragment_html =
        case affected.block do
          nil -> nil
          block -> Render.render_block(block, render_opts)
        end

      content =
        (doc.content || %{})
        |> Map.put("blocks", new_blocks)
        |> Map.put("body_html", body_html)
        |> Map.put("rev", rev)
        # Project-on-write (Exp-P2): the SOLE writer of content[fieldName] and
        # content["body"]. Re-derives the bound-field index + body from the
        # block list we just computed, so Classic queries stay in sync with the
        # blocks and never drift. Threads the PRE-patch `blocks` as old_blocks so
        # an unbind (fieldName→nil) clears the now-orphaned content[fieldName].
        |> Projection.project(blocks, new_blocks, render_opts)

      title = paper_title(content, slug)

      changeset =
        Document.changeset(doc, %{
          "content" => content,
          "title" => title,
          "rev" => generate_rev()
        })

      case Repo.update(changeset) do
        {:ok, _saved} ->
          frame = %{
            op_kind: op_kind,
            block_id: affected.block_id,
            fragment_html: fragment_html,
            position: affected.position,
            rev: rev
          }

          broadcast_paper_block(slug, doc.workspace_id, dataset, frame)

          {:ok,
           %{
             block: affected.block,
             fragment_html: fragment_html,
             op_kind: op_kind,
             block_id: affected.block_id,
             position: affected.position,
             rev: rev
           }}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Apply a LIST of portable-doc ops to a paper's block list **atomically** —
  the batch twin of `apply_paper_block_op/4`.

  All-or-nothing: the ops fold over the paper's block list in order; the FIRST
  op that fails halts the fold and the function returns the error with the
  paper **UNCHANGED** (no Repo write, no rev bump, no broadcast). Only when
  every op applies cleanly is the result persisted **once** (one row update,
  one rev bump) and a single delta frame broadcast.

  Flow:

    1. Load the paper (scoped). Unknown slug ⇒ `{:error, :not_found}`. An
       HTML-only paper seeds an empty block list so the first op can append.
    2. Fold the ops through `Barkpark.PortableDoc.Patch.apply_patch/2`,
       collecting each op's affected block id against the intermediate state.
       Halt + return `{:error, reason}` on the first failure (the same tagged
       tuples `apply_paper_block_op/4` surfaces), leaving the paper untouched.
    3. On full success: render the new block list, refresh the `body_html`
       cache, project-on-write, bump `content["rev"]` once, persist once.
    4. Broadcast one `{:paper_block, …}` delta frame carrying the new rev and
       the list of affected block ids.

  Returns `{:ok, %{slug:, op_count:, rev:, block_ids:}}` on success — the
  MINIMAL batch receipt (no per-op fragment_html). An empty `ops` list is a
  no-op that still loads the paper and returns the receipt at the current rev
  with `op_count: 0` and no block_ids, without writing.
  """
  def apply_paper_block_ops(slug, ops, dataset \\ @paper_default_dataset, opts \\ [])
      when is_binary(slug) and is_list(ops) do
    with %Document{} = doc <- get_block_op_paper(slug, dataset, opts),
         :ok <- check_paper_if_rev(doc, Keyword.get(opts, :if_rev)),
         blocks = get_in(doc.content || %{}, ["blocks"]) || [],
         {:ok, new_blocks, block_ids} <- fold_paper_ops(blocks, ops) do
      cond do
        ops == [] ->
          # Nothing to apply — report the current rev, no write, no broadcast.
          {:ok,
           %{
             slug: slug,
             op_count: 0,
             rev: paper_current_rev(doc),
             block_ids: []
           }}

        true ->
          rev = paper_next_rev(doc)
          style = get_in(doc.content || %{}, ["style"])
          render_opts = Labels.paper_render_opts(dataset, style)
          body_html = Render.render_blocks(new_blocks, render_opts)

          content =
            (doc.content || %{})
            |> Map.put("blocks", new_blocks)
            |> Map.put("body_html", body_html)
            |> Map.put("rev", rev)
            # Pre-patch `blocks` as old_blocks: a batch that unbinds a field
            # clears the orphan content[fieldName]; non-unbind ops ⇒ dropped == [].
            |> Projection.project(blocks, new_blocks, render_opts)

          title = paper_title(content, slug)

          changeset =
            Document.changeset(doc, %{
              "content" => content,
              "title" => title,
              "rev" => generate_rev()
            })

          case Repo.update(changeset) do
            {:ok, _saved} ->
              frame = %{
                op_kind: :batch,
                block_id: List.last(block_ids),
                block_ids: block_ids,
                fragment_html: nil,
                position: nil,
                rev: rev
              }

              broadcast_paper_block(slug, doc.workspace_id, dataset, frame)

              {:ok,
               %{
                 slug: slug,
                 op_count: length(ops),
                 rev: rev,
                 block_ids: block_ids
               }}

            {:error, changeset} ->
              {:error, changeset}
          end
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = err -> err
    end
  end

  # Atomic fold: thread the block list through each op via Patch.apply_patch/2,
  # collecting the affected block id per op against the post-op state. Halts on
  # the first failure (returning that op's tagged error) so a partial batch is
  # never persisted. Affected ids are de-duped while preserving first-seen order.
  defp fold_paper_ops(blocks, ops) do
    Enum.reduce_while(ops, {:ok, blocks, []}, fn op, {:ok, acc, ids} ->
      with {:ok, next} <- Patch.apply_patch(acc, op),
           {:ok, affected} <- locate_paper_affected(op, next) do
        new_ids =
          case affected.block_id do
            nil -> ids
            id -> if id in ids, do: ids, else: ids ++ [id]
          end

        {:cont, {:ok, next, new_ids}}
      else
        {:error, _reason} = err -> {:halt, err}
      end
    end)
  end

  # The CURRENT streaming rev (no bump) — used by the empty-batch no-op receipt.
  defp paper_current_rev(%Document{content: content}) when is_map(content) do
    case Map.get(content, "rev") do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp paper_current_rev(_), do: 0

  # M3 optimistic-concurrency guard. When the caller supplies an `ifRev`, reject
  # the batch BEFORE applying any op unless it matches the paper's current rev.
  # Absent `ifRev` (nil) keeps the prior behaviour (always proceed). The expected
  # value may arrive as an integer or a stringified integer (the wire shape);
  # both are compared against the integer `content["rev"]`.
  defp check_paper_if_rev(_doc, nil), do: :ok

  defp check_paper_if_rev(%Document{} = doc, expected) do
    current = paper_current_rev(doc)

    case normalize_if_rev(expected) do
      :invalid -> {:error, :precondition_failed}
      ^current -> :ok
      _other -> {:error, :precondition_failed}
    end
  end

  defp normalize_if_rev(n) when is_integer(n), do: n

  defp normalize_if_rev(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> :invalid
    end
  end

  defp normalize_if_rev(_), do: :invalid

  @doc """
  Apply a single portable-doc `op` to ANY Expectation-bearing document's block
  list (Exp-P3.2 — the generalization of `apply_paper_block_op/3` off the
  hardcoded `"paper"` type onto an arbitrary `{doc_id, type}`).

  This is the Beta block editor's write path for a non-paper document (a post):
  the same DocPatchOps the paper pane emits (`patch-block`, `insert-after`,
  `append-block`, `remove-block`, `move-block`, `replace-block`) apply to the
  document's `content["blocks"]`, then the content is re-projected
  (`Projection.project/3` — bound blocks → `content[fieldName]`, free blocks →
  `content["body"]`) and persisted through the canonical `upsert_document/4`
  path, which broadcasts `{:doc_updated,…}` + fires lifecycle hooks exactly
  like a Classic save.

  Synthesis-on-first-edit (Exp-P2/P3.1): a document with no stored
  `content["blocks"]` synthesizes its block list in memory via
  `resolve_blocks_for_edit/3`, applies the op to that, and the write persists
  the result — the first Beta edit is what materializes the blocks on disk.

  The block list is the SAME one Classic reads through projection — never a
  separate copy. Returns `{:ok, %{block, block_id, op_kind, position}}` on
  success, mirroring `apply_paper_block_op/3`'s result shape (minus the
  paper-only streaming `rev`/`fragment_html`, which the document editor does
  not stream). `opts` is forwarded to `upsert_document/4` for hook context.
  """
  @spec apply_document_block_op(String.t(), String.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def apply_document_block_op(doc_id, type, op, dataset, opts \\ [])
      when is_binary(doc_id) and is_binary(type) and is_map(op) do
    with {:ok, %Document{} = doc} <- Content.get_document(doc_id, type, dataset, opts),
         {blocks, _synth?} = resolve_blocks_for_edit(doc, type, dataset),
         {:ok, new_blocks} <- Patch.apply_patch(blocks, op),
         {:ok, affected} <- locate_paper_affected(op, new_blocks) do
      content =
        (doc.content || %{})
        |> Map.put("blocks", new_blocks)
        # Project-on-write — the SOLE writer of content[fieldName]/content["body"]
        # for this document, identical to the paper path. Bound title → "title",
        # free body blocks → content["body"]. Pre-patch `blocks` as old_blocks so
        # a Beta-editor unbind clears the orphaned content[fieldName].
        |> Projection.project(blocks, new_blocks, Labels.render_opts(dataset))

      # Derive the row title from the bound title field if present (matches the
      # Classic-save title precedence), else keep the document's current title.
      new_title = blank_to_nil(Map.get(content, "title")) || doc.title

      attrs = %{
        "doc_id" => DraftId.draft_id(DraftId.published_id(doc_id)),
        "title" => new_title,
        "status" => doc.status,
        "content" => content
      }

      case Content.upsert_document(type, attrs, dataset, opts) do
        {:ok, _saved} ->
          {:ok,
           %{
             block: affected.block,
             block_id: affected.block_id,
             op_kind: Map.get(op, "op"),
             position: affected.position
           }}

        {:error, _} = err ->
          err
      end
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} = err -> err
    end
  end

  # ── Papers — internal ──────────────────────────────────────────────────────

  # Resolve which block an op affected (post-apply) plus its top-level position.
  # Identical to the former Barkpark.Papers.locate_affected/2.
  defp locate_paper_affected(%{"op" => "append-block", "block" => block}, new_blocks) do
    {:ok, %{block: block, block_id: Map.get(block, "id"), position: length(new_blocks) - 1}}
  end

  defp locate_paper_affected(%{"op" => "insert-after", "block" => block}, new_blocks) do
    id = Map.get(block, "id")
    {:ok, %{block: block, block_id: id, position: paper_top_level_index(new_blocks, id)}}
  end

  defp locate_paper_affected(%{"op" => kind, "id" => id}, new_blocks)
       when kind in ["patch-block", "replace-block"] do
    block = paper_find_block(new_blocks, id)
    {:ok, %{block: block, block_id: id, position: paper_top_level_index(new_blocks, id)}}
  end

  defp locate_paper_affected(%{"op" => "remove-block", "id" => id}, _new_blocks) do
    {:ok, %{block: nil, block_id: id, position: nil}}
  end

  # move-block: the moved block kept its id + content; report it at its NEW
  # top-level index so the View-pane stream can re-place it correctly.
  defp locate_paper_affected(%{"op" => "move-block", "id" => id}, new_blocks) do
    block = paper_find_block(new_blocks, id)
    {:ok, %{block: block, block_id: id, position: paper_top_level_index(new_blocks, id)}}
  end

  defp locate_paper_affected(op, _new_blocks), do: {:error, {:invalid_op, op}}

  defp paper_top_level_index(blocks, id) do
    Enum.find_index(blocks, fn b -> Map.get(b, "id") == id end)
  end

  defp paper_find_block(blocks, id) do
    Enum.find_value(blocks, fn block ->
      cond do
        Map.get(block, "id") == id -> block
        Map.get(block, "type") == "section" -> paper_find_block(Map.get(block, "blocks", []), id)
        true -> nil
      end
    end)
  end

  # R2 fix (Option A). Walk a block list and fill a stable positional id
  # (`block-<index>`, sections recurse with a `<parent>.<index>` prefix) for
  # any block that lacks one. A block already carrying a non-blank "id" is left
  # untouched, so author/op-supplied ids — which DocPatchOps address blocks by —
  # survive byte-identical and stay resolvable. Sections recurse so a nested
  # id-less child also gets a unique id (the stream only keys on top-level ids,
  # but `apply_paper_block_op` addresses children too).
  defp ensure_block_ids(blocks) when is_list(blocks), do: ensure_block_ids(blocks, "block")

  defp ensure_block_ids(blocks, prefix) when is_list(blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.map(fn {block, index} -> ensure_block_id(block, prefix, index) end)
  end

  defp ensure_block_id(block, prefix, index) when is_map(block) do
    id =
      case Map.get(block, "id") do
        existing when is_binary(existing) and existing != "" -> existing
        _ -> "#{prefix}-#{index}"
      end

    block = Map.put(block, "id", id)

    case Map.get(block, "blocks") do
      children when is_list(children) -> Map.put(block, "blocks", ensure_block_ids(children, id))
      _ -> block
    end
  end

  defp ensure_block_id(block, _prefix, _index), do: block

  # `documents.title` is derived, in priority order, from:
  #   1. the PROJECTED bound title field (`content["title"]`) — Exp-P2: a bound
  #      title field-block is the explicit, editor-authored title, so it wins
  #      and the Classic query (Envelope) surfaces it as the row title;
  #   2. the first heading block's text (legacy heading-driven papers);
  #   3. the slug (the desk list always needs a title).
  defp paper_title(content, slug) when is_map(content) do
    blocks = Map.get(content, "blocks")

    heading_text =
      if is_list(blocks) do
        Enum.find_value(blocks, fn b ->
          if Map.get(b, "type") == "heading", do: blank_to_nil(Map.get(b, "text"))
        end)
      end

    blank_to_nil(Map.get(content, "title")) || heading_text || slug
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s
  defp blank_to_nil(_), do: nil

  defp broadcast_paper_update(%Document{} = doc) do
    content = doc.content || %{}

    msg =
      {:paper_updated,
       %{
         slug: doc.doc_id,
         dataset: doc.dataset,
         html: Map.get(content, "body_html"),
         rev: Map.get(content, "rev"),
         source_doc: Map.get(content, "source_doc"),
         goal_id: Map.get(content, "goal_id"),
         event_type: Map.get(content, "event_type")
       }}

    # Workspace-scope the topic (barkpark-n56v): stamp the doc's own
    # workspace_id so the frame only reaches subscribers of THIS tenant. nil
    # (legacy) normalizes to the Default ws inside paper_topic, matching the
    # public viewer's resolved workspace.
    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      Broadcast.paper_topic(doc.doc_id, doc.workspace_id, doc.dataset),
      msg
    )
  end

  defp broadcast_paper_block(slug, workspace_id, dataset, frame) do
    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      Broadcast.paper_topic(slug, workspace_id, dataset),
      {:paper_block, frame}
    )
  end

  # Allow callers to pass atom OR string keys (controller params are strings,
  # internal callers/tests may use atoms). Stringify, dropping nils.
  defp normalize_paper_attrs(attrs) do
    Enum.reduce(attrs, %{}, fn {k, v}, acc ->
      key = if is_atom(k), do: Atom.to_string(k), else: k
      if is_nil(v), do: acc, else: Map.put(acc, key, v)
    end)
  end

  defp maybe_put_paper(map, _key, nil), do: map
  defp maybe_put_paper(map, key, value), do: Map.put(map, key, value)

  # W1.5-C: build [workspace_id: …, project_id: …] from an EXPLICIT scope the
  # caller threaded through paper attrs (string keys, post-normalize). Returns
  # [] when no workspace_id is present — the Default-fallback path then applies.
  # project_id is only meaningful alongside a workspace_id (matches the
  # scope_to_workspace contract).
  defp paper_scope_opts(attrs) do
    case attrs["workspace_id"] do
      ws when is_binary(ws) and ws != "" ->
        case attrs["project_id"] do
          proj when is_binary(proj) and proj != "" -> [workspace_id: ws, project_id: proj]
          _ -> [workspace_id: ws]
        end

      _ ->
        []
    end
  end

  # The pre-write existing-paper lookup, SCOPED to this write's tenant so a
  # same-slug write in workspace B never finds (and clobbers) workspace A's row
  # (barkpark-w9dg). The scope mirrors the write-stamp fallback: an explicit
  # workspace in attrs wins; absent it, the seeded Default workspace — so the
  # flat, unscoped paper ingest keeps upserting its own Default-scoped row.
  defp get_existing_paper_for_write(slug, dataset, attrs) do
    case paper_scope_opts(attrs) do
      [_ | _] = opts ->
        get_paper(slug, dataset, opts)

      [] ->
        case Barkpark.Tenancy.get_default_workspace() do
          %{id: ws_id} when is_binary(ws_id) -> get_paper(slug, dataset, workspace_id: ws_id)
          # No seeded Default (fresh sandbox) — fall back to the prior unscoped
          # lookup so the very first single-tenant write still self-locates.
          _ -> get_paper(slug, dataset)
        end
    end
  end

  # The block-op doc load, SCOPED so a streaming op never resolves (and mutates)
  # a same-slug paper in another workspace (barkpark-af50). Mirrors the
  # write-side scope contract (get_existing_paper_for_write / get_public_paper):
  # an explicit workspace in opts wins; absent it, the seeded Default workspace
  # — the deterministic public/ingest tenant. Only when no Default is seeded
  # (fresh sandbox) does it fall back to the prior unscoped lookup so a first
  # single-tenant op still self-locates.
  defp get_block_op_paper(slug, dataset, opts) do
    case Keyword.get(opts, :workspace_id) do
      ws when is_binary(ws) and ws != "" ->
        get_paper(slug, dataset, workspace_id: ws, project_id: Keyword.get(opts, :project_id))

      _ ->
        case Barkpark.Tenancy.get_default_workspace() do
          %{id: ws_id} when is_binary(ws_id) -> get_paper(slug, dataset, workspace_id: ws_id)
          _ -> get_paper(slug, dataset)
        end
    end
  end

  # Project-on-write only when this write actually carries a block list. An
  # HTML-only legacy paper write (no blocks) leaves content[fieldName]/body
  # untouched — projection is the SOLE writer, so a no-block write must not
  # invent an empty body.
  defp maybe_project(content, blocks, dataset) when is_list(blocks) do
    Projection.project(content, blocks, Labels.render_opts(dataset))
  end

  defp maybe_project(content, _blocks, _dataset), do: content

  # Next monotonic streaming rev for a paper. Starts at 1 for a fresh paper;
  # increments the stored integer otherwise.
  defp paper_next_rev(nil), do: 1

  defp paper_next_rev(%Document{content: content}) when is_map(content) do
    case Map.get(content, "rev") do
      n when is_integer(n) -> n + 1
      _ -> 1
    end
  end

  defp paper_next_rev(_), do: 1

  # The document's opaque string `rev` (mutation-spine version), distinct from
  # the integer streaming `content["rev"]`. Pure helper duplicated here so the
  # Papers module owns its own row-rev generation without coupling to the hub's
  # private `generate_rev/0` (concern E, Step 13).
  defp generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
