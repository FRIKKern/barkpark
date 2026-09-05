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
    LabelSpine,
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

  # The terminal lifecycle states, for the tombstone fence below. DUPLICATED
  # from `Barkpark.Tasks.Close`'s private `@closed_lifecycle_statuses` because
  # a module attribute cannot be read across modules — and pinned against it by
  # `TombstoneFenceTest`'s "the terminal set matches Close's", which reads
  # close.ex's own bytes and reds if either list moves without the other. A
  # fence keyed on a stale copy of "what closed means" would let a mint through
  # on whichever status the two disagree about.
  @terminal_lifecycle_statuses ~w(done cancelled blocked)

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
  THE MUTATE-PATH SCHEMA CHECK (task-41a740fd6701ec28) — advise by default,
  enforce per dataset.

  Until this function existed, `Barkpark.Content.Validation` was never reached
  from a write door: `validate_document/4` had exactly two callers
  (`content/forms.ex` and the Studio doc handler), neither of them a write
  funnel, so a create whose content violated its own schema's `required` rule
  answered 200 and PERSISTED.

  Mounted HERE rather than in `MutateController` on purpose (the row's
  chokepoint criterion): `create_document/4` is the funnel every create-family
  verb passes through (create / createOrReplace / createIfNotExists / replace),
  and `upsert_document/4` is the update/patch/autosave funnel. A controller
  mount would have left the Studio, plugin, CLI and forms doors unchecked.

  Two modes, per the recorded ruling — see `Barkpark.Content.Validation`'s
  moduledoc for the flag, the reasoning and the migration story:

    * `Validation.enforce?(dataset)` false (DEFAULT, every dataset) — findings
      are queued on the advisory channel (`Warnings`, charter D5) as
      `schema_validation` entries naming the field and the rule, and `:ok` is
      returned. The write lands with the SAME status and the SAME bytes it
      landed with before this function existed.
    * `Validation.enforce?(dataset)` true (per-dataset opt-in) — returns
      `{:error, {:schema_validation_failed, errors}}`, which
      `Content.Errors.build/1` renders as 422 `validation_failed` with the
      per-field errors in `details`. Nothing is written: this runs BEFORE the
      changeset on every branch that calls it.

  A type with no schema, a schema with no validation rules, and content that
  satisfies its schema all return `:ok` having queued nothing — the advisory
  and the refusal fire only on content that breaks a DECLARED rule.
  """
  @spec check_document_schema(String.t(), map(), String.t()) ::
          :ok | {:error, {:schema_validation_failed, map()}}
  def check_document_schema(type, attrs, dataset) when is_binary(type) and is_binary(dataset) do
    enforce? = Barkpark.Content.Validation.enforce?(dataset)

    # ADVISE with nobody collecting: the validation would cost a `get_schema`
    # read to produce an advisory that `Warnings.put/3` then DROPS on the floor
    # (the queue is only open when a controller called `reset/0`). That is the
    # exact case `Warnings.listening?/0` exists for. NOT a fail-open — under
    # ENFORCE the check always runs, and in ADVISE the skipped work has no
    # observable output by construction.
    if enforce? or Barkpark.Content.Warnings.listening?() do
      do_check_document_schema(type, attrs, dataset, enforce?)
    else
      :ok
    end
  end

  def check_document_schema(_type, _attrs, _dataset), do: :ok

  defp do_check_document_schema(type, attrs, dataset, enforce?) do
    content = Map.get(attrs, "content") || Map.get(attrs, :content) || %{}
    title = Map.get(attrs, "title") || Map.get(attrs, :title)

    case validate_document(type, title, content, dataset) do
      {:ok, _content} ->
        :ok

      {:error, errors} when is_map(errors) and map_size(errors) > 0 ->
        if enforce? do
          {:error, {:schema_validation_failed, errors}}
        else
          emit_schema_advisories(type, attrs, errors)
          :ok
        end

      _ ->
        :ok
    end
  end

  # One advisory per offending FIELD, each naming the field and every rule it
  # broke — the validator's own message text ("Required", "Must be at least 3
  # characters", "Must be at most 80 characters", "Does not match required
  # format") is the rule name a caller can act on. Severity "warning" (the dedup wall's advise band), never an
  # error: promotion is charter-forbidden (D5). `Warnings.put/3` drops silently
  # when no collector opened the queue, so a Studio LiveView calling the writer
  # directly never grows one.
  defp emit_schema_advisories(type, attrs, errors) do
    pid = Map.get(attrs, "doc_id") || Map.get(attrs, :doc_id) || "(new)"

    errors
    |> Enum.sort_by(fn {field, _} -> to_string(field) end)
    |> Enum.each(fn {field, messages} ->
      Barkpark.Content.Warnings.put(
        "schema_validation",
        "#{type}/#{pid}: #{field} — #{messages |> List.wrap() |> Enum.join("; ")} " <>
          "(schema advisory; this dataset does not enforce schema validation)",
        "warning"
      )
    end)

    :ok
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
    # Two envelope/user-field NAME COLLISIONS, refused BEFORE the envelope
    # coercion — [collide-refusal] for the mixed shape, [status-collision] for
    # a flat `status` that cannot be a lifecycle value. See each function for
    # its full reasoning. All four create-family verbs (create /
    # createOrReplace / createIfNotExists / replace) funnel through this one
    # function, so both gates cover the family rather than one instance.
    with :ok <- refuse_orphan_top_level_keys(attrs),
         :ok <- refuse_colliding_status(attrs) do
      do_create_document_from_attrs(type, attrs, dataset, opts)
    end
  end

  defp do_create_document_from_attrs(type, attrs, dataset, opts) do
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

    # Fail-closed scope stamp (felix-w26): put_scope_attrs returns
    # {:ok, attrs} | {:error, reason} — a refused dataset resolution surfaces
    # here instead of silently stamping dataset_id=NULL. The stamp stays BEFORE
    # Sheets.hydrate_sheet_embed_snapshots (it reads the stamped scope keys).
    with :ok <- refuse_non_map_block_elements(attrs),
         {:ok, attrs} <- WriteScope.put_scope_attrs(attrs, opts),
         attrs =
           attrs
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
           |> maybe_ensure_block_ids(),
         :ok <- validate_task_kind(type, attrs),
         :ok <- refuse_malformed_label_spine(type, attrs) do
      do_create_document(type, attrs, dataset, doc_id, opts)
    end
  end

  # ── The label spine's CREATE-time half (task-e89f4a9ed2f5ce0b) ─────────────
  #
  # THE DEFECT WAS THE PARTIAL WRITE, NOT THE VALIDATION. `LabelSpine.validate/1`
  # was mounted at the publish wall ONLY (`AuthoringWall.enforce/5`'s
  # `label_gate`, reached from `Lifecycle.publish_document/4`). So
  # `bp task create --publish` — one caller intention, two server halves —
  # committed the create and THEN 422'd `label_spine` on the publish, stranding a
  # `drafts.<id>` no published-first reader can see while rc=0 and a printed
  # receipt read as success. A wall that rejects AFTER creating the draft is not
  # validating a write; it is committing half of one.
  #
  # This runs the SHAPE half BEFORE any row is persisted. It sits here — inside
  # `create_document/4`'s pre-write `with`, beside `validate_task_kind/2` — for
  # the same reason the two collision gates sit at the top of that function: all
  # four create-family verbs (create / createOrReplace / createIfNotExists /
  # replace) funnel through this one function, so the gate covers the family
  # rather than one instance.
  #
  # SCOPED TO `type:task`. The other walled type (`paper`) births published
  # through `Papers.BlockOps.upsert_paper/2`, which enforces the FULL wall on a
  # synthesized ref before its own Repo write and therefore never half-writes.
  #
  # NOT the full `validate/1`: a draft with no description and no tags is
  # unfinished, not malformed, and drafts stay free. `validate_shape/1` is the
  # judgeable subset — see its @doc and the LabelSpine moduledoc's RULING on why
  # the registry (`unknown_tag`) half stays publish-time.
  #
  # The tuple is `LabelSpine`'s own, so `Content.Errors.build/1` renders the
  # SAME 422 `label_spine` body (code / message / details) the publish wall
  # emits — one error shape for one rule, whichever door refused it.
  defp refuse_malformed_label_spine("task", attrs) do
    LabelSpine.validate_shape(Map.get(attrs, "content") || Map.get(attrs, :content) || %{})
  end

  defp refuse_malformed_label_spine(_type, _attrs), do: :ok

  # ── The transient-connection seam on the CREATE path ───────────────────────
  #
  # WHAT WAS BROKEN. `Barkpark.Tasks.Dedup.fetch_candidates/2` carries a
  # function-wide rescue that renders a pool fault as a NAMED, retryable 503
  # (`{:error, {:dedup_unavailable, _}}`). Its own comment says the rescue is on
  # the wrong side of the boundary: "That DBConnection.ConnectionError is raised
  # OUTSIDE this function, so the rescue/catch below never see it." Every OTHER
  # Repo call on the create path sits outside that guard — the `Content.
  # get_document` prev-doc lookup below, the four birth guards
  # (`ensure_task_transition_legal`, `ensure_close_reason_lands_with_a_close`,
  # `ensure_task_born_adjudicated`, `ensure_task_surface_declared`), and the
  # `Repo.insert` in `create_after_dedup/6`. A dropped checkout at any of them
  # propagated uncaught to Phoenix RenderErrors → `BarkparkWeb.ErrorJSON`, and
  # the caller got 500 `internal_error / "unknown error
  # (DBConnection.ConnectionError)"` — a TERMINAL shape for a TRANSIENT fault.
  # `BarkparkCloud.Sites.Deploy.transient_refusal?/1` grants retry grace by
  # matching the CODE, and `internal_error` is not on its transient list, so the
  # one condition that clears on its own was the one condition every caller was
  # told to escalate.
  #
  # THE FIX IS A REGION, NOT A CALL SITE. The rescue wraps the whole of
  # `do_create_document!/5` — prev-doc lookup, all four birth guards, the dedup
  # gate and the insert — because a checkout can be refused at ANY of them and
  # the caller's remedy is identical at all five: resend. The refusal is
  # `{:error, {:connection_unavailable, message}}`, which
  # `Barkpark.Content.Errors.build/1` renders as 503 `storage_unavailable` with
  # `reason: "connection_unavailable"` — the same transient shape
  # `{:dedup_unavailable, _}` already wears.
  #
  # BLAST RADIUS, STATED. This rescue covers `Writer.create_document/4` and
  # NOTHING ELSE. Its callers are the four Sanity-shaped create verbs through
  # `Content.Mutations` (create / createOrReplace / createIfNotExists /
  # replace — the door `bp task create` files through), `Tasks.Fleet.register`,
  # `Plugins.Github.Intake`, `Plugins.Tickets.Thread`, `Media.Assets`,
  # `Content.TagRegistry`, `BulldocsFormController`, the Studio field handler
  # and `mix onix.import`. `upsert_document/4` — every autosave, patch, block
  # op, media/sheets/forms/GitHub/papers/revision-restore write — is
  # DELIBERATELY NOT WRAPPED and still raises exactly as it did before; the
  # `:upsert_prev_doc_lookup` fault site below exists so a test can prove that
  # untouched door is untouched rather than asserting it in prose.
  #
  # NO FAIL-OPEN. `rescue e in DBConnection.ConnectionError` matches that one
  # struct. Nothing else is caught, nothing is reraised into a success, and no
  # arm returns `{:ok, _}` or an empty result — a fault becomes a named ERROR
  # tuple or it keeps propagating untouched. The `Tasks.Dedup` pg_trgm fallback
  # is the precedent: narrow on purpose.
  defp do_create_document(type, attrs, dataset, doc_id, opts) do
    do_create_document!(type, attrs, dataset, doc_id, opts)
  rescue
    e in DBConnection.ConnectionError ->
      Logger.error(
        "Barkpark.Content.Writer.create_document/4: the database connection was lost mid-write " <>
          "(type=#{inspect(type)} dataset=#{inspect(dataset)} doc_id=#{inspect(doc_id)}) — " <>
          "answering 503 storage_unavailable/connection_unavailable. " <>
          "exception=#{Exception.message(e)}"
      )

      {:error, {:connection_unavailable, connection_fault_message(e)}}
  end

  # The caller-facing sentence. It must say the one thing a bare 500 never did:
  # the write is AMBIGUOUS. The draft row may already have landed before the
  # connection dropped, and a blind retry then walks into the dedup wall and
  # reads as a duplicate-of-itself refusal. So the message names the check.
  defp connection_fault_message(%DBConnection.ConnectionError{} = e) do
    "the database connection was lost while writing this document " <>
      "(#{Exception.message(e)}). Nothing was refused on its merits — this is " <>
      "transient, and the correct move is to resend the identical request. " <>
      "BUT THE WRITE IS AMBIGUOUS: the draft row may already have landed " <>
      "before the connection dropped. Check before retrying — for a task, " <>
      "`bp doc ls task --perspective drafts` lists the unpublished drafts in " <>
      "this dataset; otherwise re-read the document id you sent. If it is " <>
      "already there, publish or delete that draft instead of resending, or " <>
      "the retry will be refused as a duplicate of your own first attempt."
  end

  # Test-only fault seam, mirroring `Tenancy.WorkspaceBundle.inject_copy_fault!/0`
  # (PDS-D43) verbatim in intent: the SQL sandbox cannot produce a REAL rescuable
  # transport failure — a pool timeout under `Ecto.Adapters.SQL.Sandbox` arrives
  # as an ownership-shutdown EXIT and takes the test's own connection with it — so
  # the test raises the exact exception the live 500 carried, at the exact Repo
  # call it was raised at. The config value is `{site, exception_module, message}`
  # so the SAME seam proves both halves of the contract: a
  # `DBConnection.ConnectionError` becomes the named 503, and ANY OTHER exception
  # still propagates untouched. `nil` in every non-test env — one
  # `Application.get_env` on a path that is already about to hit Postgres.
  defp inject_write_fault!(site) do
    case Application.get_env(:barkpark, :writer_fault) do
      {^site, module, message} when is_atom(module) and is_binary(message) ->
        raise module, message

      _ ->
        :ok
    end
  end

  defp do_create_document!(type, attrs, dataset, doc_id, opts) do
    ctx = WriteScope.build_ctx(opts)

    # Scope the prev-doc lookup to the writer's workspace/project. An UNSCOPED
    # lookup here would resolve (and then UPDATE/overwrite) another workspace's
    # row that happens to share the (doc_id, type, dataset) leaf — the inner
    # half of the B3 mutate leak. Scoped, a same-id write from a different
    # workspace sees no prev_doc and falls through to an insert of its own row.
    inject_write_fault!(:prev_doc_lookup)

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
         :ok <-
           ensure_close_reason_lands_with_a_close(type, attrs, dataset, doc_id, prev_doc, opts),
         :ok <- ensure_task_born_adjudicated(type, attrs, doc_id, prev_doc, opts),
         :ok <- ensure_task_surface_declared(type, attrs, doc_id, prev_doc, opts),
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
              # The schema check (task-41a740fd6701ec28) rides the same `with`,
              # BEFORE encryption, so an enforcing dataset refuses on the
              # PLAINTEXT content the caller actually sent.
              with :ok <- check_document_schema(type, attrs, dataset),
                   {:ok, enc_attrs} <- maybe_encrypt_marked_fields(attrs, type, dataset) do
                enc_attrs = maybe_render_paper_body_html(enc_attrs, type, dataset)

                # [acrc-publish-atomicity-txn-boundary] The doc write and its
                # `mutation_events` row land or fail TOGETHER. Before this wrap
                # the `Repo.update` AUTO-COMMITTED and `tap_broadcast`'s
                # `save_event` (`Repo.insert!`) raised afterwards, leaving a
                # committed document no consumer ever hears about. The wrap is
                # deliberately narrow — encryption and paper-body rendering stay
                # OUTSIDE, so the transaction covers two INSERTs and nothing else.
                Broadcast.write_atomically(fn ->
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
                end)
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
              # Schema-check AFTER scaffold/projection too and for the same
              # reason (task-41a740fd6701ec28): a schema-declared
              # `initial_values` default or a projected layout field SATISFIES a
              # `required` rule, so checking the pre-scaffold attrs would warn
              # about fields the schema itself just filled in.
              with :ok <- check_document_schema(type, attrs, dataset),
                   {:ok, enc_attrs} <- maybe_encrypt_marked_fields(attrs, type, dataset) do
                enc_attrs = maybe_render_paper_body_html(enc_attrs, type, dataset)
                inject_write_fault!(:insert)

                # [acrc-publish-atomicity-txn-boundary] See the update branch:
                # birth is wrapped for the same reason, and a failed
                # `save_event` now un-births the row instead of stranding it.
                Broadcast.write_atomically(fn ->
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
                end)
              end
          end

        finish_deferred_after_save(result, payload)
    end
  end

  @doc false
  def finish_deferred_after_save(result, payload) when is_map(payload) do
    result
    |> WriteScope.fire_after(:after_save, payload)
    |> Sheets.tap_sheet_writethrough()
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

    # Fail-closed scope stamp (felix-w26): mirror of create_document/4 — a
    # refused dataset resolution errors out here, never a silent NULL stamp.
    # The stamp stays BEFORE Sheets.hydrate_sheet_embed_snapshots and the
    # body_html render path (both read the stamped scope keys).
    with :ok <- refuse_non_map_block_elements(attrs),
         {:ok, attrs} <- WriteScope.put_scope_attrs(attrs, opts),
         attrs =
           attrs
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
           |> maybe_sanitize_paper_body_html(type),
         :ok <- validate_task_kind(type, attrs) do
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
    #
    # NOT WRAPPED IN THE CREATE PATH'S CONNECTION RESCUE, ON PURPOSE. This fault
    # site exists so `writer_connection_fault_test.exs` can PROVE the boundary:
    # the identical injected `DBConnection.ConnectionError` that the create door
    # now names as a 503 still propagates uncaught from the upsert door, so the
    # blast radius of that rescue is a measured fact rather than a claim in a
    # comment. Widening it to every autosave/patch/media/sheets/forms/GitHub
    # write is a separate contract change with its own callers to survey.
    inject_write_fault!(:upsert_prev_doc_lookup)

    prev_doc =
      case doc_id && Content.get_document(doc_id, type, dataset, opts) do
        {:ok, d} -> d
        _ -> nil
      end

    # Transition gate immediately after prev-doc resolution, BEFORE
    # :before_save fires — a refusal is side-effect-free (the validate_task_kind
    # position precedent).
    #
    # THE BIRTH GUARDS RIDE HERE TOO (cch-w28, D331). This function has its own
    # INSERT branch (`upsert_after_gate`'s `_ ->` clause, `%Document{} |>
    # changeset |> Repo.insert()`), reached whenever `prev_doc` is nil — which
    # is the same definition of birth `do_create_document` uses. Until now that
    # branch called NEITHER birth guard, so `POST /api/documents/task`
    # (LegacyController.create, `source: :api`) filed a brand-new task row
    # straight past both fences: measured 201 for an epic filing with no
    # `surface` and past the shipped PDS birth fence for `disposition` as well.
    # Both guards head-match on `prev_doc == nil`, so every UPDATE arriving here
    # (autosave, patch merges, media/sheets/GitHub/forms/revision-restore) is
    # structurally untouched — they no-op on a live row exactly as they do on
    # the create path.
    # THE DEDUP GATE RIDES HERE TOO (pds-bl-upsert-insert-branch-ungated-birth).
    # Run-proven before this line existed: the create path refused a
    # near-duplicate ({:error, {:duplicate_task, _}}) while
    # `Content.upsert_document` on the SAME attrs and an unseen doc_id BIRTHED
    # it (drafts.<id> persisted). `check_new_task/5` head-matches on
    # `prev_doc == nil` exactly like the two birth guards above, so every
    # UPDATE arriving here (autosave, patch merges, block ops, forms) is
    # structurally untouched — parity with `do_create_document:175`.
    with :ok <- ensure_task_transition_legal(type, attrs, dataset, doc_id, prev_doc, opts),
         :ok <-
           ensure_close_reason_lands_with_a_close(type, attrs, dataset, doc_id, prev_doc, opts),
         :ok <- ensure_task_born_adjudicated(type, attrs, doc_id, prev_doc, opts),
         :ok <- ensure_task_surface_declared(type, attrs, doc_id, prev_doc, opts),
         :ok <- Barkpark.Tasks.Dedup.check_new_task(type, attrs, dataset, prev_doc, opts) do
      upsert_after_gate(type, attrs, dataset, ctx, prev_doc, opts)
    end
  end

  defp upsert_after_gate(type, attrs, dataset, ctx, prev_doc, opts) do
    # The UPDATE half of the mutate-path schema check (task-41a740fd6701ec28).
    # One call covers both branches below: `attrs` reaching here is already the
    # FINAL whole-document content (patch merging, projection and block-id fill
    # all ran in `upsert_document/4`), so there is no pre-merge shape to warn
    # about. Placed before `:before_save` fires so an enforcing refusal is
    # side-effect-free — the `validate_task_kind` position precedent.
    with :ok <- check_document_schema(type, attrs, dataset) do
      do_upsert_after_gate(type, attrs, dataset, ctx, prev_doc, opts)
    end
  end

  defp do_upsert_after_gate(type, attrs, dataset, ctx, prev_doc, opts) do
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

                # [acrc-publish-atomicity-txn-boundary] The doc write and its
                # `mutation_events` row land or fail TOGETHER. Before this wrap
                # the `Repo.update` AUTO-COMMITTED and `tap_broadcast`'s
                # `save_event` (`Repo.insert!`) raised afterwards, leaving a
                # committed document no consumer ever hears about. The wrap is
                # deliberately narrow — encryption and paper-body rendering stay
                # OUTSIDE, so the transaction covers two INSERTs and nothing else.
                Broadcast.write_atomically(fn ->
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
                end)
              end

            _ ->
              with {:ok, enc_attrs} <- maybe_encrypt_marked_fields(attrs, type, dataset) do
                enc_attrs = maybe_render_paper_body_html(enc_attrs, type, dataset)

                # [acrc-publish-atomicity-txn-boundary] See the update branch:
                # birth is wrapped for the same reason, and a failed
                # `save_event` now un-births the row instead of stranding it.
                Broadcast.write_atomically(fn ->
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
                end)
              end
          end

        if Keyword.get(opts, :defer_after_save, false) do
          defer_after_save(result, payload)
        else
          finish_deferred_after_save(result, payload)
        end
    end
  end

  @doc false
  def take_deferred_after_save do
    Process.delete(:barkpark_deferred_after_save)
  end

  @doc false
  def clear_deferred_after_save do
    Process.delete(:barkpark_deferred_after_save)
    :ok
  end

  defp defer_after_save({:ok, %Document{}} = result, payload) do
    Process.put(:barkpark_deferred_after_save, {result, payload})
    result
  end

  defp defer_after_save(result, _payload), do: result

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

  # ── THE TOMBSTONE FENCE (cch-w39-bl) ──────────────────────────────────────
  #
  # A DISPOSAL REASON IS A CLAIM, NOT A MEASUREMENT. `close_reason` is written
  # once and re-read by nobody, so nothing can ever contradict it — the exact
  # property this codebase refuses in a guard ("a guard that can only stay green
  # while the disease stays untreated is not a guard"). Two live specimens, from
  # ONE disposal loop, failing in OPPOSITE directions:
  #
  #   * cch-w36-bl-mecache-unknown-arms-remaining — a cancel aimed at a
  #     `drafts.` twin that HAS NEVER EXISTED (none of the store's 403 `drafts.`
  #     rows carries that slug) landed its reason on the PUBLISHED ROW OF RECORD
  #     and killed it. The tombstone's own words were "The published row is the
  #     one of record and is NOT touched here" — written onto the row it killed.
  #   * cch-w36-s6-invalid-precedence-details-win — the reason landed and the
  #     CLOSE DID NOT: `lifecycle_status` stayed `in_progress` with
  #     `claim.closed_at` nil. A row wearing an epitaph while still alive.
  #
  # THE FENCE: a close_reason may be MINTED only by a write that also lands a
  # terminal `lifecycle_status`. The reason and the close become ONE atomic
  # fact, so a two-step loop (patch the reason, then attempt the close) can no
  # longer leave the first half standing when the second half loses its CAS —
  # and a reason aimed at a row nobody is closing is refused AT THE MOMENT IT IS
  # WRITTEN, rather than discovered by a reader months later.
  #
  # WHAT IT DELIBERATELY DOES NOT DO, and this is the placement lesson the birth
  # fence below already paid for: it is `prev_doc`-AWARE, never a content-only
  # rule. `/v1/data/mutate` merges patches BEFORE validation, so a content-only
  # "close_reason implies terminal" would be RETROACTIVE and 422 every future
  # patch to a row that already carries one. So CORRECTING an existing tombstone
  # stays legal at any status — not a loophole but a REQUIREMENT: cch-w36-bl was
  # reopened and its false tombstone corrected in place, and a fence that
  # forbade that would forbid the repair it exists to enable.
  defp ensure_close_reason_lands_with_a_close("task", attrs, dataset, doc_id, prev_doc, opts) do
    content = Map.get(attrs, "content") || %{}
    now = present_string(Map.get(content, "close_reason") || Map.get(content, :close_reason))
    was = present_string(resolve_close_reason_was(prev_doc, doc_id, dataset, opts))
    status = Map.get(content, "lifecycle_status") || Map.get(content, :lifecycle_status)

    cond do
      # No tombstone in this write, or an unchanged one carried through a patch.
      is_nil(now) -> :ok
      now == was -> :ok
      # CORRECTING an existing reason — the audit action, always legal.
      not is_nil(was) -> :ok
      # Replication mirrors upstream verbatim (the same exemption its siblings take).
      Keyword.get(opts, :source, :api) == :sync -> :ok
      # MINTING one: the close must land in this same write.
      status in @terminal_lifecycle_statuses -> :ok
      true -> {:error, {:invalid_task_content, orphan_close_reason_error(status)}}
    end
  end

  defp ensure_close_reason_lands_with_a_close(_t, _a, _d, _i, _p, _o), do: :ok

  # The row's CURRENT close_reason, resolved published-fallback — the same two
  # steps `resolve_lifecycle_was/4` takes, for the same reason: the drafts-exact
  # prev_doc the writer already loaded, then the bare (published) id.
  defp resolve_close_reason_was(%Document{content: content}, _doc_id, _dataset, _opts),
    do: (content || %{})["close_reason"]

  defp resolve_close_reason_was(_prev_doc, doc_id, dataset, opts) do
    with id when is_binary(id) <- doc_id,
         pid when pid != "" and pid != id <- DraftId.published_id(id),
         {:ok, %Document{content: content}} <-
           Content.get_document(pid, "task", dataset, opts) do
      (content || %{})["close_reason"]
    else
      _ -> nil
    end
  end

  # Blank is not a value. `nil`, `""`, whitespace and non-strings are all "no
  # tombstone" — an empty reason must not license a mint, and must not read as a
  # PREVIOUS reason that would make the next write a mere "correction".
  defp present_string(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(_), do: nil

  defp orphan_close_reason_error(status) do
    %{
      "close_reason" => [
        "a close_reason may not be minted on a row this write does not close " <>
          "(lifecycle_status #{inspect(status)}): the reason and the close are ONE fact. " <>
          "Close through the close primitive (`bp task close <id> <worker> <epoch> " <>
          "<status> <reason>`, POST /v1/tasks/:id/close), which writes both together and " <>
          "rolls BOTH back when its CAS loses. A reason written beside a close that never " <>
          "landed is an epitaph on a living row."
      ]
    }
  end

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

  # ── THE FILING-LAW DOOR GUARD (cloud-console-hardening D307 / D331) ───────
  #
  # Standing Law 0 of the cloud-console-hardening epic says a row filed under
  # the epic declares WHICH SURFACE it is about. Wave 27 proved by hand that the
  # law can hold — 13 of 13 instrument rows went to the successor at create time
  # and zero residue reached the parent — but it held because a person was
  # watching. This is the door that makes it hold without one.
  #
  # THE SEAT IS HERE, beside `ensure_task_born_adjudicated/5` (D331, which
  # SUPERSEDES D324's `Content.apply_mutations` placement). D324 filed the guard
  # at `mutations.ex` on the premise that its create clause carries no guard —
  # true at that file, wrong as a conclusion: a create-time HARD refusal already
  # ships one layer down, where `prev_doc == nil` IS birth and `opts` (and so
  # `:source`) is already in hand. The three placements the birth fence's own
  # header measured and REFUTED (PDS-D393 — pure content-only validation is
  # retroactive, `validate_task_kind/2` cannot see `prev_doc` or `:source`, a DB
  # CHECK is stateless) refute them for this guard identically. So this copies
  # that function's shape verbatim: same arity, same `{:error,
  # {:invalid_task_content, %{field => [msg]}}}` family (→ 422
  # `validation_failed`, no new error code, no new controller branch), same
  # non-`:api` source exemption, same two-tier hard/warn doctrine.
  #
  # THE SCOPING, AND WHAT IT IS MEASURABLY WORTH TODAY. The guard fires only for
  # a birth whose `content.parent_id` (drafts-normalised) is the epic. The wave
  # brief predicted that deleting that one arm would take
  # `mutate_controller_test.exs` to 23 failures including the D53 create-family
  # pins; RUN, IT DOES NOT — the mutation (delete `not cch_epic_child?(parent)
  # -> :ok`, change nothing else) yields 46 tests / 1 failure, and that one
  # failure is this slice's own scoping test. The prediction was derived against
  # a PRESENCE requirement, which would indeed refuse every task fixture in the
  # repo; D331 made ABSENCE the warn tier, and no fixture outside this slice's
  # own block carries a `surface` key at all, so an unscoped guard has almost
  # nothing to refuse. The scoping still ships — it is what stops this epic's
  # filing law from silently becoming a global rule the day another epic uses
  # the word `surface` — but it is a DESIGN boundary, not a load-bearing leg
  # under today's corpus, and saying otherwise here would be the kind of
  # sentence this epic exists to delete.
  #
  # WHAT IS HARD: an OFF-VOCABULARY `surface`. The vocabulary is closed and
  # EXACT CASE, for the reason the birth fence states about `OPEN`/`open`: a
  # differently-cased term is a row that claims to be classified in a language
  # nothing else reads, and the raw door is exactly how that split gets in.
  #   * `console`    — a surface a person operates.
  #   * `instrument` — a gate, harness, generator or required-check.
  #   * `ledger`     — a defect in the TASK ROSTER itself. This does NOT collapse
  #     into `instrument`: rows like `cchi-w27-bl-d307-create-time-door-guard`
  #     have no console and no harness, and folding them would make the filing
  #     law classify ITSELF as an instrument defect.
  #
  # WHAT IS A WARN, AND WHY THAT IS THE HONEST TIER. A birth carrying NO
  # `surface` is LOGGED (one greppable, countable line) and ALLOWED. Requiring
  # presence today would refuse legitimate filings, and that is measured, not
  # feared: `surface` is a three-day-old convention carried by only 5 of the 347
  # rows created before 2026-08-02, and of the 56 live orphans it is populated
  # on 5 and null on 51 — a presence requirement armed now refuses 91% of
  # legitimate filings. The backfill that would earn the promotion is not
  # mechanically producible either: blind against the 15 open rows carrying
  # human-written surface prose, a description classifier scores 7/15 (47%) and
  # a structured-field classifier 6/15 (40%), while a one-line constant scores
  # 11/15 (73%) — both BELOW the majority baseline. (D324 filed this guard
  # rather than shipping one that lies after measuring its drafted predicate
  # refusing 4 of 6 legitimately person-facing rows.) The promotion to hard is
  # its own row; until the backfill lands, "every epic row declares a surface"
  # is FALSE and this comment is where that is admitted.
  #
  # REPLICATION IS EXEMPT, checked FIRST, for the sibling guards' reason:
  # `Sync.Applier.apply_upsert` mirrors an upstream row verbatim inside one
  # transaction, so a refusal would roll back the batch and wedge the replica.
  # `:source` is server-set on every HTTP door, so no request body can reach it.
  @cch_epic_parent "cloud-console-hardening-epic"
  @cch_surfaces ~w(console instrument ledger)

  defp ensure_task_surface_declared("task", attrs, doc_id, nil = _prev_doc, opts) do
    content = Map.get(attrs, "content") || Map.get(attrs, :content) || %{}
    parent = Map.get(content, "parent_id") || Map.get(content, :parent_id)
    surface = Map.get(content, "surface") || Map.get(content, :surface)

    cond do
      Keyword.get(opts, :source, :api) != :api ->
        :ok

      not cch_epic_child?(parent) ->
        :ok

      blank?(surface) ->
        # ONE greppable line, deliberately (the birth fence's precedent): this
        # fires on every undeclared epic filing, so its value is that it can be
        # COUNTED — `grep -c "filing law: undeclared surface"`.
        Logger.warning(
          "filing law: undeclared surface on epic task birth #{inspect(doc_id)} — no " <>
            "content.surface (allowed; the backfill is not yet producible — 5 of 56 live " <>
            "orphans carry one. Declare it with one of: " <>
            Enum.join(@cch_surfaces, " | ") <> ")"
        )

        :ok

      surface not in @cch_surfaces ->
        {:error, {:invalid_task_content, birth_surface_term_error(surface)}}

      true ->
        :ok
    end
  end

  defp ensure_task_surface_declared(_type, _attrs, _doc_id, _prev_doc, _opts), do: :ok

  # The epic slug, drafts-normalised: a draft filing carries
  # `parent_id: "drafts.cloud-console-hardening-epic"` from the same
  # draft-first write path every other task field rides, and a guard that only
  # matched the published spelling would be bypassable by filing a draft.
  defp cch_epic_child?(parent) when is_binary(parent),
    do: DraftId.published_id(parent) == @cch_epic_parent

  defp cch_epic_child?(_parent), do: false

  # Same `invalid_task_content` family as the transition, disposition and birth
  # siblings (422 `validation_failed` with a per-field details map). The message
  # is the retry instruction: it names the vocabulary AND what each term means,
  # because the refusal is the only place a filer learns the law.
  defp birth_surface_term_error(term) do
    %{
      "surface" => [
        "cannot be filed under #{inspect(@cch_epic_parent)} as #{inspect(term)}. A row in this " <>
          "epic declares WHICH SURFACE it is about, drawn from a fixed, lowercase-canonical " <>
          "vocabulary (#{Enum.map_join(@cch_surfaces, ", ", &inspect/1)}): \"console\" is a " <>
          "surface a person operates, \"instrument\" is a gate/harness/generator/required-check, " <>
          "and \"ledger\" is a defect in the task roster itself. An off-vocabulary or " <>
          "differently-cased term is a row that claims to be classified in a language nothing " <>
          "else reads, which is how the epic's residue became uncountable in the first place. " <>
          "Re-file with one of the three terms, or omit `surface` entirely — an undeclared " <>
          "surface is warned and allowed while the backfill is unproducible."
      ]
    }
  end

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

  # THE ELEMENT-TYPE FLOOR ON THE WRITE PATH (task-f8c7b0387f50534e).
  #
  # `Render.render_blocks/2` guards the LIST (`when is_list(blocks)`) and then
  # maps `render_block/2` — which guards the ELEMENT (`when is_map(block)`) —
  # over it, with nothing in between. A create carrying
  # `{"body":{"blocks":["notamap"]}}` therefore cleared the list guard and
  # raised FunctionClauseError from inside the write projection:
  #
  #   mutate_controller → Mutations.apply_one → Writer.create_document
  #     → scaffold_expectation → Projection.project/4 (projection.ex, "body")
  #     → Projection.project_body/2 → Render.render_blocks/2 → render_block/2 ✗
  #
  # The transaction rolled back correctly, so no bad data landed — but the
  # caller got a 500 with an HTML debug page instead of the §9 JSON envelope,
  # with no `request_id` to correlate.
  #
  # WHY HERE AND NOT AT `render_blocks/2`. A guard clause on the renderer can
  # only DROP or coerce the element; it cannot tell the caller their request was
  # malformed, and the row asks for a 400 envelope. This is the first step of
  # both writer doors (`create_document/4` — which the whole create family
  # funnels through — and `upsert_document/4`), i.e. immediately after
  # `from_envelope/1` and BEFORE the scaffold, the id backfill, the normalizer
  # and the projection, so the refusal is side-effect-free and the renderer is
  # never reached with an input it has no clause for.
  #
  # SCOPE. Only the keys whose value the write path actually projects as a block
  # list are inspected — `content["blocks"]`, the body region in either of its
  # two shapes (`Projection.read_blocks/1`'s `%{"blocks" => […]}` and bare-list
  # forms), and any OTHER content value shaped `%{"blocks" => [...]}` (a schema
  # whose Expectation names its region something other than "body";
  # `Synthesis.scaffold/4` reads `values[region]`). A plain array FIELD — the
  # `"slug": ["a","b"]` shape that writes 200 today — is never a block list and
  # is deliberately not touched.
  defp refuse_non_map_block_elements(attrs) do
    case Map.get(attrs, "content") do
      content when is_map(content) ->
        Enum.reduce_while(content, :ok, fn {key, value}, :ok ->
          case validate_content_block_root(key, value) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      _ ->
        :ok
    end
  end

  # `content["blocks"]` and a bare-list body are block lists by name; any map
  # carrying a `"blocks"` list is a body-region shape whatever its key is called.
  defp validate_content_block_root("blocks", value) when is_list(value),
    do: BlockOps.validate_block_elements(value)

  defp validate_content_block_root("body", value) when is_list(value),
    do: BlockOps.validate_block_elements(value)

  defp validate_content_block_root(_key, %{"blocks" => blocks}) when is_list(blocks),
    do: BlockOps.validate_block_elements(blocks)

  defp validate_content_block_root(_key, _value), do: :ok

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
  # the extra key, so body_html is byte-unchanged. The row title is only the
  # preview's final fallback; content["title"] and a role:title block remain
  # stronger inside Preview.project/3.
  defp doc_render_opts(dataset, type, attrs) do
    scope = [
      workspace_id: Map.get(attrs, "workspace_id"),
      project_id: Map.get(attrs, "project_id")
    ]

    preview =
      %{
        media_resolver: Preview.media_resolver(scope),
        doc_type: type,
        title: Map.get(attrs, "title")
      }
      |> maybe_put_preview_url(type, attrs)

    # :style :article — task-605ba8bfbd54c871. This map used to carry NO :style,
    # so `Render.render_block/2`'s `Map.get(opts, :style, :email)` decided, and
    # the canonical `content["body"]["html"]` stored on EVERY document written
    # through this path was EMAIL html — the surface that inlines mail-client
    # typography on every element because mail clients strip stylesheets. The
    # row's census found ZERO readers that want that: the Studio editor source
    # textarea (forms.ex classic_form_value/1) and the v1 read envelope both
    # want neutral html, search subtracts the key entirely, and the one consumer
    # that genuinely wants inline email html — bulldocs_email_controller.ex —
    # passes `style: :email` itself and re-renders from blocks. So the write
    # path now NAMES its surface: :article, whose `<p>` is bare by contract
    # (`.bp-paper-surface` owns body typography). Only documents written after
    # this change move; existing rows re-project by attrition on their next
    # blocks write. The renderer's four :email defaults, labels.ex's non-article
    # fallback and the two style-less mix backfills are a filed follow-on.
    Labels.render_opts(dataset, scope)
    |> Map.put(:preview, preview)
    |> Map.put(:style, :article)
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
        content = attrs |> Map.drop(@reserved_in) |> keep_own_content_field(attrs)

        %{
          "doc_id" => id,
          "title" => title,
          "status" => status,
          "content" => content
        }
    end
  end

  # [own-content-field] gh-6291: a flat document's OWN field named `content`
  # was dropped, silently, from its own content.
  #
  # `@reserved_in` is the flat branch's FOLD-EXCLUSION list, and it is wider
  # than the set of keys this branch actually consumes. Audited key by key
  # against what `Envelope.render/3` emits back (envelope.ex — its reserved set
  # is the SEVEN `_`-prefixed keys, not these thirteen):
  #
  #   _id, doc_id            → consumed into `doc_id`, re-emitted as `_id`.
  #   _type, type            → the route's `:type` wins; re-emitted as `_type`.
  #   dataset                → the route's path segment wins.
  #   _rev, rev              → server-generated; re-emitted as `_rev`.
  #   _draft, _publishedId,
  #   _createdAt, _updatedAt → derived on read; never caller data.
  #   title                  → lifted to the column AND re-emitted by
  #                            `render/3` as "title", so it ROUND-TRIPS. Not
  #                            loss; do not "fix" it.
  #   status                 → lifted to the column but NEVER re-emitted. That
  #                            one is a real collision, handled by
  #                            `refuse_colliding_status/1` below, not here.
  #   content                → consumed by NOTHING on this branch. The branch is
  #                            DEFINED by `content` not being a map, so there is
  #                            no envelope to consume it. Dropping it was pure
  #                            loss with no beneficiary.
  #
  # So `content` is folded back in, exactly like every other non-reserved key.
  # WHY THIS IS NOT THE FOLD THE [collide-refusal] BLOCK FORBIDS: that refusal
  # protects the CONTENT-PRESENT branch, where `Content.Mutations`'
  # `incoming_content/1` sees only the nested map and is BLIND to flat siblings.
  # Here there is no nested map — `incoming_content/1` resolves through this
  # SAME function and therefore sees everything folded, which is precisely why
  # mutate_controller_test's "the FLAT Sanity envelope is not an escape" passes.
  # Folding one more key into a map the guard already reads adds no bypass.
  #
  # `@reserved_in` itself is left ALONE: `@collide_exempt` is derived from it,
  # and on the mixed branch `content` IS the envelope key and must stay exempt
  # there. The narrowing belongs to this branch only.
  #
  # An explicit `"content": null` is treated as "no value supplied" (the same
  # reading `Map.get/2` gives it everywhere else here), so it is not folded —
  # an internal caller that builds attrs with a nil content key keeps today's
  # shape rather than gaining a `%{"content" => nil}` entry.
  defp keep_own_content_field(folded, attrs) do
    case Map.fetch(attrs, "content") do
      {:ok, nil} -> folded
      {:ok, value} -> Map.put(folded, "content", value)
      :error -> folded
    end
  end

  # [collide-refusal] The mixed-shape data loss (Gyldendal field report #3).
  #
  # `from_envelope/1` above has exactly two behaviours, and the branch it takes
  # is decided by ONE test: "is there a map under the key `content`". On the
  # flat branch every non-reserved top-level key is folded into `content`. On
  # the content-present branch attrs pass through UNCHANGED — and then
  # `Document.changeset/2`'s `cast/3` whitelist (12 column names) silently
  # discards every top-level key that is not a column. Nobody wrote a line that
  # says "discard this"; the write answered 200 with the fields gone.
  #
  # THE TRIGGER IS A FIELD-NAME COLLISION, NOT A MALFORMED REQUEST. A purely
  # flat document whose own editorial field happens to be named `content` — a
  # Norwegian localized body, `content: %{"nb" => "brodtekst"}` — takes the
  # legacy-envelope branch without ever intending to use the legacy envelope,
  # and loses `slug`, `publishedAt`, `authorRef`. A bulk migration is safe until
  # ONE document type names a field `content`; then that type, and only that
  # type, loses everything else, silently, at scale.
  #
  # WHY THIS REFUSES AND MUST NEVER FOLD — do not "improve" this into a merge.
  # `Content.Mutations.incoming_content/1` (mutations.ex, the ledger
  # close-bypass guard) resolves the payload through this SAME
  # `from_envelope/1`. On a mixed shape it therefore sees only the nested
  # `content` map and is BLIND to flat siblings. That is safe today ONLY
  # because the cast strip stops those siblings landing. Folding orphan keys
  # into `content` would let a flat `lifecycle_status: "done"` beside a content
  # map land while `incoming_content` never saw it — a task-lifecycle bypass.
  # Refuse; do not fold.
  #
  # Loud, not advisory: a warning in a bulk migration is precisely how the
  # field report happened. The refusal names EVERY discarded key, taken at the
  # line that would have thrown them away, so the caller can fix the payload in
  # one pass. `_id` stays exempt — `from_envelope/1` legitimately consumes it
  # into `doc_id` — as does every other member of `@reserved_in`.
  #
  # Only string keys are considered: `@reserved_in` is a string list and the
  # HTTP/envelope shape this guards is always string-keyed. Internal callers
  # that build atom-keyed attrs are out of scope for this refusal (all of them
  # pass reserved keys only).
  #
  # `ifMatch` / `ifRevisionID` ride on the mutation payload as OPTIMISTIC-LOCK
  # CONTROL, not as document data — `Content.Mutations.if_rev/1` reads them off
  # the same map before handing it here — so they are exempt alongside
  # `@reserved_in`. They are exempt HERE only; adding them to `@reserved_in`
  # would change what `from_envelope/1` folds on the flat branch, which is a
  # different question and not this refusal's to answer.
  # The SCOPE COLUMNS. These are cast by `Document.changeset/2` exactly like
  # `title` and `status`, so they are NOT discarded on the content-present
  # branch — they land. Refusing them was a FALSE POSITIVE with teeth: it broke
  # `Content.put_scope_attrs/…`'s own callers, which pass a content map plus a
  # top-level `workspace_id`, and it was invisible to this slice's four gate
  # files. `@reserved_in` is `from_envelope/1`'s FOLD list, not the column
  # whitelist; the refusal must be keyed on the whitelist, because "would be
  # silently discarded" is precisely a statement about `cast/3`.
  #
  # Kept as its own list rather than folded into `@reserved_in`: adding them
  # there would change what the FLAT branch folds into `content`, which is a
  # different question (see the note on ifMatch/ifRevisionID above).
  @document_columns ~w(workspace_id project_id dataset_id owner_id)

  @collide_exempt @reserved_in ++ ~w(ifMatch ifRevisionID) ++ @document_columns

  defp refuse_orphan_top_level_keys(%{} = attrs) do
    if is_map(Map.get(attrs, "content")) do
      case attrs
           |> Map.drop(@collide_exempt)
           |> Map.keys()
           |> Enum.filter(&is_binary/1)
           |> Enum.sort() do
        [] -> :ok
        orphans -> {:error, orphan_keys_changeset(orphans)}
      end
    else
      :ok
    end
  end

  defp refuse_orphan_top_level_keys(_attrs), do: :ok

  # Surfaced as the canonical `validation_failed` 422 envelope
  # (`Content.Errors` already maps `{:error, %Ecto.Changeset{}}` there), keyed
  # under `unknown_fields` so a machine consumer keys on one field and a human
  # reads the names. A dedicated error code would mean a new `@hints` member
  # and an OpenAPI regeneration for a refusal that IS a validation failure.
  defp orphan_keys_changeset(orphans) do
    %Document{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(
      :unknown_fields,
      "top-level keys %{fields} are not document columns and would be silently " <>
        "discarded because this payload also carries a `content` map. Move them " <>
        "INSIDE `content`, or drop the `content` key so the flat envelope folds " <>
        "them for you. (A document whose own field is named `content` takes the " <>
        "legacy-envelope branch — rename that field or nest the whole document.)",
      fields: Enum.join(orphans, ", ")
    )
  end

  # [status-collision] gh-6292: a flat document's OWN field named `status` is
  # not storable, and the error the caller got never said so.
  #
  # `status` is the one member of `@reserved_in` that the flat branch CONSUMES
  # without ever giving back: it is lifted into the lifecycle column, and
  # `Envelope.render/3` does not re-emit it (its reserved set is the seven
  # `_`-prefixed keys; `title` is re-emitted, `status` is not). So a caller
  # whose document type has its own `status` field — an order, a subscription,
  # a stock record — hits one of two outcomes, and BOTH are bad reports:
  #
  #   1. A value outside the lifecycle vocabulary (`"in_stock"`) reaches
  #      `Document.changeset/2`'s `validate_inclusion` and comes back as
  #      `status: ["is invalid"]`. True, and useless: it blames the caller's own
  #      field without ever saying that the name is what collided, so there is
  #      nothing to act on. THAT is what this refusal replaces — same 422
  #      `validation_failed`, same `status` key, a message that names the
  #      collision and the way out.
  #
  #   2. A value that HAPPENS to be in the vocabulary (`"archived"`,
  #      `"completed"`, `"active"`) is accepted, rewrites the document's
  #      LIFECYCLE state, and the caller's field is gone from content. Silent.
  #      This refusal cannot catch that one: a flat `"status": "archived"` is
  #      byte-identical whether the caller meant the envelope or their own
  #      field, and refusing it would break the documented flat envelope
  #      (writer_test pins `"status" => "published"` → the status column).
  #      Resolving it needs a contract change (a `_status` envelope key, or
  #      consulting the type's schema for a declared `status` field), which is
  #      a different blast radius — filed, not smuggled in here.
  #
  # Guarded on the FLAT branch only: with a `content` map present, `status` is
  # unambiguously the envelope's and the caller's own field lives inside the
  # map, where nothing collides.
  defp refuse_colliding_status(%{} = attrs) do
    cond do
      is_map(Map.get(attrs, "content")) -> :ok
      not Map.has_key?(attrs, "status") -> :ok
      Map.get(attrs, "status") in Document.statuses() -> :ok
      true -> {:error, colliding_status_changeset(Map.get(attrs, "status"))}
    end
  end

  defp refuse_colliding_status(_attrs), do: :ok

  # Same envelope as the orphan-key refusal: `Content.Errors` already maps
  # `{:error, %Ecto.Changeset{}}` to the canonical 422 `validation_failed`, and
  # the error is keyed `:status` — the SAME key `validate_inclusion` would have
  # used — so a machine consumer that already branches on `status` keeps
  # working and only the human-readable message improves. No new error code, no
  # OpenAPI regeneration.
  defp colliding_status_changeset(value) do
    %Document{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(
      :status,
      "%{value} is not a document lifecycle status (one of %{allowed}). In a FLAT " <>
        "envelope the top-level `status` key is reserved for the document's lifecycle " <>
        "and is never read back as content, so a field of your own named `status` " <>
        "cannot be stored from this shape. Nest the whole document under a `content` " <>
        "map — inside it, `status` is an ordinary field and collides with nothing.",
      value: inspect(value),
      allowed: Enum.join(Document.statuses(), ", ")
    )
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
