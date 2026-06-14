defmodule Barkpark.Content do
  @moduledoc """
  Context for documents and schema definitions.

  ## Draft/Published model

  Follows Sanity's convention: drafts and published are separate document rows.

    - Published document: `doc_id = "p1"`
    - Draft of same:      `doc_id = "drafts.p1"`

  Creating a document always creates a draft (`drafts.{id}`).
  Publishing copies the draft to the published ID and removes the draft.
  Editing a published doc creates a new draft alongside it.

  ## Perspectives

    - `:published` — only documents without `drafts.` prefix (public-facing)
    - `:drafts`    — prefers draft over published when both exist (studio view)
    - `:raw`       — all documents including both drafts and published
  """

  import Ecto.Query
  alias Barkpark.Repo

  alias Barkpark.Content.{
    Document,
    Envelope,
    MutationEvent,
    Revision,
    SchemaDefinition,
    Validation
  }

  import Barkpark.Content.Scope, only: [scope_to_workspace_or_global: 3]

  alias Barkpark.PortableDoc.{Patch, Projection, Render, Synthesis}

  @drafts_prefix "drafts."

  # ── Papers (convergence: papers are first-class documents) ────────────────
  #
  # A paper is a `documents` row of type "paper" (doc_id = the slug). Its
  # portable-doc block list is the source of truth, stored under
  # `content["blocks"]`; `content["body_html"]` is the derived HTML cache
  # rendered by `Barkpark.PortableDoc.Render`. The monotonic integer streaming
  # rev — distinct from the document's opaque string `rev` used by the mutation
  # spine — lives at `content["rev"]`. `content["source_doc"]`, `["goal_id"]`,
  # and `["event_type"]` carry paperflow provenance.
  #
  # Papers ride the SAME per-doc PubSub topic shape used in Wave 4 —
  # `doc:<dataset>:paper:<slug>` — and broadcast the SAME two frames
  # (`{:paper_updated, …}` whole-HTML, `{:paper_block, …}` delta) so
  # `BarkparkWeb.BulldocsLive` keeps working with minimal change.
  @paper_type "paper"
  @paper_default_dataset "production"

  # ── Draft/Published helpers ────────────────────────────────────────────────

  def draft_id(published_id) do
    if String.starts_with?(published_id, @drafts_prefix) do
      published_id
    else
      @drafts_prefix <> published_id
    end
  end

  def published_id(doc_id) do
    String.replace_prefix(doc_id, @drafts_prefix, "")
  end

  def draft?(doc_id), do: String.starts_with?(doc_id, @drafts_prefix)

  # ── Documents ──────────────────────────────────────────────────────────────

  @doc """
  List documents by type and dataset.

  Options:
    - `:perspective`  — `:published`, `:drafts`, or `:raw` (default `:raw`)
    - `:filter_map`   — map of field=>value filters, e.g. `%{"status" => "draft"}`
    - `:limit`        — max rows returned (default 100, max 1000, min 1)
    - `:offset`       — rows to skip (default 0)
    - `:order`        — `:updated_at_desc` (default), `:updated_at_asc`,
                        `:created_at_desc`, `:created_at_asc`

  The `:drafts` perspective merges draft/published pairs at SQL level via
  `DISTINCT ON`, so `limit` and `offset` are applied after the merge.

  Tenancy scoping (Wave 1 hard boundary):
    - `:workspace_id` — scope reads to a single workspace (nil = unscoped /
                        pre-tenancy back-compat).
    - `:project_id`   — further narrow to a single project (requires
                        `:workspace_id`; nil = workspace-wide).

  The workspace/project filter is applied IN ADDITION TO the dataset-string
  filter via `Barkpark.Content.Scope.scope_to_workspace/3`.
  """
  def list_documents(type, dataset, opts \\ []) do
    perspective = Keyword.get(opts, :perspective, :raw)
    filter_map = Keyword.get(opts, :filter_map, %{})
    limit = opts |> Keyword.get(:limit, 100) |> min(1000) |> max(1)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    order = Keyword.get(opts, :order, :updated_at_desc)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    base =
      Document
      |> where([d], d.type == ^type)
      |> scope_to_dataset(dataset, opts)
      |> scope_to_workspace_or_global(workspace_id, project_id)
      |> apply_filter_map(filter_map)

    case perspective do
      :drafts -> list_with_drafts_merged(base, order, limit, offset)
      other -> list_linear(base, other, order, limit, offset)
    end
  end

  defp list_linear(query, perspective, order, limit, offset) do
    query
    |> apply_perspective(perspective)
    |> apply_order(order)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  defp list_with_drafts_merged(query, order, limit, offset) do
    inner =
      from(d in query,
        distinct: fragment("regexp_replace(?, '^drafts\\.', '')", d.doc_id),
        order_by: [
          fragment("regexp_replace(?, '^drafts\\.', '')", d.doc_id),
          fragment("CASE WHEN ? LIKE 'drafts.%' THEN 0 ELSE 1 END", d.doc_id)
        ]
      )

    from(d in subquery(inner))
    |> apply_order(order)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  defp apply_perspective(query, :published) do
    prefix = @drafts_prefix <> "%"
    where(query, [d], not like(d.doc_id, ^prefix))
  end

  defp apply_perspective(query, _), do: query

  defp apply_filter_map(query, map) when map_size(map) == 0, do: query

  defp apply_filter_map(query, map) do
    Enum.reduce(map, query, fn
      {field, %{} = ops}, q -> apply_field_ops(q, field, ops)
      {field, value}, q -> apply_field_op(q, field, "eq", value)
    end)
  end

  defp apply_field_ops(query, field, ops) do
    Enum.reduce(ops, query, fn {op, value}, q ->
      apply_field_op(q, field, op, value)
    end)
  end

  defp apply_field_op(query, "title", "eq", v), do: where(query, [d], d.title == ^v)

  defp apply_field_op(query, "title", "in", vs) when is_list(vs),
    do: where(query, [d], d.title in ^vs)

  defp apply_field_op(query, "title", "contains", v),
    do: where(query, [d], ilike(d.title, ^"%#{v}%"))

  defp apply_field_op(query, "title", "gt", v), do: where(query, [d], d.title > ^v)
  defp apply_field_op(query, "title", "gte", v), do: where(query, [d], d.title >= ^v)
  defp apply_field_op(query, "title", "lt", v), do: where(query, [d], d.title < ^v)
  defp apply_field_op(query, "title", "lte", v), do: where(query, [d], d.title <= ^v)

  defp apply_field_op(query, "status", "eq", v), do: where(query, [d], d.status == ^v)

  defp apply_field_op(query, "status", "in", vs) when is_list(vs),
    do: where(query, [d], d.status in ^vs)

  # doc_id operators — desk-group filters (e.g. drafts. prefix) need this.
  defp apply_field_op(query, "doc_id", "eq", v), do: where(query, [d], d.doc_id == ^v)

  defp apply_field_op(query, "doc_id", "starts_with", v),
    do: where(query, [d], like(d.doc_id, ^"#{v}%"))

  defp apply_field_op(query, "doc_id", "not_starts_with", v),
    do: where(query, [d], not like(d.doc_id, ^"#{v}%"))

  defp apply_field_op(query, field, "eq", v) do
    if nested_path?(field) do
      segs = nested_segments(field)

      where(
        query,
        [d],
        fragment("jsonb_extract_path_text(?, VARIADIC ?) = ?", d.content, ^segs, ^v)
      )
    else
      where(query, [d], fragment("?->>? = ?", d.content, ^field, ^v))
    end
  end

  defp apply_field_op(query, field, "in", vs) when is_list(vs) do
    if nested_path?(field) do
      segs = nested_segments(field)

      where(
        query,
        [d],
        fragment(
          "jsonb_extract_path_text(?, VARIADIC ?) = ANY(?)",
          d.content,
          ^segs,
          ^vs
        )
      )
    else
      where(query, [d], fragment("?->>? = ANY(?)", d.content, ^field, ^vs))
    end
  end

  defp apply_field_op(query, field, "contains", v),
    do: where(query, [d], fragment("?->>? ILIKE ?", d.content, ^field, ^"%#{v}%"))

  defp apply_field_op(query, field, "gt", v),
    do: where(query, [d], fragment("?->>? > ?", d.content, ^field, ^v))

  defp apply_field_op(query, field, "gte", v),
    do: where(query, [d], fragment("?->>? >= ?", d.content, ^field, ^v))

  defp apply_field_op(query, field, "lt", v),
    do: where(query, [d], fragment("?->>? < ?", d.content, ^field, ^v))

  defp apply_field_op(query, field, "lte", v),
    do: where(query, [d], fragment("?->>? <= ?", d.content, ^field, ^v))

  defp apply_field_op(query, _field, _op, _value), do: query

  defp nested_path?(field) when is_binary(field), do: String.contains?(field, ".")
  defp nested_path?(_), do: false

  # Split a dot-delimited content path into segments for
  # `jsonb_extract_path_text(content, VARIADIC …)`. The `content.` prefix
  # is conventional (desk-group filters in schema JSON write e.g.
  # `"content.bp_export_status.state"`) but the JSONB column is already
  # `d.content`, so we strip it before splitting — otherwise we'd
  # descend into `content.content.…`.
  defp nested_segments(field) when is_binary(field) do
    field
    |> String.replace_prefix("content.", "")
    |> String.split(".")
  end

  defp apply_order(q, :updated_at_desc), do: order_by(q, [d], desc: d.updated_at)
  defp apply_order(q, :updated_at_asc), do: order_by(q, [d], asc: d.updated_at)
  defp apply_order(q, :created_at_desc), do: order_by(q, [d], desc: d.inserted_at)
  defp apply_order(q, :created_at_asc), do: order_by(q, [d], asc: d.inserted_at)
  defp apply_order(q, _), do: order_by(q, [d], desc: d.updated_at)

  @doc """
  Fetch a single document by `{doc_id, type, dataset}`.

  `opts` may carry tenancy scope:
    - `:workspace_id` — scope the read to a workspace (nil = unscoped /
                        pre-tenancy back-compat; used by internal mutation
                        lookups that resolve the workspace another way).
    - `:project_id`   — further narrow to a project (requires `:workspace_id`).

  The workspace/project filter is applied IN ADDITION TO the dataset-string
  filter via `Barkpark.Content.Scope.scope_to_workspace/3`.
  """
  def get_document(doc_id, type, dataset, opts \\ [])

  def get_document(doc_id, type, dataset, _opts)
      when is_nil(doc_id) or is_nil(type) or is_nil(dataset) do
    {:error, :not_found}
  end

  def get_document(doc_id, type, dataset, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Document
    |> where([d], d.doc_id == ^doc_id and d.type == ^type)
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  @doc """
  Resolve a referenced document's display title from a stored reference value.

  `value` is a plain doc-id string (the v1 reference-field persistence model);
  `ref_type` is the optional target schema (`""` when a paper field-reference
  block has no refType set). Returns the title of the matching document, or the
  original `value` as a fallback when no document is found / `value` is blank.

  Cheap by design — a single keyed read on `(doc_id, dataset)`, narrowed
  by `type` when `ref_type` is non-empty. The published id is preferred (a
  reference value stores the published id); both the published row and its
  `drafts.` twin satisfy the `doc_id IN (...)` clause, so an unpublished target
  still resolves. Used by the View-mode renderer to show the title instead of
  the raw id.

  NEVER raises on a non-unique `doc_id`. When `ref_type` is empty there is no
  type narrowing, so the same `doc_id` can match several rows (e.g. `p1` exists
  as both a `book` and a `post`). We therefore use `Repo.all` + an explicit
  in-Elixir pick (published row before its `drafts.` twin) instead of
  `Repo.one`, which would raise `Ecto.MultipleResultsError` if the `limit(1)`
  guard were ever dropped.
  """
  @spec reference_title(String.t() | nil, String.t() | nil, String.t(), keyword()) :: String.t()
  def reference_title(value, ref_type, dataset, opts \\ [])

  def reference_title(value, _ref_type, _dataset, _opts) when value in [nil, ""],
    do: value || ""

  def reference_title(value, ref_type, dataset, opts) when is_binary(value) do
    pub_id = published_id(value)
    draft = draft_id(pub_id)

    query =
      Document
      |> scope_to_dataset(dataset, opts)
      |> where([d], d.doc_id == ^pub_id or d.doc_id == ^draft)
      # Scope the reference resolution to the caller's tenant when supplied so a
      # reference value never resolves a same-id doc in another workspace
      # (barkpark-af50). Render-pipeline callers that pass no scope keep the
      # explicit-global behaviour via scope_to_workspace_or_global/3.
      |> scope_to_workspace_or_global(
        Keyword.get(opts, :workspace_id),
        Keyword.get(opts, :project_id)
      )
      |> order_by([d], asc: fragment("CASE WHEN ? LIKE 'drafts.%' THEN 1 ELSE 0 END", d.doc_id))

    query =
      if is_binary(ref_type) and ref_type != "" do
        where(query, [d], d.type == ^ref_type)
      else
        query
      end

    # Repo.all + List.first: the published row (CASE = 0) sorts ahead of its
    # `drafts.` twin (CASE = 1), so the first row is the published-preferred
    # pick. Multiple-type matches (empty ref_type) never raise.
    case query |> Repo.all() |> List.first() do
      %Document{title: title} when is_binary(title) and title != "" -> title
      _ -> value
    end
  end

  @doc """
  Resolve a codelist CODE to its human LABEL for View-mode rendering.

  Looks the code up in the registered codelist `(plugin, codelist_id)` via
  `Barkpark.Content.Codelists.lookup/4` and returns its preferred-language
  label. Falls back to the raw `code` when the codelist is unregistered, the
  code is unknown, or `code`/`codelist_id` is blank. Dataset-independent —
  the codelist registry is keyed by `(plugin, list_id)`, not by dataset.
  """
  @spec codelist_label(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t()
  def codelist_label(plugin, codelist_id, code)

  def codelist_label(_plugin, _codelist_id, code) when code in [nil, ""], do: code || ""

  def codelist_label(plugin, codelist_id, code)
      when is_binary(plugin) and is_binary(codelist_id) and codelist_id != "" and is_binary(code) do
    case Barkpark.Content.Codelists.lookup(plugin, codelist_id, code) do
      %{label: label} when is_binary(label) and label != "" -> label
      _ -> code
    end
  end

  def codelist_label(_plugin, _codelist_id, code) when is_binary(code), do: code

  # Render options carrying the resolvers bound to a dataset. Passed to
  # `Render.render_block/2` / `render_blocks/2` so the View-mode
  # `field-reference` row shows the referenced doc's TITLE instead of the raw
  # id, and the `codelist` row shows the selected code's LABEL instead of the
  # raw code; everything else in `Render` stays pure.
  defp render_opts(dataset) do
    %{
      ref_resolver: fn value, ref_type -> reference_title(value, ref_type, dataset) end,
      codelist_resolver: fn plugin, codelist_id, code ->
        codelist_label(plugin, codelist_id, code)
      end
    }
  end

  # The same resolvers as `render_opts/1`, plus the per-doc render `:style`
  # when the paper is marked `"article"`. Threaded into `Render.render_blocks/2`
  # so an article paper's body_html cache (and delta fragments) come out in the
  # article palette. A nil / non-"article" style adds nothing → email default,
  # byte-unchanged from `render_opts/1`.
  defp paper_render_opts(dataset, "article"), do: Map.put(render_opts(dataset), :style, :article)
  defp paper_render_opts(dataset, _style), do: render_opts(dataset)

  # Resolve the per-doc style marker for an upsert: an explicit `style` in attrs
  # wins (so an ingest/POST can set it), else the existing doc's stored style is
  # preserved (a partial update never silently demotes an article paper), else
  # nil (the email default). Only "article" is meaningful; anything else is
  # normalized away so we never persist a stray marker.
  defp paper_style(attrs, existing) do
    explicit = attrs["style"]
    existing_style = existing && get_in(existing.content || %{}, ["style"])

    cond do
      explicit == "article" -> "article"
      is_binary(explicit) -> nil
      existing_style == "article" -> "article"
      true -> nil
    end
  end

  @doc """
  Fetch a document with draft-first preference. Returns the draft if it
  exists, otherwise falls back to the published row, plus flags for
  whether the returned doc is the draft and whether a published version
  exists. Used by StudioLive's native editor pane — consolidated in
  Task #11 WI3 from prior duplicates (the plugin LVs that originally
  shared this helper were removed in Goal `barkpark-zdy`).

      {doc | nil, is_draft :: boolean, has_published :: boolean}
  """
  @spec fetch_doc_with_draft(String.t(), String.t(), String.t(), keyword()) ::
          {Document.t() | nil, boolean(), boolean()}
  def fetch_doc_with_draft(type, doc_id, dataset, opts \\ []) do
    pub_id = published_id(doc_id)
    draft_r = get_document(draft_id(pub_id), type, dataset, opts)
    pub_r = get_document(pub_id, type, dataset, opts)

    {doc, is_draft} =
      case draft_r do
        {:ok, d} ->
          {d, true}

        _ ->
          case pub_r do
            {:ok, d} -> {d, false}
            _ -> {nil, false}
          end
      end

    {doc, is_draft, match?({:ok, _}, pub_r)}
  end

  @doc """
  Build a form map from a document and its schema. Returns a map keyed
  by field name with string values, including `"title"` and `"status"`
  baseline keys. Returns `%{}` when `doc` is nil. Used by StudioLive's
  native editor pane — consolidated in Task #11 WI3 from prior
  duplicates in StudioLive (`doc_to_form`, `doc_data_to_form`) and the
  deleted plugin BookEditor.
  """
  @spec doc_to_form(map() | nil, map() | nil) :: map()
  def doc_to_form(nil, _schema), do: %{}

  def doc_to_form(doc, schema) do
    base = %{"title" => doc.title || "", "status" => doc.status || "draft"}

    if schema do
      Enum.reduce(schema.fields, base, fn field, acc ->
        key = field["name"]

        val =
          if key in ["title", "status"],
            do: Map.get(acc, key),
            else: classic_form_value(get_in(doc.content || %{}, [key]))

        Map.put(acc, key, val)
      end)
    else
      base
    end
  end

  # A field's projected content value, flattened to the SCALAR the Classic form
  # input expects. A `body` REGION projects to a body map (`%{"blocks" => …,
  # "html" => …}` — Projection.project_body/2); the Classic richText/text input
  # is a string editor, so surface the rendered HTML string. This is the Classic
  # read side of the lossless Beta↔Classic toggle (Exp-P3.2): both views read
  # the ONE projected content, each presenting it in its own shape — no
  # conversion of the underlying block list. Non-map (scalar) values pass through
  # unchanged; nil becomes "".
  defp classic_form_value(%{"html" => html}) when is_binary(html), do: html
  defp classic_form_value(nil), do: ""
  defp classic_form_value(value), do: value

  @doc """
  Build a `content` map from a form params map by reducing schema
  fields. Excludes `"title"` and `"status"` (those live on the
  document row, not under `content`). Empty-string values are dropped.
  Returns `%{}` when `schema` is nil. Used by StudioLive's native
  editor pane — consolidated in Task #11 WI3 (the plugin BookEditor
  that originally shared this helper was removed in Goal `barkpark-zdy`).
  """
  @spec build_content(map(), map() | nil) :: map()
  def build_content(_params, nil), do: %{}

  def build_content(params, schema) do
    Enum.reduce(schema.fields, %{}, fn field, acc ->
      key = field["name"]
      val = Map.get(params, key, "")

      if key in ["title", "status"] or val == "" do
        acc
      else
        Map.put(acc, key, coerce_field_value(field, val))
      end
    end)
  end

  # Schema `"number"` fields arrive from the Classic form as STRINGS (the
  # numeric field renders as a text input with inputmode="numeric"), but
  # the API contract stores numbers — e.g. the task validator's
  # integer-0..4 `priority` check hard-rejects the string and fails the
  # save. Coerce at the save boundary so the API contract stays the
  # source of truth: integer parse first, float fallback. An unparseable
  # value is kept AS-IS so the schema/kind validator rejects it loudly
  # instead of the save path silently corrupting it. Empty strings never
  # reach here (build_content/2 drops them — the existing field-clearing
  # semantics). Non-binary values (API callers already sending numbers)
  # pass through unchanged.
  defp coerce_field_value(%{"type" => "number"}, val) when is_binary(val) do
    trimmed = String.trim(val)

    case Integer.parse(trimmed) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(trimmed) do
          {float, ""} -> float
          _ -> val
        end
    end
  end

  # Schema `"boolean"` fields arrive from the Classic form as the STRINGS
  # "true"/"false" (the checkbox + hidden-false pair) — found live 2026-06-12
  # by clicking the Studio switch and reading the draft back: `featured`
  # stored as the string "true", a silent JSONB type flip under every typed
  # consumer (the same bug class the TUI/CLI typed saves fixed client-side).
  # Coerce at the save boundary; any other string is kept AS-IS so a schema
  # validator rejects it loudly rather than this path guessing.
  defp coerce_field_value(%{"type" => "boolean"}, "true"), do: true
  defp coerce_field_value(%{"type" => "boolean"}, "false"), do: false

  defp coerce_field_value(_field, val), do: val

  # ── Exp-P3.2 — Classic-save content (the data-loss guard) ─────────────────
  #
  # A document THAT HAS content["blocks"] (it has been opened in the Beta block
  # editor) must NOT be saved by overwriting content from the flat Classic form
  # map — that would drop every FREE block and content["blocks"] itself. Instead
  # the submitted fields are mapped onto the matching BOUND blocks' values, the
  # block list is re-projected, and FREE blocks + block ORDER survive
  # byte-identical. A document WITHOUT blocks (legacy, never Beta-edited) keeps
  # the existing build_content/2 field-map behavior unchanged.
  defp classic_save_content(base_doc, params, schema, dataset) do
    base_content = Map.get(base_doc, :content) || %{}

    case Map.get(base_content, "blocks") do
      blocks when is_list(blocks) ->
        values = classic_field_values(params, schema)
        new_blocks = Synthesis.patch_bound_values(blocks, values)

        # A submitted field with NO bound block must still persist (e.g. an
        # image field on a doc whose block list never bound it) — patching
        # bound blocks alone silently dropped it while the editor reported
        # "Saved". Merge those onto content as plain keys with the same
        # semantics as the non-blocks branch (empty string clears the key).
        # Projection only rewrites bound fieldNames + "body", so these
        # survive the project pass.
        bound_names =
          blocks
          |> Enum.map(& &1["fieldName"])
          |> Enum.filter(&(is_binary(&1) and &1 != ""))

        unbound_params = Map.drop(params, bound_names)

        base_content
        |> Map.drop(Map.keys(unbound_params))
        |> Map.drop(["title", "status"])
        |> Map.merge(build_content(unbound_params, schema))
        |> Map.put("blocks", new_blocks)
        |> Projection.project(new_blocks, render_opts(dataset))

      _ ->
        # Merge over the existing content instead of replacing it: a key
        # PRESENT in the submitted params is form-managed — its new value
        # (or its removal, via build_content/2's empty-string drop) wins.
        # A key ABSENT from params is one the form does not manage — v1
        # "array"/"object" fields render read-only with no input (the task
        # schema's `dependencies`/`claim`), and non-schema keys like the
        # task substrate's `labels`/`papers` never render at all. Those
        # survive a Classic save byte-identical instead of being silently
        # dropped. (The blocks branch above already preserves base_content.)
        base_content
        |> Map.drop(Map.keys(params))
        |> Map.drop(["title", "status"])
        |> Map.merge(build_content(params, schema))
    end
  end

  # The field => submitted-value map a Classic save patches onto bound blocks.
  # Keyed by the SCHEMA's declared field names plus the row-level "title" field
  # (post's layout binds title), so only fields the schema knows about can
  # touch a bound block. "status" lives on the row, never in content, so it is
  # excluded. Values are taken verbatim from the form params; a field absent
  # from params is omitted (its bound block is left untouched).
  defp classic_field_values(params, schema) do
    names =
      case schema do
        %{fields: fields} when is_list(fields) ->
          Enum.map(fields, & &1["name"]) ++ ["title"]

        _ ->
          ["title"]
      end

    names
    |> Enum.uniq()
    |> Enum.reject(&(&1 in [nil, "status"]))
    |> Enum.reduce(%{}, fn name, acc ->
      case Map.fetch(params, name) do
        {:ok, value} -> Map.put(acc, name, value)
        :error -> acc
      end
    end)
  end

  @doc """
  Upsert a draft for the document being edited. Builds attrs from the
  form params + schema, runs informational validation, calls
  `upsert_document/3`, and returns the saved doc together with the
  validation errors map (drafts save with warnings; only publish blocks).

  `opts` is forwarded to `upsert_document/4` so callers can supply
  lifecycle-hook context (`:source`, `:user_id`).

  Returns `{:ok, saved_doc, validation_errors_map}` on success or
  `{:error, term}` on a DB upsert failure. The `{:error, {:halted,
  reason}}` shape from a halting `before_save` hook is passed through
  unchanged. Consolidated in Task #11 WI3 from prior duplicate bodies
  in StudioLive (`handle_event "autosave"`, `handle_info :autosave_form`,
  `save_doc/3`).
  """
  @spec upsert_draft(Document.t(), String.t(), map() | nil, map(), String.t(), keyword()) ::
          {:ok, Document.t(), map()} | {:error, term()}
  def upsert_draft(base_doc, type, schema, params, dataset, opts \\ []) do
    content = classic_save_content(base_doc, params, schema, dataset)
    new_title = Map.get(params, "title", base_doc.title)

    attrs = %{
      "doc_id" => draft_id(published_id(base_doc.doc_id)),
      "title" => new_title,
      "status" => Map.get(params, "status", base_doc.status),
      "content" => content
    }

    validation_errors =
      case validate_document(type, new_title, content, dataset) do
        {:error, errs} -> errs
        _ -> %{}
      end

    case upsert_document(type, attrs, dataset, opts) do
      {:ok, doc} -> {:ok, doc, validation_errors}
      {:error, _} = err -> err
    end
  end

  # W7a step 1 — task documents carry a tight `content` field contract
  # (`Barkpark.Tasks.validate_kind_content/2`) on top of the generic
  # schema-field validation. Enforced here at the write boundary so neither
  # `create_document/4` nor `upsert_document/4` can land a malformed task
  # row. Defense-in-depth: migration `20260528100000_w7a_task_schema` adds a
  # DB CHECK constraint that catches raw-Repo writes that bypass this hook.
  #
  # Everything is a task — goals/phases/events are gone as document types.
  # Returns `:ok` for non-task types so the existing post/page/paper write
  # path is unaffected.
  defp validate_task_kind("task", attrs) do
    content = Map.get(attrs, "content") || Map.get(attrs, :content) || %{}

    case Barkpark.Tasks.validate_kind_content("task", content) do
      :ok ->
        :ok

      {:error, errors} ->
        {:error, {:invalid_task_content, errors}}
    end
  end

  defp validate_task_kind(_type, _attrs), do: :ok

  @doc "Validate document content against its schema. Returns {:ok, content} or {:error, errors_map}."
  def validate_document(type, title, content, dataset) do
    case get_schema(type, dataset) do
      {:ok, schema} -> Validation.validate(content, title, schema)
      _ -> {:ok, content}
    end
  end

  @doc """
  Create or update a document. New docs are always created as drafts.

  `opts` is a keyword list carrying hook context:
    - `:source` — `:studio | :api | :cli | :worker` (default `:api`)
    - `:user_id` — string id of the acting user, or `nil`

  Fires `:before_save` synchronously before the DB write; on
  `{:halt, reason}` returns `{:error, {:halted, reason}}` and skips the
  write. Fires `:after_save` asynchronously after a successful write.
  """
  def create_document(type, attrs, dataset, opts \\ []) do
    attrs = from_envelope(attrs)
    raw_id = Map.get(attrs, "doc_id") || Map.get(attrs, :doc_id) || generate_id(type)
    doc_id = draft_id(raw_id)

    attrs =
      attrs
      |> Map.put("doc_id", doc_id)
      |> Map.put("type", type)
      |> Map.put("dataset", dataset)
      |> Map.put_new("status", "draft")
      |> Map.put("rev", generate_rev())
      |> put_scope_attrs(opts)
      |> maybe_recompute_sheet_formulas(type)
      |> hydrate_sheet_embed_snapshots()

    with :ok <- validate_task_kind(type, attrs) do
      do_create_document(type, attrs, dataset, doc_id, opts)
    end
  end

  defp do_create_document(type, attrs, dataset, doc_id, opts) do
    ctx = build_ctx(opts)

    # Scope the prev-doc lookup to the writer's workspace/project. An UNSCOPED
    # lookup here would resolve (and then UPDATE/overwrite) another workspace's
    # row that happens to share the (doc_id, type, dataset) leaf — the inner
    # half of the B3 mutate leak. Scoped, a same-id write from a different
    # workspace sees no prev_doc and falls through to an insert of its own row.
    prev_doc =
      case get_document(doc_id, type, dataset, opts) do
        {:ok, d} -> d
        _ -> nil
      end

    payload = %{
      event: :before_save,
      doc: attrs,
      dataset: dataset,
      prev_doc: prev_doc,
      ctx: ctx
    }

    case Barkpark.Plugins.Hooks.fire(:before_save, payload) do
      {:halt, reason} ->
        {:error, {:halted, reason}}

      :ok ->
        result =
          case prev_doc do
            %Document{} = existing ->
              existing
              |> Document.changeset(attrs)
              |> Repo.update()
              |> tap_broadcast(dataset, type, "update", existing.rev)

            _ ->
              attrs = scaffold_or_initial_values(attrs, type, dataset)

              %Document{}
              |> Document.changeset(attrs)
              |> Repo.insert()
              |> tap_broadcast(dataset, type, "create", nil)
          end

        result
        |> fire_after(:after_save, payload)
        |> tap_sheet_writethrough()
    end
  end

  @doc """
  Clone a document into a fresh draft. Copies `title` (with " (copy)"
  suffix) and the full `content` map verbatim, assigns a new generated
  id, and inserts via `create_document/3` so the draft prefix, status,
  and PubSub broadcast all go through the canonical write path.

  Returns `{:ok, new_doc}` on success or `{:error, changeset}` on
  insert failure. Used by the Studio's "Duplicate" header action.
  """
  @spec clone_document(map(), String.t(), String.t(), keyword()) ::
          {:ok, Document.t()} | {:error, term()}
  def clone_document(doc, type, dataset, opts \\ [])
      when is_map(doc) and is_binary(type) and is_binary(dataset) do
    new_id = generate_id(type)
    src_title = Map.get(doc, :title) || "Untitled"
    src_content = Map.get(doc, :content) || %{}

    create_document(
      type,
      %{
        "doc_id" => new_id,
        "title" => "#{src_title} (copy)",
        "status" => "draft",
        "content" => src_content
      },
      dataset,
      opts
    )
  end

  # ── Initial values (Sanity-style schema-declared defaults) ────────────────
  #
  # When a schema declares an `initial_values` map, those keys pre-fill the
  # content of a newly created document. Provided values always win — the
  # initial_values map is a FLOOR, never a ceiling.
  #
  # Maps merge deeply. Lists do NOT merge (a provided list replaces the
  # initial list wholesale — recursive list merging is ambiguous and a
  # publisher who provides a list almost always means "use exactly this").
  #
  # Dynamic tokens resolved at create time only:
  #   * `"$today"`      → today's ISO-8601 date string (e.g. "2026-05-14")
  #   * `"$today.year"` → today's year as a 4-digit string (e.g. "2026")

  defp apply_initial_values(attrs, type, dataset)
       when is_binary(type) and is_binary(dataset) do
    initial =
      case get_schema(type, dataset) do
        {:ok, %SchemaDefinition{initial_values: iv}} when is_map(iv) and map_size(iv) > 0 ->
          resolve_dynamics(iv)

        _ ->
          nil
      end

    case initial do
      nil ->
        attrs

      iv ->
        provided = Map.get(attrs, "content") || %{}
        Map.put(attrs, "content", deep_merge(iv, provided))
    end
  end

  defp apply_initial_values(attrs, _type, _dataset), do: attrs

  # ── Exp-P3.1 — Create-from-Expectation scaffold ──────────────────────────
  #
  # On creating a new document of an EXPECTATION-BEARING type — a type whose
  # schema carries an EXPLICIT stored `layout` (e.g. `post`; see seeds) — the
  # Expectation is instantiated into `content["blocks"]`: one BOUND block per
  # layout field (valued from provided content / row title / prefill / empty)
  # plus the body region as free blocks (an empty paragraph placeholder when
  # none provided). Then `Projection.project/3` derives `content[fieldName]` +
  # `content["body"]` from those blocks — replacing the flat
  # `apply_initial_values` for these types.
  #
  # A type with NO explicit layout (a plain v1 schema relying only on flat
  # `initial_values`, or no schema at all) keeps the unchanged
  # `apply_initial_values` path. The explicit-layout gate is what marks a type
  # as Expectation-bearing here — a derived-default layout alone does not flip
  # an existing v1 type onto the block path (it would silently drop
  # initial_values keys that are not declared fields).
  defp scaffold_or_initial_values(attrs, type, dataset)
       when is_binary(type) and is_binary(dataset) do
    case get_schema(type, dataset) do
      {:ok, %SchemaDefinition{layout: layout} = schema}
      when is_list(layout) and layout != [] ->
        scaffold_expectation(attrs, schema, dataset)

      _ ->
        apply_initial_values(attrs, type, dataset)
    end
  end

  defp scaffold_or_initial_values(attrs, type, dataset),
    do: apply_initial_values(attrs, type, dataset)

  # Build the scaffold block list from the schema's Expectation + provided
  # values, persist it under content["blocks"], and project. The row title
  # lives on the document row, not under content — it is folded in under
  # "title" so a bound title field-block picks it up, and re-derived into
  # content["title"] by projection (mirroring synthesize_blocks/3).
  defp scaffold_expectation(attrs, %SchemaDefinition{} = schema, dataset) do
    %{layout: layout, prefill: prefill} = resolve_expectation(schema)
    prefill = resolve_dynamics(prefill)
    provided = Map.get(attrs, "content") || %{}

    values =
      provided
      |> Map.put_new("title", Map.get(attrs, "title"))
      |> drop_nil_values()

    blocks = Synthesis.scaffold(layout, values, prefill, schema.fields || [])

    content =
      provided
      |> Map.put("blocks", blocks)
      |> Projection.project(blocks, render_opts(dataset))

    Map.put(attrs, "content", content)
  end

  defp drop_nil_values(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      if is_nil(v), do: acc, else: Map.put(acc, k, v)
    end)
  end

  @doc false
  def deep_merge(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn _k, av, bv ->
      cond do
        is_map(av) and is_map(bv) -> deep_merge(av, bv)
        true -> bv
      end
    end)
  end

  def deep_merge(_a, b), do: b

  @doc false
  def resolve_dynamics(term) when is_map(term) do
    Map.new(term, fn {k, v} -> {k, resolve_dynamics(v)} end)
  end

  def resolve_dynamics(list) when is_list(list), do: Enum.map(list, &resolve_dynamics/1)

  def resolve_dynamics("$today"), do: Date.utc_today() |> Date.to_iso8601()

  def resolve_dynamics("$today.year"),
    do: Date.utc_today().year |> Integer.to_string()

  def resolve_dynamics(other), do: other

  @doc """
  Publish a document: copy draft content to published ID, delete draft.
  If no draft exists, returns error.

  `opts` accepts `:source` and `:user_id` for lifecycle-hook context.
  Fires `:before_publish` (halt-capable) and `:after_publish` (async).
  """
  def publish_document(published_doc_id, type, dataset, opts \\ []) do
    did = draft_id(published_doc_id)
    pid = published_id(published_doc_id)

    case get_document(did, type, dataset, opts) do
      {:ok, draft} ->
        ctx = build_ctx(opts)

        payload = %{
          event: :before_publish,
          doc: draft,
          dataset: dataset,
          prev_doc: draft,
          ctx: ctx
        }

        case Barkpark.Plugins.Hooks.fire(:before_publish, payload) do
          {:halt, reason} ->
            {:error, {:halted, reason}}

          :ok ->
            # Upsert the published version with draft's content. Inherit the
            # draft's tenancy scope so a publish never drops workspace_id/
            # project_id on the published row.
            pub_attrs =
              %{
                "doc_id" => pid,
                "type" => type,
                "dataset" => dataset,
                "title" => draft.title,
                "status" => "published",
                "content" => draft.content,
                "rev" => generate_rev()
              }
              |> inherit_scope_attrs(draft)

            {pub_result, prev_pub_rev} =
              case get_document(pid, type, dataset, opts) do
                {:ok, existing} ->
                  {existing |> Document.changeset(pub_attrs) |> Repo.update(), existing.rev}

                _ ->
                  {%Document{} |> Document.changeset(pub_attrs) |> Repo.insert(), nil}
              end

            result =
              case pub_result do
                {:ok, published} ->
                  # Delete the draft
                  Repo.delete(draft)
                  tap_broadcast({:ok, published}, dataset, type, "publish", prev_pub_rev)

                error ->
                  error
              end

            fire_after(result, :after_publish, payload)
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Unpublish: move published doc back to draft, delete published version.

  `opts` accepts `:source` and `:user_id`. Fires `:before_unpublish`
  (halt-capable) and `:after_unpublish` (async).
  """
  def unpublish_document(published_doc_id, type, dataset, opts \\ []) do
    pid = published_id(published_doc_id)
    did = draft_id(published_doc_id)

    case get_document(pid, type, dataset, opts) do
      {:ok, pub} ->
        ctx = build_ctx(opts)

        payload = %{
          event: :before_unpublish,
          doc: pub,
          dataset: dataset,
          prev_doc: pub,
          ctx: ctx
        }

        case Barkpark.Plugins.Hooks.fire(:before_unpublish, payload) do
          {:halt, reason} ->
            {:error, {:halted, reason}}

          :ok ->
            # Create draft with published content. Inherit the published row's
            # tenancy scope so an unpublish keeps workspace_id/project_id.
            draft_attrs =
              %{
                "doc_id" => did,
                "type" => type,
                "dataset" => dataset,
                "title" => pub.title,
                "status" => "draft",
                "content" => pub.content,
                "rev" => generate_rev()
              }
              |> inherit_scope_attrs(pub)

            {draft_result, prev_draft_rev} =
              case get_document(did, type, dataset, opts) do
                {:ok, existing} ->
                  {existing |> Document.changeset(draft_attrs) |> Repo.update(), existing.rev}

                _ ->
                  {%Document{} |> Document.changeset(draft_attrs) |> Repo.insert(), nil}
              end

            result =
              case draft_result do
                {:ok, draft} ->
                  Repo.delete(pub)
                  tap_broadcast({:ok, draft}, dataset, type, "unpublish", prev_draft_rev)

                error ->
                  error
              end

            fire_after(result, :after_unpublish, payload)
        end

      error ->
        error
    end
  end

  @doc "Discard a draft without publishing. Published version (if any) remains."
  def discard_draft(published_doc_id, type, dataset, opts \\ []) do
    did = draft_id(published_doc_id)

    case get_document(did, type, dataset, opts) do
      {:ok, draft} ->
        prev_rev = draft.rev

        Repo.delete(draft)
        |> tap_broadcast(dataset, type, "discardDraft", prev_rev)

      error ->
        error
    end
  end

  @doc """
  Delete both the published and draft variants of a document.

  `opts` accepts `:source` and `:user_id`. Fires `:before_delete`
  (halt-capable) and `:after_delete` (async). The payload's `:doc` and
  `:prev_doc` carry the about-to-be-deleted document (the published row
  if present, otherwise the draft).
  """
  def delete_document(doc_id, type, dataset, opts \\ []) do
    pid = published_id(doc_id)
    did = draft_id(doc_id)

    existing =
      [pid, did]
      |> Enum.map(fn id -> get_document(id, type, dataset, opts) end)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, doc} -> doc end)

    case existing do
      [] ->
        {:error, :not_found}

      [target | _] = docs ->
        ctx = build_ctx(opts)

        payload = %{
          event: :before_delete,
          doc: target,
          dataset: dataset,
          prev_doc: target,
          ctx: ctx
        }

        case Barkpark.Plugins.Hooks.fire(:before_delete, payload) do
          {:halt, reason} ->
            {:error, {:halted, reason}}

          :ok ->
            [{first_result, prev_rev} | _] =
              Enum.map(docs, fn doc -> {Repo.delete(doc), doc.rev} end)

            result = tap_broadcast(first_result, dataset, type, "delete", prev_rev)
            fire_after(result, :after_delete, payload)
        end
    end
  end

  @doc """
  Apply a batch of mutations atomically. Returns `{:ok, {transaction_id, results}}`
  or `{:error, reason}` with rollback on any failure.

  `opts` accepts `:source` and `:user_id` and is threaded into every
  per-mutation Content call so lifecycle-hook context (`ctx.source`,
  `ctx.user_id`) is set correctly for each fired hook.

  PubSub broadcasts queued inside the transaction are flushed AFTER a
  successful commit, and discarded on rollback — no ghost events on
  the SSE stream when a batch fails partway through.
  """
  def apply_mutations(mutations, dataset, opts \\ []) when is_list(mutations) do
    # Initialise the deferred-broadcast queue for this process so
    # tap_broadcast/5 knows to queue instead of broadcast immediately.
    Process.put(:barkpark_deferred_broadcasts, [])

    try do
      result =
        Repo.transaction(fn ->
          tx_id = generate_rev()

          results =
            Enum.map(mutations, fn m ->
              case apply_one(m, dataset, opts) do
                {:ok, doc, op} -> %{id: doc.doc_id, operation: op, document: Envelope.render(doc)}
                {:error, reason} -> Repo.rollback(reason)
              end
            end)

          {tx_id, results}
        end)

      case result do
        {:ok, _} ->
          flush_deferred_broadcasts()
          result

        _ ->
          clear_deferred_broadcasts()
          result
      end
    rescue
      e ->
        clear_deferred_broadcasts()
        reraise(e, __STACKTRACE__)
    end
  end

  defp apply_one(%{"create" => attrs}, dataset, opts) do
    type = attrs["_type"] || attrs["type"]
    id = attrs["_id"] || attrs["doc_id"]

    # A create must NOT overwrite an existing draft. Skip the lookup when
    # type/id are missing — let create_document/3 surface a validation error
    # (Ecto rejects nil equality comparisons in queries).
    existing =
      if id && type do
        case get_document(draft_id(id), type, dataset, opts) do
          {:ok, doc} -> doc
          _ -> nil
        end
      end

    case existing do
      %_{} = doc ->
        case if_rev(attrs) do
          nil -> {:error, :conflict}
          expected -> {:error, {:rev_mismatch, %{expected: expected, actual: doc.rev}}}
        end

      _ ->
        with {:ok, doc} <- create_document(type, attrs, dataset, opts), do: {:ok, doc, "create"}
    end
  end

  defp apply_one(%{"createOrReplace" => attrs}, dataset, opts) do
    type = attrs["_type"] || attrs["type"]
    id = attrs["_id"] || attrs["doc_id"]
    expected = if_rev(attrs)

    existing =
      case id && get_document(draft_id(id), type, dataset, opts) do
        {:ok, doc} -> doc
        _ -> nil
      end

    with :ok <- ensure_rev(existing, expected),
         {:ok, doc} <- create_document(type, attrs, dataset, opts) do
      {:ok, doc, "createOrReplace"}
    end
  end

  defp apply_one(%{"createIfNotExists" => attrs}, dataset, opts) do
    type = attrs["_type"] || attrs["type"]
    id = attrs["_id"] || attrs["doc_id"]

    case id && get_document(draft_id(id), type, dataset, opts) do
      {:ok, existing} ->
        case ensure_rev(existing, if_rev(attrs)) do
          :ok -> {:ok, existing, "noop"}
          err -> err
        end

      _ ->
        with {:ok, doc} <- create_document(type, attrs, dataset, opts), do: {:ok, doc, "create"}
    end
  end

  defp apply_one(%{"publish" => %{"id" => id, "type" => type}}, dataset, opts) do
    with {:ok, doc} <- publish_document(id, type, dataset, opts), do: {:ok, doc, "publish"}
  end

  defp apply_one(%{"unpublish" => %{"id" => id, "type" => type}}, dataset, opts) do
    with {:ok, doc} <- unpublish_document(id, type, dataset, opts), do: {:ok, doc, "unpublish"}
  end

  defp apply_one(%{"discardDraft" => %{"id" => id, "type" => type}}, dataset, opts) do
    with {:ok, doc} <- discard_draft(id, type, dataset, opts), do: {:ok, doc, "discardDraft"}
  end

  defp apply_one(%{"delete" => %{"id" => id, "type" => type} = op}, dataset, opts) do
    case if_rev(op) do
      nil ->
        with {:ok, doc} <- delete_document(id, type, dataset, opts), do: {:ok, doc, "delete"}

      expected ->
        with {:ok, existing} <- get_document(id, type, dataset, opts),
             :ok <- ensure_rev(existing, expected),
             {:ok, doc} <- delete_document(id, type, dataset, opts) do
          {:ok, doc, "delete"}
        end
    end
  end

  defp apply_one(%{"replace" => attrs}, dataset, opts) do
    type = attrs["_type"] || attrs["type"]
    id = attrs["_id"] || attrs["doc_id"]

    with {:ok, existing} <- get_document(id && draft_id(id), type, dataset, opts),
         :ok <- ensure_rev(existing, if_rev(attrs)),
         {:ok, doc} <- create_document(type, attrs, dataset, opts) do
      {:ok, doc, "replace"}
    end
  end

  defp apply_one(
         %{"patch" => %{"id" => id, "type" => type, "set" => fields} = patch},
         dataset,
         opts
       ) do
    with {:ok, existing} <- get_document(id, type, dataset, opts),
         :ok <- ensure_rev(existing, if_rev(patch)) do
      merged =
        Map.merge(
          existing.content || %{},
          Map.drop(fields, ~w(title status _id _type _rev))
        )

      attrs = %{
        "doc_id" => id,
        "title" => fields["title"] || existing.title,
        "content" => merged
      }

      with {:ok, doc} <- upsert_document(type, attrs, dataset, opts), do: {:ok, doc, "update"}
    end
  end

  defp apply_one(_, _, _), do: {:error, :malformed}

  defp if_rev(%{} = attrs), do: attrs["ifRevisionID"] || attrs["ifMatch"]
  defp if_rev(_), do: nil

  defp ensure_rev(_doc, nil), do: :ok
  defp ensure_rev(_doc, ""), do: :ok

  defp ensure_rev(nil, expected),
    do: {:error, {:rev_mismatch, %{expected: expected, actual: nil}}}

  defp ensure_rev(%{rev: r}, r), do: :ok

  defp ensure_rev(%{rev: actual}, expected),
    do: {:error, {:rev_mismatch, %{expected: expected, actual: actual}}}

  @doc """
  Find all documents that reference a given document ID.

  `opts` may carry `:workspace_id` / `:project_id`; when present the schema
  scan and the per-type document scan are scoped to that tenant so the
  reference search never crosses the workspace boundary (barkpark-af50).
  Callers that pass no scope keep the explicit-global behaviour.
  """
  def find_referencing_docs(doc_id, dataset, opts \\ []) do
    pub_id = published_id(doc_id)
    schemas = list_schemas(dataset, opts)

    # Find all schema fields that are references
    ref_fields =
      for schema <- schemas,
          field <- schema.fields,
          field["type"] == "reference",
          do: {schema.name, field["name"]}

    # Search each type for docs that reference this ID. The predicate
    # (`content->>field == pub_id`) is pushed into SQL via the `:filter_map`
    # eq op so the DB returns ONLY the referencing rows — was a full
    # load-all-of-type per reference field followed by an in-memory
    # Enum.filter (barkpark-sji2). Scope opts (workspace/project/dataset) stay
    # threaded as before. limit: 1000 so a high fan-in reference is not
    # truncated by the default 100-row cap.
    Enum.flat_map(ref_fields, fn {type_name, field_name} ->
      ref_opts =
        opts
        |> Keyword.put(:perspective, :raw)
        |> Keyword.put(:filter_map, %{field_name => pub_id})
        |> Keyword.put_new(:limit, 1000)

      list_documents(type_name, dataset, ref_opts)
      |> Enum.map(fn doc ->
        %{doc_id: doc.doc_id, type: type_name, title: doc.title, field: field_name}
      end)
    end)
  end

  @doc """
  Remove all references to a document ID from other documents.

  `opts` may carry `:workspace_id` / `:project_id` — threaded into both the
  referencing-doc scan and the per-doc read so the disconnect stays inside the
  tenant boundary (barkpark-af50).
  """
  def disconnect_references(doc_id, dataset, opts \\ []) do
    _pub_id = published_id(doc_id)
    refs = find_referencing_docs(doc_id, dataset, opts)

    Enum.each(refs, fn %{doc_id: ref_doc_id, type: type, field: field} ->
      case get_document(ref_doc_id, type, dataset, opts) do
        {:ok, doc} ->
          updated_content = Map.delete(doc.content || %{}, field)
          prev_rev = doc.rev

          doc
          |> Document.changeset(%{"content" => updated_content, "rev" => generate_rev()})
          |> Repo.update()
          |> tap_broadcast(dataset, type, "update", prev_rev)

        _ ->
          :ok
      end
    end)
  end

  # ── Sheet formula recompute (M3) ────────────────────────────────────────────
  #
  # A "sheet" save recomputes every formula cell's cached "v" BEFORE the row
  # persists — `Barkpark.Sheets.Engine.recompute/1` runs in the attrs pipeline
  # of `create_document/4` and `upsert_document/4`, so the stored content
  # carries computed values and the write-through below projects them into
  # embed snapshots with zero renderer changes. The engine is pure and total:
  # non-sheet types and writes without a "tabs" list pass through untouched.

  defp maybe_recompute_sheet_formulas(attrs, "sheet") do
    case Map.get(attrs, "content") do
      %{"tabs" => _} = content ->
        Map.put(attrs, "content", Barkpark.Sheets.Engine.recompute(content))

      _ ->
        attrs
    end
  end

  defp maybe_recompute_sheet_formulas(attrs, _type), do: attrs

  # ── Sheet embed write-through ───────────────────────────────────────────────
  #
  # A `{"type":"sheet","ref":<sheet doc id>}` block in any document's
  # `content["blocks"]` carries a cached `"snapshot"` — the dense value grid
  # `Barkpark.Sheets.snapshot_for/2` synthesizes from the sheet's sparse cells.
  # The snapshot is what keeps the block rendering with the Sheets plugin off
  # (fresh-install invariant), so it must never go stale: every successful save
  # of a `"sheet"` document rewrites the snapshot in all same-scope documents
  # embedding it, in the same logical operation.
  #
  # Targeting is JSONB containment (`content @> {"blocks":[{"type":"sheet",
  # "ref":…}]}`) so the DB returns ONLY embedding rows — the same predicate
  # push-down discipline as `find_referencing_docs/3`, never a full scan.
  # Refreshed docs persist through the direct changeset + `tap_broadcast` tail
  # `disconnect_references/3` uses, so revisions land and PubSub fires for every
  # refreshed doc. The direct path cannot re-enter this trigger (only
  # `create_document/4` / `upsert_document/4` call it), so a sheet embedding
  # another sheet terminates after one refresh level, and the query excludes the
  # sheet's own rows — a sheet never embeds itself.

  defp tap_sheet_writethrough({:ok, %Document{type: "sheet"} = sheet} = result) do
    refresh_sheet_embeds(sheet)
    result
  end

  defp tap_sheet_writethrough(result), do: result

  defp refresh_sheet_embeds(%Document{} = sheet) do
    # Match both id forms: papers canonically embed the published id, but the
    # mutated row is (almost always) the draft — and a block authored against
    # the draft id must refresh too.
    pub_id = published_id(sheet.doc_id)
    refs = [pub_id, draft_id(pub_id)]

    sheet
    |> sheet_embed_targets(refs)
    |> Enum.each(&refresh_doc_sheet_snapshots(&1, refs, sheet.content || %{}))
  end

  # Same-scope embedding rows. `dataset_id` is the authoritative scope key when
  # the sheet row carries one (W2); legacy/unscoped rows fall back to the
  # dataset STRING + nil-safe workspace match, so a fresh sandbox without the
  # tenancy backfill still resolves its own scope and never crosses another's.
  defp sheet_embed_targets(%Document{} = sheet, refs) do
    [embed_a, embed_b] = Enum.map(refs, &%{"blocks" => [%{"type" => "sheet", "ref" => &1}]})

    base =
      from d in Document,
        where: d.doc_id not in ^refs,
        where:
          fragment("? @> ?", d.content, ^embed_a) or
            fragment("? @> ?", d.content, ^embed_b)

    scoped =
      cond do
        sheet.dataset_id ->
          where(base, [d], d.dataset_id == ^sheet.dataset_id)

        sheet.workspace_id ->
          where(base, [d], d.dataset == ^sheet.dataset and d.workspace_id == ^sheet.workspace_id)

        true ->
          where(base, [d], d.dataset == ^sheet.dataset and is_nil(d.workspace_id))
      end

    Repo.all(scoped)
  end

  defp refresh_doc_sheet_snapshots(%Document{} = doc, refs, sheet_content) do
    content = doc.content || %{}
    blocks = Map.get(content, "blocks") || []

    {blocks, changed?} =
      Enum.map_reduce(blocks, false, fn block, changed ->
        if is_map(block) and Map.get(block, "type") == "sheet" and
             Map.get(block, "ref") in refs do
          snapshot = Barkpark.Sheets.snapshot_for(sheet_content, embed_tab_index(block))
          {Map.put(block, "snapshot", snapshot), true}
        else
          {block, changed}
        end
      end)

    if changed? do
      # Re-derive everything downstream of the refreshed blocks: the paper
      # body_html cache (when the doc carries one — upsert_paper's render of
      # the full block list) and the projected content[fieldName] /
      # content["body"] keys, whose html also embeds the rendered grid.
      # Projection remains the SOLE writer of the projected keys.
      render_opts = paper_render_opts(doc.dataset, Map.get(content, "style"))

      content =
        case content do
          %{"body_html" => _} ->
            Map.put(content, "body_html", Render.render_blocks(blocks, render_opts))

          _ ->
            content
        end

      content =
        content
        |> Map.put("blocks", blocks)
        |> Projection.project(blocks, render_opts)

      doc
      |> Document.changeset(%{"content" => content, "rev" => generate_rev()})
      |> Repo.update()
      |> tap_broadcast(doc.dataset, doc.type, "update", doc.rev)
    end

    :ok
  end

  defp embed_tab_index(block) do
    case Map.get(block, "tab") do
      i when is_integer(i) and i >= 0 -> i
      _ -> 0
    end
  end

  # ── Sheet embed hydration (M0a) ─────────────────────────────────────────────
  #
  # The write-through above keeps embed snapshots fresh when the SHEET saves;
  # this is its mirror for the EMBEDDING side. A document save whose blocks
  # introduce or change `{"type":"sheet","ref":…}` blocks hydrates each
  # block's `"snapshot"` from the referenced sheet IMMEDIATELY — same
  # `Barkpark.Sheets.snapshot_for/2` projection, same per-block `"tab"`,
  # same scope ladder — so a paper embedding an EXISTING sheet renders its
  # values on the first read instead of an empty grid until the sheet's next
  # save. ONE batched query fetches every referenced sheet (both id forms,
  # draft preferred — the freshest content, matching what the write-through
  # last projected); a ref that resolves to nothing leaves its block
  # untouched (the renderer keeps the valid empty-grid placeholder), and a
  # self-reference is skipped — the mirror of the write-through's
  # `doc_id not in refs` exclusion, so a sheet embedding itself terminates.
  # Runs pre-write in the attrs pipeline (zero extra writes); a save without
  # sheet blocks costs zero extra queries.

  defp hydrate_sheet_embed_snapshots(attrs) do
    content = Map.get(attrs, "content")

    case content && Map.get(content, "blocks") do
      blocks when is_list(blocks) ->
        blocks = hydrate_sheet_blocks(blocks, attrs, Map.get(attrs, "doc_id"))
        Map.put(attrs, "content", Map.put(content, "blocks", blocks))

      _ ->
        attrs
    end
  end

  defp hydrate_sheet_blocks(blocks, scope, self_id) do
    self_root = self_id && published_id(self_id)

    refs =
      for %{"type" => "sheet", "ref" => ref} <- blocks,
          is_binary(ref) and ref != "" and published_id(ref) != self_root,
          uniq: true,
          do: published_id(ref)

    case refs do
      [] ->
        blocks

      refs ->
        sheets = fetch_embedded_sheets(refs, scope)

        Enum.map(blocks, fn block ->
          with %{"type" => "sheet", "ref" => ref} when is_binary(ref) <- block,
               %{} = sheet_content <- Map.get(sheets, published_id(ref)) do
            snapshot = Barkpark.Sheets.snapshot_for(sheet_content, embed_tab_index(block))
            Map.put(block, "snapshot", snapshot)
          else
            _ -> block
          end
        end)
    end
  end

  # Same-scope sheet rows for the refs an embedding doc carries — the reverse
  # of `sheet_embed_targets/2`, same scope ladder (`dataset_id` authoritative,
  # workspace + dataset STRING, then unscoped dataset STRING). Returns a map
  # of published root → sheet content; when a ref has both a draft and a
  # published row the DRAFT wins.
  defp fetch_embedded_sheets(refs, scope) do
    ids = refs ++ Enum.map(refs, &draft_id/1)
    dataset = Map.get(scope, "dataset")
    dataset_id = Map.get(scope, "dataset_id")
    workspace_id = Map.get(scope, "workspace_id")

    base = from d in Document, where: d.type == "sheet", where: d.doc_id in ^ids

    scoped =
      cond do
        dataset_id ->
          where(base, [d], d.dataset_id == ^dataset_id)

        workspace_id ->
          where(base, [d], d.dataset == ^dataset and d.workspace_id == ^workspace_id)

        true ->
          where(base, [d], d.dataset == ^dataset and is_nil(d.workspace_id))
      end

    scoped
    |> Repo.all()
    |> Enum.reduce(%{}, fn doc, acc ->
      root = published_id(doc.doc_id)

      if draft?(doc.doc_id) or not Map.has_key?(acc, root) do
        Map.put(acc, root, doc.content || %{})
      else
        acc
      end
    end)
  end

  @reserved_in ~w(_id _type _rev _draft _publishedId _createdAt _updatedAt doc_id type dataset rev title status content)

  defp from_envelope(attrs) do
    cond do
      # Already legacy shape — pass through, but honor a Sanity-style "_id"
      # when no "doc_id" was given. Mixing `_id` with a nested `content` map
      # used to silently DROP the supplied id (create fell back to a generated
      # task-### id), which broke every doc example that followed the id.
      Map.has_key?(attrs, "content") and is_map(Map.get(attrs, "content")) ->
        case {Map.get(attrs, "doc_id"), Map.get(attrs, "_id")} do
          {nil, id} when is_binary(id) and id != "" -> Map.put(attrs, "doc_id", id)
          _ -> attrs
        end

      true ->
        id = Map.get(attrs, "_id") || Map.get(attrs, "doc_id")
        title = Map.get(attrs, "title")
        status = Map.get(attrs, "status", "draft")
        content = Map.drop(attrs, @reserved_in)

        %{
          "doc_id" => id,
          "title" => title,
          "status" => status,
          "content" => content
        }
    end
  end

  defp generate_id(type) do
    "#{type}-#{:rand.uniform(999_999)}"
  end

  defp generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  # ── Legacy upsert (for backward compat) ───────────────────────────────────

  @doc """
  Upsert a document — used by autosave and patch paths.

  `opts` accepts `:source` and `:user_id`. Fires `:before_save` and
  `:after_save` around the DB write, same contract as `create_document/4`.
  """
  def upsert_document(type, attrs, dataset, opts \\ []) do
    attrs = from_envelope(attrs)
    raw_id = Map.get(attrs, "doc_id") || Map.get(attrs, :doc_id)
    doc_id = raw_id && draft_id(raw_id)

    attrs =
      attrs
      |> Map.put("doc_id", doc_id)
      |> Map.put("type", type)
      |> Map.put("dataset", dataset)
      |> Map.put_new("status", "draft")
      |> Map.put("rev", generate_rev())
      |> put_scope_attrs(opts)
      |> maybe_recompute_sheet_formulas(type)
      |> hydrate_sheet_embed_snapshots()
      # Project-on-write on the DOCUMENT path (Exp-P3.1): a whole-doc write that
      # carries content["blocks"] re-derives content[fieldName]/content["body"]
      # from those blocks — the same project-on-write the paper path runs.
      # Projection stays the SOLE writer of those keys; a write WITHOUT blocks
      # (legacy field-map save) skips it untouched.
      |> maybe_project_document_content(dataset)

    with :ok <- validate_task_kind(type, attrs) do
      do_upsert_document(type, attrs, dataset, doc_id, opts)
    end
  end

  defp do_upsert_document(type, attrs, dataset, doc_id, opts) do
    ctx = build_ctx(opts)

    # Scope the prev-doc lookup to the writer's workspace/project (mirror of
    # create_document:654). An UNSCOPED lookup here would resolve (and then
    # UPDATE/overwrite) another workspace's row sharing the (doc_id, type,
    # dataset) leaf — the write-path scoping gap. Scoped, a same-id write from
    # a different workspace sees no prev_doc and inserts its own row.
    prev_doc =
      case doc_id && get_document(doc_id, type, dataset, opts) do
        {:ok, d} -> d
        _ -> nil
      end

    payload = %{
      event: :before_save,
      doc: attrs,
      dataset: dataset,
      prev_doc: prev_doc,
      ctx: ctx
    }

    case Barkpark.Plugins.Hooks.fire(:before_save, payload) do
      {:halt, reason} ->
        {:error, {:halted, reason}}

      :ok ->
        result =
          case prev_doc do
            %Document{} = existing ->
              existing
              |> Document.changeset(attrs)
              |> Repo.update()
              |> tap_broadcast(dataset, type, "update", existing.rev)

            _ ->
              %Document{}
              |> Document.changeset(attrs)
              |> Repo.insert()
              |> tap_broadcast(dataset, type, "create", nil)
          end

        result
        |> fire_after(:after_save, payload)
        |> tap_sheet_writethrough()
    end
  end

  # Re-project content[fieldName]/content["body"] from content["blocks"] when a
  # whole-document write carries a block list (Exp-P3.1 — generalizes the
  # paper-path project-on-write to the document path). A write whose content has
  # no "blocks" key is returned untouched, so legacy field-map saves are
  # unaffected and projection remains the SOLE writer of the projected keys.
  defp maybe_project_document_content(attrs, dataset) do
    content = Map.get(attrs, "content")

    case content && Map.get(content, "blocks") do
      blocks when is_list(blocks) ->
        Map.put(attrs, "content", Projection.project(content, blocks, render_opts(dataset)))

      _ ->
        attrs
    end
  end

  # ── Lifecycle-hook helpers ────────────────────────────────────────────────
  #
  # `build_ctx/1` constructs the `ctx` map every hook payload carries. The
  # `:source` field is the recursion guard — plugins inspect it (e.g.
  # `ctx.source == :worker`) to short-circuit hooks they themselves fired.
  # `fire_after/3` only fires after_* on a successful write; errors flow
  # through untouched so existing `{:error, changeset}` paths keep working.

  defp build_ctx(opts) do
    %{
      source: Keyword.get(opts, :source, :api),
      user_id: Keyword.get(opts, :user_id)
    }
  end

  # Stamp the tenancy scope onto write attrs when the caller supplied it via
  # opts (`:workspace_id` / `:project_id`). Only non-nil scope keys are added,
  # so a write WITHOUT scope opts leaves attrs untouched — the Document
  # changeset only casts these keys when present, so an existing row's
  # workspace_id/project_id is never nulled by an unscoped update. New rows
  # created under a resolved scope are stamped on insert from that scope.
  #
  # W2 dual-write: alongside the workspace/project scope, resolve the row's
  # `dataset` STRING → its `dataset_id` (within the resolved project) and stamp
  # BOTH. The string stays the safety-net mirror; `dataset_id` is the new
  # authoritative scoping key. Degrades to no `dataset_id` key (string-only)
  # when the project or dataset string can't be resolved — never crashes a
  # write, and the changeset leaves an existing row's dataset_id untouched.
  defp put_scope_attrs(attrs, opts) do
    {ws_id, project_id} = resolve_write_scope(attrs, opts)
    dataset_id = resolve_dataset_id_for_write(attrs, project_id)

    attrs
    |> maybe_put_scope_attr("workspace_id", ws_id)
    |> maybe_put_scope_attr("project_id", project_id)
    |> maybe_put_scope_attr("dataset_id", dataset_id)
  end

  # Resolve the `dataset_id` to stamp on a write from the row's `dataset` STRING
  # + the resolved `project_id`. Returns the id, or nil when either is missing
  # (the caller then stamps nothing — keeping the string-only mirror). Uses
  # get_or_create_dataset so a brand-new dataset string lands a row on first
  # write rather than silently dropping the id.
  defp resolve_dataset_id_for_write(attrs, project_id) do
    dataset = Map.get(attrs, "dataset") || Map.get(attrs, :dataset)

    cond do
      is_nil(project_id) or not is_binary(dataset) ->
        nil

      true ->
        case Barkpark.Tenancy.get_or_create_dataset(project_id, dataset) do
          {:ok, %Barkpark.Tenancy.Dataset{id: id}} -> id
          _ -> nil
        end
    end
  end

  # Resolve the {workspace_id, project_id} to stamp on a write. Explicit scope
  # (opts, or an existing scope key already in attrs) ALWAYS wins. When the
  # caller supplied no scope at all, fall back to the seeded Default Workspace /
  # Default Project so unscoped (nil) fixtures land in Default and stay visible
  # to Default-scoped flat-route reads. Degrades to nil when the backfill hasn't
  # run yet (fresh test sandbox before seed) — never crashes.
  #
  # Workspace-only scope (barkpark-wykb): the `scope_to_workspace(q, ws, nil)`
  # contract lets a caller pass workspace_id WITHOUT a project_id. Without
  # resolution that write got workspace_id stamped but dataset_id=NULL (the
  # dataset_id resolver below short-circuits on a nil project) — invisible to a
  # strict dataset_id reader in its own scope. So when we hold a workspace but
  # no project, resolve the WORKSPACE'S OWN default project (prefer the
  # "default"-slug project, else the first project of that workspace) and stamp
  # it, which lets the dataset_id resolve too. NEVER-WORSE: if the workspace has
  # no projects, project_id stays nil (and dataset_id stays NULL) — the
  # yx7f NULL-tolerant read still finds the row.
  defp resolve_write_scope(attrs, opts) do
    opt_ws = Keyword.get(opts, :workspace_id)
    opt_proj = Keyword.get(opts, :project_id)

    cond do
      not is_nil(opt_ws) and is_nil(opt_proj) ->
        {opt_ws, default_project_id_for_workspace(opt_ws)}

      not is_nil(opt_ws) ->
        {opt_ws, opt_proj}

      scope_key_present?(attrs) ->
        {opt_ws, opt_proj}

      true ->
        ws = Barkpark.Tenancy.get_default_workspace()
        proj = Barkpark.Tenancy.get_default_project()
        {ws && ws.id, proj && proj.id}
    end
  end

  # Resolve a workspace's OWN default project id for a workspace-only write.
  # Prefers the project whose slug is "default", else the first project (the
  # list is slug-ordered). Returns nil when the workspace has no projects —
  # the caller then keeps the nil project_id (and the dataset_id resolver
  # keeps dataset_id NULL), never crashing.
  defp default_project_id_for_workspace(ws_id) when is_binary(ws_id) do
    case Barkpark.Tenancy.list_projects(ws_id) do
      [] ->
        nil

      projects ->
        project = Enum.find(projects, &(&1.slug == "default")) || hd(projects)
        project.id
    end
  end

  defp default_project_id_for_workspace(_), do: nil

  defp scope_key_present?(attrs) do
    Map.has_key?(attrs, "workspace_id") or Map.has_key?(attrs, :workspace_id)
  end

  # W2 read-scope: resolve the incoming `dataset` STRING → its `dataset_id`
  # within the read's project scope (opts `:project_id`, else the seeded Default
  # project). Returns the id, or nil when no matching dataset row exists — in
  # which case the caller keeps the legacy `dataset` STRING filter (back-compat:
  # a read against a never-written dataset string returns no rows either way).
  # Read-only (Repo.get_by) — never creates a dataset on a read path.
  #
  # Public so search read paths (DocumentsRetriever) can resolve the same
  # dataset_id and filter authoritatively instead of on the bare `dataset`
  # STRING, which conflates same-name datasets within a workspace (barkpark-y9ee).
  @doc false
  def resolve_read_dataset_id(dataset, opts) when is_binary(dataset) do
    # Project resolution — only fall back to the seeded Default project when
    # the caller passed NO scope at all (flat back-compat read). When the
    # caller pinned a workspace but no project, falling back to Default's
    # project crosses tenants: get_dataset(default_proj, dataset) can match a
    # same-named dataset row under Default and the resolver returns Default's
    # dataset_id, which scope_to_dataset then applies as a strict
    # `dataset_id == default_ds_id` filter that excludes the workspace's own
    # rows (barkpark-sknf, surfaced when 5znv memo no longer hides it). With
    # `workspace_id` present and `project_id` absent the resolver returns nil
    # → scope_to_dataset uses the legacy STRING path, and the subsequent
    # `scope_to_workspace_or_global` filter keeps the read tenant-correct.
    project_id =
      cond do
        pid = Keyword.get(opts, :project_id) -> pid
        Keyword.has_key?(opts, :workspace_id) -> nil
        true -> read_default_project_id(opts)
      end

    # Per-request memoization (barkpark-5znv, gated barkpark-sknf): a single
    # public HTTP read fans this resolve across schema_public? + list_documents
    # + schema_hash_for_dataset (~9 calls), all for the immutable {project_id,
    # dataset} pair. The result (id OR nil) is keyed in the Process dictionary.
    #
    # The memo is GATED on an explicit `memoize: true` opt that ONLY HTTP
    # request controllers set via `ScopeHelpers.scope_opts(conn)`. LiveView
    # callers, Oban workers, mix tasks, and search retrievers DON'T pass the
    # opt → no memo → no staleness. The original 5znv goal (collapse the 9
    # redundant get_dataset reads on a single HTTP request) is preserved; the
    # staleness foot-gun in long-lived processes (LV session lifetime, reused
    # Oban worker pids, sandbox-reused test pids) is closed.
    #
    # The resolved id is identical to the uncached path — only the redundant
    # get_dataset roundtrips are skipped on the request path.
    memoize?(opts, {:resolve_read_dataset_id, project_id, dataset}, fn ->
      case project_id && Barkpark.Tenancy.get_dataset(project_id, dataset) do
        %Barkpark.Tenancy.Dataset{id: id} -> id
        _ -> nil
      end
    end)
  end

  def resolve_read_dataset_id(_dataset, _opts), do: nil

  # The Default project id is immutable within a request; memoize it so the
  # no-`:project_id` (flat/back-compat) route resolves get_default_project once
  # — collapsing get_default_workspace + get_default_project (2 reads) that
  # otherwise repeated on every resolve call within the same request.
  #
  # Same gating as resolve_read_dataset_id (barkpark-sknf): memoization only
  # fires when the caller opted in via `memoize: true`. LV/worker callers see
  # the fresh-every-call path.
  defp read_default_project_id(opts \\ []) do
    memoize?(opts, :read_default_project_id, fn ->
      case Barkpark.Tenancy.get_default_project() do
        %{id: id} -> id
        _ -> nil
      end
    end)
  end

  # Per-request memo helper, gated on an explicit `memoize: true` opt
  # (barkpark-sknf). When the opt is absent the fun is invoked fresh and
  # nothing is written to the Process dictionary — long-lived LV/Oban/test
  # processes never accumulate stale memos. When the opt is present the
  # result is cached under `key` in the Process dictionary, distinguishing
  # "cached nil" from "not yet computed" via a private sentinel so a
  # legitimately-nil resolution is not recomputed.
  @memo_miss :"$barkpark_memo_miss"
  defp memoize?(opts, key, fun) do
    if Keyword.get(opts, :memoize, false) do
      case Process.get({:barkpark_request_memo, key}, @memo_miss) do
        @memo_miss ->
          value = fun.()
          Process.put({:barkpark_request_memo, key}, value)
          value

        value ->
          value
      end
    else
      fun.()
    end
  end

  # Apply the W2 dataset scope to a read query. When the dataset string resolves
  # to a `dataset_id`, filter authoritatively by `x.dataset_id` BUT also match
  # rows whose `dataset_id` is NULL and whose `dataset` STRING equals the
  # requested one — legacy/unstamped rows the strict filter would drop (asset
  # docs, non-Default-project rows the 132000 backfill skipped, workspace-only
  # writes). This mirrors scope_schema_to_dataset/3. The dataset STRING and
  # dataset_id are 1:1 within a project, so the OR never crosses datasets.
  # Never-worse: stamped rows still match strictly by dataset_id; NULL rows
  # recover the legacy string match. Otherwise fall back to the legacy
  # `x.dataset` STRING filter (the mirror still works for datasets that predate
  # a row or live outside the resolved project).
  defp scope_to_dataset(query, dataset, opts) do
    case resolve_read_dataset_id(dataset, opts) do
      id when is_binary(id) ->
        where(query, [x], x.dataset_id == ^id or (is_nil(x.dataset_id) and x.dataset == ^dataset))

      _ ->
        where(query, [x], x.dataset == ^dataset)
    end
  end

  # Schema-specific dataset scope. Like scope_to_dataset, but ALSO matches rows
  # whose `dataset_id` is NULL but whose `dataset` STRING equals the requested
  # one — legacy/pre-tenancy schema fixtures that the W2 dual-write never
  # stamped. The dataset STRING and dataset_id are 1:1 within a project, so the
  # OR never crosses datasets; get_schema/3 orders dataset_id-first + limit 1 to
  # resolve the (rare) backfilled-vs-fixture overlap deterministically.
  defp scope_schema_to_dataset(query, dataset, opts) do
    case resolve_read_dataset_id(dataset, opts) do
      id when is_binary(id) ->
        where(query, [s], s.dataset_id == ^id or (is_nil(s.dataset_id) and s.dataset == ^dataset))

      _ ->
        where(query, [s], s.dataset == ^dataset)
    end
  end

  defp maybe_put_scope_attr(attrs, _key, nil), do: attrs
  defp maybe_put_scope_attr(attrs, key, value), do: Map.put(attrs, key, value)

  # Copy the tenancy scope (workspace_id/project_id) from a source document
  # onto write attrs — used by the draft↔published transitions (publish /
  # unpublish) so the moved row keeps the scope of the row it was derived from.
  # A nil source field is skipped, leaving the destination as-is.
  defp inherit_scope_attrs(attrs, %Document{
         workspace_id: ws_id,
         project_id: project_id,
         dataset_id: dataset_id
       }) do
    attrs
    |> maybe_put_scope_attr("workspace_id", ws_id)
    |> maybe_put_scope_attr("project_id", project_id)
    |> maybe_put_scope_attr("dataset_id", dataset_id)
  end

  defp inherit_scope_attrs(attrs, _), do: attrs

  defp fire_after({:ok, doc}, event, payload) do
    after_payload = %{payload | event: event, doc: doc}
    _ = Barkpark.Plugins.Hooks.fire(event, after_payload)
    {:ok, doc}
  end

  defp fire_after(other, _event, _payload), do: other

  # ── Schema Definitions ────────────────────────────────────────────────────

  @doc """
  The default dataset for a bare Studio landing (no `:dataset` in the URL).

  The `dataset` string is the leaf content discriminator and is orthogonal to
  the workspace/project tenancy envelope (see `Barkpark.Content.Scope`): the
  Default-tenancy backfill assigned the seeded Default workspace/project to all
  pre-tenancy rows, which live under the `"production"` dataset. So the Default
  scope's content is the `"production"` dataset. Resolving it here gives the
  Studio LiveView, the dashboard, and the bare-`/studio` redirect ONE source
  of truth instead of three scattered `"production"` literals.
  """
  @spec default_dataset() :: String.t()
  def default_dataset, do: "production"

  @doc """
  Return the dataset slugs OWNED by a project, sorted alphabetically.
  Always includes `"production"` so a brand-new project still has something to
  show.

  Datasets are project-owned (the `dataset` STRING is unique only *within* a
  project), so this scopes to a project rather than listing globally. The arity
  resolves to:

    * `list_datasets(project_id)` — the slugs of that project's datasets.
    * `list_datasets/0` — defaults to the seeded Default project (the legacy
      flat-route landing where no workspace/project is in scope). Degrades to a
      bare `"production"` when no Default project exists (fresh sandbox).

  Reads the `dataset` STRING mirror (filtered by `project_id`) rather than the
  Tenancy `datasets` table so pre-`get_or_create_dataset` fixtures still list.
  """
  def list_datasets(project_id \\ :default)

  def list_datasets(:default), do: list_datasets(read_default_project_id())

  def list_datasets(nil), do: ["production"]

  def list_datasets(project_id) when is_binary(project_id) do
    from_schemas =
      from(s in SchemaDefinition,
        where: s.project_id == ^project_id,
        select: s.dataset,
        distinct: true
      )
      |> Repo.all()

    from_docs =
      from(d in Document,
        where: d.project_id == ^project_id,
        select: d.dataset,
        distinct: true
      )
      |> Repo.all()

    (from_schemas ++ from_docs ++ ["production"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def list_schemas(dataset, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    SchemaDefinition
    |> scope_schema_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    # dataset_id-bearing rows before legacy nil-dataset_id fixtures, then dedup
    # by name — one catalog entry per type even on a backfill/fixture overlap.
    |> order_by([s], asc: s.name, asc_nulls_last: s.dataset_id)
    |> Repo.all()
    |> Enum.uniq_by(& &1.name)
  end

  def get_schema(name, dataset, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    SchemaDefinition
    |> where([s], s.name == ^name)
    |> scope_schema_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    # A backfilled row (dataset_id set) and a legacy nil-dataset_id fixture of
    # the same name can both match the dataset-OR-string scope. Prefer the
    # backfilled (dataset_id-bearing) row and take exactly one — deterministic.
    |> order_by([s], asc_nulls_last: s.dataset_id)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      schema -> {:ok, schema}
    end
  end

  @doc """
  Resolve the full Expectation for a schema definition.

  An Expectation is the schema PLUS its SOFT `layout` (ordered field-refs +
  free-content region markers) and `prefill` (create-time scaffold). Explicit
  stored `layout`/`prefill` columns win when non-empty; otherwise a field-order
  default is derived (`SchemaDefinition.default_layout/1` + `default_prefill/1`)
  so nothing has to migrate. The layout is metadata, never a constraint — a
  document with missing or reordered fields is always valid.

  Returns `%{layout: [map()], prefill: map()}`.
  """
  @spec resolve_expectation(SchemaDefinition.t()) :: %{layout: [map()], prefill: map()}
  def resolve_expectation(%SchemaDefinition{} = schema) do
    SchemaDefinition.resolve_expectation(schema)
  end

  def upsert_schema(attrs, dataset, opts \\ []) do
    name = Map.get(attrs, "name") || Map.get(attrs, :name)

    attrs =
      attrs
      |> Map.put("dataset", dataset)
      |> put_scope_attrs(opts)

    case name && get_schema(name, dataset, opts) do
      {:ok, existing} ->
        existing
        |> SchemaDefinition.changeset(attrs)
        |> Repo.update()

      _ ->
        %SchemaDefinition{}
        |> SchemaDefinition.changeset(attrs)
        |> Repo.insert()
    end
  end

  def delete_schema(name, dataset, opts \\ []) do
    case get_schema(name, dataset, opts) do
      {:ok, schema} -> Repo.delete(schema)
      error -> error
    end
  end

  @doc """
  Whether the schema's public-read gate is open for `type` in `dataset`.

  Threads the caller's tenancy `opts` (`[workspace_id:, project_id:]`) into
  `get_schema/3` so the visibility flag is read from the SAME tenant the row
  read resolves to — never the Default project. Without `opts` (the flat /
  legacy plug caller) it resolves against the Default scope, preserving prior
  behavior. See barkpark-su54: closing the latent split-brain where the gate
  and the row-read could read visibility from two different tenants.
  """
  def schema_public?(type, dataset, opts \\ []) do
    case get_schema(type, dataset, opts) do
      {:ok, %{visibility: "public"}} -> true
      _ -> false
    end
  end

  @doc """
  Returns the union of CORS origin allow-lists across all schemas in the dataset.

  An empty list means "no dataset-level policy" (default-allow).
  A list containing `"*"` means "public, any origin".
  Otherwise the list is an explicit allow-list of origin strings.
  """
  @spec allowed_origins_for_dataset(String.t(), keyword()) :: [String.t()]
  def allowed_origins_for_dataset(dataset, opts \\ []) when is_binary(dataset) do
    SchemaDefinition
    |> scope_to_dataset(dataset, opts)
    |> select([s], s.cors_origins)
    |> Repo.all()
    |> List.flatten()
    |> Enum.uniq()
  end

  def schema_hash_for_dataset(dataset, opts \\ []) when is_binary(dataset) do
    SchemaDefinition
    |> scope_to_dataset(dataset, opts)
    |> select([s], {count(s.id), max(s.updated_at)})
    |> Repo.one()
    |> hash_schema_tuple()
  end

  @doc """
  Deterministic 16-char hex content hash of a single schema definition.
  Derived from `{name, fields sorted by name}` so it changes iff the schema
  body changes, regardless of row metadata (updated_at, id).
  """
  def schema_hash_for_schema(%SchemaDefinition{} = schema) do
    normalized_fields =
      (schema.fields || [])
      |> Enum.map(&stringify_keys/1)
      |> Enum.sort_by(& &1["name"])

    payload = :erlang.term_to_binary({schema.name, normalized_fields})

    :crypto.hash(:sha256, payload)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc """
  Render a single schema in SDK envelope shape, with `schemaHash`,
  per-field `required?`, and `of`/`to` specs where applicable.
  """
  def serialize_schema_for_sdk(%SchemaDefinition{} = schema) do
    %{
      id: schema.name,
      name: schema.name,
      title: schema.title,
      icon: schema.icon,
      visibility: schema.visibility,
      schemaHash: schema_hash_for_schema(schema),
      fields: Enum.map(schema.fields || [], &serialize_field/1),
      actions: schema.actions || [],
      groups: schema.groups || [],
      deskGroups: schema.desk_groups || [],
      crossValidations: schema.cross_validations || [],
      # Generic list-row preview declaration (badge + meta content fields);
      # empty map == no declaration, SDK/TUI rows render unchanged.
      listPreview: schema.list_preview || %{}
    }
  end

  @doc """
  List every schema in a dataset in SDK envelope shape, plus a
  top-level `datasetSchemaHash` mirroring `schema_hash_for_dataset/1`.
  """
  def list_schemas_for_sdk(dataset, opts \\ []) when is_binary(dataset) do
    schemas = list_schemas(dataset, opts)

    %{
      schemas: Enum.map(schemas, &serialize_schema_for_sdk/1),
      datasetSchemaHash: schema_hash_for_dataset(dataset)
    }
  end

  defp serialize_field(field) do
    f = stringify_keys(field)
    type = f["type"]

    base = Map.put(f, "required?", truthy?(f["required"]))

    base
    |> maybe_put_of(type, f)
    |> maybe_put_to(type, f)
  end

  defp maybe_put_of(out, "array", f) do
    of =
      cond do
        is_list(f["of"]) ->
          Enum.map(f["of"], &element_spec/1)

        is_list(get_in(f, ["options", "list"])) ->
          Enum.map(f["options"]["list"], &element_spec/1)

        true ->
          [%{"type" => "string"}]
      end

    Map.put(out, "of", of)
  end

  defp maybe_put_of(out, _type, _f), do: out

  defp maybe_put_to(out, "reference", f) do
    to =
      cond do
        is_list(f["to"]) ->
          Enum.map(f["to"], &element_spec/1)

        is_list(get_in(f, ["options", "references"])) ->
          Enum.map(f["options"]["references"], &element_spec/1)

        is_binary(f["refType"]) ->
          [%{"type" => f["refType"]}]

        true ->
          []
      end

    Map.put(out, "to", to)
  end

  defp maybe_put_to(out, _type, _f), do: out

  defp element_spec(%{} = spec) do
    spec
    |> stringify_keys()
    |> Map.take(["type", "to", "name"])
  end

  defp element_spec(type) when is_binary(type), do: %{"type" => type}
  defp element_spec(_), do: %{"type" => "string"}

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp stringify_keys(%{} = m) do
    Map.new(m, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  def schema_hash_for_all_datasets do
    from(s in SchemaDefinition,
      group_by: s.dataset,
      select: {s.dataset, count(s.id), max(s.updated_at)}
    )
    |> Repo.all()
    |> Map.new(fn {ds, n, t} -> {ds, hash_schema_tuple({n, t})} end)
  end

  defp hash_schema_tuple({nil, nil}), do: "0000000000000000"

  defp hash_schema_tuple({n, t}) do
    payload = "#{n}|#{inspect(t)}"
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  # ── Analytics ───────────────────────────────────────────────────────────

  @doc "Count documents grouped by type, with published/draft breakdown."
  def document_stats(dataset, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Document
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> group_by([d], d.type)
    |> select([d], %{
      type: d.type,
      total: count(d.id),
      published: count(fragment("CASE WHEN ? NOT LIKE 'drafts.%' THEN 1 END", d.doc_id)),
      drafts: count(fragment("CASE WHEN ? LIKE 'drafts.%' THEN 1 END", d.doc_id))
    })
    |> order_by([d], asc: d.type)
    |> Repo.all()
  end

  @doc "Count total documents in a dataset."
  def total_documents(dataset, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Document
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> select([d], count(d.id))
    |> Repo.one()
  end

  @doc "Recent mutation activity — last N events."
  def recent_activity(dataset, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    MutationEvent
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> select([e], %{
      id: e.id,
      type: e.type,
      doc_id: e.doc_id,
      mutation: e.mutation,
      timestamp: e.inserted_at
    })
    |> Repo.all()
  end

  # ── PubSub ────────────────────────────────────────────────────────────────
  #
  # Broadcasts are DEFERRED when we're inside an Ecto transaction (e.g.
  # apply_mutations/2). They land in the process dict and are flushed by
  # flush_deferred_broadcasts/0 after the transaction commits. If the
  # transaction rolls back, clear_deferred_broadcasts/0 discards them
  # (no ghost events on the SSE stream). Direct writes outside a
  # transaction broadcast immediately — same behaviour as before.

  @doc """
  Broadcast an ALREADY-PERSISTED document mutation on the canonical PubSub
  topics — the public seam for writers that bypass `tap_broadcast/5` (the
  task lifecycle paths in `Barkpark.Tasks`, `Tasks.TtlSweeper`,
  `Tasks.Compactor`, which mutate `documents` rows via CAS-guarded
  `Repo.update_all` and write their own `mutation_events` rows).

  Emits the SAME message shape `tap_broadcast/5` emits, on the SAME three
  topics, so every existing subscriber (the `/v1/data/listen/:dataset` SSE
  controller, StudioLive's list + per-doc handlers, the nextjs revalidate
  consumer) consumes task-op events with zero changes:

    * `documents:<dataset>`                      — `{:document_changed, msg}`
    * `doc:ws:<ws>:<dataset>:<type>:<pubid>`     — `{:doc_updated, msg}`
    * `documents:ws:<workspace_id>:<dataset>`    — `{:document_changed, msg}`
      (only when the doc carries a workspace_id)

  This module stays the single owner of the topic shapes — callers never
  build topic strings themselves.

  ## Options
    * `:event_id` — the caller's `mutation_events` row id. REQUIRED for the
      SSE path: the listen controller pattern-matches on `event_id` and
      drops messages without one (it's also the SSE `id:` used for
      Last-Event-ID resume).
    * `:previous_rev` — the rev the caller observed before its CAS write.

  `mutation` is the caller's mutation kind string (e.g. `"task.claimed"`) —
  it matches the `mutation` column of the caller's `mutation_events` row, so
  a live SSE frame and a Last-Event-ID replayed frame carry the same kind.

  IMPORTANT: call AFTER the writing transaction commits. This broadcasts
  immediately (no transaction-deferral) — firing it inside an open
  transaction would let subscribers read state that may still roll back.
  """
  @spec broadcast_document_mutation(Document.t(), String.t(), keyword()) :: :ok
  def broadcast_document_mutation(%Document{} = doc, mutation, opts \\ [])
      when is_binary(mutation) do
    event_id = Keyword.get(opts, :event_id)
    previous_rev = Keyword.get(opts, :previous_rev)
    dataset = doc.dataset

    msg = %{
      event_id: event_id,
      type: doc.type,
      mutation: mutation,
      action: :mutate,
      doc_id: doc.doc_id,
      rev: doc.rev,
      previous_rev: previous_rev,
      workspace_id: doc.workspace_id,
      project_id: doc.project_id,
      document: Envelope.render(doc),
      doc: %{
        doc_id: doc.doc_id,
        title: doc.title,
        status: doc.status,
        content: doc.content,
        updated_at: doc.updated_at
      },
      sender: self()
    }

    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      "documents:#{dataset}",
      {:document_changed, msg}
    )

    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      doc_topic(published_id(doc.doc_id), doc.type, doc.workspace_id, dataset),
      {:doc_updated, msg}
    )

    if doc.workspace_id do
      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        "documents:ws:#{doc.workspace_id}:#{dataset}",
        {:document_changed, msg}
      )
    end

    :ok
  end

  defp tap_broadcast(result, dataset, type, action, prev_rev) do
    case result do
      {:ok, doc} ->
        save_revision(doc, type, dataset, action)
        ev = save_event(doc, type, dataset, action, prev_rev)

        msg = %{
          event_id: ev.id,
          type: type,
          mutation: action,
          action: :mutate,
          doc_id: doc.doc_id,
          rev: doc.rev,
          previous_rev: prev_rev,
          # Additive workspace/project context (LOCKED #10): existing
          # subscribers ignore unknown keys; the nextjs revalidate consumer
          # and workspace-scoped subscribers filter on these.
          workspace_id: doc.workspace_id,
          project_id: doc.project_id,
          document: Envelope.render(doc),
          doc: %{
            doc_id: doc.doc_id,
            title: doc.title,
            status: doc.status,
            content: doc.content,
            updated_at: doc.updated_at
          },
          sender: self()
        }

        global_topic = "documents:#{dataset}"

        # Workspace-scope the per-doc topic (barkpark-rwva, P1 sibling of
        # barkpark-n56v). doc_ids/pubids are per-workspace, so the old
        # workspace-less `doc:<dataset>:<type>:<pubid>` topic collapsed two
        # tenants' colliding-id docs onto ONE topic — an editor in A could
        # receive B's `{:doc_updated,…}`. Stamping the doc's workspace_id keeps
        # them distinct; StudioLive subscribes with current_workspace.id and
        # both sides normalize nil identically (see doc_topic/3).
        doc_topic = doc_topic(published_id(doc.doc_id), type, doc.workspace_id, dataset)

        maybe_broadcast(global_topic, {:document_changed, msg})
        maybe_broadcast(doc_topic, {:doc_updated, msg})

        # Additional workspace-scoped topic so consumers can subscribe by
        # workspace without filtering the global stream. ADDITIVE — the
        # global `documents:#{dataset}` topic above is untouched.
        if doc.workspace_id do
          maybe_broadcast(
            "documents:ws:#{doc.workspace_id}:#{dataset}",
            {:document_changed, msg}
          )
        end

        maybe_dispatch_webhook(dataset, action, type, doc.doc_id, msg.document, ev.id,
          workspace_id: doc.workspace_id,
          project_id: doc.project_id
        )

        {:ok, doc}

      error ->
        error
    end
  end

  # Defer if we're inside a transaction; broadcast immediately otherwise.
  defp maybe_broadcast(topic, msg) do
    if Repo.in_transaction?() do
      queue = Process.get(:barkpark_deferred_broadcasts, [])
      Process.put(:barkpark_deferred_broadcasts, [{topic, msg} | queue])
    else
      Phoenix.PubSub.broadcast(Barkpark.PubSub, topic, msg)
    end
  end

  # Defer webhook dispatch when inside a transaction, fire immediately otherwise.
  # `opts` carries `:workspace_id` / `:project_id` so the delivered payload
  # emits workspace/project-scoped sync-tags.
  defp maybe_dispatch_webhook(dataset, action, type, doc_id, document, event_id, opts) do
    if Repo.in_transaction?() do
      queue = Process.get(:barkpark_deferred_webhooks, [])

      Process.put(
        :barkpark_deferred_webhooks,
        [{dataset, action, type, doc_id, document, event_id, opts} | queue]
      )
    else
      Barkpark.Webhooks.Dispatcher.dispatch_async(
        dataset,
        action,
        type,
        doc_id,
        document,
        event_id,
        opts
      )
    end
  end

  # Flush broadcasts queued during a successful transaction, preserving
  # their original order (the queue is built by prepending).
  defp flush_deferred_broadcasts do
    queue = Process.delete(:barkpark_deferred_broadcasts) || []

    queue
    |> Enum.reverse()
    |> Enum.each(fn {topic, msg} ->
      Phoenix.PubSub.broadcast(Barkpark.PubSub, topic, msg)
    end)

    webhook_queue = Process.delete(:barkpark_deferred_webhooks) || []

    webhook_queue
    |> Enum.reverse()
    |> Enum.each(fn {dataset, action, type, doc_id, document, event_id, opts} ->
      Barkpark.Webhooks.Dispatcher.dispatch_async(
        dataset,
        action,
        type,
        doc_id,
        document,
        event_id,
        opts
      )
    end)
  end

  defp clear_deferred_broadcasts do
    Process.delete(:barkpark_deferred_broadcasts)
    Process.delete(:barkpark_deferred_webhooks)
    :ok
  end

  defp save_event(doc, type, dataset, action, prev_rev) do
    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: dataset,
      type: type,
      doc_id: doc.doc_id,
      mutation: action,
      rev: doc.rev,
      previous_rev: prev_rev,
      document: Envelope.render(doc),
      # Stamp the tenancy scope from the source document so workspace-scoped
      # analytics (recent_activity) only surface a workspace's own events.
      # `dataset_id` is the authoritative dataset leaf (the `dataset` STRING is
      # the mirror): without it, recent_activity's dataset_id-scoped read would
      # miss this event and same-named datasets across projects would conflate.
      workspace_id: doc.workspace_id,
      project_id: doc.project_id,
      dataset_id: doc.dataset_id,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp save_revision(doc, type, dataset, action) do
    %Revision{}
    |> Revision.changeset(%{
      doc_id: published_id(doc.doc_id),
      type: type,
      dataset: dataset,
      dataset_id: doc.dataset_id,
      title: doc.title,
      status: doc.status,
      content: doc.content,
      action: action,
      # Stamp the tenancy scope from the source document so workspace-scoped
      # history reads only surface a workspace's own revisions. `dataset_id` is
      # the authoritative dataset leaf (the `dataset` STRING is the mirror) so a
      # dataset_id-scoped list_revisions read finds it and same-named datasets
      # across projects no longer conflate.
      workspace_id: doc.workspace_id,
      project_id: doc.project_id
    })
    |> Repo.insert()
  end

  # ── Search ──────────────────────────────────────────────────────────────

  @doc "Search documents by title using the QueryPipeline. Returns `{docs, count, meta}`."
  def search_documents(query, dataset, opts \\ []) do
    context = %{
      query: query,
      filters: %{"type" => Keyword.get(opts, :type)},
      offset: Keyword.get(opts, :offset, 0)
    }

    {:ok, result} = Barkpark.Search.QueryPipeline.search("documents", dataset, context, opts)

    meta = Map.take(result, [:parsed, :highlights, :recovery, :corrected_to, :facets, :truncation])
    {result.hits, result.total, meta}
  end

  # ── Export ──────────────────────────────────────────────────────────────

  @doc "Stream all documents for a dataset as envelope maps. Optionally filter by type."
  def export_stream(dataset, opts \\ []) do
    type = Keyword.get(opts, :type)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Document
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> then(fn q ->
      if type, do: where(q, [d], d.type == ^type), else: q
    end)
    |> order_by([d], asc: d.inserted_at)
    |> Repo.stream()
    |> Stream.map(&Envelope.render/1)
  end

  # ── Revision queries ──────────────────────────────────────────────────────

  @doc "List revisions for a document, newest first."
  def list_revisions(doc_id, type, dataset, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Revision
    |> where([r], r.doc_id == ^published_id(doc_id) and r.type == ^type)
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> order_by([r], desc: r.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Get a single revision by ID, scoped to a dataset and (optionally)
  workspace/project.

  Dataset scoping closes an intra-workspace IDOR: without it a member can read
  ANY revision in their workspace by UUID regardless of the dataset named in the
  URL. Workspace/project scoping additionally prevents cross-workspace reads of
  a guessed/leaked id. `scope_to_dataset` is NULL-tolerant (matches rows whose
  `dataset_id` is NULL but whose `dataset` STRING equals the requested one).
  """
  def get_revision(id, dataset, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Revision
    |> where([r], r.id == ^id)
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      rev -> {:ok, rev}
    end
  end

  @doc """
  Restore a document to a specific revision.

  `opts` is forwarded to `upsert_document/4` so callers can supply
  lifecycle-hook context (`:source`, `:user_id`).
  """
  def restore_revision(revision_id, type, dataset, opts \\ []) do
    with {:ok, rev} <- get_revision(revision_id, dataset, opts),
         :ok <- assert_revision_dataset(rev, dataset) do
      attrs = %{
        "doc_id" => draft_id(rev.doc_id),
        "title" => rev.title,
        "status" => rev.status,
        "content" => rev.content
      }

      upsert_document(type, attrs, dataset, opts)
    end
  end

  # Defence-in-depth on top of get_revision's dataset scoping: refuse to restore
  # a revision whose own `dataset` does not match the requested one, so a rev
  # from dataset A can never be re-upserted into dataset B within a workspace.
  defp assert_revision_dataset(%Revision{dataset: rev_dataset}, dataset)
       when rev_dataset == dataset,
       do: :ok

  defp assert_revision_dataset(_rev, _dataset), do: {:error, :not_found}

  # ── Papers — context functions ─────────────────────────────────────────────
  #
  # These operate on `documents` rows of type "paper". They preserve the Wave 4
  # streaming protocol exactly — only the storage moved from the dedicated
  # `papers` table into the unified `documents` table. The logic below is the
  # port of the former `Barkpark.Papers` context.

  @doc """
  The default dataset papers live under. Convergence: papers are now
  first-class documents in the `production` dataset (was `paperflow`),
  so they surface in the Studio desk at `/studio/production`.
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

  BulldocsLive subscribes to this; writes broadcast to it.
  """
  def paper_topic(slug, workspace_id, dataset \\ @paper_default_dataset)
      when is_binary(slug) do
    "doc:ws:#{normalize_topic_ws(workspace_id)}:#{dataset}:#{@paper_type}:#{slug}"
  end

  # Normalize a (possibly nil) workspace_id into the deterministic token both
  # the broadcast side and the subscribe side use to build a PubSub topic. A
  # present id passes through verbatim. A `nil` id (a legacy NULL-workspace
  # row) maps to the seeded Default workspace id — the public read path
  # (`get_public_paper/2`) resolves into exactly that workspace, so the two
  # sides agree. When NO Default is seeded (fresh sandbox) we fall back to a
  # literal `"global"` token so both sides STILL agree on a non-empty value.
  defp normalize_topic_ws(ws) when is_binary(ws) and ws != "", do: ws

  defp normalize_topic_ws(_nil_or_blank) do
    case Barkpark.Tenancy.get_default_workspace() do
      %{id: ws_id} when is_binary(ws_id) -> ws_id
      _ -> "global"
    end
  end

  @doc """
  Per-doc PubSub topic for an ordinary document, SCOPED to the owning
  workspace: `doc:ws:<workspace_id>:<dataset>:<type>:<pubid>`.

  WORKSPACE SCOPE (barkpark-rwva, P1): the old workspace-less
  `doc:<dataset>:<type>:<pubid>` topic collapsed two tenants' colliding
  `(type, pubid)` docs onto one topic, leaking `{:doc_updated,…}` across
  workspaces. The `ws:<workspace_id>` segment keeps them distinct. `pubid` is
  the PUBLISHED id (the caller applies `published_id/1`). Broadcaster
  (`tap_broadcast`) and subscriber (StudioLive `subscribe_to_doc`) MUST agree
  on `workspace_id`; both resolve a nil id through `normalize_topic_ws/1`.
  """
  def doc_topic(pubid, type, workspace_id, dataset)
      when is_binary(pubid) and is_binary(type) do
    "doc:ws:#{normalize_topic_ws(workspace_id)}:#{dataset}:#{type}:#{pubid}"
  end

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
    case get_document(slug, @paper_type, dataset, opts) do
      {:ok, doc} -> doc
      {:error, :not_found} -> nil
    end
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
  that is where the flat, unauthenticated paperflow ingest lands by Default
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
        case get_document(slug, type, dataset, workspace_id: ws_id) do
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
      case get_schema(type, dataset) do
        {:ok, schema} -> {resolve_expectation(schema).layout, schema.fields || []}
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

  def available_expected_fields(blocks, %{layout: layout}, schema)
      when is_list(blocks) and is_list(layout) do
    type_by_name = expected_field_type_index(schema)
    label_by_name = expected_field_label_index(schema)

    layout
    |> Enum.filter(&match?(%{"kind" => "field"}, &1))
    |> Enum.map(&expected_field_descriptor(&1, blocks, type_by_name, label_by_name))
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&field_at_cap?/1)
  end

  def available_expected_fields(_blocks, _expectation, _schema), do: []

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
          Map.delete(put_scope_attrs(%{"dataset" => dataset}, scope_opts), "dataset")

        existing ->
          %{}

        true ->
          Map.delete(put_scope_attrs(%{"dataset" => dataset}, []), "dataset")
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
          list |> ensure_block_ids() |> hydrate_sheet_blocks(embed_scope, slug)

        other ->
          other
      end

    # Per-doc article marker. An ingest/POST may set `style: "article"` in
    # attrs; otherwise it sticks at whatever the existing doc already carries
    # (so a partial update never silently demotes an article paper). Threaded
    # into render_opts so the body_html cache is rendered in the article palette.
    style = paper_style(attrs, existing)
    render_opts = paper_render_opts(dataset, style)

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
    # the moment paperflow starts sending the goal's scope. Absent it, this
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
      render_opts = paper_render_opts(dataset, style)
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
        # blocks and never drift.
        |> Projection.project(new_blocks, render_opts)

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
          render_opts = paper_render_opts(dataset, style)
          body_html = Render.render_blocks(new_blocks, render_opts)

          content =
            (doc.content || %{})
            |> Map.put("blocks", new_blocks)
            |> Map.put("body_html", body_html)
            |> Map.put("rev", rev)
            |> Projection.project(new_blocks, render_opts)

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
    with {:ok, %Document{} = doc} <- get_document(doc_id, type, dataset, opts),
         {blocks, _synth?} = resolve_blocks_for_edit(doc, type, dataset),
         {:ok, new_blocks} <- Patch.apply_patch(blocks, op),
         {:ok, affected} <- locate_paper_affected(op, new_blocks) do
      content =
        (doc.content || %{})
        |> Map.put("blocks", new_blocks)
        # Project-on-write — the SOLE writer of content[fieldName]/content["body"]
        # for this document, identical to the paper path. Bound title → "title",
        # free body blocks → content["body"].
        |> Projection.project(new_blocks, render_opts(dataset))

      # Derive the row title from the bound title field if present (matches the
      # Classic-save title precedence), else keep the document's current title.
      new_title = blank_to_nil(Map.get(content, "title")) || doc.title

      attrs = %{
        "doc_id" => draft_id(published_id(doc_id)),
        "title" => new_title,
        "status" => doc.status,
        "content" => content
      }

      case upsert_document(type, attrs, dataset, opts) do
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
      paper_topic(doc.doc_id, doc.workspace_id, doc.dataset),
      msg
    )
  end

  defp broadcast_paper_block(slug, workspace_id, dataset, frame) do
    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      paper_topic(slug, workspace_id, dataset),
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
  # flat, unscoped paperflow ingest keeps upserting its own Default-scoped row.
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
    Projection.project(content, blocks, render_opts(dataset))
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
end
