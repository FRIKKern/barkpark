defmodule Barkpark.Content.EventLog do
  @moduledoc """
  Read-side domain queries over the `mutation_events` backlog that the SSE
  listen stream (`BarkparkWeb.ListenController`) needs.

  Owns two reads the controller used to build inline, so the web layer keeps
  ONLY transport (cursor paging over HTTP, chunking) and never touches `Repo`
  or the schemas directly:

    * `replay_since/4` — the keyset-paginated Last-Event-ID replay stream.
    * `document_present?/2` — the delete-vs-owner-ACL tombstone discriminator.

  Both queries are intentionally distinct from `Barkpark.Content.Analytics`'
  scope helpers: replay filters on the DENORMALISED `mutation_events.workspace_id`
  (never an INNER JOIN to `documents`) so delete tombstones survive, and the
  presence check is deliberately scope-free (it asks only whether the row still
  physically exists). See the per-function docs.
  """

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Content.{Document, MutationEvent}

  # Keyset page size for the Last-Event-ID replay. The backlog grows without
  # bound, so replay is fetched one bounded batch at a time (below) instead of a
  # single unbounded Repo.all — a small resume cursor no longer loads the whole
  # history onto the heap. Overridable per call via `replay_since(.., batch: N)`
  # (tests drive a tiny batch to exercise the pagination loop across boundaries).
  @replay_batch 500

  @doc """
  Return a lazy Stream of mutation_events for dataset with id > since, oldest
  first — keyset-paginated in `@replay_batch`-sized batches so a small
  Last-Event-ID never materializes the whole (monotonically growing) backlog
  onto the heap. Output is identical to the old one-shot Repo.all (same events,
  same id order); only the memory profile changes. `Enum`/`Stream` consumers
  work unchanged; a caller that needs a materialized list wraps in
  `Enum.to_list/1`. Pass `batch: N` to override the page size (tests use a tiny
  batch to prove the loop advances the cursor across a boundary).

  With a non-nil `workspace_id`, only events whose own denormalised
  `mutation_events.workspace_id` matches are returned — the SSE stream is the
  hard tenant boundary for real-time changes, mirroring the query-layer WHERE
  workspace_id filter. The filter is row-local, so paging never widens the
  tenant boundary.

  The filter reads `mutation_events.workspace_id` (stamped from
  `doc.workspace_id` by `save_event/5` on every write) rather than INNER-JOINing
  the owning `documents` row. A join would silently DROP every delete tombstone:
  a delete's `documents` row is GONE by the time we replay, so the join matches
  nothing and the tenant-scoped listener never learns the doc was deleted (its
  cache serves the deleted doc forever). The event's own denormalised column
  survives the delete and is the correct tenant discriminator here.

  Three workspace values, three DIFFERENT filters — the middle one is the point:

    * a binary id  → `workspace_id == <id>` (the hard tenant boundary).
    * `:shared_only` → `workspace_id IS NULL`. This is the empty-scope sentinel
      `BarkparkWeb.ScopeHelpers.scope_opts/1` emits when a REQUEST resolved no
      workspace (task-3e2a70930c6df723); it means "the shared/global layer",
      never "every tenant". Mirrors `Content.Scope.scope_to_workspace/3`'s own
      `:shared_only` arm, so the SSE replay leg lands on the same answer as
      every other request-driven read.
    * `nil` → unfiltered (back-compat). Reachable ONLY from an internal caller
      that deliberately wants the global read: `ListenController.listen/2` now
      derives its filter from `scope_opts/1`, so an unresolved REQUEST produces
      `:shared_only` and can no longer reach this arm. It used to — that was the
      cross-tenant replay (a nil-workspace subscriber resumed and received every
      co-dataset tenant's mutation events, document payload included).
  """
  def replay_since(dataset, since, workspace_id \\ nil, opts \\ [])

  def replay_since(dataset, since, nil, opts) when is_integer(since) do
    batch = Keyword.get(opts, :batch, @replay_batch)

    # `type != "listener"` mirrors the `Sync.Outbox` egress exclusion (#5626,
    # PDF-D18): Personal Dev Fleet listener presence is per-machine truth and
    # must never resurface through the Last-Event-ID replay to an SSE consumer.
    from(e in MutationEvent,
      where: e.dataset == ^dataset and e.type != "listener",
      order_by: e.id,
      limit: ^batch
    )
    |> keyset_stream(since, batch)
  end

  # The empty-scope sentinel: the SHARED layer (`workspace_id IS NULL`) only —
  # NOT every tenant. Ordered before the binary clause purely for readability;
  # the two are disjoint. `type != "listener"` is carried here too, so the
  # eventId-70357 egress exclusion holds on all THREE legs.
  def replay_since(dataset, since, :shared_only, opts) when is_integer(since) do
    batch = Keyword.get(opts, :batch, @replay_batch)

    from(e in MutationEvent,
      where: e.dataset == ^dataset and is_nil(e.workspace_id) and e.type != "listener",
      order_by: e.id,
      limit: ^batch
    )
    |> keyset_stream(since, batch)
  end

  def replay_since(dataset, since, workspace_id, opts)
      when is_integer(since) and is_binary(workspace_id) do
    batch = Keyword.get(opts, :batch, @replay_batch)

    # `type != "listener"` — same egress exclusion as the nil-workspace leg
    # above (#5626, PDF-D18): listener presence never resurfaces through replay.
    from(e in MutationEvent,
      where: e.dataset == ^dataset and e.workspace_id == ^workspace_id and e.type != "listener",
      order_by: e.id,
      limit: ^batch
    )
    |> keyset_stream(since, batch)
  end

  def replay_since(_dataset, _since, _workspace_id, _opts), do: []

  # Drive the ordered, `limit`-bounded `base_query` as a keyset cursor: each step
  # fetches one batch with `id > cursor`, emits it, and advances the cursor to
  # the batch's last id; a batch shorter than `batch` is the tail, so we stop.
  # Emitting batches lazily (Stream.unfold → flat_map) keeps at most one batch of
  # structs on the heap regardless of how far back the resume cursor points.
  defp keyset_stream(base_query, since, batch) do
    Stream.unfold(since, fn
      nil ->
        nil

      cursor ->
        case Repo.all(where(base_query, [e], e.id > ^cursor)) do
          [] -> nil
          rows -> {rows, if(length(rows) < batch, do: nil, else: List.last(rows).id)}
        end
    end)
    |> Stream.flat_map(& &1)
  end

  @doc """
  True when a `documents` row for `doc_id` in `dataset` still physically exists.

  Deliberately scope-free: the listen path uses this only to distinguish an
  owner-row ACL denial (row present, filtered out for ownership) from a genuine
  delete (row gone), so it must ask about raw row existence, NOT a scoped read.
  """
  def document_present?(doc_id, dataset) do
    Repo.exists?(from(d in Document, where: d.doc_id == ^doc_id and d.dataset == ^dataset))
  end
end
