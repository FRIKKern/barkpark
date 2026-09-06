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
      `Content.Lifecycle.ensure_task_publish_transition_legal/5` (legal
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
  alias Barkpark.Content.{Broadcast, CallerContext, DraftId, Envelope, Warnings, Writer}

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
        result = do_apply_mutations(mutations, dataset, opts)
        {result, %{count: length(mutations), dataset: dataset, workspace_id: workspace_id}}
      end
    )
  end

  defp do_apply_mutations(mutations, dataset, opts) do
    # Initialise the deferred-broadcast queue for this process so
    # tap_broadcast/5 knows to queue instead of broadcast immediately.
    Process.put(:barkpark_deferred_broadcasts, [])

    try do
      result =
        Repo.transaction(fn ->
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

          {results, _schema_cache} =
            Enum.map_reduce(mutations, %{}, fn m, cache ->
              case apply_one(m, dataset, opts) do
                {:ok, doc, op} ->
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

          {tx_id, results}
        end)

      case result do
        {:ok, _} ->
          Broadcast.flush_deferred_broadcasts()
          result

        _ ->
          Broadcast.clear_deferred_broadcasts()
          compensating_discard(result, mutations, dataset, opts)
      end
    rescue
      e ->
        Broadcast.clear_deferred_broadcasts()
        reraise(e, __STACKTRACE__)
    end
  end

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
        with {:ok, doc} <- Content.create_document(type, attrs, dataset, opts),
             do: {:ok, doc, "create"}
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
    with :ok <- ensure_rev(existing, expected),
         :ok <- ensure_task_close_is_cas(type, existing, incoming_content(attrs), attrs, opts),
         :ok <- ensure_claim_not_dropped(type, existing, incoming_content(attrs), opts),
         :ok <- ensure_disposition_via_verb(type, existing, incoming_content(attrs), opts),
         :ok <- ensure_adoption_adjudicated(type, existing, incoming_content(attrs), opts),
         {:ok, doc} <- Content.create_document(type, attrs, dataset, with_if_rev(opts, expected)) do
      {:ok, doc, "createOrReplace"}
    end
  end

  defp apply_one(%{"createIfNotExists" => attrs}, dataset, opts) do
    type = attrs["_type"] || attrs["type"]
    id = attrs["_id"] || attrs["doc_id"]

    case id && Content.get_document(DraftId.draft_id(id), type, dataset, opts) do
      {:ok, existing} ->
        case ensure_rev(existing, if_rev(attrs)) do
          :ok -> {:ok, existing, "noop"}
          err -> err
        end

      _ ->
        with {:ok, doc} <- Content.create_document(type, attrs, dataset, opts),
             do: {:ok, doc, "create"}
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

  defp apply_one(%{"delete" => %{"id" => id, "type" => type} = op}, dataset, opts) do
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
         :ok <- ensure_disposition_via_verb(type, existing, incoming_content(attrs), opts),
         :ok <- ensure_adoption_adjudicated(type, existing, incoming_content(attrs), opts),
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
  # (title/status/_id/_type/_rev) stay protected throughout; malformed ops (a
  # non-map setIfMissing/inc/dec/append/prepend, a non-list unset, a non-numeric
  # delta, non-list append/prepend items) are ignored, not fatal.
  defp apply_one(%{"patch" => %{"id" => id, "type" => type} = patch}, dataset, opts)
       when is_map_key(patch, "setIfMissing") or is_map_key(patch, "unset") or
              is_map_key(patch, "inc") or is_map_key(patch, "dec") or
              is_map_key(patch, "append") or is_map_key(patch, "prepend") do
    with {:ok, existing} <- get_patch_base(id, type, dataset, opts),
         :ok <- ensure_rev(existing, if_rev(patch)) do
      protected = ~w(title status _id _type _rev)
      set_fields = Map.get(patch, "set", %{})
      unset_keys = list_or_empty(Map.get(patch, "unset"))

      merged =
        (existing.content || %{})
        |> put_new_fields(Map.get(patch, "setIfMissing"), protected)
        |> Map.merge(Map.drop(set_fields, protected))
        |> apply_delta(Map.get(patch, "inc"), protected, 1)
        |> apply_delta(Map.get(patch, "dec"), protected, -1)
        |> apply_array_op(Map.get(patch, "append"), protected, :append)
        |> apply_array_op(Map.get(patch, "prepend"), protected, :prepend)
        |> Map.drop(unset_keys -- protected)

      attrs = %{
        "doc_id" => id,
        "title" => set_fields["title"] || existing.title,
        "content" => merged
      }

      with :ok <- ensure_task_close_is_cas(type, existing, merged, patch, opts),
           :ok <- ensure_claim_not_dropped(type, existing, merged, opts),
           :ok <- ensure_disposition_via_verb(type, existing, merged, opts),
           :ok <- ensure_adoption_adjudicated(type, existing, merged, opts),
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
    with {:ok, existing} <- get_patch_base(id, type, dataset, opts),
         :ok <- ensure_rev(existing, if_rev(patch)) do
      warn_on_nested_content(fields)

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

      with :ok <- ensure_task_close_is_cas(type, existing, merged, patch, opts),
           :ok <- ensure_claim_not_dropped(type, existing, merged, opts),
           :ok <- ensure_disposition_via_verb(type, existing, merged, opts),
           :ok <- ensure_adoption_adjudicated(type, existing, merged, opts),
           {:ok, doc} <-
             Content.upsert_document(type, attrs, dataset, with_if_rev(opts, if_rev(patch))),
           {:ok, doc} <- land_patch(existing, type, doc, dataset, opts),
           do: {:ok, doc, "update"}
    end
  end

  defp apply_one(_, _, _), do: {:error, :malformed}

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
  # (queue.ex, the `ready_done_tasks` CTE; the same disjunction `QueueGate`
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

  # ── The adjudication's own fence (PDS wave 24, charter D298 amended) ──────
  #
  # THE CLASS THIS CLOSES: a `type:task` row that SAYS it was adjudicated and
  # cannot say on what terms. `content.disposition` is the epic's adjudication
  # vocabulary — `open` / `parked` / `closed` — and until this slice it had ZERO
  # code writers repo-wide (re-derived 2026-07-30: `git grep '"disposition'`
  # over `api/lib`, `internal`, `js` and `scripts` returned exactly two hits,
  # neither a writer of the term). It existed because charter D298 instructed
  # AGENTS to hand-patch it through this very door. A field with no writer has,
  # by construction, no normaliser and no requirement, and the measured
  # consequence was both: a vocabulary reading `OPEN` 57 / `open` 47 / `parked`
  # 27 / ABSENT 37, and parked rows carrying nothing that says what would ever
  # reopen them. `content.reopen_trigger` existed in zero files and on zero
  # rows.
  #
  # WHY A GUARD HERE IS NOT ENOUGH ON ITS OWN, AND WHY THE VERB IS NOT EITHER.
  # This is the two-door judgment, and it is settled by measurement, not taste:
  #   * `Barkpark.Tasks.Stage` — the sole sanctioned writer of a durable
  #     adjudication REASON — could not write the TERM at all. Measured pre-fix:
  #     after a stage the persisted keys were exactly
  #     ["description","disposition_reason","engagement","kind",
  #      "lifecycle_status","tags"]. A stage-side requirement therefore cannot
  #     even SEE a parked disposition, so it can never fire.
  #   * Conversely a guard ONLY here leaves that sanctioned writer unfenced:
  #     `api/lib/barkpark/tasks/` contains ZERO references to
  #     `Content.apply_mutations` (the same fact the close guard above relies
  #     on), and `Stage` persists with a bare `Repo.update_all` inside its own
  #     advisory lock.
  # Both doors are therefore load-bearing: this one refuses the raw write and
  # NAMES the verb; `Tasks.Stage` makes the verb able to write the whole triple
  # (term + reason + trigger) atomically, and refuses a park with no trigger.
  #
  # SCOPE: ANY CHANGE OF THE TERM, NOT JUST A HOLLOW PARK. Refusing only
  # `parked`-without-a-trigger has a near-zero fire rate — under the charter's
  # own recipe a park usually arrives WITH a reason, and the ungoverned
  # two-case `OPEN`/`open` writes would sail past untouched. Refusing every raw
  # change routes all of them to the one writer that normalises, which is what
  # makes the vocabulary converge instead of merely making one shape harder.
  # `now == was` is NOT a change: bookkeeping on already-adjudicated rows
  # (digests, github sync fingerprints, compaction) passes untouched, exactly
  # as it does for the two sibling guards.
  #
  # THE SECOND STEP IS FENCED TOO. Writing the term through the verb and then
  # erasing `reopen_trigger` through this door would restore hollowness in two
  # moves, so an api-door write that BLANKS or DROPS the trigger of a row whose
  # resulting disposition is `parked` is refused as well. ADDING a trigger raw
  # is deliberately still allowed — it can only make an existing hollow park
  # honest, and the 27 already-parked rows need exactly that remediation.
  #
  # THERE IS NO REVISION ESCAPE, UNLIKE THE CLOSE GUARD. A rev precondition
  # proves the caller READ the row; it says nothing about whether the value
  # being written is a governed term with its trigger. The escape here is the
  # verb, and the message says so.
  #
  # REPLICATION IS EXEMPT, checked FIRST, for the same concrete reason the
  # claim fence states: `Sync.Applier.apply_upsert` mirrors an upstream row with
  # `createOrReplace` + the FULL remote document, and because `apply_mutations`
  # wraps the batch in one transaction, a refusal would roll back the ENTIRE
  # sync batch and wedge the replica on that row with no operator recourse.
  # `:source` is server-set (`MutateController` prepends `source: :api`), so a
  # request body can never reach the `:sync` value.
  #
  # THE FRESH-CREATE EXEMPTION IS STILL INHERITED HERE, AND IS NOW CLOSED
  # DOWNSTREAM (PDS wave 28). `ensure_*("task", nil, …), do: :ok` is still the
  # head of every sibling guard on this seam and the plain `create` clause still
  # calls none of them — that is unchanged and correct, because a birth has no
  # prior revision and no prior term for a CHANGE guard to compare against.
  # What changed is that the create-family doors all funnel into
  # `Content.create_document/4`, and `Writer.ensure_task_born_adjudicated/5` now
  # sits in that chain where `prev_doc == nil` IS expressible: a birth carrying
  # an off-vocabulary term, or a park with no reopen trigger, is refused there.
  # It is a fence and not a ban — a COMPLETE adjudication is born, so the
  # dataset-importer shape the substrate anticipates (migration
  # 20260528100000) still works. The pinning test inverted on purpose.
  #
  # WHAT REMAINS, STATED NOT IMPLIED AWAY: a birth carrying NO disposition at
  # all is logged and allowed (see that function's comment for why a hard
  # requirement is a protocol change, not a fence), so "every task row is
  # adjudicated" is NOT true by construction yet.
  @disposition_key "disposition"
  @reopen_trigger_key "reopen_trigger"
  @trigger_required_dispositions ~w(parked)

  # PDS wave 28: the FOURTH durable key gets the SAME raw-door treatment as the
  # term. `Tasks.Stage` screens a rerun that cannot fail (`git -C`, a `test`
  # predicate, command substitution, `merge-base --is-ancestor`, a pipe-masked
  # formatting tail) at the write seam — a screen a raw patch would walk
  # straight past, leaving the sanctioned-writer property as decoration. Any
  # CHANGE of the key through this door is refused and named to the verb;
  # `now == was` is not a change, so bookkeeping passes untouched.
  @disposition_rerun_key "disposition_rerun"

  defp ensure_disposition_via_verb("task", nil, _merged, _opts), do: :ok

  defp ensure_disposition_via_verb("task", existing, merged, opts) do
    was = existing.content || %{}
    was_term = was[@disposition_key]
    now_term = merged[@disposition_key]

    cond do
      # Replication mirrors upstream rows verbatim — checked BEFORE any change
      # predicate so a mirror always applies.
      Keyword.get(opts, :source, :api) != :api ->
        :ok

      # The term CHANGED through the raw door. Route it to the verb.
      now_term != was_term ->
        {:error, {:invalid_task_content, disposition_bypass_error(was_term, now_term)}}

      # The RERUN changed through the raw door — the same bypass one field
      # over. Route it to the verb, which screens a rerun that cannot fail.
      merged[@disposition_rerun_key] != was[@disposition_rerun_key] ->
        {:error, {:invalid_task_content, rerun_bypass_error(merged[@disposition_rerun_key])}}

      # The term is unchanged, but the trigger that makes a park honest is
      # being erased underneath it.
      now_term in @trigger_required_dispositions and
          trigger_erased?(was[@reopen_trigger_key], merged[@reopen_trigger_key]) ->
        {:error, {:invalid_task_content, trigger_erasure_error(now_term)}}

      true ->
        :ok
    end
  end

  defp ensure_disposition_via_verb(_type, _existing, _merged, _opts), do: :ok

  # ── ADOPTION-BY-REPARENT (PDS wave 28, the birth fence's second half) ──────
  #
  # A birth-scoped fence is STRUCTURALLY BLIND to adoption. A task filed outside
  # an epic carries no `parent_id`; giving it one later is an UPDATE with
  # `prev_doc` non-nil, so `Writer.ensure_task_born_adjudicated/5` — and every
  # other birth-scoped gate — never sees it. Without this guard the closure has
  # a side door: file bare, then reparent in, and the row is inside the epic's
  # denominator having never been adjudicated by anything.
  #
  # So: a `type:task` write that CHANGES `content.parent_id` must leave the row
  # carrying a disposition. It reads `merged` (the write's RESULT, not the
  # patch) for the same reason its siblings do — a patch that sets only
  # `parent_id` still has to be judged on what the row will BE.
  #
  # The vocabulary check is deliberate, not decorative: `disposition: "maybe"`
  # would otherwise satisfy a mere-presence test while meaning nothing, and the
  # raw door has no normaliser (`Tasks.Stage` is the one writer).
  #
  # THIS COMPOSES WITH `ensure_disposition_via_verb/4` INTO A DELIBERATE ORDER
  # OF OPERATIONS, and callers must know it: that guard refuses any raw CHANGE
  # of the term, so a bare row cannot be reparented and adjudicated in the same
  # mutate — the disposition has to be written FIRST, through the verb, and the
  # reparent comes after. That is the intended shape (adopt only rows that have
  # been judged), and the message says so rather than leaving the caller to
  # discover a two-guard interaction by trial.
  #
  # Replication is exempt first, same reason as every sibling: a mirror applies
  # verbatim or wedges the batch.
  @parent_key "parent_id"

  defp ensure_adoption_adjudicated("task", nil, _merged, _opts), do: :ok

  defp ensure_adoption_adjudicated("task", existing, merged, opts) do
    was = existing.content || %{}
    was_parent = was[@parent_key]
    now_parent = merged[@parent_key]

    cond do
      Keyword.get(opts, :source, :api) != :api -> :ok
      was_parent == now_parent -> :ok
      merged[@disposition_key] in Barkpark.Tasks.Stage.dispositions() -> :ok
      true -> {:error, {:invalid_task_content, adoption_error(was_parent, now_parent)}}
    end
  end

  defp ensure_adoption_adjudicated(_type, _existing, _merged, _opts), do: :ok

  defp adoption_error(was_parent, now_parent) do
    %{
      @parent_key => [
        "cannot be changed from #{inspect(was_parent)} to #{inspect(now_parent)} on a task " <>
          "carrying no adjudication. Reparenting is ADOPTION: it moves the row into (or out " <>
          "of) a parent's closure, and a row that joins a closure unjudged is exactly the " <>
          "bare row a birth-time fence cannot see, because giving a task a parent later is an " <>
          "update, not a birth. Adjudicate it FIRST through the sanctioned verb (`bp task " <>
          "stage <id> <state> --disposition <open|parked|closed> --note <why>`, " <>
          "POST /v1/tasks/:id/stage) — the disposition cannot be written in this same " <>
          "mutate, because the raw door refuses any change of it — then reparent."
      ]
    }
  end

  # A trigger is "erased" when the row carried a real one and the write's result
  # carries none. A blank string is not a trigger — the verb normalises the same
  # way (`Tasks.Stage.normalize_note/1`), so the two doors agree on what
  # "present" means.
  defp trigger_erased?(was, now), do: present_trigger?(was) and not present_trigger?(now)

  defp present_trigger?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_trigger?(_), do: false

  # Same `invalid_task_content` family as the close and claim siblings (422
  # `validation_failed` with a per-field details map) — no new error code, no
  # new controller branch. Keyed on the field the caller actually wrote, and the
  # message is the retry instruction: it names the verb, the flags, and the fact
  # that the verb writes the triple atomically.
  defp disposition_bypass_error(was, now) do
    %{
      @disposition_key => [
        "cannot be set to #{inspect(now)} through /v1/data/mutate" <>
          if(is_binary(was), do: " (currently #{inspect(was)})", else: "") <>
          ". A disposition is an adjudication: written raw it carries no normalised term, no " <>
          "durable reason and — for a park — nothing that says what would ever reopen it, " <>
          "which is a row that claims to be decided and has decided nothing. A revision " <>
          "precondition does NOT unlock this. Write it through the sanctioned verb instead " <>
          "(`bp task stage <id> <state> --disposition <open|parked|closed> " <>
          "--note <why> --reopen-trigger <what would reconsider it>`, " <>
          "POST /v1/tasks/:id/stage), which normalises the term and writes term, reason and " <>
          "trigger in one atomic write — and refuses a park with no trigger."
      ]
    }
  end

  # Same `invalid_task_content` family, keyed on the field the caller wrote,
  # and the message is the retry instruction. It states the property the raw
  # door would destroy: the rerun is screened at the verb's write seam, so a
  # rerun written raw is one nobody has checked can fail.
  defp rerun_bypass_error(now) do
    %{
      @disposition_rerun_key => [
        "cannot be set to #{inspect(now)} through /v1/data/mutate. The rerun is the one " <>
          "thing that could prove a durable reason WRONG, and it is screened at the verb's " <>
          "write seam — a rerun that cannot fail (`git -C`, a `test` predicate, `$( … )` " <>
          "command substitution, `git merge-base --is-ancestor`, or a pipe-masked " <>
          "formatting tail like `| head -1`) is refused there. Written raw it bypasses that " <>
          "screen, which is a check nobody has checked. A revision precondition does NOT " <>
          "unlock this. Write it through the sanctioned verb instead " <>
          "(`bp task stage <id> <state> --rerun \"git cat-file -e origin/main:<path>\"`), " <>
          "POST /v1/tasks/:id/stage — and omitting the rerun is always allowed: a reason " <>
          "may honestly refuse to be checkable."
      ]
    }
  end

  defp trigger_erasure_error(term) do
    %{
      @reopen_trigger_key => [
        "cannot be erased through /v1/data/mutate while this task is #{inspect(term)}. The " <>
          "reopen trigger is the only thing that makes a park a deferral rather than a silent " <>
          "drop: without it nothing states what would bring the row back. Re-adjudicate it " <>
          "through the sanctioned verb (`bp task stage <id> <state> --disposition open` to " <>
          "un-park, or `--reopen-trigger <new condition>` to replace the condition), " <>
          "POST /v1/tasks/:id/stage."
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

  defp list_or_empty(l) when is_list(l), do: l
  defp list_or_empty(_), do: []

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
end
