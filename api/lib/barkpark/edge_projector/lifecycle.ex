defmodule Barkpark.EdgeProjector.Lifecycle do
  @moduledoc """
  Routes the four `after_*` Content events to the right `ProjectorWorker` op,
  mirroring `Barkpark.Plugins.Indx.Lifecycle`.

  ## Invoked from TWO places

    1. The CORE wiring in `Barkpark.Content.fire_after/3` — called DIRECTLY
       (not through the plugin Hooks dispatch) on every mutating Content op, so
       the content graph projects even with ALL plugins off. This is the
       load-bearing fresh-install hook: `Barkpark.Plugins.Hooks.fire/2`
       dispatches only to plugins' `lifecycle_hooks/0`, and core is not a
       plugin, so without the direct call a plugins-`[]` install never projects.
    2. (Future) a plugin's `lifecycle_hooks/0` MAY also register this if a
       plugin wants graph projection on its own non-core event surface.

  ## Event → op routing

    * `:after_save`      — a doc was created/updated → REBUILD op (flag OFF,
      default) | UPSERT op (flag ON) — debounced (autosave bursts collapse).
    * `:after_publish`   — a draft was published      → SYNCHRONOUS per-doc
      UPSERT, inline, before this hook returns, when this publish is NOT
      inside a shared transaction (task-3fd3c0c53d08a6bd) | DEFERRED until
      that transaction commits, when it IS inside one AND that transaction's
      owner claimed the deferred queue (task-9231839aa8f5f891 — a batch
      `apply_mutations`/`POST /v1/data/mutate` with multiple publishes) |
      debounced UPSERT job, same as `:after_save`, on any failure, on a doc
      with no resolvable `_id`, or on a shared transaction NOBODY claimed the
      deferred queue for. See "Why a batch publish is DEFERRED, never run
      inline" below — this is load-bearing, not an optimisation.
    * `:after_unpublish` — a published doc went back to draft → DELETE op
      (always — the published graph must stop showing it the moment it leaves
      published state; the next publish re-projects it). Modelled as a delete,
      mirroring Indx.
    * `:after_delete`    — a doc was removed          → DELETE op (always)

  ## The feature flag (default OFF)

  `Settings.get().incremental_project` gates the `:after_save` add/update path
  ONLY:

    * OFF (the DEFAULT) → save takes the deterministic full per-scope REBUILD
      path. Inert incremental path.
    * ON  → save routes to the per-document incremental UPSERT op. A mis-diff
      strands stale edges in the durable table (no blue/green to discard,
      unlike Indx) — UNPROVEN, spike-gated.

  `:after_publish` no longer reads this flag (see below) — it always runs the
  bounded per-doc upsert, synchronously. delete/unpublish are ALWAYS
  incremental (no flag): the doc's edges just need to be GONE.

  ## Why `:after_publish` is synchronous (task-3fd3c0c53d08a6bd)

  Both `:after_save` and `:after_publish` used to share the SAME 5-second
  debounced `ProjectorWorker` job (`@debounce_seconds` there). That gave
  neither direction of an edge change (add OR remove) any promptness
  GUARANTEE: `publish_document/4` — and the broadcast/listen-frame it fires —
  returned the instant the job was *enqueued*, long before the job *ran*.

  Measured (barkpark-studio, guerrilla e2e-sanity, 2026-10-09): a reference
  change looked "prompt" (visible in well under 50ms) on some docs and
  "laggy" (3-6s) on others. The difference was never the write path (`patch`
  vs `createOrReplace` — both resolve to the SAME stable published-row PK;
  `Projector.upsert_record/2` diffs and prunes correctly either way, confirmed
  directly). It was purely Oban's own unique-job dedup: `ProjectorWorker`
  dedups `(op, …, _id, types)` across `:available`/`:scheduled`/`:executing`,
  so repeated writes to the same doc within the SAME 5s window are silently
  swallowed (no new schedule) — meaning the APPARENT latency any later read
  observes is just "however much of some EARLIER job's window happened to be
  left," which can look anywhere from instant (a stale, nearly-due job) to a
  full fresh 5s (a job that just (re)armed on the most recent write). A doc
  that received an extra write shortly before the one under test (e.g. a
  `createOrReplace` re-save) simply re-armed a fresh window right before the
  measurement, while a doc with only one prior write often had an already-due
  job by the time it was measured — same mechanism, different luck.

  The fix makes `:after_publish` NOT rely on that luck: it runs
  `Projector.upsert_record/2` for the one just-published doc inline, so by the
  time `publish_document/4` returns, `content_edges` already reflects both the
  new edge and the pruned stale one. This is safe to always run (regardless of
  the `incremental_project` flag) because it is bounded to ONE document's own
  extract + diff — not a corpus-wide rebuild.

  ## Why a batch publish is DEFERRED, never run inline (task-9231839aa8f5f891)

  `publish_document/4`'s OWN transaction always commits BEFORE `:after_publish`
  fires for a STANDALONE publish (`Content.Lifecycle.publish_after_commit/4`
  runs after `Broadcast.write_atomically/1` has already returned) — so for the
  common case, running `Projector.upsert_record/2` inline has NO transaction
  of its own to interact with. A BATCH `POST /v1/data/mutate` (or any caller
  of `Content.Mutations.apply_mutations/3`) is different: every mutation in
  the batch, including every `publish`, runs inside ONE shared
  `Repo.transaction/1` that does not commit until the whole batch finishes —
  so `:after_publish` fires for publish #2 of 500 while that ONE transaction
  is still open.

  MEASURED (scratch harness, not committed): a raised exception inside
  `Projector.upsert_record/2`'s own `Repo.transaction/1` call, when that call
  is ITSELF nested inside the batch's transaction, poisons the connection for
  the REST of that transaction — `rescue`-ing it one level up (exactly what
  `upsert_now/3` does) does NOT save it: the very next query on the same
  connection fails with `DBConnection.ConnectionError: transaction rolling
  back`. Ecto's documented `mode: :savepoint` escape is NOT a
  `Repo.transaction/2` option (it exists only for `Ecto.Adapters.SQL.Sandbox`,
  and for individual `Repo.insert/update/delete` calls, not an arbitrary
  nested block) — confirmed it does nothing here. Running the risky work in a
  separate `Task` (its own pool connection) was also tried and RULED OUT: it
  deadlocks, because the task's writes can need a lock the still-open outer
  transaction already holds, and the outer transaction will not release it
  until the task — which it is synchronously awaiting — returns.

  So for THIS event, inside someone else's open transaction, running it
  inline is not just slower, it is UNSAFE: a single doc's projector hiccup
  could poison and roll back an entire unrelated batch. `route_publish/2`
  instead DEFERS (`defer_upsert/3`) whenever the transaction's deferred queue
  is OWNED (`Broadcast.claim_deferred_queue/0` — every caller of
  `apply_mutations/3`, and the paper document-op path, already claims it
  before opening their transaction, for the SAME reason broadcasts and
  webhooks need it). The deferred upsert runs for real in
  `flush_deferred_upserts/0`, called from
  `Broadcast.flush_deferred_broadcasts/0` AFTER that transaction has
  committed — by construction, with no transaction of its own (or anyone
  else's) open on this process, so the batch is both prompt (correct by the
  time the batch call returns) and exactly as safe as the standalone case.

  The ONE remaining fallback is a transaction NOBODY claimed the deferred
  queue for (the same situation `Broadcast.record_orphan_if_unowned/2` warns
  about for a broadcast) — there, nothing will ever call
  `flush_deferred_upserts/0`, so deferring would silently strand the upsert
  forever. That case alone still takes the debounced `ProjectorWorker` path,
  exactly the pre-defer-queue behaviour.

  ## Recursion guard

  `ctx.source == :worker` is a no-op. The projector writes the `content_edges`
  table, not documents through `Content.*`, so it cannot re-fire these hooks
  today. The guard is defense-in-depth: if a future projector path EVER
  re-saves a doc it MUST stamp `ctx.source == :worker`, or `fire_after/3` will
  re-enqueue indefinitely (see the invariant note at `Content.fire_after/3`).
  When the payload has no `:ctx`, `source` is treated as nil → enqueue.
  """

  require Logger

  alias Barkpark.EdgeProjector.Projector
  alias Barkpark.EdgeProjector.ProjectorWorker
  alias Barkpark.EdgeProjector.Settings
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @after_events [:after_save, :after_publish, :after_unpublish, :after_delete]
  @save_events [:after_save]
  @delete_events [:after_unpublish, :after_delete]

  # task-9231839aa8f5f891's deferred-upsert queue. `@deferred_owner_key` MUST
  # stay byte-identical to `Barkpark.Content.Broadcast`'s OWN
  # `@deferred_owner_key` (`:barkpark_deferred_owner`) — process-dictionary
  # keys are plain terms, not namespaced by module, so reading the SAME atom
  # here needs no call back into Broadcast (which would make a cycle:
  # Broadcast already calls INTO this module, at `flush_deferred_upserts/0`).
  # `@deferred_edge_upserts_key` is this module's OWN queue, parallel to
  # Broadcast's `:barkpark_deferred_broadcasts` / `:barkpark_deferred_webhooks`.
  @deferred_owner_key :barkpark_deferred_owner
  @deferred_edge_upserts_key :barkpark_deferred_edge_upserts

  @doc """
  The single fast hook fn for all four `after_*` events. Always returns `:ok`
  — a projection-enqueue failure must never crash the mutating Content op.

  No-ops on:
    * `ctx.source == :worker` (recursion guard)
    * a payload with no resolvable dataset

  Routes:
    * `:after_save` → debounced REBUILD job (flag OFF, default) or debounced
      UPSERT job carrying the doc `_id` (flag ON); falls through to a rebuild
      when ON if the doc has no resolvable `_id`.
    * `:after_publish` → SYNCHRONOUS per-doc upsert, inline (see moduledoc);
      falls back to the same debounced path as `:after_save` on any failure
      or a doc with no resolvable `_id`.
    * `:after_unpublish` / `:after_delete` → debounced DELETE job (carries the
      doc `_id`); falls through to a rebuild only if the doc has no resolvable
      `_id`.
  """
  @spec enqueue_rebuild(map()) :: :ok
  def enqueue_rebuild(%{event: event, doc: doc, dataset: dataset, ctx: ctx})
      when event in @after_events do
    cond do
      Map.get(ctx || %{}, :source) == :worker ->
        :ok

      not is_binary(dataset) or dataset == "" ->
        :ok

      event in @delete_events ->
        do_enqueue_delete(doc, dataset)

      event == :after_publish ->
        route_publish(doc, dataset)

      event in @save_events ->
        route_save(doc, dataset)

      true ->
        :ok
    end
  end

  # The Content payload may omit :dataset/:ctx (e.g. the bare fire_after map).
  # Resolve the dataset off the doc when the payload key is absent, and treat a
  # missing :ctx as source nil → enqueue.
  def enqueue_rebuild(%{event: event, doc: doc} = payload) when event in @after_events do
    dataset = Map.get(payload, :dataset) || dataset_of(doc)
    ctx = Map.get(payload, :ctx)
    enqueue_rebuild(%{event: event, doc: doc, dataset: dataset, ctx: ctx})
  end

  def enqueue_rebuild(_other), do: :ok

  # add/update routing gated by the incremental_project flag. OFF (default) →
  # the full per-scope REBUILD op. ON → the per-document UPSERT op carrying the
  # doc _id; with no resolvable _id we cannot target a doc, so fall back to a
  # rebuild (never leave the graph stale).
  defp route_save(doc, dataset) do
    if incremental_project?() do
      do_enqueue_upsert(doc, dataset)
    else
      do_enqueue_rebuild(doc, dataset)
    end
  end

  # PUBLISH: a bounded, synchronous per-doc upsert — no flag, no debounce (see
  # moduledoc, task-3fd3c0c53d08a6bd) — UNLESS this publish is already inside
  # someone else's open transaction (a batch mutate), in which case running it
  # INLINE is not an optimisation question, it is a SAFETY one (see "Why batch
  # publishes stay debounced" above). Three cases:
  #
  #   1. Not in a transaction (the standalone publish — by far the common
  #      case): run `upsert_now/3` immediately, as before.
  #   2. In a transaction whose owner CLAIMED the deferred queue
  #      (`Broadcast.claim_deferred_queue/0` — `Content.Mutations` and
  #      `Papers.BlockOps`'s own batch boundaries always do): DEFER. The
  #      upsert runs for real once that transaction commits
  #      (`flush_deferred_upserts/0`, called from
  #      `Broadcast.flush_deferred_broadcasts/0`) — never while any
  #      connection is still inside the risky transaction.
  #   3. In a transaction nobody claimed (an UNOWNED deferred scope — the
  #      same situation `Broadcast.record_orphan_if_unowned/2` warns about
  #      for a broadcast/webhook): nothing will ever flush a deferred item
  #      here, so take the debounced `ProjectorWorker` path instead —
  #      byte-identical to this fix's very first (pre-defer-queue) cut.
  #
  # A doc with no resolvable `_id` cannot be targeted at all (deferred or
  # not), so it always takes the debounced-rebuild fallback `:after_save`
  # uses, regardless of which of the three cases above it would have hit.
  defp route_publish(doc, dataset) do
    case doc_id(doc) do
      id when is_binary(id) and id != "" ->
        cond do
          not Repo.in_transaction?() ->
            case upsert_now(doc, id, dataset) do
              :ok -> :ok
              :fallback -> do_enqueue_upsert(doc, dataset)
            end

          Process.get(@deferred_owner_key) ->
            defer_upsert(doc, id, dataset)

          true ->
            do_enqueue_upsert(doc, dataset)
        end

      _ ->
        do_enqueue_rebuild(doc, dataset)
    end
  end

  # Queue this doc's upsert for `flush_deferred_upserts/0` instead of running
  # it now. Stores the ALREADY-RESOLVED `id` (the caller just matched on it)
  # so the flush never has to re-derive it, and prepends (flushed in reverse
  # — the same "built by prepending" convention `Broadcast`'s own two queues
  # use, for the same reason: O(1) here, one `Enum.reverse/1` at flush time).
  defp defer_upsert(doc, id, dataset) do
    queue = Process.get(@deferred_edge_upserts_key, [])
    Process.put(@deferred_edge_upserts_key, [{doc, id, dataset} | queue])
    :ok
  end

  @doc """
  Run every edge-upsert `route_publish/2` deferred during a transaction that
  just committed (task-9231839aa8f5f891 — the safe completion of
  task-3fd3c0c53d08a6bd's batch-publish gap). Called from
  `Barkpark.Content.Broadcast.flush_deferred_broadcasts/0`, AFTER it flushes
  broadcasts and webhooks — so by the time any of these run, the write that
  queued them has already committed and released its connection. This is the
  one guarantee the inline path could not give a BATCH publish: every queued
  upsert here runs with NO transaction of its own (or anyone else's) open on
  this process, so a raised exception can only ever fall back to the
  debounced job (`flush_one_deferred_upsert/1`), never touch — let alone
  roll back — the commit that already happened.

  A no-op when nothing was deferred (the overwhelmingly common case: most
  committed transactions publish nothing, or publish standalone and never
  reach `defer_upsert/3` at all).
  """
  @spec flush_deferred_upserts() :: :ok
  def flush_deferred_upserts do
    queue = Process.delete(@deferred_edge_upserts_key) || []

    queue
    |> Enum.reverse()
    |> Enum.each(&flush_one_deferred_upsert/1)

    :ok
  end

  # ONE queued upsert, isolated — mirrors `Broadcast.flush_one_webhook/1`
  # exactly in intent: a raise here must not abort the `Enum.each` and drop
  # every LATER queued upsert of the same committed batch. `upsert_now/3`
  # already rescues internally (so this `rescue` is belt-and-suspenders for
  # a raise in `do_enqueue_upsert/2` itself — an Oban insert failing in a way
  # that raises rather than returning `{:error, _}`), but the isolation
  # guarantee must hold at THIS boundary regardless of which layer catches it.
  defp flush_one_deferred_upsert({doc, id, dataset}) do
    case upsert_now(doc, id, dataset) do
      :ok -> :ok
      :fallback -> do_enqueue_upsert(doc, dataset)
    end
  rescue
    e ->
      Logger.error(
        "EdgeProjector.Lifecycle: flushing a deferred publish-upsert RAISED for _id=#{id} " <>
          "dataset=#{dataset}, falling back to the debounced path: " <> Exception.message(e)
      )

      do_enqueue_upsert(doc, dataset)
  end

  defp upsert_now(doc, id, dataset) do
    ws = scope_field(doc, :workspace_id)

    project_opts =
      [dataset: dataset]
      |> maybe_scope(:workspace_id, ws)
      |> maybe_scope(:project_id, scope_field(doc, :project_id))
      |> maybe_scope(:require_workspace, require_workspace?(ws))

    case injected_upsert_fault() || Projector.upsert_record(doc, project_opts) do
      {:ok, %{added: added, removed: removed}} ->
        Logger.info(
          "EdgeProjector.Lifecycle: synchronous publish-upsert _id=#{id} dataset=#{dataset} " <>
            "added=#{added} removed=#{removed}"
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "EdgeProjector.Lifecycle: synchronous publish-upsert FAILED for _id=#{id} " <>
            "dataset=#{dataset}: #{inspect(reason)} — falling back to the debounced path"
        )

        :fallback
    end
  rescue
    e ->
      Logger.error(
        "EdgeProjector.Lifecycle: synchronous publish-upsert RAISED for _id=#{id} " <>
          "dataset=#{dataset}, falling back to the debounced path: " <> Exception.message(e)
      )

      :fallback
  end

  # Test-only fault seam, mirroring `Barkpark.Content.Writer.inject_write_fault!/1`
  # verbatim in intent: proves the fallback branches in `upsert_now/3` ACTUALLY
  # run (task-3fd3c0c53d08a6bd's failure-isolation requirement — "a projection
  # error must never fail or roll back the publish") without needing a real,
  # hard-to-reproduce DB fault. `nil` in every non-test env — one
  # `Application.get_env` on a path that is already about to hit Postgres.
  defp injected_upsert_fault do
    case Application.get_env(:barkpark, :edge_projector_upsert_fault) do
      {:raise, module, message} when is_atom(module) and is_binary(message) ->
        raise module, message

      {:error, _reason} = err ->
        err

      _ ->
        nil
    end
  end

  # Mirrors `ProjectorWorker`'s own `require_workspace?/1`: a nil workspace in
  # a multi-tenant install fails the endpoint resolution closed rather than
  # resolving across tenants; a single-tenant install (or a resolved
  # workspace) keeps the or-global back-compat resolution.
  defp require_workspace?(nil), do: Tenancy.multi_tenant?()
  defp require_workspace?(ws) when is_binary(ws), do: false

  defp incremental_project? do
    Settings.get().incremental_project == true
  rescue
    # Settings.get/0 never raises by contract, but a misconfigured DB read must
    # never crash a lifecycle hook — degrade to the safe rebuild path.
    _ -> false
  end

  defp do_enqueue_upsert(doc, dataset) do
    case doc_id(doc) do
      id when is_binary(id) and id != "" ->
        finish(ProjectorWorker.enqueue_upsert(dataset, id, scope_opts(doc)), dataset, "upsert")

      _ ->
        do_enqueue_rebuild(doc, dataset)
    end
  end

  defp do_enqueue_rebuild(doc, dataset) do
    finish(ProjectorWorker.enqueue(dataset, scope_opts(doc)), dataset, "rebuild")
  end

  defp do_enqueue_delete(doc, dataset) do
    case doc_id(doc) do
      id when is_binary(id) and id != "" ->
        finish(ProjectorWorker.enqueue_delete(dataset, id, scope_opts(doc)), dataset, "delete")

      _ ->
        do_enqueue_rebuild(doc, dataset)
    end
  end

  defp scope_opts(doc) do
    [types: types_of(doc)]
    |> maybe_scope(:workspace_id, scope_field(doc, :workspace_id))
    |> maybe_scope(:project_id, scope_field(doc, :project_id))
  end

  defp finish({:ok, _job}, _dataset, _op), do: :ok

  defp finish({:error, reason}, dataset, op) do
    Logger.error(
      "EdgeProjector.Lifecycle: failed to enqueue #{op} for dataset=#{dataset}: #{inspect(reason)}"
    )

    :ok
  end

  # The doc's Barkpark _id. A %Document{} carries it as :doc_id; map shapes use
  # "_id"/:_id. Mirrors Indexer.doc_id/1's key precedence.
  defp doc_id(%{doc_id: id}) when is_binary(id) and id != "", do: id
  defp doc_id(%{"_id" => id}) when is_binary(id) and id != "", do: id
  defp doc_id(%{_id: id}) when is_binary(id) and id != "", do: id
  defp doc_id(%{"doc_id" => id}) when is_binary(id) and id != "", do: id
  defp doc_id(_), do: nil

  # Read the doc's type from either struct (atom `:type`) or map (string
  # `"_type"`/`"type"`) shape. Single-element list so the worker rebuilds just
  # the changed type's slice of the corpus.
  defp types_of(%{type: t}) when is_binary(t) and t != "", do: [t]
  defp types_of(%{"_type" => t}) when is_binary(t) and t != "", do: [t]
  defp types_of(%{_type: t}) when is_binary(t) and t != "", do: [t]
  defp types_of(%{"type" => t}) when is_binary(t) and t != "", do: [t]
  defp types_of(_), do: []

  defp dataset_of(%{dataset: d}) when is_binary(d) and d != "", do: d
  defp dataset_of(%{"dataset" => d}) when is_binary(d) and d != "", do: d
  defp dataset_of(_), do: nil

  defp scope_field(%{} = doc, key) do
    Map.get(doc, key) || Map.get(doc, Atom.to_string(key))
  end

  defp scope_field(_, _), do: nil

  defp maybe_scope(opts, _key, nil), do: opts
  defp maybe_scope(opts, key, value), do: Keyword.put(opts, key, value)
end
