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

  import Ecto.Query, only: [from: 2]

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

  alias Barkpark.PortableDoc.{HtmlSanitizer, Projection, Render, Synthesis}
  alias Barkpark.Preview
  alias Barkpark.Tasks.Stage
  alias Barkpark.Tasks.Transitions

  require Logger

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

    # Transition gate first (side-effect-free refusal, before dedup and
    # :before_save), then the find-or-create gate (task-obsession layer 1): a
    # NEW kind:task birth is refused if it duplicates an existing task. Dedup
    # only fires when prev_doc is nil (a genuine create — updates/autosaves/
    # publishes pass straight through) and fails LOUD: a scan that times out or
    # dies returns {:error, {:dedup_unavailable, msg}} rather than filing the
    # task unchecked. content.dedup_bypass: true is the deliberate escape.
    # See Barkpark.Tasks.Dedup.
    with :ok <- ensure_task_transition_legal(type, attrs, dataset, doc_id, prev_doc, opts),
         :ok <- ensure_task_born_adjudicated(type, attrs, doc_id, prev_doc, opts),
         :ok <- Barkpark.Tasks.Dedup.check_new_task(type, attrs, dataset, prev_doc, opts) do
      create_after_dedup(type, attrs, dataset, ctx, prev_doc, opts)
    end
  end

  defp create_after_dedup(type, attrs, dataset, ctx, prev_doc, opts) do
    # XSS hardening: the raw mutate/Writer path stores content verbatim, so an
    # attacker-supplied content["body_html"] would persist and later be emitted
    # raw() to the anonymous /papers reader. Scrub it here (covers create AND
    # createOrReplace — both the insert and the prev_doc-update branch below run
    # off this attrs). Mirrors the BlockOps chokepoint for the ingest path.
    attrs = maybe_sanitize_paper_body_html(attrs, type)

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
                enc_attrs = maybe_render_paper_body_html(enc_attrs, type, dataset)

                existing
                |> Document.changeset(enc_attrs)
                |> fenced_or_plain_update(existing, opts)
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
              attrs =
                attrs
                |> scaffold_or_initial_values(type, dataset)
                # Doctrine (pdd-t16): a paper born through the RAW mutate/Writer
                # path gets the same birth guarantee as upsert_paper — the
                # forced template on an explicit empty block list, doc.title
                # derived from the title block, and the article style stamp.
                # Additive: non-papers and block-less/legacy shapes untouched.
                |> maybe_apply_paper_template(type)

              # Encrypt AFTER scaffold/projection so the final projected field
              # values (the ciphertext-at-rest source of truth) are encrypted.
              with {:ok, enc_attrs} <- maybe_encrypt_marked_fields(attrs, type, dataset) do
                enc_attrs = maybe_render_paper_body_html(enc_attrs, type, dataset)

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
  # pdd-t16 — the Writer half of the paper birth guarantee. Mirrors the
  # upsert_paper chokepoint (block_ops.ex): seed on explicit [], derive title,
  # stamp article. Blocks live under content["blocks"] on this path.
  defp maybe_apply_paper_template(attrs, "paper") do
    alias Barkpark.Content.Papers.Template

    content = Map.get(attrs, "content") || %{}
    blocks = Map.get(content, "blocks")

    seeded = Template.maybe_seed(blocks, nil, %{"title" => Map.get(attrs, "title")})

    if is_list(seeded) do
      derived = Template.derive_title(%{"title" => Map.get(attrs, "title")}, seeded)
      styled = Template.stamp_article_style(%{"style" => content["style"]}, seeded)

      content =
        content
        |> Map.put("blocks", seeded)
        |> then(fn c ->
          case styled["style"] do
            s when is_binary(s) -> Map.put(c, "style", s)
            _ -> c
          end
        end)

      attrs
      |> Map.put("content", content)
      |> then(fn a ->
        case derived["title"] do
          t when is_binary(t) and t != "" -> Map.put(a, "title", t)
          _ -> a
        end
      end)
    else
      attrs
    end
  end

  defp maybe_apply_paper_template(attrs, _type), do: attrs

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
      |> BlockOps.normalize_render_shapes()

    content =
      provided
      |> Map.put("blocks", blocks)
      |> Projection.project(blocks, doc_render_opts(dataset, schema.name, attrs))

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
      # XSS hardening (mirror of create_after_dedup): scrub a verbatim
      # content["body_html"] on the patch/autosave path so poisoned markup
      # never persists as a draft that publish later promotes unchanged.
      |> maybe_sanitize_paper_body_html(type)

    with :ok <- validate_task_kind(type, attrs) do
      do_upsert_document(type, attrs, dataset, doc_id, opts)
    end
  end

  # Scrub an untrusted verbatim `content["body_html"]` on a paper write. Papers
  # carrying `content["blocks"]` still get scrubbed here (the reader serves the
  # body_html cache only when there are no blocks, but the cache on this generic
  # path is caller-supplied, not re-rendered — so it is never trusted). Every
  # non-paper type and any paper without a string body_html passes through
  # byte-identical.
  defp maybe_sanitize_paper_body_html(
         %{"content" => %{"body_html" => html} = content} = attrs,
         "paper"
       )
       when is_binary(html) do
    Map.put(attrs, "content", Map.put(content, "body_html", HtmlSanitizer.sanitize(html)))
  end

  defp maybe_sanitize_paper_body_html(attrs, _type), do: attrs

  # A block-backed Paper's PortableDoc blocks are the source of truth. The
  # generic document writer used to sanitize but otherwise preserve a caller's
  # body_html, so a patch could change blocks while retaining stale HTML and a
  # still-current renderer stamp. Re-render AFTER field encryption/template
  # normalization and immediately before the changeset, making blocks + cache +
  # stamp one atomic row write. HTML-only legacy papers keep the sanitizer path.
  defp maybe_render_paper_body_html(%{"content" => content} = attrs, "paper", dataset)
       when is_map(content) do
    case Projection.read_blocks(content) do
      blocks when is_list(blocks) ->
        scope = [
          workspace_id: Map.get(attrs, "workspace_id"),
          project_id: Map.get(attrs, "project_id")
        ]

        render_opts =
          Labels.paper_render_opts(dataset, Map.get(content, "style"), scope)

        content =
          content
          |> Map.put("body_html", Render.render_blocks(blocks, render_opts))
          |> Map.put("body_html_sv", Render.body_html_render_version())

        Map.put(attrs, "content", content)

      nil ->
        # No blocks to render from, so nothing on this write was server-rendered
        # and any "body_html_sv" in the payload is caller-controlled. Under a
        # stamp-vs-digest reader rule that is a classification switch a client
        # can flip (sv == digest pins a paper at 422; sv != digest forces the
        # overwrite branch). Provenance is server-derived only — strip it.
        Map.put(attrs, "content", Map.delete(content, "body_html_sv"))
    end
  end

  defp maybe_render_paper_body_html(attrs, _type, _dataset), do: attrs

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

    # Transition gate immediately after prev-doc resolution, BEFORE
    # :before_save fires — a refusal is side-effect-free (the validate_task_kind
    # position precedent).
    with :ok <- ensure_task_transition_legal(type, attrs, dataset, doc_id, prev_doc, opts) do
      upsert_after_gate(type, attrs, dataset, ctx, prev_doc, opts)
    end
  end

  defp upsert_after_gate(type, attrs, dataset, ctx, prev_doc, opts) do
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
                enc_attrs = maybe_render_paper_body_html(enc_attrs, type, dataset)

                existing
                |> Document.changeset(enc_attrs)
                |> fenced_or_plain_update(existing, opts)
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
                enc_attrs = maybe_render_paper_body_html(enc_attrs, type, dataset)

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

  # ── The Writer-seam transition gate (task-lifecycle-visibility, D7b + D21) ─
  #
  # Every HTTP door that can change a `type:task` row's `lifecycle_status`
  # funnels through do_create_document/do_upsert_document, so the ONE
  # transition-legality table (`Barkpark.Tasks.Transitions`, charter D7) is
  # enforced HERE — immediately after prev-doc resolution, BEFORE
  # `:before_save` fires, so a refusal is side-effect-free.
  #
  # `was` is resolved PUBLISHED-FALLBACK (get_patch_base-style: the Writer's
  # own drafts-exact prev_doc first, then the bare id), NOT drafts-exact.
  # Proven open at L1 (run probe 2026-07-22): with the drafts-exact lookup, a
  # createOrReplace on a PUBLISHED-ONLY open task births a `drafts.<id>` done
  # twin that Queue.ready's done-CTE (which regexp-strips the `drafts.` prefix)
  # counts — flipping a gated dependent to ready with zero attribution. A BIRTH
  # is when NEITHER spelling exists. Both lookups ride the caller's scope opts
  # (the B3 rule), so a same-id row in a foreign workspace never gates a birth.
  #
  # Exemptions — never consult `legal?/2` on a birth (`legal?(nil, x)` is false
  # by design and would refuse every task birth):
  #   * `was == nil` — a birth, or a legacy row with no lifecycle. The importer
  #     shape (migration 20260528100000 seeds already-`done` rows) depends on
  #     the birth being exempt.
  #   * `source == :sync` — `Sync.Applier` mirrors upstream transitions
  #     verbatim; `:source` is server-set (MutateController prepends
  #     `source: :api`), so a request body can never reach the exemption.
  #
  # `bp migrate` arrives `source: :api` via /v1/data/mutate: a fresh target is
  # birth-exempt, a steady re-migrate is same→same legal, and forcing a LIVE
  # target's lifecycle to mirror a since-closed source is REFUSED BY DESIGN —
  # divergence repair is Sync's job.
  #
  # This SUPERSEDES the mutations.ex revision escape for ILLEGAL transitions
  # (D7a): `ensure_task_close_is_cas`'s `ifRevisionID` escape still proves the
  # caller read the row, but a read no longer licenses an illegal transition —
  # this downstream gate wins for e.g. `open → done`. mutations.ex is untouched
  # (its rev-escape ordering is load-bearing for the claim fence), and LEGAL
  # terminal transitions (`open → blocked`, `open → cancelled`) still pass with
  # the rev escape exactly as before.
  defp ensure_task_transition_legal("task", attrs, dataset, doc_id, prev_doc, opts) do
    content = Map.get(attrs, "content") || %{}
    now = Map.get(content, "lifecycle_status") || Map.get(content, :lifecycle_status)
    was = resolve_lifecycle_was(prev_doc, doc_id, dataset, opts)

    cond do
      # Birth (neither id spelling exists) or a legacy no-lifecycle row.
      is_nil(was) -> :ok
      # Replication mirrors upstream transitions verbatim.
      Keyword.get(opts, :source, :api) == :sync -> :ok
      Transitions.legal?(was, now) -> :ok
      true -> {:error, {:invalid_task_content, illegal_transition_error(was, now)}}
    end
  end

  defp ensure_task_transition_legal(_type, _attrs, _dataset, _doc_id, _prev_doc, _opts), do: :ok

  # ── THE BIRTH FENCE (PDS wave 28) ─────────────────────────────────────────
  #
  # `Mutations.ensure_disposition_via_verb/4` fences every CHANGE of
  # `content.disposition` on a live row, and states its own residual harm:
  # "`ensure_*("task", nil, …), do: :ok` is the head of every sibling guard, and
  # the plain `create` clause calls no guard at all. So a `createOrReplace` on a
  # BRAND-NEW id carrying `disposition: "parked"` and no trigger is STILL
  # ACCEPTED". That is a row which SAYS it was adjudicated and adjudicated
  # nothing — born hollow, and thereafter untouchable by the update-path fence
  # precisely because the value never changes again.
  #
  # This is that fence, at the only place that can express "birth": beside
  # `Tasks.Dedup.check_new_task/5` in `do_create_document`'s `with` chain, where
  # `prev_doc` is already resolved and `opts` is already in hand. Three other
  # placements were measured and REFUTED (PDS-D393):
  #
  #   * `Barkpark.Tasks.Validation` is pure and receives CONTENT only — and
  #     `/v1/data/mutate`'s patch clauses (`mutations.ex:288`/`:324`) build
  #     `merged` and hand it to `upsert_document`, which validates at `:490`.
  #     Merge happens BEFORE validation on EVERY update, so a content-only rule
  #     is RETROACTIVE: it would 422 every future patch to today's bare rows.
  #   * `validate_task_kind/2` is arity 2 — it never receives `opts`, so it can
  #     carry no `:source` carve-out — and it runs at `:114`/`:490` BEFORE
  #     `prev_doc` is resolved, so it cannot tell a birth from an update.
  #   * A DB CHECK is stateless: it sees the candidate row and never `prev_doc`,
  #     so it can require a disposition on ALL task rows or on NONE. (No
  #     migration is forced either — `20260528100000_w7a_task_schema` constrains
  #     `lifecycle_status` VALUES only.)
  #
  # WHAT IS HARD, AND WHY EXACTLY THAT. The rule is PARITY WITH THE VERB: the
  # birth door may not accept an adjudication that `Barkpark.Tasks.Stage` — the
  # one sanctioned writer — would refuse. Stage refuses a term outside its
  # vocabulary and refuses a park with no reopen trigger, so those two refusals
  # transfer here verbatim, sourced from Stage's own accessors so the two doors
  # can never drift. Case is exact for the same reason Stage normalises: the
  # measured OPEN 57 / open 47 split is a raw-door artefact, and a birth that
  # writes "OPEN" would re-open it under a fence that claims to have closed it.
  #
  # WHAT IS A WARN, AND WHY IT IS HONEST TO SAY SO. A birth carrying NO
  # disposition at all is LOGGED (`pds birth fence: unadjudicated task birth`,
  # greppable and countable) and allowed. Requiring one is not a fence, it is a
  # protocol change for every existing producer — `bp task create`, every fleet
  # file-order, every fixture — and landing it as a hard halt here would refuse
  # writes that no client yet knows how to make. The promotion to hard is filed
  # as its own row rather than implied; until it lands, "residue 0 by
  # construction" is FALSE and this comment is where that is admitted.
  #
  # REPLICATION IS EXEMPT, checked FIRST, for the reason the sibling guard
  # states: `Sync.Applier.apply_upsert` mirrors an upstream row verbatim inside
  # one transaction, so a refusal would roll back the whole batch and wedge the
  # replica. `:source` is server-set (every HTTP door prepends `source: :api`),
  # so a request body can never reach a non-`:api` value. The inbound GitHub
  # bridge rides `source: :github` and is therefore structurally exempt — but it
  # is NOT exempted in practice: `Github.Intake.build_attrs/4` supplies the term
  # AND a reason naming the issue, so the bridge is born adjudicated and the
  # carve-out is only its fail-safe. That matters because an unmatched intake
  # error becomes HTTP 500 (`intake.ex` fallthrough →
  # `github_webhook_controller.ex`), and GitHub redelivers a 5xx forever.
  defp ensure_task_born_adjudicated("task", attrs, doc_id, nil = _prev_doc, opts) do
    content = Map.get(attrs, "content") || Map.get(attrs, :content) || %{}
    term = Map.get(content, "disposition") || Map.get(content, :disposition)
    trigger = Map.get(content, "reopen_trigger") || Map.get(content, :reopen_trigger)

    cond do
      Keyword.get(opts, :source, :api) != :api ->
        :ok

      blank?(term) ->
        # ONE greppable line, deliberately: this warning fires on every bare
        # birth, so its value is that it can be COUNTED
        # (`grep -c "pds birth fence: unadjudicated"`) — a paragraph per row
        # would drown the signal it exists to raise.
        Logger.warning(
          "pds birth fence: unadjudicated task birth #{inspect(doc_id)} — no " <>
            "content.disposition (allowed; adjudicate with `bp task stage <id> <state> " <>
            "--disposition <open|parked|closed> --note <why>`)"
        )

        :ok

      term not in Stage.dispositions() ->
        {:error, {:invalid_task_content, birth_disposition_term_error(term)}}

      term in Stage.trigger_required_dispositions() and blank?(trigger) ->
        {:error, {:invalid_task_content, birth_hollow_park_error(term)}}

      true ->
        :ok
    end
  end

  defp ensure_task_born_adjudicated(_type, _attrs, _doc_id, _prev_doc, _opts), do: :ok

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_), do: false

  # Same `invalid_task_content` family as the transition and disposition
  # siblings (422 `validation_failed` with a per-field details map) — no new
  # error code, no new controller branch. The message is the retry instruction.
  defp birth_disposition_term_error(term) do
    %{
      "disposition" => [
        "cannot be born as #{inspect(term)}. A disposition is an adjudication drawn from a " <>
          "fixed, lowercase-canonical vocabulary (#{Enum.map_join(Stage.dispositions(), ", ", &inspect/1)}) — " <>
          "an off-vocabulary or differently-cased term is a row that claims to be decided in " <>
          "a language nothing else reads, and it is exactly how the measured OPEN/open split " <>
          "got in. File the task without a disposition and adjudicate it through the sanctioned " <>
          "verb (`bp task stage <id> <state> --disposition <open|parked|closed> --note <why> " <>
          "--reopen-trigger <what would reconsider it>`, POST /v1/tasks/:id/stage), which " <>
          "normalises the term and writes term, reason and trigger in one atomic write."
      ]
    }
  end

  defp birth_hollow_park_error(term) do
    %{
      "reopen_trigger" => [
        "is required when a task is BORN #{inspect(term)}. The reopen trigger is the only " <>
          "thing that makes a park a deferral rather than a silent drop: without it nothing " <>
          "states what would bring the row back, and because the term never changes again the " <>
          "update-path fence will never see it either. Supply `reopen_trigger` at birth, or " <>
          "file the task undecided and park it through the sanctioned verb (`bp task stage " <>
          "<id> <state> --disposition parked --note <why> --reopen-trigger <what would " <>
          "reconsider it>`, POST /v1/tasks/:id/stage)."
      ]
    }
  end

  # The row's CURRENT lifecycle_status, resolved published-fallback: the
  # drafts-exact prev_doc the writer already loaded first, then the bare
  # (published) id — mirroring Mutations.get_patch_base/4, and scoped through
  # the same opts as the prev-doc lookup.
  defp resolve_lifecycle_was(%Document{content: content}, _doc_id, _dataset, _opts),
    do: (content || %{})["lifecycle_status"]

  defp resolve_lifecycle_was(_prev_doc, doc_id, dataset, opts) do
    with id when is_binary(id) <- doc_id,
         pid when pid != "" and pid != id <- DraftId.published_id(id),
         {:ok, %Document{content: content}} <-
           Content.get_document(pid, "task", dataset, opts) do
      (content || %{})["lifecycle_status"]
    else
      _ -> nil
    end
  end

  # Renders through the existing `invalid_task_content` family →
  # `Content.Errors` 422 validation_failed envelope, keyed on the field. The
  # message names from, to and the sanctioned verb — the refusal TEACHES
  # (tasks_controller stage/close precedent). Never the `{:halted, _}` shape,
  # which is reserved for plugin vetoes.
  defp illegal_transition_error(from, to) do
    %{
      "lifecycle_status" => [
        "illegal lifecycle transition #{inspect(from)} → #{inspect(to)}: no document " <>
          "write may perform it — " <> sanctioned_verb(to)
      ]
    }
  end

  defp sanctioned_verb("done"),
    do:
      "`done` is reached only through the close primitive (`bp task close <id> <worker> " <>
        "<epoch>`, POST /v1/tasks/:id/close), which records who closed it."

  defp sanctioned_verb("in_progress"),
    do:
      "a live claim is minted only by the claim primitive (`bp task claim <id> <worker>`, " <>
        "POST /v1/tasks/:id/claim), which fences on the claim epoch."

  defp sanctioned_verb(to) when to in ~w(considering researching),
    do:
      "thought states move through the sanctioned stage verb (`bp task stage <id> #{to}`, " <>
        "POST /v1/tasks/:id/stage), which enforces the same legality table."

  defp sanctioned_verb(_to),
    do:
      "move through the sanctioned task lifecycle verbs instead (`bp task stage` for " <>
        "considering|researching|open, `bp task claim`, `bp task close`)."

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
        new_blocks = blocks |> BlockOps.ensure_block_ids() |> BlockOps.normalize_render_shapes()
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
          Projection.project(
            content,
            blocks,
            doc_render_opts(dataset, Map.get(attrs, "type"), attrs)
          )
        )

      _ ->
        attrs
    end
  end

  # render_opts for the document projection paths, carrying the :preview sub-map
  # so Projection.project derives content["preview"] on a block-bearing whole-doc
  # write. doc_type is the raw type; the media resolver is bound to the write's
  # tenancy scope. A paper (unusual on this generic path) also gets its reader
  # url; other doctypes leave manifest["url"] nil. Render.render_blocks ignores
  # the extra key, so body_html is byte-unchanged.
  defp doc_render_opts(dataset, type, attrs) do
    scope = [
      workspace_id: Map.get(attrs, "workspace_id"),
      project_id: Map.get(attrs, "project_id")
    ]

    preview =
      %{media_resolver: Preview.media_resolver(scope), doc_type: type}
      |> maybe_put_preview_url(type, attrs)

    Map.put(Labels.render_opts(dataset, scope), :preview, preview)
  end

  defp maybe_put_preview_url(preview, "paper", %{"doc_id" => doc_id}) when is_binary(doc_id) do
    case DraftId.published_id(doc_id) do
      slug when slug != "" -> Map.put(preview, :url, "/papers/#{slug}")
      _ -> preview
    end
  end

  defp maybe_put_preview_url(preview, _type, _attrs), do: preview

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
        # Attribute the DEK to the document's workspace (charter D51-D54). The
        # scope-resolution (`WriteScope.put_scope_attrs`) has already stamped
        # `attrs["workspace_id"]` with the value the `Document.changeset` will
        # persist, so the encrypt-time workspace equals the stored one — a later
        # `reveal_fields` resolves the same (workspace_id, scope) DEK. `nil` (an
        # unscoped write) → the NULL-workspace DEK.
        workspace_id = Map.get(attrs, "workspace_id")

        case Encryption.encrypt_marked(content, type, dataset, workspace_id) do
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

  # [ifmatch-unfenced-update] Rev-fenced UPDATE — the write-path mirror of
  # lifecycle's `fenced_delete/1`. The mutation spine (`Content.Mutations`)
  # validates `ifMatch`/`ifRevisionID` against the row it READ, then calls
  # create/upsert whose UPDATE branch would otherwise issue a plain
  # `UPDATE … WHERE id = pk` (last-write-wins). A concurrent write committing in
  # the window between that guard read and this write would be CLOBBERED despite
  # the client's precondition — a lost update. When the caller threaded the
  # asserted rev through `opts[:if_rev]`, fence the UPDATE on it: the write lands
  # only if the row's rev is STILL what the client asserted; otherwise 0 rows
  # change and we surface the SAME `{:rev_mismatch, …}` (→ 412 precondition_failed)
  # that the delete fence already returns. With NO `:if_rev` (the client sent no
  # ifMatch) the original unfenced last-write-wins `Repo.update` is unchanged.
  defp fenced_or_plain_update(changeset, existing, opts) do
    case Keyword.get(opts, :if_rev) do
      expected when is_binary(expected) and expected != "" ->
        fenced_update(changeset, existing, expected)

      _ ->
        Repo.update(changeset)
    end
  end

  defp fenced_update(%Ecto.Changeset{valid?: false} = changeset, _existing, _expected),
    do: {:error, changeset}

  defp fenced_update(%Ecto.Changeset{} = changeset, %Document{} = existing, expected) do
    # Set from the changeset's computed changes (encrypted content, the freshly
    # generated rev, projected fields, scope). `updated_at` is stamped here since
    # `update_all` bypasses the schema's autogenerated timestamp. The
    # `WHERE rev = expected` clause is the fence: a concurrent write that bumped
    # the rev — already committed OR still in-flight (Postgres row-locks the
    # UPDATE until that txn commits, then re-evaluates the WHERE) — leaves 0 rows
    # matched, so a stale write can never clobber the newer one.
    set =
      changeset.changes
      |> Map.to_list()
      |> Keyword.put_new(:updated_at, DateTime.utc_now())

    query =
      from(d in Document,
        where: d.id == ^existing.id and d.rev == ^expected,
        select: d
      )

    case Repo.update_all(query, set: set) do
      {1, [doc]} ->
        {:ok, doc}

      {0, _} ->
        # Distinguish a vanished row from a rev bump — the exact shape of
        # `fenced_delete/1` so `Content.Errors` maps it identically.
        case Repo.get(Document, existing.id) do
          nil ->
            {:error, :not_found}

          %Document{rev: actual} ->
            {:error, {:rev_mismatch, %{expected: expected, actual: actual}}}
        end
    end
  end

  @doc false
  def generate_id(type) do
    # [doc-id-collision-overwrite] The old `:rand.uniform(999_999)` drew from a
    # 1M-value space, so an id-less `create` or a `clone_document`/"Duplicate"
    # that happened to draw a number already used by an unrelated same-type doc
    # landed in the write path as a `prev_doc` UPDATE — SILENTLY OVERWRITING that
    # doc (the UPDATE branch never errors on collision). Draw 8 bytes (64 bits)
    # of strong entropy instead so a collision is negligible, while keeping the
    # id shape readable (`<type>-<hex>`).
    "#{type}-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end

  @doc false
  def generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
