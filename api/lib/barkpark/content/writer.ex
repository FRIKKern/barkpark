defmodule Barkpark.Content.Writer do
  @moduledoc """
  The document WRITE concern (E) — create / clone / upsert plus the write-path
  helpers: envelope coercion, id/rev generation, task-kind validation, schema
  initial-values + Expectation scaffolding, deep-merge, and dynamic-token
  resolution.

  Extracted from `Barkpark.Content` (decomposition Step 13, concern E).
  `Barkpark.Content` keeps facade delegations so every external caller is
  unchanged; reads (`get_document`/`get_schema`), the lifecycle hub, and the
  edges/sheets collaborators are called back through `Barkpark.Content.*` /
  their own modules.
  """

  alias Barkpark.Repo
  alias Barkpark.Content

  alias Barkpark.Content.{
    Broadcast,
    Document,
    DraftId,
    Encryption,
    Labels,
    SchemaDefinition,
    Sheets,
    WriteScope
  }

  alias Barkpark.Content.Papers.BlockOps

  alias Barkpark.PortableDoc.{Projection, Synthesis}

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
  def validate_task_kind("task", attrs) do
    content = Map.get(attrs, "content") || Map.get(attrs, :content) || %{}

    case Barkpark.Tasks.validate_kind_content("task", content) do
      :ok ->
        :ok

      {:error, errors} ->
        {:error, {:invalid_task_content, errors}}
    end
  end

  def validate_task_kind(_type, _attrs), do: :ok

  @doc "Validate document content against its schema. Returns {:ok, content} or {:error, errors_map}."
  def validate_document(type, title, content, dataset) do
    case Content.get_schema(type, dataset) do
      {:ok, schema} -> Barkpark.Content.Validation.validate(content, title, schema)
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
    doc_id = DraftId.draft_id(raw_id)

    attrs =
      attrs
      |> Map.put("doc_id", doc_id)
      |> Map.put("type", type)
      |> Map.put("dataset", dataset)
      |> Map.put_new("status", "draft")
      # The row id is forced to `drafts.<id>` above, so a caller-supplied
      # `"status":"published"` would be an incoherent draft-prefixed/published
      # row — coerce that one value to "draft". Task workflow statuses
      # (active/planning/completed/archived) pass through untouched; lifecycle
      # publish/unpublish write via Document.changeset directly, not here.
      |> Map.update("status", "draft", fn
        "published" -> "draft"
        s -> s
      end)
      |> Map.put("rev", generate_rev())
      |> WriteScope.put_scope_attrs(opts)
      |> Sheets.maybe_recompute_sheet_formulas(type)
      |> Sheets.hydrate_sheet_embed_snapshots()
      # R2 chokepoint (id-less backfill, barkpark-obsidian): a Sanity-shaped
      # mutation (`create`/`createOrReplace`/`replace`) or the legacy create
      # controller can carry author-supplied `content["blocks"]` that lack ids.
      # Route them through the SAME `ensure_block_ids` the paper upsert path uses
      # so an id-less block can never reach storage from this entry either — the
      # continuous canvas keys its diff on block id, and an id-less block
      # projects to bpId:null → spurious insert-after → duplicate-block
      # corruption on the next edit. Additive (present ids preserved), idempotent.
      |> maybe_ensure_block_ids()

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
      case Content.get_document(doc_id, type, dataset, opts) do
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
              # Field-encryption chokepoint: marked fields become ciphertext
              # BEFORE the changeset, so plaintext never reaches storage. A field
              # that cannot be sealed REJECTS the write (HIGH-3, fail closed).
              with {:ok, enc_attrs} <- maybe_encrypt_marked_fields(attrs, type, dataset) do
                existing
                |> Document.changeset(enc_attrs)
                |> Repo.update()
                |> Broadcast.tap_broadcast(
                  dataset,
                  type,
                  "update",
                  existing.rev,
                  Keyword.get(opts, :source, :api),
                  Keyword.get(opts, :user_id)
                )
              end

            _ ->
              attrs = scaffold_or_initial_values(attrs, type, dataset)
              # Encrypt AFTER scaffold/projection so the final projected field
              # values (the ciphertext-at-rest source of truth) are encrypted.
              with {:ok, enc_attrs} <- maybe_encrypt_marked_fields(attrs, type, dataset) do
                %Document{}
                |> Document.changeset(enc_attrs)
                |> Repo.insert()
                |> Broadcast.tap_broadcast(
                  dataset,
                  type,
                  "create",
                  nil,
                  Keyword.get(opts, :source, :api),
                  Keyword.get(opts, :user_id)
                )
              end
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
      case Content.get_schema(type, dataset) do
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
    case Content.get_schema(type, dataset) do
      {:ok, %SchemaDefinition{layout: layout} = schema}
      when is_list(layout) and layout != [] ->
        scaffold_expectation(attrs, schema, dataset)

      _ ->
        # R2 chokepoint (id-less backfill). The earlier `maybe_ensure_block_ids`
        # in `create_document/4` runs BEFORE this step; `apply_initial_values`
        # can deep-merge a schema-declared `content["blocks"]` that lacks ids
        # AFTER it. Re-run the SAME chokepoint so the final block list is always
        # id-bearing. (No projection on this v1 path, so there is no body-mirror
        # to keep in sync.) Additive + idempotent.
        attrs
        |> apply_initial_values(type, dataset)
        |> maybe_ensure_block_ids()
    end
  end

  defp scaffold_or_initial_values(attrs, type, dataset),
    do: maybe_ensure_block_ids(apply_initial_values(attrs, type, dataset))

  # Build the scaffold block list from the schema's Expectation + provided
  # values, persist it under content["blocks"], and project. The row title
  # lives on the document row, not under content — it is folded in under
  # "title" so a bound title field-block picks it up, and re-derived into
  # content["title"] by projection (mirroring synthesize_blocks/3).
  defp scaffold_expectation(attrs, %SchemaDefinition{} = schema, dataset) do
    %{layout: layout, prefill: prefill} = Content.resolve_expectation(schema)
    prefill = resolve_dynamics(prefill)
    provided = Map.get(attrs, "content") || %{}

    values =
      provided
      |> Map.put_new("title", Map.get(attrs, "title"))
      |> drop_nil_values()

    # R2 chokepoint (id-less backfill). `Synthesis.scaffold` mints synth ids for
    # every bound field-block, but the body region can be a caller-provided
    # `%{"blocks" => [...]}` reused VERBATIM (see `scaffold_body_blocks/2`) whose
    # free blocks may be id-less. Fill ids BEFORE projection so `content["blocks"]`
    # AND the projected `content["body"]["blocks"]` (a copy of the free blocks)
    # carry the SAME ids — no id mismatch between the two mirrors. Additive +
    # idempotent (the scaffold's synth ids survive byte-identical).
    blocks =
      layout
      |> Synthesis.scaffold(values, prefill, schema.fields || [])
      |> BlockOps.ensure_block_ids()
      # Canonicalize any flat-string list item the scaffold body carried (the
      # obsidian list-item-crash fix) — additive + idempotent + render-preserving,
      # so a scaffold with no list (or only canonical lists) is byte-identical.
      |> BlockOps.normalize_list_items()

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

  # ── Legacy upsert (for backward compat) ───────────────────────────────────

  @doc """
  Upsert a document — used by autosave and patch paths.

  `opts` accepts `:source` and `:user_id`. Fires `:before_save` and
  `:after_save` around the DB write, same contract as `create_document/4`.
  """
  def upsert_document(type, attrs, dataset, opts \\ []) do
    attrs = from_envelope(attrs)
    raw_id = Map.get(attrs, "doc_id") || Map.get(attrs, :doc_id)
    doc_id = raw_id && DraftId.draft_id(raw_id)

    attrs =
      attrs
      |> Map.put("doc_id", doc_id)
      |> Map.put("type", type)
      |> Map.put("dataset", dataset)
      |> Map.put_new("status", "draft")
      # The row id is forced to `drafts.<id>` above, so a caller-supplied
      # `"status":"published"` would be an incoherent draft-prefixed/published
      # row — coerce that one value to "draft". Task workflow statuses
      # (active/planning/completed/archived) pass through untouched; lifecycle
      # publish/unpublish write via Document.changeset directly, not here.
      |> Map.update("status", "draft", fn
        "published" -> "draft"
        s -> s
      end)
      |> Map.put("rev", generate_rev())
      |> WriteScope.put_scope_attrs(opts)
      |> Sheets.maybe_recompute_sheet_formulas(type)
      |> Sheets.hydrate_sheet_embed_snapshots()
      # R2 chokepoint (id-less backfill, barkpark-obsidian): the Sanity-shaped
      # `patch` mutation and the autosave/upsert path can carry id-less
      # `content["blocks"]`. Fill ids BEFORE projection (projection reads block
      # ids, it never mints them) so the persisted + projected blocks all carry
      # a stable id — the canvas-diff prerequisite. Additive, idempotent.
      |> maybe_ensure_block_ids()
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
      case doc_id && Content.get_document(doc_id, type, dataset, opts) do
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
              # Field-encryption chokepoint (mirror of create_document). Fail
              # closed: a marked field that cannot be sealed rejects the write.
              with {:ok, enc_attrs} <- maybe_encrypt_marked_fields(attrs, type, dataset) do
                existing
                |> Document.changeset(enc_attrs)
                |> Repo.update()
                |> Broadcast.tap_broadcast(
                  dataset,
                  type,
                  "update",
                  existing.rev,
                  Keyword.get(opts, :source, :api),
                  Keyword.get(opts, :user_id)
                )
              end

            _ ->
              with {:ok, enc_attrs} <- maybe_encrypt_marked_fields(attrs, type, dataset) do
                %Document{}
                |> Document.changeset(enc_attrs)
                |> Repo.insert()
                |> Broadcast.tap_broadcast(
                  dataset,
                  type,
                  "create",
                  nil,
                  Keyword.get(opts, :source, :api),
                  Keyword.get(opts, :user_id)
                )
              end
          end

        result
        |> WriteScope.fire_after(:after_save, payload)
        |> Sheets.tap_sheet_writethrough()
    end
  end

  # R2 chokepoint (id-less backfill). When a document write carries a
  # `content["blocks"]` LIST, route it through the canonical
  # `BlockOps.ensure_block_ids/1` so every block has a stable, unique id before
  # storage — the exact contract the paper upsert path already enforces. A write
  # whose content has no "blocks" key (a legacy flat field-map save) is returned
  # untouched. Additive (a present non-blank id is preserved byte-identical) and
  # idempotent (re-running over an id-bearing list writes nothing new), so this
  # never changes content beyond filling absent/blank ids on id-less blocks.
  defp maybe_ensure_block_ids(attrs) do
    content = Map.get(attrs, "content")

    case content && Map.get(content, "blocks") do
      blocks when is_list(blocks) ->
        # Two normalizers at the SAME chokepoint: `ensure_block_ids` fills id-less
        # blocks; `normalize_list_items` coerces legacy flat-STRING list items to
        # the canonical inline-array shape (the obsidian list-item-crash fix). Both
        # additive + idempotent + render-preserving, so a write of a clean
        # (id-bearing, canonical-item) block list passes through byte-identical.
        new_blocks = blocks |> BlockOps.ensure_block_ids() |> BlockOps.normalize_list_items()
        Map.put(attrs, "content", Map.put(content, "blocks", new_blocks))

      _ ->
        attrs
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
        Map.put(
          attrs,
          "content",
          Projection.project(content, blocks, Labels.render_opts(dataset))
        )

      _ ->
        attrs
    end
  end

  # Field-encryption write chokepoint (Phase 2, core-auth). Replaces each
  # `encrypted: true` schema field's value in `content` with a ciphertext
  # envelope so plaintext never persists. A write with no content map, or whose
  # type has no encrypted field, passes through byte-identical (additive +
  # idempotent — see `Barkpark.Content.Encryption`). Called immediately before
  # every `Document.changeset` in both create and upsert.
  defp maybe_encrypt_marked_fields(attrs, type, dataset)
       when is_binary(type) and is_binary(dataset) do
    case Map.get(attrs, "content") do
      content when is_map(content) ->
        # HIGH-3 (red-team): FAIL CLOSED. `encrypt_marked/3` now returns
        # `{:error, {:encryption_failed, …}}` when a marked-encrypted field cannot
        # be sealed; we surface it so create/upsert REJECT the write (422-class)
        # instead of persisting plaintext-at-rest.
        case Encryption.encrypt_marked(content, type, dataset) do
          {:ok, encrypted} -> {:ok, Map.put(attrs, "content", encrypted)}
          {:error, _} = err -> err
        end

      _ ->
        {:ok, attrs}
    end
  end

  # A nil/non-binary `type` or `dataset` never reaches here as a write that could
  # persist an encrypted-marked field as plaintext: the upstream owner-scope
  # resolution (`WriteScope.put_scope_attrs` → `owner_scoped?` → `get_schema`)
  # already fails closed on a non-binary dataset, and the mutate route's
  # `:dataset` is a path param (always binary). So this is a plain no-op.
  defp maybe_encrypt_marked_fields(attrs, _type, _dataset), do: {:ok, attrs}

  # ── Envelope coercion + id/rev generation ─────────────────────────────────

  @reserved_in ~w(_id _type _rev _draft _publishedId _createdAt _updatedAt doc_id type dataset rev title status content)

  @doc false
  def from_envelope(attrs) do
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

  @doc false
  def generate_id(type) do
    "#{type}-#{:rand.uniform(999_999)}"
  end

  @doc false
  def generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
