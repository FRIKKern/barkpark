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
    Analytics,
    Broadcast,
    Document,
    DraftId,
    Edge,
    Envelope,
    Export,
    Labels,
    Query,
    Revisions,
    Schema,
    SchemaDefinition,
    Search,
    Sheets,
    Validation,
    WriteScope
  }

  import Barkpark.Content.Scope,
    only: [scope_to_workspace_or_global: 3, scope_to_workspace: 3]

  alias Barkpark.PortableDoc.{Projection, Synthesis}

  alias Barkpark.Content.Papers

  # ── Draft/Published helpers (extracted → Content.DraftId) ──────────────────

  defdelegate draft_id(published_id), to: DraftId
  defdelegate published_id(doc_id), to: DraftId
  defdelegate draft?(doc_id), to: DraftId

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
  def list_documents(type, dataset, opts \\ []),
    do: Query.list_documents(type, dataset, opts)

  @doc """
  Fetch a single document by `{doc_id, type, dataset}`.

  Delegates to `Barkpark.Content.Query.get_document/4`.
  """
  def get_document(doc_id, type, dataset, opts \\ []),
    do: Query.get_document(doc_id, type, dataset, opts)

  @doc """
  Batch sibling of `get_document/4`: load many documents by `doc_id` in ONE
  scoped query, returned as a `%{doc_id => %Document{}}` map.

  Delegates to `Barkpark.Content.Query.get_documents_by_ids/3`.
  """
  @spec get_documents_by_ids([String.t()], String.t(), keyword()) ::
          %{optional(String.t()) => Document.t()}
  def get_documents_by_ids(doc_ids, dataset, opts \\ []),
    do: Query.get_documents_by_ids(doc_ids, dataset, opts)

  # ── Reference / codelist labels (extracted → Content.Labels) ───────────────
  #
  # Public `reference_title/4` and `codelist_label/3` keep their facade entry
  # points (explicit wrappers because `reference_title/4` carries a default
  # `opts \\ []`). The private render-opts builders delegate too, so the paper /
  # write paths inside this module call `Labels.render_opts(...)` etc.

  @doc """
  Resolve a referenced document's display title from a stored reference value.

  Delegates to `Barkpark.Content.Labels.reference_title/4`.
  """
  @spec reference_title(String.t() | nil, String.t() | nil, String.t(), keyword()) :: String.t()
  def reference_title(value, ref_type, dataset, opts \\ []),
    do: Labels.reference_title(value, ref_type, dataset, opts)

  @doc """
  Resolve a codelist CODE to its human LABEL for View-mode rendering.

  Delegates to `Barkpark.Content.Labels.codelist_label/3`.
  """
  defdelegate codelist_label(plugin, codelist_id, code), to: Labels

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
  def fetch_doc_with_draft(type, doc_id, dataset, opts \\ []),
    do: Query.fetch_doc_with_draft(type, doc_id, dataset, opts)

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
        |> Projection.project(new_blocks, Labels.render_opts(dataset))

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
      |> WriteScope.put_scope_attrs(opts)
      |> Sheets.maybe_recompute_sheet_formulas(type)
      |> Sheets.hydrate_sheet_embed_snapshots()

    with :ok <- validate_task_kind(type, attrs) do
      do_create_document(type, attrs, dataset, doc_id, opts)
    end
  end

  defp do_create_document(type, attrs, dataset, doc_id, opts) do
    ctx = WriteScope.build_ctx(opts)

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
              |> Broadcast.tap_broadcast(dataset, type, "update", existing.rev)

            _ ->
              attrs = scaffold_or_initial_values(attrs, type, dataset)

              %Document{}
              |> Document.changeset(attrs)
              |> Repo.insert()
              |> Broadcast.tap_broadcast(dataset, type, "create", nil)
          end

        result
        |> WriteScope.fire_after(:after_save, payload)
        |> Sheets.tap_sheet_writethrough()
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
      |> Projection.project(blocks, Labels.render_opts(dataset))

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
        ctx = WriteScope.build_ctx(opts)

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
              |> WriteScope.inherit_scope_attrs(draft)

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
                  Broadcast.tap_broadcast({:ok, published}, dataset, type, "publish", prev_pub_rev)

                error ->
                  error
              end

            WriteScope.fire_after(result, :after_publish, payload)
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
        ctx = WriteScope.build_ctx(opts)

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
              |> WriteScope.inherit_scope_attrs(pub)

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
                  Broadcast.tap_broadcast({:ok, draft}, dataset, type, "unpublish", prev_draft_rev)

                error ->
                  error
              end

            WriteScope.fire_after(result, :after_unpublish, payload)
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
        |> Broadcast.tap_broadcast(dataset, type, "discardDraft", prev_rev)

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
        ctx = WriteScope.build_ctx(opts)

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

            result = Broadcast.tap_broadcast(first_result, dataset, type, "delete", prev_rev)
            WriteScope.fire_after(result, :after_delete, payload)
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
          Broadcast.flush_deferred_broadcasts()
          result

        _ ->
          Broadcast.clear_deferred_broadcasts()
          result
      end
    rescue
      e ->
        Broadcast.clear_deferred_broadcasts()
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

  ## arrayOf-aware (the blast-radius fix)

  The referencing-source set is the UNION of two probes, so it matches the
  Studio guard modal exactly while staying robust when edges are not yet
  materialised:

    * the scalar SQL scan `find_referencing_docs/3` (`content->>field == pub_id`)
      — finds scalar `reference` referencers WITHOUT depending on the
      `content_edges` projection (the projector is async / `:manual` in tests);
      and
    * `Content.Graph.reverse_referencers/2` — the arrayOf-aware inbound-edge
      query over `content_edges` (materialised in Phase 2) — finds referencers
      via `arrayOf`-of-`reference` fields like `task.attachments`.

  The previous path built its `ref_fields` from `field["type"] == "reference"`
  ONLY, so it silently skipped arrayOf referencers: the guard modal warned about
  them (it probes via `reverse_referencers`) but the disconnect never acted on
  them, leaving those references dangling after the doc was unpublished anyway —
  defeating the disconnect remediation for the headline arrayOf case. This
  closes the gap: for each referencing source we strip the target from BOTH
  scalar `reference` fields (delete the field) AND `arrayOf`-of-`reference`
  fields (`List.delete` the element, keeping the array's other references).
  """
  def disconnect_references(doc_id, dataset, opts \\ []) do
    pub_id = published_id(doc_id)

    scalar_refs =
      find_referencing_docs(doc_id, dataset, opts)
      |> Enum.map(fn ref -> {ref.doc_id, ref.type} end)

    array_refs =
      Barkpark.Content.Graph.reverse_referencers(pub_id, [dataset: dataset] ++ opts)
      |> Enum.map(fn ref -> {ref[:from_doc_id] || ref[:from_id], ref[:type]} end)

    # Distinct referencing sources — a source can reference the target via
    # several edges (a scalar `rel` AND an `arrayOf` `attachments`), and the two
    # probes can both surface the same scalar source; we load + rewrite each
    # source doc once, stripping the id from every matching field in one update.
    (scalar_refs ++ array_refs)
    |> Enum.reject(fn {ref_doc_id, type} -> is_nil(ref_doc_id) or is_nil(type) end)
    |> Enum.uniq()
    |> Enum.each(fn {ref_doc_id, type} ->
      disconnect_one_source(ref_doc_id, type, pub_id, dataset, opts)
    end)
  end

  # Strip every reference to `target_pub_id` out of one referencing source doc,
  # across BOTH scalar `reference` fields and `arrayOf`-of-`reference` fields.
  defp disconnect_one_source(ref_doc_id, type, target_pub_id, dataset, opts) do
    with {:ok, schema} <- get_schema(type, dataset),
         {:ok, doc} <- get_document(ref_doc_id, type, dataset, opts) do
      content = doc.content || %{}
      updated_content = strip_reference_fields(content, schema.fields, target_pub_id)

      if updated_content != content do
        prev_rev = doc.rev

        doc
        |> Document.changeset(%{"content" => updated_content, "rev" => generate_rev()})
        |> Repo.update()
        |> Broadcast.tap_broadcast(dataset, type, "update", prev_rev)
      end

      :ok
    else
      _ -> :ok
    end
  end

  # Walk the schema fields and remove `target_pub_id` from each reference-bearing
  # field of `content`. Scalar `reference` whose value coalesces to the target →
  # delete the key. `arrayOf` of `reference` → keep every element that is NOT the
  # target (published-coalesced compare), so OTHER references in the array
  # survive. All other fields pass through untouched.
  defp strip_reference_fields(content, fields, target_pub_id) do
    Enum.reduce(fields, content, fn field, acc ->
      name = field["name"]
      value = Map.get(acc, name)

      cond do
        field["type"] == "reference" and is_binary(value) and
            published_id(value) == target_pub_id ->
          Map.delete(acc, name)

        get_in(field, ["of", "type"]) == "reference" and is_list(value) ->
          kept =
            Enum.reject(value, fn v ->
              is_binary(v) and published_id(v) == target_pub_id
            end)

          if kept == value, do: acc, else: Map.put(acc, name, kept)

        true ->
          acc
      end
    end)
  end

  # ── Content graph edges (reference-field extraction + CRUD) ─────────────────
  #
  # extract_edges/2 walks a document's schema reference fields (scalar AND
  # arrayOf-of-reference) and emits one raw edge per target. from_id/to_id are
  # ALWAYS published-coalesced (published_id/1) so keys are publish-stable and a
  # draft is never a from_id. Dangling is computed here at READ time — there is
  # no dangling column (the to_id FK makes a dangling edge unstorable; see
  # `Barkpark.Content.Edge` moduledoc). The closest live precedents are the
  # scalar-only find_referencing_docs/3 and the untyped reference_title/4.

  @doc """
  Extract the outbound reference-field edges of a document.

  For the doc's schema (`list_schemas/2` → matched by `doc.type`) enumerate
  BOTH:

    * scalar fields where `f["type"] == "reference"` — value is
      `doc.content[field]`, refType `f["refType"]` (MAY be nil); and
    * arrayOf fields where `get_in(f, ["of", "type"]) == "reference"` — value is
      `List.wrap(doc.content[field])` (one edge per element), refType
      `get_in(f, ["of", "refType"])` (MAY be nil).

  Each raw target value becomes one edge map with `from_id` =
  `published_id(doc.doc_id)`, `to_id` = `published_id(target)`. `dangling` is
  resolved per target via `resolve_target_existence/4` (typed `get_document/4`
  when refType is a non-empty binary; type-agnostic `Repo.exists?` when refType
  is nil/empty — NEVER `get_document` with a nil type, which would short-circuit
  to `:not_found` and false-flag every untyped ref). Resolution runs under the
  `:published` lens (mirrors anonymous reads); a target whose published twin
  does not yet exist is reported dangling.

  Pure of plugins — reads only core schema reference fields, so it still emits
  core edges with `Application.put_env(:barkpark, :plugins, [])` (fresh-install
  invariant). Resolves EACH target → O(edges) DB round-trips; the Phase-3
  projector runs it off the request path.

  Returns `[%{from_id, to_id, kind, field, refType, dangling}]`. `kind` is the
  source reference field's NAME (e.g. `"dependencies"`, `"intentions"`,
  `"related"`) so distinct reference fields become distinct edge kinds in
  /v1/graph; plugin-projected kinds (Phase 3) arrive via the registry
  collector, not this function.
  """
  @spec extract_edges(map() | Document.t(), keyword()) :: [
          %{
            from_id: String.t(),
            to_id: String.t(),
            kind: String.t(),
            field: String.t(),
            refType: String.t() | nil,
            dangling: boolean()
          }
        ]
  def extract_edges(doc, opts \\ []) do
    doc_id = Map.get(doc, :doc_id) || Map.get(doc, "doc_id")
    type = Map.get(doc, :type) || Map.get(doc, "type")
    dataset = Map.get(doc, :dataset) || Map.get(doc, "dataset")
    content = Map.get(doc, :content) || Map.get(doc, "content") || %{}

    from_id = published_id(doc_id)

    schema =
      dataset
      |> list_schemas(opts)
      |> Enum.find(fn s -> s.name == type end)

    case schema do
      nil ->
        []

      %SchemaDefinition{fields: fields} ->
        fields
        |> Enum.flat_map(fn field -> extract_field_edges(field, content) end)
        |> Enum.map(fn {raw_target, field_name, ref_type} ->
          to_id = published_id(raw_target)

          dangling =
            not resolve_target_existence(to_id, ref_type, dataset, opts)

          %{
            from_id: from_id,
            to_id: to_id,
            # kind IS the source reference field's name (graph-edge-seam): a
            # `dependencies` ref → kind "dependencies", `intentions` → "intentions",
            # `related` → "related". This makes distinct reference fields distinct
            # edge kinds in /v1/graph (bp-graph.js colours by kind) WITHOUT a
            # via_field column or API change — the kind column already surfaces.
            # Was the generic "references" for every field. Plugin-projected kinds
            # (Phase 3) arrive via the registry collector, not this function.
            kind: field_name,
            field: field_name,
            refType: ref_type,
            dangling: dangling
          }
        end)
    end
  end

  # Scalar reference field → at most one {raw_target, field_name, ref_type}.
  defp extract_field_edges(%{"type" => "reference"} = field, content) do
    field_name = field["name"]
    ref_type = field["refType"]

    case Map.get(content, field_name) do
      value when is_binary(value) and value != "" ->
        [{value, field_name, ref_type}]

      _ ->
        []
    end
  end

  # arrayOf-of-reference field → one entry per non-blank element (bare-id
  # string array, the task.attachments shape).
  defp extract_field_edges(%{"type" => "arrayOf", "of" => %{"type" => "reference"} = of} = field, content) do
    field_name = field["name"]
    ref_type = of["refType"]

    content
    |> Map.get(field_name)
    |> List.wrap()
    |> Enum.filter(fn v -> is_binary(v) and v != "" end)
    |> Enum.map(fn value -> {value, field_name, ref_type} end)
  end

  defp extract_field_edges(_field, _content), do: []

  # The SHARED resolve-and-dangling helper (gap #2). TWO branches that MUST
  # agree on lens (:published) + scope so a typed and an untyped ref to the same
  # target never disagree:
  #
  #   (i)  refType is a non-empty binary → typed get_document/4; resolvable
  #        unless it returns {:error, :not_found}.
  #   (ii) refType is nil OR "" → DO NOT call get_document with a nil type
  #        (get_document/4 short-circuits to :not_found on a nil type and would
  #        false-positive EVERY untyped ref). Instead run a type-agnostic
  #        existence query — present? under the :published lens means
  #        resolvable.
  #
  # BOTH branches share the :published lens: the typed branch resolves only the
  # published row (get_document/4 matches `doc_id == to_id` where to_id is
  # already published-coalesced), and the untyped branch matches the published
  # id ONLY — NOT the `drafts.` twin. A draft-only target (no published twin)
  # is therefore dangling under EITHER branch, so a typed ref and an untyped ref
  # to the same target never disagree on dangling (gap #2 contract). This is
  # why we do NOT copy reference_title/4's `or doc_id == draft` clause —
  # reference_title intentionally falls back to the draft twin for a cosmetic
  # title, which is the WRONG lens for published-dangling.
  #
  # Returns true when the target is resolvable (NOT dangling).
  @spec resolve_target_existence(String.t(), String.t() | nil, String.t() | nil, keyword()) ::
          boolean()
  defp resolve_target_existence(to_id, ref_type, dataset, opts)
       when is_binary(ref_type) and ref_type != "" do
    case get_document(to_id, ref_type, dataset, opts) do
      {:ok, _doc} -> true
      {:error, :not_found} -> false
    end
  end

  defp resolve_target_existence(to_id, _ref_type, dataset, opts) do
    pub_id = published_id(to_id)

    Document
    |> where([d], d.doc_id == ^pub_id)
    |> WriteScope.scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(
      Keyword.get(opts, :workspace_id),
      Keyword.get(opts, :project_id)
    )
    |> Repo.exists?()
  end

  @doc """
  Insert (or REPLACE) a single content edge by its `(from_id, to_id, kind)`
  triple.

  ## Id model — slug `doc_id` IN, `documents.id` UUID stored

  `extract_edges/2` emits `from_id`/`to_id` as STRING slug `doc_id`s (e.g.
  `"art-1"`), but the `content_edges` FKs reference `documents.id` — the
  binary_id UUID PK, NOT the `doc_id` slug (same contract as `task_edges`,
  whose `Tasks.add_dep/3` is called with `child.id`/`parent.id` UUIDs). So
  `add_edge/4` RESOLVES each endpoint slug to its `documents.id` before
  inserting, preferring the published row (mirroring `reference_title/4`'s
  published-before-draft pick). A value that is already a UUID for an existing
  `documents.id` is used as-is. An unresolvable endpoint → `{:error, :no_target}`
  (a dangling edge is UNSTORABLE — the read-time `extract_edges/2` dangling
  signal is the place that surfaces it, not this writer).

  Resolution scope is read from `attrs` (`dataset`, optional `workspace_id` /
  `project_id`) — `extract_edges/2`'s slugs are scope-relative, so a caller
  MUST pass the same `dataset` it extracted under.

  `on_conflict: {:replace, [:weight, :plugin_source, :updated_at]}` with
  `conflict_target: [:from_id, :to_id, :kind]` — REPLACE (not `:nothing`) so a
  re-extracted edge with changed `weight`/`plugin_source` UPDATES rather than
  keeping stale values (gap #9). `updated_at` exists per the schema divergence
  so it is bumped on conflict. The row is reloaded by its unique triple so
  callers always get the canonical struct (same shape as `Tasks.add_dep/3`).

  Returns `{:ok, %Edge{}}` on success, `{:error, :no_target}` when an endpoint
  cannot be resolved to a `documents.id`, or `{:error, %Ecto.Changeset{}}` on
  validation failure (self-edge, unknown kind).
  """
  @spec add_edge(binary(), binary(), String.t(), map()) ::
          {:ok, Edge.t()} | {:error, :no_target} | {:error, Ecto.Changeset.t()}
  def add_edge(from_id, to_id, kind, attrs \\ %{}) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    dataset = attrs["dataset"]
    scope_opts = edge_scope_opts(attrs)

    with from_pk when is_binary(from_pk) <- resolve_doc_pk(from_id, dataset, scope_opts),
         to_pk when is_binary(to_pk) <- resolve_doc_pk(to_id, dataset, scope_opts) do
      base = %{"from_id" => from_pk, "to_id" => to_pk, "kind" => to_string(kind)}

      changeset =
        Edge.changeset(
          %Edge{},
          Map.merge(base, %{
            "weight" => attrs["weight"],
            "plugin_source" => attrs["plugin_source"]
          })
        )

      if changeset.valid? do
        case Repo.insert(changeset,
               on_conflict: {:replace, [:weight, :plugin_source, :updated_at]},
               conflict_target: [:from_id, :to_id, :kind]
             ) do
          {:ok, %Edge{}} ->
            {:ok, fetch_content_edge!(from_pk, to_pk, to_string(kind))}

          {:error, %Ecto.Changeset{} = cs} ->
            {:error, cs}
        end
      else
        {:error, changeset}
      end
    else
      _ -> {:error, :no_target}
    end
  end

  # Resolve a slug `doc_id` (or an already-resolved `documents.id` UUID) to the
  # `documents.id` binary_id PK the content_edges FKs reference. Published row
  # preferred over its `drafts.` twin (CASE-ordered, mirroring reference_title/4)
  # so the stored edge is publish-stable. Returns the UUID string, or nil when
  # nothing in scope matches (caller turns that into {:error, :no_target} — a
  # dangling edge is unstorable).
  defp resolve_doc_pk(nil, _dataset, _scope_opts), do: nil

  defp resolve_doc_pk(id, dataset, scope_opts) when is_binary(id) do
    pub_id = published_id(id)
    draft = draft_id(pub_id)

    query =
      Document
      |> where([d], d.doc_id == ^pub_id or d.doc_id == ^draft or d.id == ^id)
      |> scope_edge_endpoint(scope_opts)
      |> order_by([d], asc: fragment("CASE WHEN ? LIKE 'drafts.%' THEN 1 ELSE 0 END", d.doc_id))

    query =
      if is_binary(dataset) and dataset != "" do
        WriteScope.scope_to_dataset(query, dataset, scope_opts)
      else
        query
      end

    case query |> Repo.all() |> List.first() do
      %Document{id: pk} -> pk
      _ -> nil
    end
  rescue
    # An `id` that is not a valid binary_id makes `d.id == ^id` raise on cast.
    # Fall back to the slug-only match (drop the `d.id == ^id` disjunct).
    Ecto.Query.CastError -> resolve_doc_pk_by_slug(id, dataset, scope_opts)
  end

  defp resolve_doc_pk_by_slug(id, dataset, scope_opts) do
    pub_id = published_id(id)
    draft = draft_id(pub_id)

    query =
      Document
      |> where([d], d.doc_id == ^pub_id or d.doc_id == ^draft)
      |> scope_edge_endpoint(scope_opts)
      |> order_by([d], asc: fragment("CASE WHEN ? LIKE 'drafts.%' THEN 1 ELSE 0 END", d.doc_id))

    query =
      if is_binary(dataset) and dataset != "" do
        WriteScope.scope_to_dataset(query, dataset, scope_opts)
      else
        query
      end

    case query |> Repo.all() |> List.first() do
      %Document{id: pk} -> pk
      _ -> nil
    end
  end

  # Tenancy scope for an edge endpoint resolution. With `require_workspace:
  # true` (the multi-tenant projector, FIX 3) the STRICT `scope_to_workspace/3`
  # is used — a nil workspace_id FAILS CLOSED (where: false), so a nil-scope
  # endpoint resolves to NOTHING and add_edge/4 returns {:error, :no_target}
  # rather than crossing into another tenant's colliding-slug doc. Without the
  # flag (single-tenant / unflagged callers) it is the documented or-global
  # back-compat resolution, byte-identical to before.
  defp scope_edge_endpoint(query, scope_opts) do
    ws = Keyword.get(scope_opts, :workspace_id)
    proj = Keyword.get(scope_opts, :project_id)

    if Keyword.get(scope_opts, :require_workspace, false) do
      scope_to_workspace(query, ws, proj)
    else
      scope_to_workspace_or_global(query, ws, proj)
    end
  end

  defp edge_scope_opts(attrs) do
    []
    |> maybe_put_kw(:dataset_id, attrs["dataset_id"])
    |> maybe_put_kw(:workspace_id, attrs["workspace_id"])
    |> maybe_put_kw(:project_id, attrs["project_id"])
    # FAIL-CLOSED flag (FIX 3) — carried so resolve_doc_pk/3 can refuse a
    # cross-tenant slug match when the multi-tenant projector demands a
    # resolved workspace. Only put when truthy so single-tenant callers keep
    # the default or-global resolution.
    |> maybe_put_kw(:require_workspace, truthy(attrs["require_workspace"]))
  end

  # Keep only a genuinely-true flag (drop nil/false) so `maybe_put_kw` leaves
  # the default resolution untouched on a single-tenant / unflagged caller.
  defp truthy(true), do: true
  defp truthy(_), do: nil

  defp maybe_put_kw(opts, _key, nil), do: opts
  defp maybe_put_kw(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  Insert/replace a batch of edge maps (the `extract_edges/2` shape, or any map
  carrying `from_id`/`to_id`/`kind` + optional `weight`/`plugin_source`).
  Returns the list of CRUD results in order. `dangling`/`field`/`refType` keys
  on the input maps are ignored (they are read-time signals, not stored).

  Because `extract_edges/2` emits scope-relative slug `doc_id`s, the resolution
  `dataset` (and optional `workspace_id`/`project_id`) MUST be passed via
  `opts` so each `add_edge/4` can resolve the slugs to `documents.id` UUIDs in
  the SAME scope they were extracted under. A per-edge `dataset` key wins over
  the batch `opts` default.
  """
  @spec add_edges([map()], keyword()) ::
          [{:ok, Edge.t()} | {:error, :no_target} | {:error, Ecto.Changeset.t()}]
  def add_edges(edges, opts \\ []) when is_list(edges) do
    scope = %{
      "dataset" => Keyword.get(opts, :dataset),
      "dataset_id" => Keyword.get(opts, :dataset_id),
      "workspace_id" => Keyword.get(opts, :workspace_id),
      "project_id" => Keyword.get(opts, :project_id),
      # FAIL-CLOSED tenancy (Goal ges/graph-edge-seam, FIX 3). When the
      # projector runs in a multi-tenant install it sets this so a nil-workspace
      # endpoint is REFUSED across tenants (→ {:error, :no_target}) instead of
      # resolving a colliding-slug doc in another tenant and storing a
      # cross-tenant content_edges row. Absent/false = the documented
      # single-tenant or-global back-compat resolution.
      "require_workspace" => Keyword.get(opts, :require_workspace, false)
    }

    Enum.map(edges, fn e ->
      from_id = e[:from_id] || e["from_id"]
      to_id = e[:to_id] || e["to_id"]
      kind = e[:kind] || e["kind"]

      attrs =
        scope
        |> Map.put("dataset", (e[:dataset] || e["dataset"]) || scope["dataset"])
        |> Map.put("weight", e[:weight] || e["weight"])
        |> Map.put("plugin_source", e[:plugin_source] || e["plugin_source"])
        |> Map.put("require_workspace", scope["require_workspace"])

      add_edge(from_id, to_id, kind, attrs)
    end)
  end

  @doc """
  Outbound edges of a document id (indexed `(from_id, kind)` scan). Ordered by
  `inserted_at` ASC — the forward-BFS input for Phase 4. `:kind` opt narrows to
  one kind.
  """
  @spec list_outbound_edges(binary(), keyword()) :: [Edge.t()]
  def list_outbound_edges(from_id, opts \\ []) do
    Edge
    |> where([e], e.from_id == ^from_id)
    |> maybe_filter_edge_kind(opts)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  @doc """
  Inbound edges of a document id (indexed `(to_id, kind)` scan). Ordered by
  `inserted_at` ASC — the reverse-walk input for the Studio unpublish guard
  (Phase 4/5). `:kind` opt narrows to one kind.
  """
  @spec list_inbound_edges(binary(), keyword()) :: [Edge.t()]
  def list_inbound_edges(to_id, opts \\ []) do
    Edge
    |> where([e], e.to_id == ^to_id)
    |> maybe_filter_edge_kind(opts)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  defp maybe_filter_edge_kind(query, opts) do
    case Keyword.get(opts, :kind) do
      nil -> query
      kind -> where(query, [e], e.kind == ^to_string(kind))
    end
  end

  defp fetch_content_edge!(from_id, to_id, kind) do
    Repo.one!(
      from(e in Edge,
        where: e.from_id == ^from_id and e.to_id == ^to_id and e.kind == ^kind
      )
    )
  end

  @doc """
  The projection SOURCE corpus — fold `extract_edges/2` over every published
  document of the given `type` in `dataset`. `perspective: :published` so no
  `drafts.<id>` is ever a from_id (drafts decision guard a). The Phase-3
  projector folds this across all types to build the materialised graph.
  """
  @spec corpus_edges(String.t(), String.t(), keyword()) :: [map()]
  def corpus_edges(type, dataset, opts \\ []) do
    list_opts = Keyword.put(opts, :perspective, :published)

    type
    |> list_documents(dataset, list_opts)
    |> Enum.flat_map(fn doc -> extract_edges(doc, opts) end)
  end

  # ── Sheets write-through + embed hydration (extracted → Content.Sheets) ─────
  #
  # Concern J — recompute, write-through, and embed-snapshot hydration live in
  # `Barkpark.Content.Sheets`. The create/upsert write path calls through
  # `Sheets.*` directly; the paper-ingest block path uses `Sheets.hydrate_sheet_blocks/3`.


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
      |> WriteScope.put_scope_attrs(opts)
      |> Sheets.maybe_recompute_sheet_formulas(type)
      |> Sheets.hydrate_sheet_embed_snapshots()
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
    ctx = WriteScope.build_ctx(opts)

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
              |> Broadcast.tap_broadcast(dataset, type, "update", existing.rev)

            _ ->
              %Document{}
              |> Document.changeset(attrs)
              |> Repo.insert()
              |> Broadcast.tap_broadcast(dataset, type, "create", nil)
          end

        result
        |> WriteScope.fire_after(:after_save, payload)
        |> Sheets.tap_sheet_writethrough()
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
        Map.put(attrs, "content", Projection.project(content, blocks, Labels.render_opts(dataset)))

      _ ->
        attrs
    end
  end

  # ── Scope resolution (extracted → Content.WriteScope) ─────────────────────
  #
  # Tenancy scope stamping/resolution + the lifecycle-hook helpers moved to
  # Barkpark.Content.WriteScope (concern K). These thin wrappers keep every
  # external caller (Media, Webhooks, Papers, Schema, the search retrievers)
  # unchanged. The `read_default_project_id/1` default (\\) is spelled out as
  # explicit clauses rather than a bare defdelegate.

  @doc false
  defdelegate put_scope_attrs(attrs, opts), to: WriteScope

  @doc false
  defdelegate resolve_read_dataset_id(dataset, opts), to: WriteScope

  @doc false
  def read_default_project_id, do: WriteScope.read_default_project_id([])
  @doc false
  def read_default_project_id(opts), do: WriteScope.read_default_project_id(opts)

  # ── Schema Definitions (extracted → Content.Schema) ───────────────────────
  #
  # All schema-definition reads/writes, SDK serialization, hashing, and the
  # dataset catalog moved to Barkpark.Content.Schema. These thin wrappers keep
  # every external caller (SchemaController, Bootstrap, capabilities, SDK
  # serialization) unchanged. Defaults (\\) are spelled out as explicit
  # wrappers rather than bare defdelegate.

  @doc """
  The default dataset for a bare Studio landing (no `:dataset` in the URL).
  See `Barkpark.Content.Schema.default_dataset/0`.
  """
  @spec default_dataset() :: String.t()
  def default_dataset, do: Schema.default_dataset()

  @doc """
  Return the dataset slugs OWNED by a project, sorted alphabetically.
  See `Barkpark.Content.Schema.list_datasets/1`.
  """
  def list_datasets(project_id \\ :default), do: Schema.list_datasets(project_id)

  def list_schemas(dataset, opts \\ []), do: Schema.list_schemas(dataset, opts)

  def get_schema(name, dataset, opts \\ []), do: Schema.get_schema(name, dataset, opts)

  @doc """
  Resolve the full Expectation for a schema definition.
  See `Barkpark.Content.Schema.resolve_expectation/1`.
  """
  @spec resolve_expectation(SchemaDefinition.t()) :: %{layout: [map()], prefill: map()}
  def resolve_expectation(%SchemaDefinition{} = schema),
    do: Schema.resolve_expectation(schema)

  def upsert_schema(attrs, dataset, opts \\ []), do: Schema.upsert_schema(attrs, dataset, opts)

  def delete_schema(name, dataset, opts \\ []), do: Schema.delete_schema(name, dataset, opts)

  @doc """
  Whether the schema's public-read gate is open for `type` in `dataset`.
  See `Barkpark.Content.Schema.schema_public?/3`.
  """
  def schema_public?(type, dataset, opts \\ []), do: Schema.schema_public?(type, dataset, opts)

  @doc """
  Returns the union of CORS origin allow-lists across all schemas in the dataset.
  See `Barkpark.Content.Schema.allowed_origins_for_dataset/2`.
  """
  @spec allowed_origins_for_dataset(String.t(), keyword()) :: [String.t()]
  def allowed_origins_for_dataset(dataset, opts \\ []) when is_binary(dataset),
    do: Schema.allowed_origins_for_dataset(dataset, opts)

  def schema_hash_for_dataset(dataset, opts \\ []) when is_binary(dataset),
    do: Schema.schema_hash_for_dataset(dataset, opts)

  @doc """
  Deterministic 16-char hex content hash of a single schema definition.
  See `Barkpark.Content.Schema.schema_hash_for_schema/1`.
  """
  def schema_hash_for_schema(%SchemaDefinition{} = schema),
    do: Schema.schema_hash_for_schema(schema)

  @doc """
  Render a single schema in SDK envelope shape.
  See `Barkpark.Content.Schema.serialize_schema_for_sdk/1`.
  """
  def serialize_schema_for_sdk(%SchemaDefinition{} = schema),
    do: Schema.serialize_schema_for_sdk(schema)

  @doc """
  List every schema in a dataset in SDK envelope shape, plus a
  top-level `datasetSchemaHash`. See `Barkpark.Content.Schema.list_schemas_for_sdk/2`.
  """
  def list_schemas_for_sdk(dataset, opts \\ []) when is_binary(dataset),
    do: Schema.list_schemas_for_sdk(dataset, opts)

  def schema_hash_for_all_datasets, do: Schema.schema_hash_for_all_datasets()

  # ── Analytics (extracted → Content.Analytics) ─────────────────────────────

  @doc "Count documents grouped by type, with published/draft breakdown."
  def document_stats(dataset, opts \\ []), do: Analytics.document_stats(dataset, opts)

  @doc "Count total documents in a dataset."
  def total_documents(dataset, opts \\ []), do: Analytics.total_documents(dataset, opts)

  @doc "Recent mutation activity — last N events."
  def recent_activity(dataset, opts \\ []), do: Analytics.recent_activity(dataset, opts)

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

  Extracted to `Content.Broadcast`, which is the single owner of the topic
  shapes — callers never build topic strings themselves.

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
      when is_binary(mutation),
      do: Broadcast.broadcast_document_mutation(doc, mutation, opts)

  # ── Search (extracted → Content.Search) ───────────────────────────────────

  @doc "Search documents by title using the QueryPipeline. Returns `{docs, count, meta}`."
  def search_documents(query, dataset, opts \\ []), do: Search.search_documents(query, dataset, opts)

  # ── Export (extracted → Content.Export) ────────────────────────────────────

  @doc "Stream all documents for a dataset as envelope maps. Optionally filter by type."
  def export_stream(dataset, opts \\ []), do: Export.export_stream(dataset, opts)

  # ── Revisions (extracted → Content.Revisions) ─────────────────────────────

  @doc "List revisions for a document, newest first."
  def list_revisions(doc_id, type, dataset, opts \\ []),
    do: Revisions.list_revisions(doc_id, type, dataset, opts)

  @doc "Get a single revision by ID, scoped to a dataset and (optionally) workspace/project."
  def get_revision(id, dataset, opts \\ []), do: Revisions.get_revision(id, dataset, opts)

  @doc "Restore a document to a specific revision."
  def restore_revision(revision_id, type, dataset, opts \\ []),
    do: Revisions.restore_revision(revision_id, type, dataset, opts)

  # ── Papers — context functions (extracted → Content.Papers, Step 10) ───────
  #
  # The `type:"paper"` feature (the Bulldocs surface) lives in
  # `Barkpark.Content.Papers`. These facade entries keep every external caller
  # (`Barkpark.Content.<fn>`) unchanged. Explicit thin wrappers preserve the
  # `\\` default args; bare delegations cover the no-default arities.

  @doc "The default dataset papers live under. See `Content.Papers`."
  def paper_default_dataset, do: Papers.paper_default_dataset()

  @doc "The document type discriminator for papers. See `Content.Papers`."
  def paper_type, do: Papers.paper_type()

  @doc "Per-doc PubSub topic for a paper, scoped to the owning workspace. See `Content.Papers`."
  def paper_topic(slug, workspace_id, dataset \\ Papers.paper_default_dataset()),
    do: Papers.paper_topic(slug, workspace_id, dataset)

  @doc "Per-doc PubSub topic for an ordinary document, scoped to the owning workspace."
  defdelegate doc_topic(pubid, type, workspace_id, dataset), to: Broadcast

  @doc "Fetch a paper (a type-\"paper\" document) by slug. See `Content.Papers`."
  def get_paper(slug, dataset \\ Papers.paper_default_dataset(), opts \\ []),
    do: Papers.get_paper(slug, dataset, opts)

  @doc "Resolve a paper for the PUBLIC, unauthenticated surface. See `Content.Papers`."
  def get_public_paper(slug, dataset \\ Papers.paper_default_dataset()),
    do: Papers.get_public_paper(slug, dataset)

  @doc "Resolve a document of `type` by `slug` for a PUBLIC surface. See `Content.Papers`."
  def get_public_document(type, slug, dataset \\ Papers.paper_default_dataset()),
    do: Papers.get_public_document(type, slug, dataset)

  @doc "The paper's block list, or `nil` for an HTML-only paper. See `Content.Papers`."
  def paper_blocks(slug, dataset \\ Papers.paper_default_dataset()),
    do: Papers.paper_blocks(slug, dataset)

  @doc "Resolve the block list for editing a document. See `Content.Papers`."
  defdelegate resolve_blocks_for_edit(doc, type, dataset), to: Papers

  @doc "The expected fields still recommendable for a document's block list. See `Content.Papers`."
  def available_expected_fields(blocks, expectation, schema \\ nil),
    do: Papers.available_expected_fields(blocks, expectation, schema)

  @doc "True when a HARD cap blocks inserting another bound block. See `Content.Papers`."
  defdelegate expected_field_blocked?(blocks, expectation, field_name), to: Papers

  @doc "Upsert a paper keyed by `{dataset, slug}` and broadcast a whole-HTML frame. See `Content.Papers`."
  defdelegate upsert_paper(attrs), to: Papers

  @doc "Apply a single portable-doc op to a paper's block list. See `Content.Papers`."
  def apply_paper_block_op(slug, op, dataset \\ Papers.paper_default_dataset(), opts \\ []),
    do: Papers.apply_paper_block_op(slug, op, dataset, opts)

  @doc "Apply a LIST of portable-doc ops to a paper's block list atomically. See `Content.Papers`."
  def apply_paper_block_ops(slug, ops, dataset \\ Papers.paper_default_dataset(), opts \\ []),
    do: Papers.apply_paper_block_ops(slug, ops, dataset, opts)

  @doc "Apply a single portable-doc op to any Expectation-bearing document. See `Content.Papers`."
  def apply_document_block_op(doc_id, type, op, dataset, opts \\ []),
    do: Papers.apply_document_block_op(doc_id, type, op, dataset, opts)
end
