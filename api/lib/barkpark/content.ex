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
  # `BarkparkWeb.PaperLive` keeps working with minimal change.
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
  """
  def list_documents(type, dataset, opts \\ []) do
    perspective = Keyword.get(opts, :perspective, :raw)
    filter_map = Keyword.get(opts, :filter_map, %{})
    limit = opts |> Keyword.get(:limit, 100) |> min(1000) |> max(1)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    order = Keyword.get(opts, :order, :updated_at_desc)

    base =
      Document
      |> where([d], d.type == ^type and d.dataset == ^dataset)
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

  def get_document(doc_id, type, dataset)
      when is_nil(doc_id) or is_nil(type) or is_nil(dataset) do
    {:error, :not_found}
  end

  def get_document(doc_id, type, dataset) do
    Document
    |> where([d], d.doc_id == ^doc_id and d.type == ^type and d.dataset == ^dataset)
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
  @spec reference_title(String.t() | nil, String.t() | nil, String.t()) :: String.t()
  def reference_title(value, ref_type, dataset)

  def reference_title(value, _ref_type, _dataset) when value in [nil, ""], do: value || ""

  def reference_title(value, ref_type, dataset) when is_binary(value) do
    pub_id = published_id(value)
    draft = draft_id(pub_id)

    query =
      Document
      |> where([d], d.dataset == ^dataset)
      |> where([d], d.doc_id == ^pub_id or d.doc_id == ^draft)
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

  @doc """
  Fetch a document with draft-first preference. Returns the draft if it
  exists, otherwise falls back to the published row, plus flags for
  whether the returned doc is the draft and whether a published version
  exists. Used by StudioLive's native editor pane — consolidated in
  Task #11 WI3 from prior duplicates (the plugin LVs that originally
  shared this helper were removed in Goal `barkpark-zdy`).

      {doc | nil, is_draft :: boolean, has_published :: boolean}
  """
  @spec fetch_doc_with_draft(String.t(), String.t(), String.t()) ::
          {Document.t() | nil, boolean(), boolean()}
  def fetch_doc_with_draft(type, doc_id, dataset) do
    pub_id = published_id(doc_id)
    draft_r = get_document(draft_id(pub_id), type, dataset)
    pub_r = get_document(pub_id, type, dataset)

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
  duplicates in StudioLive (`doc_to_form`, `doc_data_to_form`),
  DocumentEditLive (orphan), and the deleted plugin BookEditor.
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
            else: get_in(doc.content || %{}, [key]) || ""

        Map.put(acc, key, val)
      end)
    else
      base
    end
  end

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
      if key in ["title", "status"] or val == "", do: acc, else: Map.put(acc, key, val)
    end)
  end

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

        base_content
        |> Map.put("blocks", new_blocks)
        |> Projection.project(new_blocks, render_opts(dataset))

      _ ->
        build_content(params, schema)
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

    ctx = build_ctx(opts)

    prev_doc =
      case get_document(doc_id, type, dataset) do
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

        fire_after(result, :after_save, payload)
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

    case get_document(did, type, dataset) do
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
            # Upsert the published version with draft's content
            pub_attrs = %{
              "doc_id" => pid,
              "type" => type,
              "dataset" => dataset,
              "title" => draft.title,
              "status" => "published",
              "content" => draft.content,
              "rev" => generate_rev()
            }

            {pub_result, prev_pub_rev} =
              case get_document(pid, type, dataset) do
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

    case get_document(pid, type, dataset) do
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
            # Create draft with published content
            draft_attrs = %{
              "doc_id" => did,
              "type" => type,
              "dataset" => dataset,
              "title" => pub.title,
              "status" => "draft",
              "content" => pub.content,
              "rev" => generate_rev()
            }

            {draft_result, prev_draft_rev} =
              case get_document(did, type, dataset) do
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
  def discard_draft(published_doc_id, type, dataset) do
    did = draft_id(published_doc_id)

    case get_document(did, type, dataset) do
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
      |> Enum.map(fn id -> get_document(id, type, dataset) end)
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
        case get_document(draft_id(id), type, dataset) do
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
      case id && get_document(draft_id(id), type, dataset) do
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

    case id && get_document(draft_id(id), type, dataset) do
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

  defp apply_one(%{"discardDraft" => %{"id" => id, "type" => type}}, dataset, _opts) do
    with {:ok, doc} <- discard_draft(id, type, dataset), do: {:ok, doc, "discardDraft"}
  end

  defp apply_one(%{"delete" => %{"id" => id, "type" => type} = op}, dataset, opts) do
    case if_rev(op) do
      nil ->
        with {:ok, doc} <- delete_document(id, type, dataset, opts), do: {:ok, doc, "delete"}

      expected ->
        with {:ok, existing} <- get_document(id, type, dataset),
             :ok <- ensure_rev(existing, expected),
             {:ok, doc} <- delete_document(id, type, dataset, opts) do
          {:ok, doc, "delete"}
        end
    end
  end

  defp apply_one(%{"replace" => attrs}, dataset, opts) do
    type = attrs["_type"] || attrs["type"]
    id = attrs["_id"] || attrs["doc_id"]

    with {:ok, existing} <- get_document(id && draft_id(id), type, dataset),
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
    with {:ok, existing} <- get_document(id, type, dataset),
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

  @doc "Find all documents that reference a given document ID."
  def find_referencing_docs(doc_id, dataset) do
    pub_id = published_id(doc_id)
    schemas = list_schemas(dataset)

    # Find all schema fields that are references
    ref_fields =
      for schema <- schemas,
          field <- schema.fields,
          field["type"] == "reference",
          do: {schema.name, field["name"]}

    # Search each type for docs that reference this ID
    Enum.flat_map(ref_fields, fn {type_name, field_name} ->
      list_documents(type_name, dataset, perspective: :raw)
      |> Enum.filter(fn doc ->
        val = get_in(doc.content || %{}, [field_name])
        val == pub_id
      end)
      |> Enum.map(fn doc ->
        %{doc_id: doc.doc_id, type: type_name, title: doc.title, field: field_name}
      end)
    end)
  end

  @doc "Remove all references to a document ID from other documents."
  def disconnect_references(doc_id, dataset) do
    _pub_id = published_id(doc_id)
    refs = find_referencing_docs(doc_id, dataset)

    Enum.each(refs, fn %{doc_id: ref_doc_id, type: type, field: field} ->
      case get_document(ref_doc_id, type, dataset) do
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

  @reserved_in ~w(_id _type _rev _draft _publishedId _createdAt _updatedAt doc_id type dataset rev title status content)

  defp from_envelope(attrs) do
    cond do
      # Already legacy shape — pass through unchanged
      Map.has_key?(attrs, "content") and is_map(Map.get(attrs, "content")) ->
        attrs

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
      # Project-on-write on the DOCUMENT path (Exp-P3.1): a whole-doc write that
      # carries content["blocks"] re-derives content[fieldName]/content["body"]
      # from those blocks — the same project-on-write the paper path runs.
      # Projection stays the SOLE writer of those keys; a write WITHOUT blocks
      # (legacy field-map save) skips it untouched.
      |> maybe_project_document_content(dataset)

    ctx = build_ctx(opts)

    prev_doc =
      case doc_id && get_document(doc_id, type, dataset) do
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

        fire_after(result, :after_save, payload)
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

  defp fire_after({:ok, doc}, event, payload) do
    after_payload = %{payload | event: event, doc: doc}
    _ = Barkpark.Plugins.Hooks.fire(event, after_payload)
    {:ok, doc}
  end

  defp fire_after(other, _event, _payload), do: other

  # ── Schema Definitions ────────────────────────────────────────────────────

  @doc """
  Return all datasets known to the system, sorted alphabetically.
  Always includes `"production"` so a brand-new DB still has something to show.
  """
  def list_datasets do
    from_schemas =
      from(s in SchemaDefinition, select: s.dataset, distinct: true)
      |> Repo.all()

    from_docs =
      from(d in Document, select: d.dataset, distinct: true)
      |> Repo.all()

    (from_schemas ++ from_docs ++ ["production"])
    |> Enum.uniq()
    |> Enum.sort()
  end

  def list_schemas(dataset) do
    SchemaDefinition
    |> where([s], s.dataset == ^dataset)
    |> order_by([s], asc: s.name)
    |> Repo.all()
  end

  def get_schema(name, dataset) do
    SchemaDefinition
    |> where([s], s.name == ^name and s.dataset == ^dataset)
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

  def upsert_schema(attrs, dataset) do
    name = Map.get(attrs, "name") || Map.get(attrs, :name)
    attrs = Map.put(attrs, "dataset", dataset)

    case name && get_schema(name, dataset) do
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

  def delete_schema(name, dataset) do
    case get_schema(name, dataset) do
      {:ok, schema} -> Repo.delete(schema)
      error -> error
    end
  end

  def schema_public?(type, dataset) do
    case get_schema(type, dataset) do
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
  @spec allowed_origins_for_dataset(String.t()) :: [String.t()]
  def allowed_origins_for_dataset(dataset) when is_binary(dataset) do
    SchemaDefinition
    |> where([s], s.dataset == ^dataset)
    |> select([s], s.cors_origins)
    |> Repo.all()
    |> List.flatten()
    |> Enum.uniq()
  end

  def schema_hash_for_dataset(dataset) when is_binary(dataset) do
    from(s in SchemaDefinition,
      where: s.dataset == ^dataset,
      select: {count(s.id), max(s.updated_at)}
    )
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
      crossValidations: schema.cross_validations || []
    }
  end

  @doc """
  List every schema in a dataset in SDK envelope shape, plus a
  top-level `datasetSchemaHash` mirroring `schema_hash_for_dataset/1`.
  """
  def list_schemas_for_sdk(dataset) when is_binary(dataset) do
    schemas = list_schemas(dataset)

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
  def document_stats(dataset) do
    Document
    |> where([d], d.dataset == ^dataset)
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
  def total_documents(dataset) do
    Document
    |> where([d], d.dataset == ^dataset)
    |> select([d], count(d.id))
    |> Repo.one()
  end

  @doc "Recent mutation activity — last N events."
  def recent_activity(dataset, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    MutationEvent
    |> where([e], e.dataset == ^dataset)
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
        doc_topic = "doc:#{dataset}:#{type}:#{published_id(doc.doc_id)}"

        maybe_broadcast(global_topic, {:document_changed, msg})
        maybe_broadcast(doc_topic, {:doc_updated, msg})
        maybe_dispatch_webhook(dataset, action, type, doc.doc_id, msg.document, ev.id)

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
  defp maybe_dispatch_webhook(dataset, action, type, doc_id, document, event_id) do
    if Repo.in_transaction?() do
      queue = Process.get(:barkpark_deferred_webhooks, [])

      Process.put(
        :barkpark_deferred_webhooks,
        [{dataset, action, type, doc_id, document, event_id} | queue]
      )
    else
      Barkpark.Webhooks.Dispatcher.dispatch_async(
        dataset,
        action,
        type,
        doc_id,
        document,
        event_id
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
    |> Enum.each(fn {dataset, action, type, doc_id, document, event_id} ->
      Barkpark.Webhooks.Dispatcher.dispatch_async(
        dataset,
        action,
        type,
        doc_id,
        document,
        event_id
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
      title: doc.title,
      status: doc.status,
      content: doc.content,
      action: action
    })
    |> Repo.insert()
  end

  # ── Search ──────────────────────────────────────────────────────────────

  @doc "Search documents by title using ILIKE. Returns published docs by default."
  def search_documents(query, dataset, opts \\ []) do
    type = Keyword.get(opts, :type)
    perspective = Keyword.get(opts, :perspective, :published)
    limit = Keyword.get(opts, :limit, 50) |> min(200)
    offset = Keyword.get(opts, :offset, 0)

    pattern = "%" <> String.replace(query, "%", "\\%") <> "%"

    base =
      Document
      |> where([d], d.dataset == ^dataset)
      |> where([d], ilike(d.title, ^pattern))

    base = if type, do: where(base, [d], d.type == ^type), else: base

    base = search_perspective_filter(base, perspective)

    docs =
      base |> order_by([d], desc: d.updated_at) |> limit(^limit) |> offset(^offset) |> Repo.all()

    count = base |> select([d], count(d.id)) |> Repo.one()

    {docs, count}
  end

  defp search_perspective_filter(query, :published) do
    where(query, [d], not like(d.doc_id, "drafts.%"))
  end

  defp search_perspective_filter(query, :drafts) do
    where(query, [d], like(d.doc_id, "drafts.%"))
  end

  defp search_perspective_filter(query, _raw), do: query

  # ── Export ──────────────────────────────────────────────────────────────

  @doc "Stream all documents for a dataset as envelope maps. Optionally filter by type."
  def export_stream(dataset, opts \\ []) do
    type = Keyword.get(opts, :type)

    Document
    |> where([d], d.dataset == ^dataset)
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

    Revision
    |> where([r], r.doc_id == ^published_id(doc_id) and r.type == ^type and r.dataset == ^dataset)
    |> order_by([r], desc: r.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Get a single revision by ID."
  def get_revision(id) do
    case Repo.get(Revision, id) do
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
    with {:ok, rev} <- get_revision(revision_id) do
      attrs = %{
        "doc_id" => draft_id(rev.doc_id),
        "title" => rev.title,
        "status" => rev.status,
        "content" => rev.content
      }

      upsert_document(type, attrs, dataset, opts)
    end
  end

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
  Per-doc PubSub topic for a paper. Same shape as the documents spine:
  `doc:<dataset>:paper:<slug>`. PaperLive subscribes to this; writes broadcast
  to it.
  """
  def paper_topic(slug, dataset \\ @paper_default_dataset) when is_binary(slug) do
    "doc:#{dataset}:#{@paper_type}:#{slug}"
  end

  @doc """
  Fetch a paper (a type-"paper" document) by slug (and dataset). Returns the
  `%Document{}` or `nil`. Papers are always published (no draft prefix).
  """
  def get_paper(slug, dataset \\ @paper_default_dataset) when is_binary(slug) do
    case get_document(slug, @paper_type, dataset) do
      {:ok, doc} -> doc
      {:error, :not_found} -> nil
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

    existing = slug && get_paper(slug, dataset)

    blocks = attrs["blocks"]

    body_html =
      cond do
        is_list(blocks) -> Render.render_blocks(blocks, render_opts(dataset))
        is_binary(attrs["body_html"]) -> attrs["body_html"]
        true -> (existing && get_in(existing.content || %{}, ["body_html"])) || ""
      end

    next_rev = paper_next_rev(existing)

    content =
      (existing && existing.content || %{})
      |> Map.put("body_html", body_html)
      |> maybe_put_paper("blocks", if(is_list(blocks), do: blocks))
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
        {:ok, doc}

      error ->
        error
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
  def apply_paper_block_op(slug, op, dataset \\ @paper_default_dataset)
      when is_binary(slug) and is_map(op) do
    with %Document{} = doc <- get_paper(slug, dataset),
         blocks = get_in(doc.content || %{}, ["blocks"]) || [],
         {:ok, new_blocks} <- Patch.apply_patch(blocks, op),
         {:ok, affected} <- locate_paper_affected(op, new_blocks) do
      op_kind = Map.get(op, "op")
      rev = paper_next_rev(doc)
      render_opts = render_opts(dataset)
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

          broadcast_paper_block(slug, dataset, frame)

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

  # ── Papers — internal ──────────────────────────────────────────────────────

  # Resolve which block an op affected (post-apply) plus its top-level position.
  # Identical to the former Barkpark.Papers.locate_affected/2.
  defp locate_paper_affected(%{"op" => "append-block", "block" => block}, new_blocks) do
    {:ok,
     %{block: block, block_id: Map.get(block, "id"), position: length(new_blocks) - 1}}
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

    Phoenix.PubSub.broadcast(Barkpark.PubSub, paper_topic(doc.doc_id, doc.dataset), msg)
  end

  defp broadcast_paper_block(slug, dataset, frame) do
    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      paper_topic(slug, dataset),
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
