defmodule Barkpark.Content.Mutations do
  @moduledoc """
  The batch-mutation concern (H) — `apply_mutations/2` wraps the per-mutation
  `apply_one` dispatch in a `Repo.transaction`, driving broadcast-deferral:
  PubSub frames queued inside the transaction are flushed after a successful
  commit and discarded on rollback (no ghost SSE events on a failed batch).

  Extracted from `Barkpark.Content` (decomposition Step 13, concern H).
  `Barkpark.Content` keeps facade delegations so every external caller is
  unchanged; the per-mutation write/publish primitives are called back through
  `Barkpark.Content.*`, rev generation through `Content.Writer`, deferral
  through `Content.Broadcast`.

  ## `patch` on a `type:task` is PUBLISHED-FIRST (task-b9c618482e688500)

  Every other mutation kind resolves its base through
  `DraftId.draft_id/1` — draft-first — and `Writer.upsert_document/4` always
  writes to `drafts.<id>`. That is correct for a CMS content type: an edit is
  a draft until someone publishes it. It is WRONG for a `type:task` row,
  because the task API (`tasks_controller.ex find_task_by_doc_id/2`, the board,
  the ready queue, `bp task get`) reads PUBLISHED-first. The two doors
  therefore disagreed about which row `task-…` names, and the disagreement was
  silent: a patch carrying the rev `GET /v1/tasks/<id>` served 412'd (the
  actual rev being the draft twin's), and a patch carrying the TWIN's rev
  returned 200 with `results[0].id = "drafts.task-…"` while the row every
  reader serves stayed unchanged. Measured live on guerrilla 2026-09-02;
  22 task rows had already forked their `lifecycle_status` this way.

  THE BLAST RADIUS IS EXACTLY ONE MUTATION KIND AND ONE TYPE:

    * kinds: `patch` only — both clauses (plain `set`, and the compound
      `setIfMissing`/`unset`/`inc`/`dec`/`append`/`prepend` clause).
    * types: `@published_first_patch_types` — `task` only. `create`,
      `createOrReplace`, `createIfNotExists`, `replace` and `delete` keep their
      draft-first semantics VERBATIM for every type, tasks included; ordinary
      content types keep draft-first patching too, so the draft/publish model
      the Studio is built on is untouched.
    * ids: a BARE id only. `patch` naming `drafts.task-…` explicitly still
      resolves and writes the draft — the escape hatch for a caller that really
      does mean the twin.

  With a published row present, the patch base is that published row (so the
  rev a task reader served is the rev `ensure_rev/2` checks) and the write is
  LANDED there: `land_patch/5` publishes the freshly written draft through
  `Content.publish_document/4`, which upserts the published row and deletes the
  draft. Two consequences worth naming:

    * a task patch now passes the publish door's gates —
      `Tasks.PublishGuards.door_gate/4`, a `:door` pre-publish fence (legal
      lifecycle transition, no claim substitution, no criteria regression) and
      `Content.AuthoringWall.enforce/5` (`task` is a walled type). Those turn
      writes that used to 200-onto-nothing into honest refusals. This is the
      point: the write now goes where readers look, so it is now held to the
      rules that guard what readers see.
    * a PRE-EXISTING draft twin is refused, not merged: publishing through it
      would silently destroy whatever that twin holds. The refusal is a 422
      `validation_failed` whose detail NAMES `drafts.<id>` and says how to
      resolve it (`discardDraft` or `publish`).

  A task with NO published row (never published) still resolves and writes
  draft-first — the same fallback `find_task_by_doc_id/2` performs, so the two
  doors agree in that case too.
  """

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.ManagedRuntime.WriteAdmission.Door

  alias Barkpark.Content.{
    BoundFieldSync,
    Broadcast,
    CallerContext,
    DraftId,
    Envelope,
    MutateDoorFences,
    PatchPath,
    ReadOnlyFields,
    ReferenceIntegrity,
    Warnings,
    Writer
  }

  # ── dryRun (task-ca600d55736bc9ca) ──────────────────────────────────────────
  #
  # `opts[:dry_run]` (the mutate door's `dryRun`) runs the batch inside its
  # transaction and then ROLLS IT BACK: the document, revision, event and audit
  # rows go with it, and the deferred broadcast/webhook queue is cleared instead
  # of flushed. The door used to ignore the flag, so a `dryRun: true` request
  # committed a real draft.
  #
  # The rollback cannot reach the one thing that runs during the batch and
  # outside its connection: `WriteScope.fire_after/3`'s after_* hooks, edge
  # projector and after-write listeners. This process flag tells it to skip
  # them; `dry_run?/0` is how it asks.
  @dry_run_key :barkpark_mutate_dry_run

  @doc "True while this process is inside a dryRun batch (see `apply_mutations/3`)."
  def dry_run?, do: Process.get(@dry_run_key) == true

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
    # TIMED: the batch-mutate hot path had ZERO telemetry, so "what is p95 of a
    # mutate?" was unanswerable. `:telemetry.span` emits
    # `[:barkpark, :content, :mutate, :start | :stop | :exception]` with a
    # `:duration`; BarkparkWeb.Telemetry subscribes a Prometheus histogram to
    # `:stop` (p95 via histogram_quantile). `count` tags batch size. The span
    # reraises on exception exactly as the inner rescue already does.
    # `workspace_id` tags the span so per-workspace mutate volume/latency is
    # derivable (perfect-plan-build W1, D12). The value already rides `opts` via
    # `scope_opts(conn)`; nil (unscoped caller) coerces to "global" so the
    # Prometheus tag is always present and never crashes the reporter handler.
    workspace_id = Keyword.get(opts, :workspace_id) || "global"

    :telemetry.span(
      [:barkpark, :content, :mutate],
      %{count: length(mutations), dataset: dataset, workspace_id: workspace_id},
      fn ->
        result = Door.admit(fn -> do_apply_mutations(mutations, dataset, opts) end)
        {result, %{count: length(mutations), dataset: dataset, workspace_id: workspace_id}}
      end
    )
  end

  defp do_apply_mutations(mutations, dataset, opts) do
    dry_run? = Keyword.get(opts, :dry_run, false) == true

    # Initialise the deferred-broadcast queue for this process so
    # tap_broadcast/5 knows to queue instead of broadcast immediately, and CLAIM
    # it: the claim is what tells `maybe_dispatch_webhook/7` that this queue has
    # a flusher. It also resets `:barkpark_deferred_webhooks`, which this line
    # used to leave alone — a stale webhook entry stranded on this process by an
    # unowned transaction would otherwise be dispatched by the next mutate.
    Broadcast.claim_deferred_queue()
    if dry_run?, do: Process.put(@dry_run_key, true)

    try do
      result =
        Repo.transaction(fn ->
          :ok = serialize_unscoped_batch(opts)
          tx_id = Writer.generate_rev()

          # SECURITY: echo each mutated document through the REAL caller + the
          # type's schema, NOT the `:internal` no-redaction sentinel. A `patch`
          # op merges server-side `existing.content` the caller never supplied,
          # so an :internal echo would leak private/owner_only/readable_by
          # plaintext (and encrypted ciphertext) to a non-admin write or
          # edit-share token — exactly the fields a GET redacts. Admins /
          # admin-tokens still see all via the is_admin bypass; a writer that
          # supplied a field it can't read simply won't see it echoed (it
          # already knows the value it sent). Schema is memoised per type.
          caller = Keyword.get(opts, :caller_context) || CallerContext.anonymous()

          results = apply_all(mutations, dataset, opts, caller)

          # DRY RUN: every gate, fence and write above ran for real, so the
          # results are exactly what a real batch would answer — then the whole
          # transaction is thrown away.
          if dry_run?, do: Repo.rollback({@dry_run_key, {tx_id, results}}), else: {tx_id, results}
        end)

      case result do
        {:ok, _} ->
          Broadcast.flush_deferred_broadcasts()
          result

        {:error, {@dry_run_key, would_be}} ->
          Broadcast.clear_deferred_broadcasts()
          {:ok, would_be}

        # A failed dry run answers the real error, but never runs the
        # compensating discard: that is a write of its own.
        _ when dry_run? ->
          Broadcast.clear_deferred_broadcasts()
          result

        _ ->
          Broadcast.clear_deferred_broadcasts()
          compensating_discard(result, mutations, dataset, opts)
      end
    rescue
      e ->
        Broadcast.clear_deferred_broadcasts()

        case classify_search_vector_overflow(e, mutations) do
          {:ok, reason} -> {:error, reason}
          :no -> reraise(e, __STACKTRACE__)
        end
    after
      Process.delete(@dry_run_key)
    end
  end

  # task-6b5e4b3e572d38c9 — `ensure_unreferenced/5` (called from the plain
  # `"delete"` clause below) ran `ReferenceIntegrity.referrers/3` once PER
  # delete: a query per reference-typed field across every schema in the
  # dataset, PER delete, so a batch of N deletes cost O(N × reference
  # fields) queries inside one transaction (task-c801daf4efd35a74, the
  # 250-delete 500). Batched here: a RUN of 2+ CONSECUTIVE `"delete"`
  # mutations gets its referrers precomputed in ONE pass
  # (`ReferenceIntegrity.referrers_for_ids/3`) before any of them run, so the
  # whole run costs the SAME query count as a single delete, not that count
  # times the run's length.
  #
  # WHY ONLY A CONSECUTIVE RUN, NOT THE WHOLE BATCH AT ONCE: precomputing
  # referrers for every delete in the batch BEFORE the batch starts would
  # miss a reference CREATED earlier in the SAME transaction by an EARLIER,
  # non-delete mutation — the live per-id check sees it (Postgres read-committed:
  # your own transaction's earlier writes are visible to its later reads);
  # a single global precompute, run before mutation 1, would not. Chunking
  # on "is this a delete" and precomputing ONLY within each consecutive run —
  # right when that run begins, after every PRECEDING mutation in the batch
  # (delete or not) has already applied — preserves that visibility exactly:
  # a run's precompute sees everything that ran before it, same as the
  # unbatched per-id code would have. A lone delete between two non-deletes
  # still runs the ORIGINAL single-id path unchanged (a run of 1 gains
  # nothing from batching and this keeps that path's surface untouched).
  #
  # `referrers_for_ids/3`'s own moduledoc states the one deliberate
  # behaviour refinement this introduces: two documents in the SAME run that
  # reference each other no longer block one another (they vanish together
  # regardless of order, since the whole mutate is one transaction) — the
  # unbatched path was order-dependent for exactly that case.
  defp apply_all(mutations, dataset, opts, caller) do
    {chunks_results, _cache} =
      mutations
      |> Enum.chunk_by(&delete_mutation?/1)
      |> Enum.map_reduce(%{}, fn chunk, cache ->
        apply_chunk(chunk, dataset, opts, caller, cache)
      end)

    List.flatten(chunks_results)
  end

  defp delete_mutation?(%{"delete" => _}), do: true
  defp delete_mutation?(_), do: false

  defp apply_chunk([_, _ | _] = chunk, dataset, opts, caller, cache) do
    if delete_mutation?(hd(chunk)) do
      ids =
        chunk
        |> Enum.map(fn %{"delete" => %{"id" => id}} -> DraftId.published_id(id) end)
        |> Enum.uniq()

      precomputed = ReferenceIntegrity.referrers_for_ids(ids, dataset, opts)
      chunk_opts = Keyword.put(opts, :precomputed_referrers, precomputed)

      apply_each(chunk, dataset, chunk_opts, caller, cache)
    else
      apply_each(chunk, dataset, opts, caller, cache)
    end
  end

  defp apply_chunk(chunk, dataset, opts, caller, cache),
    do: apply_each(chunk, dataset, opts, caller, cache)

  defp apply_each(chunk, dataset, opts, caller, cache) do
    Enum.map_reduce(chunk, cache, fn m, cache ->
      case apply_one(m, dataset, opts) do
        {:ok, doc, op} ->
          :ok = between_mutations_barrier()
          {schema, cache} = echo_schema(doc.type, dataset, opts, cache)

          {%{
             id: doc.doc_id,
             operation: op,
             document: Envelope.render(doc, schema, caller)
           }, cache}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  # ── The tsvector cap is a CALLER fault, not an engine fault ────────────────
  #
  # `documents.search_vector` is a GENERATED ALWAYS ... STORED column (migration
  # 20260614220000_search_vector_fields — NOT the 20260526181000 original, which
  # has since been dropped and re-added twice). It folds `title` plus every
  # string value in the `content` jsonb through `to_tsvector`/`jsonb_to_tsvector`.
  # Postgres caps ONE tsvector at 1 048 575 bytes; past that the INSERT raises
  # `Postgrex.Error` SQLSTATE 54000 (`:program_limit_exceeded`) from inside the
  # transaction. Nothing rescued it, so it escaped `apply_mutations/3` and
  # Phoenix's RenderErrors rendered a bare 500 `internal_error` — which tells the
  # caller to RETRY a request that will fail identically forever, and books a
  # client mistake against the server's error rate. Measured live on guerrilla
  # 2026-09-10 (task-655f368ae5c72120): an 800 000-byte high-entropy body → 500.
  #
  # It is translated HERE, not in `MutateController`, for two reasons:
  #
  #   * the exception is raised by the WRITER, and every caller of
  #     `apply_mutations/3` (the HTTP mutate door, the plugin write paths, the
  #     Studio's LiveView saves) inherits the typed refusal instead of only the
  #     one door a controller rescue would cover;
  #   * this rescue already exists — it is the deferred-broadcast cleanup — and
  #     the `{:error, reason}` shape it now returns is exactly what the door
  #     already routes through `Content.Errors.to_envelope/2`. No new seam.
  #
  # NARROW BY CONSTRUCTION: only SQLSTATE 54000 whose message names `tsvector`
  # is claimed. Every other `Postgrex.Error` — and every other exception — is
  # reraised byte-identically, so no real engine fault is laundered into a 4xx.
  #
  # WHY 422 AND NOT 413: the cap is on the DERIVED tsvector, not on the request.
  # A 2 000 000-byte LOW-entropy body succeeds while an 800 000-byte high-entropy
  # one fails, so `payload_too_large` ("reduce the request body — it exceeds the
  # maximum allowed size") would be an actively false instruction. 422 is this
  # codebase's slot for "well-formed, but I cannot act on it as sent"
  # (`workspace_scope_required`, `batch_too_large`, `create_wall`).
  @tsvector_limit_bytes 1_048_575

  # THE UNSCOPED-BATCH SERIALIZER (task-59136713cece112c, ruling option b).
  #
  # `Audit.emit/1` takes the audit-chain lock of each DOCUMENT's workspace and
  # holds it to the end of this transaction. A batch whose opts name a workspace
  # reads fail-closed to it and stamps it on creates, so it audits under ONE
  # chain; the /mutate door always sends one (it refuses a key-absent write with
  # `workspace_scope_required`). A batch with NO workspace in its opts (internal
  # callers only) reads unscoped, so a `delete`/`publish` of rows in W1 and W2
  # takes chain(W1) and chain(W2) in mutation order, and two such batches in
  # opposite order deadlock (40P01) — pinned by
  # test/barkpark/content/unscoped_batch_audit_lock_order_test.exs.
  #
  # The chains it will need are known only after `apply_one/3` reads each row,
  # so a sorted up-front set is not computable. Instead every unscoped batch
  # takes the GLOBAL chain lock (the nil key) FIRST: two unscoped batches then
  # never interleave. A scoped transaction holds one chain and only ever takes
  # locks ordered after it (the #20369 publish-scope lock, rows), so it cannot
  # close a cycle with one either. `lock_chain!/1` is re-entrant, so a nil-
  # workspace document's own emit later in the batch does not wait on itself.
  # Scoped batches are untouched.
  defp serialize_unscoped_batch(opts) do
    if is_nil(Keyword.get(opts, :workspace_id)), do: Barkpark.Audit.lock_chain!(nil), else: :ok
  end

  # TEST-ONLY BARRIER SEAM (task-59136713cece112c). A lock-order race between
  # two batches needs each one parked INSIDE its transaction after its first
  # mutation, holding what that mutation locked, before its second one runs.
  # Nothing in a serial test produces that interleaving. A harness puts a
  # `fun/0` under this key in the BATCH process's dictionary; it runs once,
  # after the first successful mutation, and is removed before it runs, so it
  # fires at most once per `Process.put`. Process-scoped, so a concurrently
  # running async test can never trip it; unset (every production path), it
  # costs one `Process.get`. Nothing under api/lib may set the key:
  # test/barkpark/content/mutations_between_barrier_census_test.exs enforces
  # it. Same shape and rationale as `DedupWall.post_check_barrier/3`.
  @between_mutations_barrier :barkpark_mutations_between_barrier

  defp between_mutations_barrier do
    case Process.get(@between_mutations_barrier) do
      fun when is_function(fun, 0) ->
        Process.delete(@between_mutations_barrier)
        fun.()
        :ok

      _ ->
        :ok
    end
  end

  defp classify_search_vector_overflow(
         %Postgrex.Error{postgres: %{code: :program_limit_exceeded, message: message}},
         mutations
       )
       when is_binary(message) do
    if String.contains?(message, "tsvector") do
      {:ok, {:searchable_text_too_large, @tsvector_limit_bytes, largest_text_field(mutations)}}
    else
      :no
    end
  end

  defp classify_search_vector_overflow(_e, _mutations), do: :no

  # WHICH field overflowed. Postgres reports only a total byte count, so the
  # culprit is located from the payload the caller actually sent: the longest
  # string value across the batch, named by its `<doc id>` and JSON-pointer path.
  # That is a heuristic and the envelope's message says so — but it is the one
  # datum that turns "something in your write was too big" into an edit the
  # caller can make. Returns nil when the batch carries no string worth naming.
  defp largest_text_field(mutations) when is_list(mutations) do
    mutations
    |> Enum.flat_map(&mutation_payloads/1)
    |> Enum.flat_map(fn payload ->
      doc_id = payload["_id"] || payload[:_id]
      payload |> strings_with_paths("") |> Enum.map(fn {path, len} -> {doc_id, path, len} end)
    end)
    |> case do
      [] -> nil
      candidates -> candidates |> Enum.max_by(fn {_id, _path, len} -> len end) |> drop_length()
    end
  end

  defp largest_text_field(_), do: nil

  defp drop_length({doc_id, path, bytes}), do: %{document: doc_id, field: path, bytes: bytes}

  # A mutation is `%{"createOrReplace" => payload}` etc.; a `patch` nests the
  # document body one level deeper under `set`/`setIfMissing`/`append`/….
  defp mutation_payloads(mutation) when is_map(mutation) do
    Enum.flat_map(mutation, fn
      {_op, %{} = payload} ->
        nested =
          payload
          |> Map.take(["set", "setIfMissing", "append", "prepend", "unset", "inc", "dec"])
          |> Map.values()
          |> Enum.filter(&is_map/1)

        [payload | nested]

      _ ->
        []
    end)
  end

  defp mutation_payloads(_), do: []

  # Every string leaf of a payload, keyed by JSON pointer. Keys that begin with
  # `_` (`_id`, `_type`, `_rev`) are skipped: they are identity, never body, and
  # `title`/`content.*` are what the generated column actually reads.
  defp strings_with_paths(%{} = map, prefix) do
    Enum.flat_map(map, fn {key, value} ->
      key = to_string(key)

      if String.starts_with?(key, "_") do
        []
      else
        strings_with_paths(value, prefix <> "/" <> key)
      end
    end)
  end

  defp strings_with_paths(list, prefix) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, idx} ->
      strings_with_paths(value, prefix <> "/" <> to_string(idx))
    end)
  end

  defp strings_with_paths(value, prefix) when is_binary(value), do: [{prefix, byte_size(value)}]
  defp strings_with_paths(_value, _prefix), do: []

  # ── The `duplicate_of` compensation, OUTSIDE the batch transaction ─────────
  #
  # `Lifecycle.publish_after_gate/5` discards the draft a `duplicate_of` (E4)
  # refusal rejected — the wall's ONE terminal code, whose body names the
  # incumbent published document that survives. That delete is correct and
  # commits for a direct `Content.publish_document/4` caller, but under THIS
  # door it runs inside the batch transaction and `Repo.rollback/1` above puts
  # the draft straight back. A publish refused through `POST /v1/data/mutate`
  # would therefore still strand a `drafts.<id>` that no published-first reader
  # (`bp task ready`, the board, the epic roster) can see — the exact row the
  # 2026-09-04 census counted 409 of.
  #
  # So the delete is re-run HERE, after the rollback has unwound, keyed on
  # `payload.refused_draft_id` (stamped by Lifecycle, and dropped from the wire
  # body by `Content.Errors.build/1`'s `Map.take`). Two properties make this
  # safe rather than a second guess at the batch's intent:
  #
  #   * it fires ONLY on `{:duplicate_of, _}` — the other four wall refusals
  #     (label_spine / unknown_tag / invalid_epic_paper_quality / the transient
  #     dedup_unavailable) are author-fixable or retryable and their draft must
  #     survive, so they never reach this clause.
  #   * the id must be named by a `publish` op IN THIS BATCH, so a rollback
  #     reason can never authorise a delete the caller did not ask for. A batch
  #     that created the draft in the same transaction needs no compensation —
  #     the rollback already removed it, and `discard_draft/4` then answers
  #     `{:error, :not_found}`, which is discarded here.
  #
  # The refusal itself is returned UNCHANGED: the caller still gets the 409 and
  # the incumbent id.
  defp compensating_discard(
         {:error, {:duplicate_of, %{refused_draft_id: draft_id}}} = result,
         mutations,
         dataset,
         opts
       )
       when is_binary(draft_id) do
    case publish_op_type(mutations, draft_id) do
      nil -> result
      type -> with _ <- Content.discard_draft(draft_id, type, dataset, opts), do: result
    end
  end

  defp compensating_discard(result, _mutations, _dataset, _opts), do: result

  defp publish_op_type(mutations, draft_id) do
    bare = DraftId.published_id(draft_id)

    Enum.find_value(mutations, fn
      %{"publish" => %{"id" => id, "type" => type}} when is_binary(id) ->
        if DraftId.published_id(id) == bare, do: type

      _ ->
        nil
    end)
  end

  # Resolve the type's schema for the redacted echo, memoised across the batch.
  # Same scope-aware lookup the read path uses (`Content.get_schema/3` with the
  # request's scope opts); a missing schema → `nil` (Envelope still drops
  # encrypted ciphertext, but a typed schema is needed to redact non-encrypted
  # private fields, so a real type must resolve its schema here).
  defp echo_schema(type, dataset, opts, cache) do
    case Map.fetch(cache, type) do
      {:ok, schema} ->
        {schema, cache}

      :error ->
        schema =
          case Content.Schema.get_schema_for_redaction(type, dataset, opts) do
            {:ok, s} -> s
            _ -> nil
          end

        {schema, Map.put(cache, type, schema)}
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
        case Content.get_document(DraftId.draft_id(id), type, dataset, opts) do
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
        with :ok <-
               run_mutate_door_fences(:before_rev, type, nil, attrs, dataset, opts),
             :ok <-
               ensure_read_only_unchanged(type, nil, incoming_content(attrs), id, dataset, opts),
             {:ok, doc} <- Content.create_document(type, attrs, dataset, opts) do
          warn_create_over_published("create", type, id, dataset, opts, doc)
          {:ok, doc, "create"}
        end
    end
  end

  defp apply_one(%{"createOrReplace" => attrs}, dataset, opts) do
    type = attrs["_type"] || attrs["type"]
    id = attrs["_id"] || attrs["doc_id"]
    expected = if_rev(attrs)

    existing =
      case id && Content.get_document(DraftId.draft_id(id), type, dataset, opts) do
        {:ok, doc} -> doc
        _ -> nil
      end

    # The create-family doors onto the ledger (cch-w2, epic decision D53).
    # `existing` is nil for a genuine fresh create — both guards exempt that
    # case structurally (see their heads), so the importer shape
    # (migration 20260528100000 seeds already-`done` rows) keeps working while
    # a write ONTO a live claimed/open task is fenced exactly like a patch.
    with :ok <- run_mutate_door_fences(:before_rev, type, existing, attrs, dataset, opts),
         :ok <- ensure_rev(existing, expected),
         :ok <- ensure_task_close_is_cas(type, existing, incoming_content(attrs), attrs, opts),
         :ok <- ensure_claim_not_dropped(type, existing, incoming_content(attrs), opts),
         :ok <- run_mutate_door_fences(:after_claim, type, existing, attrs, dataset, opts),
         :ok <-
           ensure_read_only_unchanged(type, existing, incoming_content(attrs), id, dataset, opts),
         {:ok, doc} <- Content.create_document(type, attrs, dataset, with_if_rev(opts, expected)) do
      {:ok, doc, "createOrReplace"}
    end
  end

  # A PUBLISHED row occupies its id (owner ruling #41, task-e27126ee5e796e47).
  # The lookup used to read the draft alone, so on a published document with
  # no draft the call minted a fresh draft over the live content and the next
  # publish replaced the page with the "if not exists" payload. The SDK docs
  # and Sanity both call this a no-op; the server now agrees. A caller who
  # names `drafts.<id>` explicitly asks for the draft row itself, so only that
  # row is checked.
  defp apply_one(%{"createIfNotExists" => attrs}, dataset, opts) do
    type = attrs["_type"] || attrs["type"]
    id = attrs["_id"] || attrs["doc_id"]

    case id && type && create_if_not_exists_existing(id, type, dataset, opts) do
      {:ok, existing} ->
        case ensure_rev(existing, if_rev(attrs)) do
          :ok -> {:ok, existing, "noop"}
          err -> err
        end

      _ ->
        with :ok <-
               run_mutate_door_fences(:before_rev, type, nil, attrs, dataset, opts),
             :ok <-
               ensure_read_only_unchanged(type, nil, incoming_content(attrs), id, dataset, opts),
             {:ok, doc} <- Content.create_document(type, attrs, dataset, opts) do
          warn_create_over_published("createIfNotExists", type, id, dataset, opts, doc)
          {:ok, doc, "create"}
        end
    end
  end

  defp apply_one(%{"publish" => %{"id" => id, "type" => type}}, dataset, opts) do
    case Content.publish_document(id, type, dataset, opts) do
      {:ok, doc} ->
        {:ok, doc, "publish"}

      {:error, :not_found} = err ->
        # ALREADY LANDED, not missing (task-b9c618482e688500). `patch` on a
        # published-first type now publishes what it wrote (`land_patch/5`), and
        # publishing DELETES the draft — so the trailing `publish` of the
        # documented patch-then-publish idiom (`bp doc patch` + `bp doc publish`,
        # the cmux hook's met-flip republish) would find no draft and 404, which
        # reads to its caller as "the patch did not land" precisely when it did.
        # A publish whose whole effect is already on the published row is a NOOP,
        # not a failure. Deliberately NOT widened to every type: for an ordinary
        # content type a publish with no draft is still a genuine 404, because
        # nothing on that path lands a patch for it.
        if published_first_patch?(DraftId.published_id(id), type) do
          case Content.get_document(DraftId.published_id(id), type, dataset, opts) do
            {:ok, doc} -> {:ok, doc, "noop"}
            _ -> err
          end
        else
          err
        end

      other ->
        other
    end
  end

  defp apply_one(%{"unpublish" => %{"id" => id, "type" => type}}, dataset, opts) do
    with {:ok, doc} <- Content.unpublish_document(id, type, dataset, opts),
         do: {:ok, doc, "unpublish"}
  end

  defp apply_one(%{"discardDraft" => %{"id" => id, "type" => type}}, dataset, opts) do
    with {:ok, doc} <- Content.discard_draft(id, type, dataset, opts),
         do: {:ok, doc, "discardDraft"}
  end

  defp apply_one(%{"deleteExactDraft" => %{"id" => id, "type" => type} = op}, dataset, opts) do
    with {:ok, doc} <- Content.delete_exact_draft(id, type, dataset, if_rev(op), opts),
         do: {:ok, doc, "deleteExactDraft"}
  end

  defp apply_one(%{"delete" => %{"id" => id, "type" => type} = op}, dataset, opts) do
    # Reference integrity (task-c8c22ee8076535fe): refuse while another document
    # still points here, unless the op says `force: true`. See ensure_unreferenced/5.
    with :ok <- ensure_unreferenced(id, type, op, dataset, opts) do
      case if_rev(op) do
        nil ->
          with {:ok, doc} <- Content.delete_document(id, type, dataset, opts),
               do: {:ok, doc, "delete"}

        expected ->
          # The guard must read the SAME row-set delete_document acts on. It removes
          # BOTH the draft and published spellings, but get_document is an exact-id
          # match with no draft/published fallback — so an unpublished doc (present
          # only as drafts.<id>) guarded by its canonical id would miss the row and
          # spuriously 412. Read the exact id first (preserves every working case),
          # then fall back to the sibling spelling. ensure_rev(nil, _) still yields
          # rev_mismatch for a truly-absent doc — no regression on that path.
          existing =
            case Content.get_document(id, type, dataset, opts) do
              {:ok, d} ->
                d

              _ ->
                Enum.find_value([DraftId.draft_id(id), DraftId.published_id(id)] -- [id], fn v ->
                  case Content.get_document(v, type, dataset, opts) do
                    {:ok, d} -> d
                    _ -> nil
                  end
                end)
            end

          with :ok <- ensure_rev(existing, expected),
               {:ok, doc} <- Content.delete_document(id, type, dataset, opts) do
            {:ok, doc, "delete"}
          end
      end
    end
  end

  defp apply_one(%{"replace" => attrs}, dataset, opts) do
    type = attrs["_type"] || attrs["type"]
    id = attrs["_id"] || attrs["doc_id"]

    # The with-chain is DELIBERATELY UNCHANGED apart from the two guard steps
    # (epic decision D50). `replace` reads FIRST and propagates
    # `{:error, :not_found}` for an absent id — that 404 is the documented
    # contract (`docs/api-v1.md:105`: "overwrites an *existing* draft,
    # `not_found` if none"). Binding `existing` to nil to "make the guard's nil
    # fork reachable here" silently converts `replace` into an UPSERT (measured:
    # HTTP 200 + row created, and the whole mutate + writer-fence suite stayed
    # green through the regression). `existing` is therefore always a
    # `%Document{}` by the time the guards run, and their nil heads are simply
    # dead code on this path — load-bearing only for `createOrReplace` above.
    # `test "replace against a non-existent id is 404"` pins the contract.
    with {:ok, existing} <- Content.get_document(id && DraftId.draft_id(id), type, dataset, opts),
         :ok <- ensure_rev(existing, if_rev(attrs)),
         :ok <- ensure_task_close_is_cas(type, existing, incoming_content(attrs), attrs, opts),
         :ok <- ensure_claim_not_dropped(type, existing, incoming_content(attrs), opts),
         :ok <- run_mutate_door_fences(:after_claim, type, existing, attrs, dataset, opts),
         :ok <-
           ensure_read_only_unchanged(type, existing, incoming_content(attrs), id, dataset, opts),
         {:ok, doc} <-
           Content.create_document(type, attrs, dataset, with_if_rev(opts, if_rev(attrs))) do
      {:ok, doc, "replace"}
    end
  end

  # Phase-1B patch ops: setIfMissing / unset / inc / dec / append / prepend,
  # composable with set in one op. Placed BEFORE the set-only clause so any patch
  # carrying one of these lands here — the set clause would otherwise match on
  # `set` and silently ignore them; a pure-set patch carries none of these keys
  # and falls through to it. Order: setIfMissing fills absent defaults → set
  # merges (overriding) → inc/dec adjust the merged numeric values →
  # append/prepend extend list fields → unset removes. Promoted/system fields
  # (title/status/_id/_type/_rev) stay protected in `content`; an unset of
  # `title` clears the title COLUMN, as `set {title: ""}` does; malformed ops (a
  # non-map setIfMissing/inc/dec/append/prepend, a non-list unset, a non-numeric
  # delta, non-list append/prepend items) are ignored, not fatal.
  defp apply_one(%{"patch" => %{"id" => id, "type" => type} = patch}, dataset, opts)
       when is_map_key(patch, "setIfMissing") or is_map_key(patch, "unset") or
              is_map_key(patch, "inc") or is_map_key(patch, "dec") or
              is_map_key(patch, "append") or is_map_key(patch, "prepend") or
              is_map_key(patch, "insert") do
    # [bare-id-refusal] task-eeaf3a622b6c74c7 — `id`/`_id` under set/setIfMissing
    # address nothing here; refuse BEFORE the read so the answer does not depend
    # on whether the document exists. See Writer.refuse_bare_id/2.
    with :ok <- Writer.refuse_bare_id(Map.get(patch, "set"), :patch),
         :ok <- Writer.refuse_bare_id(Map.get(patch, "setIfMissing"), :patch),
         :ok <- lock_patch_target(id, dataset, opts),
         {:ok, existing} <- get_patch_base(id, type, dataset, opts),
         :ok <- ensure_rev(existing, if_rev(patch)),
         protected = patch_protected_keys(patch, type, dataset, opts),
         {:ok, applied} <- apply_patch_ops(existing.content || %{}, patch, protected) do
      set_fields = Map.get(patch, "set", %{})
      # The title is a row column, so an `unset` of it never reached the row:
      # unsetting clears it exactly as `set {title: ""}` does (task-a50bcf53bee78a53).
      # A `set` of the title in the same patch wins.
      title =
        if not Map.has_key?(set_fields, "title") and
             "title" in list_or_empty(Map.get(patch, "unset")),
           do: "",
           else: set_fields["title"]

      merged =
        applied
        # Bound-block write-through (task-d8785cff163c8013). On a blocks-bearing
        # document `Writer.maybe_project_document_content/2` re-derives every
        # `content[fieldName]` from `content["blocks"]`, so a merge alone was
        # overwritten back to the stale block value on the way to the row. Update
        # the block projection reads FROM; projection stays its sole writer. A
        # document with no block list is byte-identical. See BoundFieldSync.
        |> BoundFieldSync.sync(existing.content || %{}, title)

      attrs = %{
        "doc_id" => id,
        "title" => title || existing.title,
        "content" => merged
      }

      with :ok <- ensure_task_close_is_cas(type, existing, merged, patch, opts),
           :ok <- ensure_claim_not_dropped(type, existing, merged, opts),
           :ok <-
             run_mutate_door_fences(:after_claim, type, existing, merged, patch, dataset, opts),
           :ok <- ensure_read_only_unchanged(type, existing, merged, id, dataset, opts),
           {:ok, doc} <-
             Content.upsert_document(type, attrs, dataset, with_if_rev(opts, if_rev(patch))),
           {:ok, doc} <- land_patch(existing, type, doc, dataset, opts),
           do: {:ok, doc, "update"}
    end
  end

  defp apply_one(
         %{"patch" => %{"id" => id, "type" => type, "set" => fields} = patch},
         dataset,
         opts
       ) do
    # [bare-id-refusal] task-eeaf3a622b6c74c7 — see the ops arm above.
    with :ok <- Writer.refuse_bare_id(fields, :patch),
         :ok <- lock_patch_target(id, dataset, opts),
         {:ok, existing} <- get_patch_base(id, type, dataset, opts),
         :ok <- ensure_rev(existing, if_rev(patch)),
         prior = existing.content || %{},
         {:ok, applied} <-
           apply_patch_ops(
             prior,
             %{"set" => fields},
             patch_protected_keys(patch, type, dataset, opts)
           ) do
      warn_on_nested_content(fields)

      merged =
        applied
        # Bound-block write-through — see the ops clause above and
        # `Barkpark.Content.BoundFieldSync`.
        |> BoundFieldSync.sync(prior, fields["title"])

      attrs = %{
        "doc_id" => id,
        "title" => fields["title"] || existing.title,
        "content" => merged
      }

      with :ok <- ensure_task_close_is_cas(type, existing, merged, patch, opts),
           :ok <- ensure_claim_not_dropped(type, existing, merged, opts),
           :ok <-
             run_mutate_door_fences(:after_claim, type, existing, merged, patch, dataset, opts),
           :ok <- ensure_read_only_unchanged(type, existing, merged, id, dataset, opts),
           {:ok, doc} <-
             Content.upsert_document(type, attrs, dataset, with_if_rev(opts, if_rev(patch))),
           {:ok, doc} <- land_patch(existing, type, doc, dataset, opts),
           do: {:ok, doc, "update"}
    end
  end

  # [mutation-shape-422] #18, Gyldendal field report — a known {id,type} verb
  # sent WITHOUT one of the two keys names the field instead of answering a
  # bare 400 "request body is malformed".
  #
  # Every verb in @id_type_verbs has an `apply_one/3` head above that
  # pattern-matches `%{"id" => id, "type" => type}`. Omit either key and the
  # mutation matches no head at all and lands here — where, until this clause,
  # the caller got `{"code":"malformed","message":"request body is malformed"}`
  # with no verb and no field. That is a well-formed request the server cannot
  # act on as sent, which is what 422 already means in this codebase (see the
  # `workspace_scope_required` note in content/errors.ex), and the refusal now
  # says WHICH key is missing so a caller never has to read this file to
  # proceed. The list is derived from the heads above, not from the report —
  # the report named `publish`/`unpublish`/`delete`; `discardDraft` and `patch`
  # have the same shape and the same trap.
  #
  # DELIBERATELY NARROW — the generic 400 survives for anything genuinely
  # malformed: an unknown verb, a known verb whose payload is not a map, and a
  # `patch` that carries id+type but no recognized op (it has both keys, so
  # nothing is "missing" — it fails for a different reason and must not be
  # mislabelled).
  @id_type_verbs ~w(publish unpublish discardDraft delete deleteExactDraft patch)

  # Every verb an `apply_one/3` head above accepts. An object naming NONE of
  # them is still a 400 malformed (task-2f601b4f24e9af66). The code and status
  # stay, but the message now names what was sent and what is accepted, so a
  # typo'd verb does not send the caller into content/mutations.ex. A KNOWN verb
  # with a bad payload keeps the generic 400; see the note above.
  @mutation_verbs ~w(create createOrReplace createIfNotExists replace patch publish unpublish discardDraft delete deleteExactDraft)

  defp apply_one(mutation, _dataset, _opts) when is_map(mutation) do
    case missing_id_type(mutation) do
      {verb, missing} ->
        {:error, {:missing_mutation_fields, verb, missing}}

      nil ->
        if Enum.any?(Map.keys(mutation), &(&1 in @mutation_verbs)),
          do: {:error, :malformed},
          else: {:error, {:unknown_mutation_verb, Enum.sort(Map.keys(mutation)), @mutation_verbs}}
    end
  end

  defp apply_one(_, _, _), do: {:error, :malformed}

  defp create_if_not_exists_existing(id, type, dataset, opts) do
    case Content.get_document(DraftId.draft_id(id), type, dataset, opts) do
      {:ok, _} = found ->
        found

      _ ->
        if DraftId.draft?(id),
          do: {:error, :not_found},
          else: Content.get_document(DraftId.published_id(id), type, dataset, opts)
    end
  end

  # The first @id_type_verbs key present with a MAP payload that omits `id` or
  # `type`, as `{verb, missing_keys}`. `nil` means "not this defect" — either no
  # known verb, a non-map payload, or both keys present.
  defp missing_id_type(mutation) do
    Enum.find_value(@id_type_verbs, fn verb ->
      case Map.get(mutation, verb) do
        payload when is_map(payload) ->
          case Enum.reject(["id", "type"], &present_string?(Map.get(payload, &1))) do
            [] -> nil
            missing -> {verb, missing}
          end

        _ ->
          nil
      end
    end)
  end

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  # The ledger's back door (cch-w1-ledger-close-guard, epic decision D22).
  #
  # OBSERVED LIVE: a published, unclaimed `type:task` row went `open` → `done`
  # through a single `/v1/data/mutate` patch carrying `set:{"lifecycle_status":
  # "done"}`. No claim, no epoch, no worker, no `ifRevisionID` — HTTP 200, and
  # the row read back `lifecycle_status=done claim=None closed_by=None`. Zero
  # attribution. This is the mechanism behind this repo's costliest recurring
  # defect (11 tasks fake-done, then reopened). Worse, a `setIfMissing` in the
  # same patch FORGES `closed_by`, and after such a close the honest claimant —
  # correct worker AND correct epoch — gets `stale_claim` from the
  # already-terminal guard at `Tasks.Close` (close.ex:92), so the row is
  # permanently uncloseable through the sanctioned path and the error lies
  # about why.
  #
  # WHY IT LIVES HERE, AND AT BOTH CALL SITES: the compound-op clause (the
  # `setIfMissing`/`unset`/`inc`/… clause above) is exploitable through its OWN
  # `set` merge, independently of the plain-set clause — a patch carrying
  # `setIfMissing` + `unset` + `set:{"lifecycle_status":"done"}` matches the
  # compound guard and never reaches the plain clause. Guarding one leaves the
  # other fully open (D22). Both clauses call this after computing `merged`, so
  # the check reads the write's ACTUAL resulting value rather than trying to
  # re-derive which op supplied it.
  #
  # WHY IT IS SAFE:
  #   * `:source` is already threaded and already read with an `:api` default
  #     (write_scope.ex:39). `Sync.Applier` passes `source: :sync`
  #     (applier.ex:177), `MutateController` passes `source: :api`
  #     (mutate_controller.ex:14). Replication is allowed through verbatim — a
  #     replica must be able to mirror an upstream close it did not perform —
  #     and only direct API writes are fenced. No new plumbing.
  #   * `api/lib/barkpark/tasks/` contains ZERO references to
  #     `Content.apply_mutations`, so `bp task claim` / `bp task close` do not
  #     route through here at all and cannot be collateral damage.
  #   * It fires only on a CHANGE into a terminal state. A patch that touches
  #     an unrelated field on an already-`done` task leaves `lifecycle_status`
  #     equal to the existing value and passes untouched, so re-patching closed
  #     rows (retros, digests, compaction bookkeeping) keeps working.
  #
  # THE ESCAPE IS A REVISION PRECONDITION, NOT A ROLE. Carrying
  # `ifRevisionID`/`ifMatch` proves the caller read the row it is closing, and
  # `ensure_rev/2` has already matched it against the live rev by the time we
  # get here — a blind close becomes impossible, which is exactly the observed
  # exploit. It is deliberately NOT an authorization check: the worker identity
  # on a claim is still never compared, tracked separately as the epoch-only
  # close fence (wave-2 candidate). Do not read this guard as proof that a
  # CAS-carrying close is attributed.
  #
  # Terminal set mirrors `@closed_lifecycle_statuses` in
  # `api/lib/barkpark/tasks/close.ex:26` — that module owns the definition; it
  # is duplicated (not imported) because this slice's fence is this file plus
  # its test, and close.ex exposes no public accessor.
  @terminal_lifecycle_statuses ~w(done cancelled blocked)

  # WAVE-2 WIDENING (cch-w2, D53): the same guard now runs on `createOrReplace`
  # and `replace`, which reach `Content.create_document` and therefore never
  # touched `ensure_task_close_is_cas` before. Measured on pristine main:
  #
  #   createOrReplace %{"_id" => "probe1", "_type" => "task",
  #     "content" => %{"kind" => "task", "lifecycle_status" => "done"}}
  #   => :ok, lifecycle="done", claim=nil
  #
  # `create` / `createIfNotExists` are NOT wired, and the exemption is
  # STRUCTURAL, not a preference: against an existing row `create` returns
  # `{:error, :conflict}` (409, never writes) and `createIfNotExists` returns a
  # `"noop"` with the row untouched, so neither can terminalise a live task.
  # Against a FRESH id every create-family op is a birth with no prior revision
  # — `ifRevisionID` is undefined there, so this guard would degrade from a
  # FENCE into an unconditional ban on filing an already-`done` row and break
  # the dataset importer the substrate anticipates (migration 20260528100000).
  # That is what this nil head encodes, and the exemption is DELIBERATE.
  #
  # THE EXEMPTION'S PRICE, AND WHERE IT WAS PAID (cch-w3-task-birth-attribution).
  # The forgery still LANDS: a fresh `create` carrying `lifecycle_status: "done"`
  # is accepted here, and nothing on this write path stops it. What it no longer
  # BUYS is a completion. `Tasks.Queue.ready` once gated dependency satisfaction
  # on that value alone, so one forged create of a dependency id flipped a
  # dependent task from not-ready to ready. The fix landed on the READ side: a
  # done row now satisfies a dependent only if it ALSO carries close provenance
  # — `claim.closed_by`, `claim.closed_at`, or a non-empty `close_reason`
  # (queue.ex, the `ready_done_tasks` CTE; the same disjunction the Tasks queue gate
  # applies in `closed?/1`). A forged birth carries none of the three.
  #
  # Pinned by `test "CLOSED: a forged FRESH create no longer unblocks a
  # dependent in Tasks.Queue.ready"` in
  # test/barkpark_web/controllers/mutate_controller_test.exs, which asserts that
  # the forgery still WRITES and that the dependent stays unready, against a
  # dependency-free control that keeps the refutation from passing vacuously.
  # The exemption itself is pinned beside it by `test "the FRESH-create
  # exemption is intact: an importer can still file an already-done task"`.
  #
  # THE OTHER DELIBERATE DOOR is `source: :sync` in the cond below: replication
  # mirrors an upstream close verbatim, because a replica must be able to
  # reflect a close it did not perform. Both doors are CHOSEN. Neither is a
  # claim that what walks through them is attributed — see the warning above.
  defp ensure_task_close_is_cas("task", nil, _merged, _attrs, _opts), do: :ok

  defp ensure_task_close_is_cas("task", existing, merged, patch, opts) do
    was = (existing.content || %{})["lifecycle_status"]
    now = merged["lifecycle_status"]

    cond do
      # Not a transition into a terminal state — nothing to guard.
      now == was or now not in @terminal_lifecycle_statuses -> :ok
      # Replication mirrors upstream closes verbatim.
      Keyword.get(opts, :source, :api) != :api -> :ok
      # A revision precondition proves the caller read the row it is closing.
      is_binary(if_rev(patch)) and if_rev(patch) != "" -> :ok
      true -> {:error, {:invalid_task_content, close_bypass_error(now)}}
    end
  end

  defp ensure_task_close_is_cas(_type, _existing, _merged, _patch, _opts), do: :ok

  # Reuses the existing `invalid_task_content` family (422 `validation_failed`
  # with a per-field details map) that `Content.Errors` already builds and
  # `MutateController` already renders — no new error code, no new controller
  # branch. The message is the retry instruction.
  defp close_bypass_error(status) do
    %{
      "lifecycle_status" => [
        "cannot be moved to the terminal state #{inspect(status)} through /v1/data/mutate " <>
          "without a revision precondition — a blind patch closes a task with no claim, no " <>
          "worker and no epoch, recording zero attribution. Close it through the task " <>
          "lifecycle instead (`bp task close <id> <worker> <epoch>`, POST /v1/tasks/:id/close), " <>
          "which records who closed it, or resend this patch with `ifRevisionID` set to the " <>
          "revision you read."
      ]
    }
  end

  # ── The claim's own fence (cch-w2, epic decisions D51 / D52) ──────────────
  #
  # THE CLASS THIS CLOSES: any write routed through `Content.apply_mutations`
  # that ERASES the `claim` of a live `type:task` document — at all four
  # clauses that can reach one (both `patch` clauses, `createOrReplace`,
  # `replace`). A claim is the ledger's only attribution: `Tasks.Close` fences
  # on `claim.epoch` (close.ex:159) and `Tasks.Stamp` / `Tasks.Pulse` renew
  # through it, so a dropped claim does not merely lose the worker's name — it
  # detaches the row from every sanctioned lifecycle verb at once.
  #
  # WHY IT IS A SEPARATE FUNCTION AND NOT A BRANCH IN
  # `ensure_task_close_is_cas` (D51). Proven by mutation, not by reading: a
  # claim-drop branch APPENDED to that cond is DEAD CODE. Two earlier branches
  # short-circuit `:ok` above it —
  #   * `is_binary(if_rev(patch))`: a caller carrying a CORRECT `ifRevisionID`
  #     returns `:ok` before the claim is ever inspected (measured: HTTP 200,
  #     `claim=nil`); and
  #   * `now == was or now not in @terminal_lifecycle_statuses`: a claim drop
  #     with NO lifecycle change never reaches the cond body at all.
  # Both are LOAD-BEARING for D22's own committed tests (the revision escape IS
  # the sanctioned path; the no-change branch is what keeps bookkeeping on
  # already-closed rows working), so they cannot be reordered. The claim fence
  # is therefore orthogonal by construction: no revision escape, no lifecycle
  # predicate.
  #
  # THREE SIBLINGS MEASURED OPEN ON MAIN, ALL HTTP 200 (D52 — the refutation of
  # D37's "the patch door is already claim-safe"):
  #   (a) `unset: ["claim"]` + terminal `set` + CORRECT rev — `"claim"` is
  #       absent from the `protected` list, so `Map.drop` deletes it;
  #   (b) `set: {"claim": null}` + terminal set + correct rev — straight
  #       through the `Map.merge`;
  #   (c) `unset: ["claim"]` with NO rev and NO lifecycle change — pure claim
  #       theft, completely unfenced.
  # There is no legitimate caller of these shapes: `api/lib/barkpark/tasks/`
  # contains ZERO references to `Content.apply_mutations`, and every sanctioned
  # verb that ends a claim (`Tasks.Release`, `Tasks.Close`, `Tasks.TtlSweeper`)
  # `Map.put`s a REPLACEMENT claim map rather than deleting the key — so an
  # honest release still satisfies this guard.
  #
  # WHAT IT DOES **NOT** COVER (D40 boundary — state it, do not imply it):
  #   * direct `Repo`/`Ecto` writes and `Content.Writer` calls that bypass
  #     `apply_mutations` entirely — this is a door guard, not a row invariant;
  #   * the sanctioned `Barkpark.Tasks.*` modules, which are deliberately
  #     upstream of it and keep full authority over a claim's lifetime;
  #   * the FRESH-CREATE exemption above — a forged birth has no claim to
  #     drop, so this guard cannot see it (what that exemption does and no
  #     longer buys is written out beside the exemption itself).
  #
  # SUBSTITUTION IS NOW IN SCOPE (cch-w3, epic decision D52 residue). Wave 2
  # declared "a claim REPLACED by a different claim map is out of scope"; wave 3
  # MEASURED that boundary and it was a live hole, not a comment: patch
  # `set:{"claim":{"worker":"attacker","epoch":99}}` on a task claimed by
  # honest-worker(epoch=1) returned HTTP 200, the stored claim became the
  # attacker's, and `Barkpark.Tasks.close(honest-worker, epoch: 1)` then returned
  # `{:error, :fenced_off}` — the honest owner locked out of its own row, the
  # exact D22 failure shape with one extra step. The fence therefore refuses ANY
  # api-door write that CHANGES a live claim (erasure OR substitution): the
  # predicate is `now == was`, not `now != nil`. There is still no legitimate
  # api-door claimant rewrite — every sanctioned verb (`Tasks.Claim` renewal,
  # `Tasks.Fence` epoch bump, `Tasks.Release`, `Tasks.TtlSweeper`) `Map.put`s the
  # new claim through `Repo`, never `Content.apply_mutations`, so an honest
  # renewal never reaches this guard. Replication (`source != :api`) is exempt
  # BEFORE the change check so a mirror that substitutes a claim upstream still
  # applies. A patch that leaves the claim byte-identical (`now == was`, e.g. a
  # value-writeback touching an unrelated field) passes untouched.
  #
  # REPLICATION IS EXEMPT, AND THE SCENARIO IS CONCRETE — not copy-paste from
  # D22. `Sync.Applier.apply_upsert` mirrors an upstream row with
  # `createOrReplace` + the FULL remote document (applier.ex:172-181). Pull a
  # task that was claimed LOCALLY after the last push and the remote copy simply
  # has no `claim` key: without this exemption the mirror write is refused, and
  # because `apply_mutations` wraps the batch in one transaction the ENTIRE sync
  # batch rolls back — the replica wedges permanently on that row with no
  # operator recourse (`Sync.Applier` has no quarantine path). The exemption
  # widens the attack surface by exactly ZERO: `:source` is server-set, and
  # `MutateController` prepends `source: :api` (mutate_controller.ex:14) so a
  # request body can never reach the `:sync` value.
  defp ensure_claim_not_dropped("task", nil, _merged, _opts), do: :ok

  defp ensure_claim_not_dropped("task", existing, merged, opts) do
    was = (existing.content || %{})["claim"]
    now = merged["claim"]

    cond do
      # Nothing to preserve — an unclaimed row is not this guard's business.
      not is_map(was) or map_size(was) == 0 -> :ok
      # Replication mirrors upstream rows verbatim (erasure OR substitution) —
      # checked BEFORE the change predicate so a mirror still applies.
      Keyword.get(opts, :source, :api) != :api -> :ok
      # The claim is untouched by this write — an unrelated patch is fine.
      now == was -> :ok
      # The claim was ERASED (drop).
      is_nil(now) -> {:error, {:invalid_task_content, claim_drop_error(was)}}
      # The claim was SUBSTITUTED for a different map (theft-by-overwrite).
      true -> {:error, {:invalid_task_content, claim_substitution_error(was)}}
    end
  end

  defp ensure_claim_not_dropped(_type, _existing, _merged, _opts), do: :ok

  # Same `invalid_task_content` family the close guard uses (422
  # `validation_failed` with a per-field details map) — no new error code, no
  # new controller branch. Keyed on `claim` so the caller sees WHICH field it
  # erased, and the message names the sanctioned verb for each intent.
  defp claim_drop_error(claim) do
    worker = if is_map(claim), do: claim["worker"], else: nil

    %{
      "claim" => [
        "cannot be dropped through /v1/data/mutate" <>
          if(is_binary(worker), do: " — this task is claimed by #{inspect(worker)}", else: "") <>
          ". The claim is the ledger's only attribution: erasing it detaches the row from " <>
          "every sanctioned lifecycle verb (`bp task close` fences on `claim.epoch`, so an " <>
          "unclaimed-but-in-progress row becomes uncloseable). A revision precondition does " <>
          "NOT unlock this — release it (`bp task release <id> <worker> <epoch>`, " <>
          "POST /v1/tasks/:id/release) or close it (`bp task close <id> <worker> <epoch>`), " <>
          "both of which record who let it go."
      ]
    }
  end

  # Theft-by-overwrite: the claim was replaced by a DIFFERENT map through the
  # api door (cch-w3, D52 residue). Same `invalid_task_content` family and same
  # `claim` key as the drop message, so no new error code and no new controller
  # branch — but worded for substitution: the honest holder of the current epoch
  # is fenced off from `bp task close` (which CAS-checks `claim.epoch`) the
  # instant a foreign claim lands, so the row becomes uncloseable by its owner.
  defp claim_substitution_error(claim) do
    worker = if is_map(claim), do: claim["worker"], else: nil

    %{
      "claim" => [
        "cannot be reassigned through /v1/data/mutate" <>
          if(is_binary(worker), do: " — this task is claimed by #{inspect(worker)}", else: "") <>
          ". Substituting the claim map impersonates the claimant: the honest holder of the " <>
          "current epoch is immediately fenced off from `bp task close` (which fences on " <>
          "`claim.epoch`), so the row becomes uncloseable by its real owner. A revision " <>
          "precondition does NOT unlock this — claim, renew, release or close it through the " <>
          "task lifecycle (`bp task claim`/`release`/`close`), which record who holds the claim."
      ]
    }
  end

  # The content the write will ACTUALLY land, resolved through the same
  # `Writer.from_envelope/1` the create path uses — so a create-family op in the
  # FLAT Sanity shape (`%{"_id" => …, "_type" => "task", "lifecycle_status" =>
  # "done"}`, no nested `content` map) is read exactly as it will be stored,
  # rather than appearing to carry no content at all and slipping both guards.
  defp incoming_content(%{} = attrs) do
    case Writer.from_envelope(attrs) do
      %{"content" => %{} = content} -> content
      _ -> %{}
    end
  end

  defp incoming_content(_attrs), do: %{}

  # Merge base for a patch MUST be the row the write will actually target. The
  # create/replace siblings read draft-first via DraftId.draft_id/1, and
  # Writer.upsert_document always draft-prefixes the write target — so a patch
  # that read the raw (published) id would merge published content and then
  # OVERWRITE the newer draft with it (data loss), and its ensure_rev would
  # guard the published row while the draft is what's written. Read the draft
  # first (falling back to the raw id when no draft exists) so merge base ==
  # write target and the rev guard checks the row actually being written.
  # Land a `patch` where the type's READERS look.
  #
  # `Writer.upsert_document/4` ALWAYS draft-prefixes its write target, so
  # resolving a published base is only half the repair: without this step the
  # patch would read the published row and still park the result on
  # `drafts.<id>` — the same invisible write, now with a rev check that passes.
  # When the base we resolved IS the published row (published-first types only,
  # see `published_first_patch?/2`), publish the draft we just wrote:
  # `Content.publish_document/4` upserts the published row from it and deletes
  # the draft, so `GET /v1/tasks/<id>` reflects the patch and no twin is left
  # behind for the next patch to trip over.
  #
  # Keyed on the BASE's `doc_id`, not on the request's: a draft-first base
  # (`drafts.…`) — every non-task type, and a task with no published row —
  # returns the upsert's own document untouched, which is the pre-existing
  # behaviour byte for byte.
  defp land_patch(%{doc_id: base_id}, type, doc, dataset, opts) do
    if published_first_patch?(base_id, type) do
      Content.publish_document(DraftId.published_id(doc.doc_id), type, dataset, opts)
    else
      {:ok, doc}
    end
  end

  # The types whose `patch` base is resolved PUBLISHED-first, mirroring the read
  # door that serves them (`tasks_controller.ex find_task_by_doc_id/2`: exact id
  # first, `drafts.` fallback). Deliberately a one-element list rather than a
  # blanket "whenever a published row exists": widening this to every type would
  # convert the Studio's draft/publish model into publish-on-write. See the
  # moduledoc's blast-radius note.
  @published_first_patch_types ~w(task)

  defp get_patch_base(id, type, dataset, opts) do
    if published_first_patch?(id, type) do
      published_first_patch_base(id, type, dataset, opts)
    else
      draft_first_patch_base(id, type, dataset, opts)
    end
  end

  # BARE ids only: `drafts.task-…` names the twin explicitly and keeps the
  # draft-first path (the escape hatch). A nil/non-binary id falls through to
  # the draft-first clause, whose `id &&` guard already handles it.
  defp published_first_patch?(id, type),
    do: is_binary(id) and type in @published_first_patch_types and not DraftId.draft?(id)

  # ── The plugin mutate-door fences (task-b04cbe7823d084a6) ─────────────────
  #
  # The task guards this door used to name — the create family's
  # published-fork fence and the adjudication guards (disposition by verb,
  # rerun, operating instruction, reopen trigger, adoption, disposition owner)
  # — are declared by the Tasks plugin through `mutate_door_fences/0` and run
  # here, at the two positions they held (see `Content.MutateDoorFences` for
  # why this is its own list and not the writer's pre-write fences). With
  # plugins off the list is empty and both steps are `:ok`.
  #
  #   * `:before_rev` — first step of `create`, `createOrReplace` and
  #     `createIfNotExists`, before `ensure_rev/2`.
  #   * `:after_claim` — after `ensure_claim_not_dropped/4`, before the writer,
  #     on `createOrReplace`, `replace` and both `patch` clauses.
  #
  # The create family passes its attrs as `op` and `incoming_content/1` as
  # `merged` (what the guards read today); `patch` passes the patch map and the
  # merged content it computed.
  # ── readOnly schema fields (owner ruling #35, item 5) ──────────────────────
  #
  # The last step before the writer on every clause that stores content, so a
  # task's own guards keep refusing first. `existing` is the row the clause
  # resolved; a create (or a `createOrReplace` with no draft) compares against
  # the published row instead, read only when the check applies. Who is refused
  # and what counts as a change: `Barkpark.Content.ReadOnlyFields`.
  defp ensure_read_only_unchanged(type, %{content: content}, merged, _id, dataset, opts),
    do: ReadOnlyFields.check(type, content || %{}, merged, dataset, opts)

  defp ensure_read_only_unchanged(type, _existing, merged, id, dataset, opts) do
    base = fn ->
      with true <- is_binary(id) and is_binary(type),
           {:ok, published} <-
             Content.get_document(DraftId.published_id(id), type, dataset, opts) do
        published.content || %{}
      else
        _ -> %{}
      end
    end

    ReadOnlyFields.check(type, base, merged, dataset, opts)
  end

  defp run_mutate_door_fences(phase, type, existing, attrs, dataset, opts),
    do:
      run_mutate_door_fences(
        phase,
        type,
        existing,
        incoming_content(attrs),
        attrs,
        dataset,
        opts
      )

  defp run_mutate_door_fences(phase, type, existing, merged, op, dataset, opts) do
    MutateDoorFences.run(MutateDoorFences.list(), phase, [
      type,
      existing,
      merged,
      op,
      dataset,
      opts
    ])
  end

  @doc """
  The mutate door's content guards for a client write that reaches the writer
  WITHOUT `apply_mutations/3`: the document block ops door
  (`POST /v1/data/doc/:dataset/:type/:doc_id/ops`, owner ruling #35 item 4).

  A block op re-projects every bound block (`fieldName`) into `content`, so it
  can set any field a `patch` can. This runs, in the mutate door's order, the
  close fence (`ensure_task_close_is_cas`), the claim fence
  (`ensure_claim_not_dropped`), the `:after_claim` plugin fences and the
  readOnly field check (`Barkpark.Content.ReadOnlyFields`) over the row the op read (`existing`) and the content it will store (`merged`), and
  returns the same refusal the mutate door would.

  One difference, on purpose: the close fence is judged as a write WITHOUT a
  revision precondition. The ops door requires `ifRev` on every op to fence
  concurrent block edits, so it proves nothing about intent to close; a block
  edit is never a sanctioned close path.
  """
  @spec ensure_content_write_guards(String.t(), map() | nil, map(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def ensure_content_write_guards(type, existing, merged, dataset, opts) do
    no_revision_precondition = %{}

    with :ok <- ensure_task_close_is_cas(type, existing, merged, no_revision_precondition, opts),
         :ok <- ensure_claim_not_dropped(type, existing, merged, opts),
         :ok <-
           run_mutate_door_fences(
             :after_claim,
             type,
             existing,
             merged,
             no_revision_precondition,
             dataset,
             opts
           ) do
      ensure_read_only_unchanged(type, existing, merged, nil, dataset, opts)
    end
  end

  @doc """
  Run the create family's `:before_rev` mutate-door fences for a create
  naming `id` — the published-fork fence the Tasks plugin declares (refuse a
  create that would fork a published task somebody holds, otherwise advise).

  Returns `:ok` or the first refusal verbatim. Public, and kept at this name,
  because the legacy door (`POST /api/documents/:type` →
  `Content.upsert_document/4`) forks the same twin without passing through
  `apply_mutations/3`. With plugins off it is `:ok`, on both doors alike.
  """
  @spec ensure_create_not_forking_published_task(
          String.t() | nil,
          String.t() | nil,
          String.t(),
          keyword()
        ) :: :ok | term()
  def ensure_create_not_forking_published_task(type, id, dataset, opts),
    do: run_mutate_door_fences(:before_rev, type, nil, %{"doc_id" => id}, dataset, opts)

  defp published_first_patch_base(id, type, dataset, opts) do
    case Content.get_document(id, type, dataset, opts) do
      {:ok, published} ->
        # A twin already exists. `land_patch/5` would publish OVER it, so refuse
        # instead of destroying it — and NAME it, because an agent holding a 200
        # onto an invisible row is exactly the failure this path was filed for.
        case Content.get_document(DraftId.draft_id(id), type, dataset, opts) do
          {:ok, _twin} -> {:error, {:invalid_task_content, draft_twin_error(id)}}
          _ -> {:ok, published}
        end

      _ ->
        # No published row — an unpublished task. `find_task_by_doc_id/2` falls
        # back to `drafts.<id>` here too, so draft-first is the AGREEING answer.
        draft_first_patch_base(id, type, dataset, opts)
    end
  end

  defp draft_twin_error(id) do
    twin = DraftId.draft_id(id)

    %{
      "_id" => [
        "a draft twin `#{twin}` already exists for the published task `#{id}`, and no reader " <>
          "serves it (`GET /v1/tasks/#{id}`, the board and the ready queue are all " <>
          "published-first). Patching through it would return 200 for a write nothing reads, " <>
          "and landing this patch on the published row would silently destroy the twin. " <>
          "Resolve the fork first — `discardDraft` `#{id}` to drop the twin, or `publish` " <>
          "`#{id}` to land it — then resend this patch. To edit the twin deliberately, " <>
          "address it by name: `\"id\": \"#{twin}\"`."
      ]
    }
  end

  defp draft_first_patch_base(id, type, dataset, opts) do
    # `id &&` mirrors the create/replace clauses — a nil id short-circuits to the
    # raw lookup, which returns {:error, :not_found} rather than raising in
    # DraftId.draft_id/1.
    case id && Content.get_document(DraftId.draft_id(id), type, dataset, opts) do
      {:ok, doc} ->
        warn_on_published_fork(id, type, dataset, opts, :stale_base)
        {:ok, doc}

      _ ->
        case Content.get_document(id, type, dataset, opts) do
          {:ok, doc} = ok ->
            if is_binary(id) and not DraftId.draft?(id),
              do: warn_on_published_fork(doc, :fresh_fork)

            ok

          other ->
            other
        end
    end
  end

  # A patch naming a BARE published id returns 200 with `results[].id =
  # "drafts.<id>"` and a fresh `_rev` that NO canonical reader will ever serve:
  # `Writer.upsert_document` always draft-prefixes the write target, while
  # `/v1/data/doc`, `/v1/tasks/:id`, the board and the queue are all
  # published-first. The write is not lost — it is parked on a draft twin until
  # something publishes it — but the receipt reads exactly like a landed edit,
  # which is how 22 task rows came to carry a draft twin diverging from their
  # published row on `lifecycle_status` with nobody noticing
  # (pds-w33-bl-wrong-row-mutate-forks-published-tasks).
  #
  # There is already a Warnings channel that drains into the mutate success
  # envelope, and it costs nothing to say so. Two shapes, two codes:
  #
  #   * `patch.forked_published` — no draft existed, so this patch MINTS the
  #     twin off the published row. The content is right; only the visibility
  #     is wrong until a publish.
  #   * `patch.stale_draft_base` — a draft twin ALREADY existed, so the merge
  #     base is that draft, not the published row an agent just read. This is
  #     the dangerous half: the draft can be arbitrarily old (its
  #     `lifecycle_status` may say `open` while the published row says `done`),
  #     and publishing the result would carry that stale state forward. The
  #     criteria half of that hazard is fenced at the publish door
  #     (`Content.Lifecycle` refuses a publish that clears a stamped `met`),
  #     but lifecycle_status is not, so the warning is the only signal.
  #
  # The `:stale_base` arm needs a published-row lookup it does not otherwise
  # perform, so it is gated on `Warnings.listening?/0` — no collector, no read.
  defp warn_on_published_fork(id, type, dataset, opts, :stale_base) do
    if is_binary(id) and not DraftId.draft?(id) and Warnings.listening?() do
      case Content.get_document(id, type, dataset, opts) do
        {:ok, published} -> warn_on_published_fork(published, :stale_base)
        _ -> :ok
      end
    else
      :ok
    end
  end

  defp warn_on_published_fork(%{id: _} = published, kind) do
    {code, why} =
      case kind do
        :stale_base ->
          {"patch.stale_draft_base",
           "the merge base was that EXISTING draft, not the published row — the draft may " <>
             "carry stale fields (lifecycle_status among them) that this patch now inherits"}

        :fresh_fork ->
          {"patch.forked_published", "this patch minted a NEW draft twin off the published row"}
      end

    Warnings.put(
      code,
      "this patch names a published document but writes a DRAFT twin " <>
        "(`drafts.#{doc_id_of(published)}`): #{why}. Every canonical reader " <>
        "(/v1/data/doc, /v1/tasks/:id, the board, the queue) is published-first " <>
        "and will keep serving the OLD row until the draft is published — " <>
        "`bp doc publish #{type_of(published)} #{doc_id_of(published)}` (or the " <>
        "sanctioned verb for this type) is what makes the edit visible.",
      "warning"
    )
  end

  defp doc_id_of(%{doc_id: doc_id}) when is_binary(doc_id), do: doc_id
  defp doc_id_of(_), do: "<id>"

  defp type_of(%{type: type}) when is_binary(type), do: type
  defp type_of(_), do: "<type>"

  # Double-nest trap advisory (option 1 — make it LOUD, do NOT change semantics).
  # A `patch.set` map is merged INTO the document's `content`, so a `set` field
  # literally named `content` lands the caller's data at `content.content.*` —
  # the classic `--set 'content:={"blocks":…}'` mistake, which silently no-ops
  # the real `blocks` (they never reach `content.blocks` where the renderer reads
  # them). The merge stays byte-identical (option 2 — unwrapping — was NOT
  # approved); we only emit a non-blocking Warnings advisory so the CLI/SDK
  # success envelope surfaces the footgun. Guard on a MAP value only: a scalar
  # `content` field (a legitimate content-level string/number named "content")
  # is not the double-nest shape and must stay quiet. Warnings.put is
  # collect-only-when-listening, so this is inert unless a controller opened the
  # queue with reset/0.
  defp warn_on_nested_content(%{"content" => value}) when is_map(value) do
    Warnings.put(
      "patch.content_nested",
      "patch `set` fields are merged INTO document content; a field named `content` " <>
        "created a nested `content.content` — did you mean to set the inner fields " <>
        "directly, e.g. --set 'blocks:=[…]'?"
    )
  end

  defp warn_on_nested_content(_fields), do: :ok

  # [declaring-type-status] task-949bee3f1fb1d304 — the PATCH counterpart of
  # #17346's CREATE/UPSERT fix (`Writer.declared_status_field?/4`).
  #
  # THE DEFECT. `status` sits in the patch path's hard `protected` list, so
  # every patch verb DROPS it: `set` merges a map it was removed from, `unset`
  # cannot name it, `inc`/`dec`/`append`/`prepend`/`setIfMissing` skip it. On a
  # type that does NOT declare a `status` field that is correct — `status` is
  # the document's LIFECYCLE word there and a caller must move it with
  # `publish`/`archive`, never by writing a content key. But on a type whose
  # SchemaDefinition declares its own `status` field (Tickets ships one), the
  # key is the caller's ordinary field, and dropping it returned HTTP 2xx while
  # writing nothing at all: no field write, no lifecycle write, no error. A
  # silent no-op is the one failure a write API cannot let the caller detect.
  #
  # THE SHAPE, AND THE ONE WE REFUSED. Removing `status` from `protected`
  # outright would let any caller rewrite any document's lifecycle through
  # `content`, on every type. #17346 already settled how this repo tells the
  # two cases apart: ASK THE TYPE. `Writer.schema_declares_status?/3` is that
  # question, and it is now called from both doors instead of one.
  #
  # COST. One `Content.resolve_schema/3` read, and only when the patch actually
  # MENTIONS `status` in some verb — `patch_mentions_status?/1` gates it, the
  # same way #17346 gated its read behind a present top-level `status` key. A
  # patch that never says `status` costs exactly what it cost before.
  #
  # BACKWARD COMPATIBILITY. A type that does not declare `status` keeps the
  # byte-identical old list, so its patches are unchanged down to the stored
  # map. The only behaviour that moves belongs to declaring types, where the
  # previous behaviour stored nothing — there is no working caller to migrate,
  # because nobody was reading back a value that was never written. A missing
  # schema or any resolver error reads as NOT DECLARED, so the predicate can
  # only ever move a patch from the silent reading to the stored one.
  #
  # `title` is deliberately NOT part of this. It is protected here but it is
  # not silently discarded: the clauses below lift `set["title"]` into the
  # document's `title` COLUMN, which is what a read renders. Its story is a
  # different one (a declaring type's `content["title"]` shadowing the column)
  # with a different remedy, and it is not this row.
  defp patch_protected_keys(patch, type, dataset, opts) do
    base = ~w(title status _id _type _rev)

    if patch_mentions_status?(patch) and is_binary(type) and
         Writer.schema_declares_status?(type, dataset, opts) do
      base -- ["status"]
    else
      base
    end
  end

  @status_bearing_ops ~w(set setIfMissing inc dec append prepend)

  defp patch_mentions_status?(patch) when is_map(patch) do
    Enum.any?(@status_bearing_ops, fn op ->
      case Map.get(patch, op) do
        m when is_map(m) -> Map.has_key?(m, "status")
        _ -> false
      end
    end) or "status" in list_or_empty(Map.get(patch, "unset"))
  end

  defp patch_mentions_status?(_), do: false

  defp list_or_empty(l) when is_list(l), do: l
  defp list_or_empty(_), do: []

  # ── Patch ops with paths (task-bfb66a2ff491f6e7) ─────────────────────────
  #
  # One pass for both patch clauses. Order is unchanged for plain keys:
  # setIfMissing fills absent defaults → set merges (overriding) → inc/dec →
  # append/prepend → insert → unset. A key containing `.` or `[` is a PATH
  # (`seo.metaTitle`, `body[_key=="b1"].text`) applied in the same slot through
  # `PatchPath`; plain keys keep the shallow top-level behaviour byte for byte.
  # A path whose first key is protected is skipped like a protected plain key.
  # A path that does not parse, or walks into a scalar, refuses the batch (422);
  # a selector that matches no item is a no-op with a `patch.path_unmatched`
  # warning, as Sanity's API leaves the document unchanged there.
  defp apply_patch_ops(content, patch, protected) do
    {set_plain, set_paths} = split_paths(Map.get(patch, "set"))
    {sim_plain, sim_paths} = split_paths(Map.get(patch, "setIfMissing"))
    {inc_plain, inc_paths} = split_paths(Map.get(patch, "inc"))
    {dec_plain, dec_paths} = split_paths(Map.get(patch, "dec"))

    {unset_paths, unset_plain} =
      Enum.split_with(list_or_empty(Map.get(patch, "unset")), &PatchPath.path?/1)

    content
    |> put_new_fields(sim_plain, protected)
    |> path_ops(sim_paths, protected, &set_if_missing_fun/1, true)
    |> ok_then(&Map.merge(&1, Map.drop(set_plain, protected)))
    |> path_ops(set_paths, protected, &set_fun/1, true)
    |> ok_then(&apply_delta(&1, inc_plain, protected, 1))
    |> path_ops(numeric(inc_paths), protected, &delta_fun(&1, 1), true)
    |> ok_then(&apply_delta(&1, dec_plain, protected, -1))
    |> path_ops(numeric(dec_paths), protected, &delta_fun(&1, -1), true)
    |> ok_then(&apply_array_op(&1, Map.get(patch, "append"), protected, :append))
    |> ok_then(&apply_array_op(&1, Map.get(patch, "prepend"), protected, :prepend))
    |> apply_insert(Map.get(patch, "insert"), protected)
    |> path_ops(Enum.map(unset_paths, &{&1, nil}), protected, &unset_fun/1, false)
    |> ok_then(&Map.drop(&1, unset_plain -- protected))
  end

  defp split_paths(fields) when is_map(fields) do
    {paths, plain} = Enum.split_with(fields, fn {k, _} -> PatchPath.path?(k) end)
    {Map.new(plain), Enum.sort(paths)}
  end

  defp split_paths(nil), do: {%{}, []}
  defp split_paths(other), do: {other, []}

  defp numeric(pairs), do: Enum.filter(pairs, fn {_k, d} -> is_number(d) end)

  # PatchPath.update/4 callbacks: given the current value (`{:ok, v}` or
  # `:absent`), say what to store.
  defp set_fun(value), do: fn _ -> {:put, value} end

  defp set_if_missing_fun(value) do
    fn
      :absent -> {:put, value}
      {:ok, _} -> :keep
    end
  end

  defp unset_fun(_value) do
    fn
      :absent -> :keep
      {:ok, _} -> :delete
    end
  end

  defp delta_fun(delta, sign) do
    fn
      {:ok, n} when is_number(n) -> {:put, n + sign * delta}
      _ -> {:put, sign * delta}
    end
  end

  defp ok_then({:ok, content}, fun), do: {:ok, fun.(content)}
  defp ok_then(content, fun) when is_map(content), do: {:ok, fun.(content)}
  defp ok_then(error, _fun), do: error

  defp wrap_ok({:ok, _} = ok), do: ok
  defp wrap_ok(content) when is_map(content), do: {:ok, content}
  defp wrap_ok(error), do: error

  defp path_ops({:error, _} = error, _pairs, _protected, _make_fun, _create?), do: error

  defp path_ops(acc, pairs, protected, make_fun, create?) do
    Enum.reduce_while(pairs, wrap_ok(acc), fn {path, value}, {:ok, content} ->
      with {:ok, segs} <- path_error(PatchPath.parse(path)),
           false <- PatchPath.root(path) in protected do
        case PatchPath.update(content, segs, create?, make_fun.(value)) do
          {:ok, updated} -> {:cont, {:ok, updated}}
          :unmatched -> {:cont, {:ok, warn_unmatched(path, content)}}
          {:error, msg} -> {:halt, path_error({:error, "#{msg} (path #{inspect(path)})"})}
        end
      else
        true -> {:cont, {:ok, content}}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  # `insert: {"before"|"after"|"replace": path, "items": [...]}` — one anchor.
  defp apply_insert(acc, nil, _protected), do: wrap_ok(acc)

  defp apply_insert(acc, insert, protected) do
    with {:ok, content} <- wrap_ok(acc),
         {:ok, position, path, items} <- insert_shape(insert),
         {:ok, segs} <- path_error(PatchPath.parse(path)) do
      if PatchPath.root(path) in protected do
        {:ok, content}
      else
        case PatchPath.insert(content, segs, position, items) do
          {:ok, _} = ok -> ok
          :unmatched -> {:ok, warn_unmatched(path, content)}
          {:error, msg} -> path_error({:error, "#{msg} (path #{inspect(path)})"})
        end
      end
    end
  end

  defp insert_shape(%{"items" => items} = insert) when is_list(items) do
    case Enum.filter(~w(before after replace), &is_binary(Map.get(insert, &1))) do
      [pos] -> {:ok, String.to_existing_atom(pos), insert[pos], items}
      _ -> path_error({:error, "insert needs exactly one of before, after or replace"})
    end
  end

  defp insert_shape(_),
    do: path_error({:error, "insert must be an object with `items` (a list) and one anchor path"})

  defp path_error({:error, msg}) when is_binary(msg),
    do:
      {:error,
       {:validation_failed, "patch path", %{"path" => [msg]},
        ~s(Use field.sub, list[_key=="…"] or list[N]; insert takes {"after"|"before"|"replace": path, "items": [...]}.)}}

  defp path_error(other), do: other

  defp warn_unmatched(path, content) do
    Warnings.put(
      "patch.path_unmatched",
      "patch path #{inspect(path)} matched no array item, so that op changed nothing. " <>
        "Re-read the document: the item may have been removed or re-keyed.",
      "warning"
    )

    content
  end

  # Serialize patches on one document (task-bfb66a2ff491f6e7 c1). Without this,
  # two clients patching sibling nested fields (seo.metaTitle, seo.metaDescription)
  # both read the same base, and the later UPDATE writes its stale merge over the
  # earlier one. A transaction-scoped advisory lock on the document's published
  # id makes the second patch wait and read the first one's result. It covers
  # the fork-from-published case too, where no draft row exists yet to lock.
  # Released at commit or rollback. Two-key form, so it never shares a lock
  # with the single-key audit-chain locks.
  @patch_lock_class 0x7061

  defp lock_patch_target(id, dataset, opts) when is_binary(id) do
    key =
      :erlang.crc32("#{Keyword.get(opts, :workspace_id)}:#{dataset}:#{DraftId.published_id(id)}") -
        2_147_483_648

    Repo.query!("SELECT pg_advisory_xact_lock($1::int, $2::int)", [@patch_lock_class, key])
    :ok
  end

  defp lock_patch_target(_id, _dataset, _opts), do: :ok

  # setIfMissing: put each field only if absent (Map.put_new), so it fills
  # defaults without clobbering existing values. Protected keys are skipped; a
  # non-map `fields` (malformed op) is a no-op.
  defp put_new_fields(content, fields, protected) when is_map(fields) do
    Enum.reduce(fields, content, fn {k, v}, acc ->
      if k in protected, do: acc, else: Map.put_new(acc, k, v)
    end)
  end

  defp put_new_fields(content, _fields, _protected), do: content

  # inc/dec: add sign*delta to each numeric field, treating a missing or
  # non-numeric current value as 0. Protected keys and non-numeric deltas are
  # skipped; a non-map `fields` (malformed op) is a no-op.
  defp apply_delta(content, fields, protected, sign) when is_map(fields) do
    Enum.reduce(fields, content, fn
      {k, delta}, acc when is_number(delta) ->
        if k in protected do
          acc
        else
          current = if is_number(acc[k]), do: acc[k], else: 0
          Map.put(acc, k, current + sign * delta)
        end

      {_k, _delta}, acc ->
        acc
    end)
  end

  defp apply_delta(content, _fields, _protected, _sign), do: content

  # append/prepend: extend a LIST field with items. A missing field starts from
  # [] (append/prepend onto nothing are identical); a non-list existing value (a
  # scalar) is left untouched — never clobbered with an array. Protected keys,
  # non-list items, and a non-map `fields` (malformed op) are no-ops.
  defp apply_array_op(content, fields, protected, position) when is_map(fields) do
    Enum.reduce(fields, content, fn
      {k, items}, acc when is_list(items) ->
        cond do
          k in protected ->
            acc

          is_list(Map.get(acc, k)) ->
            current = Map.get(acc, k)
            Map.put(acc, k, if(position == :append, do: current ++ items, else: items ++ current))

          not Map.has_key?(acc, k) ->
            Map.put(acc, k, items)

          true ->
            acc
        end

      {_k, _items}, acc ->
        acc
    end)
  end

  defp apply_array_op(content, _fields, _protected, _position), do: content

  # ── Reference integrity on delete (task-c8c22ee8076535fe) ─────────────────
  #
  # A delete of a document that other documents still reference is refused
  # 409 `document_referenced`, listing the referrers, as Sanity's API does. The
  # op's `"force": true` deletes anyway; that path writes a
  # `document.delete_forced` audit event naming the referrers, in the same
  # transaction, so an override is never silent. A target that does not exist
  # is left to the delete itself to answer 404. Who counts as a referrer:
  # `Barkpark.Content.ReferenceIntegrity`.
  # task-6b5e4b3e572d38c9 — `opts[:precomputed_referrers]` is set ONLY by
  # `apply_chunk/5` for a RUN of 2+ consecutive deletes, keyed by PUBLISHED
  # id (the same key `ReferenceIntegrity.referrers_for_ids/3` returns, and
  # the same resolution `referrers/3` performs internally on `id`). A lone
  # delete in a mixed batch, or any caller of `delete_document`/`apply_one`
  # outside `apply_mutations` entirely, carries no such opt and falls
  # through to the ORIGINAL per-id query unchanged.
  defp ensure_unreferenced(id, type, op, dataset, opts) when is_binary(id) do
    referrers =
      case Keyword.get(opts, :precomputed_referrers) do
        %{} = precomputed -> Map.get(precomputed, DraftId.published_id(id), [])
        _ -> ReferenceIntegrity.referrers(id, dataset, opts)
      end

    case referrers do
      [] ->
        :ok

      found ->
        case {delete_target(id, type, dataset, opts), Map.get(op, "force") == true} do
          {nil, _} -> :ok
          {doc, true} -> audit_forced_delete(doc, type, dataset, found, opts)
          {_doc, false} -> {:error, {:document_referenced, DraftId.published_id(id), found}}
        end
    end
  end

  defp ensure_unreferenced(_id, _type, _op, _dataset, _opts), do: :ok

  defp delete_target(id, type, dataset, opts) do
    Enum.find_value([DraftId.published_id(id), DraftId.draft_id(id)], fn v ->
      case Content.get_document(v, type, dataset, opts) do
        {:ok, doc} -> doc
        _ -> nil
      end
    end)
  end

  defp audit_forced_delete(doc, type, dataset, referrers, opts) do
    user_id = Keyword.get(opts, :user_id)

    result =
      Barkpark.Audit.emit(%{
        category: "content_mutation",
        action: "document.delete_forced",
        subject: DraftId.published_id(doc.doc_id),
        actor_type: if(user_id, do: "user"),
        actor_id: user_id,
        workspace_id: doc.workspace_id,
        project_id: doc.project_id,
        metadata: %{
          "type" => type,
          "dataset" => dataset,
          "referrer_count" => length(referrers),
          "referrers" => Enum.map(referrers, &"#{&1.type}:#{&1.id}")
        }
      })

    case result do
      {:ok, _event} -> :ok
      {:error, _} = error -> error
    end
  end

  defp if_rev(%{} = attrs), do: attrs["ifRevisionID"] || attrs["ifMatch"]
  defp if_rev(_), do: nil

  # [ifmatch-unfenced-update] Thread the client-asserted rev into the writer's
  # opts so its UPDATE branch can fence `WHERE rev = expected` (see
  # `Writer.fenced_or_plain_update/3`). `ensure_rev` already validated this rev
  # at READ time; the fence closes the read→write window a concurrent writer
  # could otherwise clobber. Only set for a real precondition — a nil/blank
  # ifMatch leaves opts untouched so the non-ifMatch path stays last-write-wins.
  defp with_if_rev(opts, expected) when is_binary(expected) and expected != "",
    do: Keyword.put(opts, :if_rev, expected)

  defp with_if_rev(opts, _expected), do: opts

  defp ensure_rev(_doc, nil), do: :ok
  defp ensure_rev(_doc, ""), do: :ok

  defp ensure_rev(nil, expected),
    do: {:error, {:rev_mismatch, %{expected: expected, actual: nil}}}

  defp ensure_rev(%{rev: r}, r), do: :ok

  defp ensure_rev(%{rev: actual}, expected),
    do: {:error, {:rev_mismatch, %{expected: expected, actual: actual}}}

  # CREATE OVER A PUBLISHED-ONLY ID (task-ab87d3e04f02021e). `create`
  # conflicts only with an existing DRAFT (docs/api-v1.md), so over an id whose
  # PUBLISHED row exists it mints a FRESH draft. (`createIfNotExists` reaches
  # here only when the caller named `drafts.<id>` explicitly; on a bare id a
  # published row is a noop since owner ruling #41.) It is
  # not seeded from the published row, so the next publish replaces the
  # document with only the fields this create set. That is silent field loss
  # through two documented verbs used in their obvious order (found by
  # dogfooding bp: create, publish, create again, publish, and pages + genre
  # were gone). The contract is unchanged; the response now SAYS so on the
  # advisory channel and names the fields a publish would drop. A create that
  # carries every published field drops nothing, so it gets no warning
  # (task-b64beb44bafc6023: it used to, and called the full draft "EMPTY").
  defp warn_create_over_published(op, type, id, dataset, opts, %_{} = draft)
       when is_binary(id) and is_binary(type) do
    published_id = DraftId.published_id(id)

    with true <- published_id != draft.doc_id,
         {:ok, %{} = published} <- Content.get_document(published_id, type, dataset, opts),
         [_ | _] = dropped <- Enum.sort(field_names(published) -- field_names(draft)) do
      Warnings.put(
        "create_over_published",
        "#{op} minted a FRESH draft over the PUBLISHED #{type} #{inspect(published_id)}: " <>
          "the draft is not seeded from it, so publishing it replaces the document with only " <>
          "the fields this #{op} set and DROPS #{Enum.join(dropped, ", ")}. " <>
          "To edit the published document, patch it instead (`bp doc patch #{type} #{published_id} --set …`).",
        "warning"
      )
    end

    :ok
  end

  defp warn_create_over_published(_op, _type, _id, _dataset, _opts, _doc), do: :ok

  # The user-visible field names of a stored document: its content keys plus a
  # non-blank title (a column, not a content key).
  defp field_names(%{content: content} = doc) do
    keys = if is_map(content), do: Map.keys(content), else: []
    title = Map.get(doc, :title)
    keys = if is_binary(title) and title != "", do: ["title" | keys], else: keys
    keys |> Enum.map(&to_string/1) |> Enum.reject(&String.starts_with?(&1, "_")) |> Enum.uniq()
  end
end
