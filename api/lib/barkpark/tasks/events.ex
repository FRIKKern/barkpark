defmodule Barkpark.Tasks.Events do
  @moduledoc """
  Keyset replay of task `mutation_events` for `GET /v1/tasks/events?since=<id>`.

  The task-events feed is a THIN projection over the existing `mutation_events`
  backlog — no new store, no second event stream, no migration (D1
  one-substrate law, D10). It is the read side of the epic's "one event stream
  feeding every surface" wish: chat / statusline / deck / TUI all poll this ONE
  endpoint with the last id they saw and get every task mutation since, in
  commit order.

  Modeled on `Barkpark.Content.EventLog.replay_since/4` (the SSE Last-Event-ID
  stream) with the SAME keyset discipline — `WHERE id > since ORDER BY id ASC`
  over the monotonic PK — but narrowed to `type = "task"` and projected to the
  lean wire shape the feed needs.

  ## Why NOT `Barkpark.Tasks.Prime.recent_events`

  Prime's recent-events read is orientation, not replay: it sorts
  `inserted_at DESC` and carries NO `id`. Both make it replay-UNSAFE as a
  cursor stream:

    * no `id` → the caller has no monotonic cursor to resume from;
    * `inserted_at DESC` on the wall clock → under concurrent commits two events
      can share (or invert) a microsecond timestamp, so a "give me everything
      after time T" resume would silently drop or duplicate rows.

  The `id` PK is strictly monotonic, so `id > since` is an exact, lossless
  resume cursor even while other workers commit concurrently. That is the whole
  reason this is a NEW query and not a Prime reuse.

  ## Projected shape

  Each event is `%{id, event, doc_id, rev, at}`:

    * `id`     — the `mutation_events` PK. THE CURSOR: pass the last one you saw
                 back as `?since=` to resume exactly after it. Never `at`.
    * `event`  — the mutation kind (`task.claimed` / `task.closed` /
                 `task.pulse` / `task.criterion` / `task.reparented` / …). The
                 feed is kind-agnostic: whatever a task write path emits into
                 `mutation_events` surfaces here in id order.
    * `doc_id` — the task the event is about.
    * `rev`    — the task's rev after the mutation.
    * `at`     — the commit timestamp (display only — NEVER a resume cursor).
  """

  import Ecto.Query

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo

  @task_type "task"

  # Keyset page size, matching EventLog's replay batch. A single feed call
  # returns at most this many events; the caller pages by advancing `since` to
  # the last id (`has_more` is true when a full batch came back). The tail query
  # rides the PK index — proven 0.39ms (D10); a `(dataset, type, id)` covering
  # index is backlog before the table 10x's, NOT this wave.
  @default_limit 500
  @max_limit 500

  @doc """
  The ordered page of task events for `dataset` with `id > since`, oldest-first.

  Returns a list of `%{id, event, doc_id, rev, at}` maps (see the moduledoc). An
  empty list means the caller is caught up. Options:

    * `:limit` — page size, clamped to `[1, #{@max_limit}]` (default
      #{@default_limit}). A raw/oversized/negative value can never emit an
      unbounded or negative SQL `LIMIT`.
    * `:workspace_id` — when a non-nil binary, restrict to events whose own
      denormalised `workspace_id` matches — the SAME row-local tenant boundary
      `EventLog.replay_since/4` enforces (never an INNER JOIN to `documents`, so
      delete tombstones survive). The `:shared_only` empty-scope sentinel
      (`ScopeHelpers.scope_opts/1` for a request that resolved NO workspace)
      narrows to `workspace_id IS NULL` — the shared layer alone, never every
      tenant. nil → unscoped (back-compat / admin token).

  `since` below 0 is floored to 0 (a first call with no cursor replays from the
  start of the backlog, exactly like a `Last-Event-ID: 0`).
  """
  @spec replay_since(String.t(), integer(), keyword()) :: [map()]
  def replay_since(dataset, since, opts \\ [])
      when is_binary(dataset) and is_integer(since) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()
    since = max(since, 0)
    workspace_id = Keyword.get(opts, :workspace_id)

    from(e in MutationEvent,
      where: e.dataset == ^dataset and e.type == ^@task_type and e.id > ^since,
      order_by: [asc: e.id],
      limit: ^limit,
      select: %{
        id: e.id,
        event: e.mutation,
        doc_id: e.doc_id,
        rev: e.rev,
        at: e.inserted_at
      }
    )
    |> maybe_scope_workspace(workspace_id)
    |> Repo.all()
  end

  @doc """
  The clamped page size a `replay_since/3` call would use for `raw` — so the
  HTTP controller computes `has_more` (a full page came back) against the SAME
  bound the query applied, instead of duplicating the clamp.
  """
  @spec page_limit(term()) :: pos_integer()
  def page_limit(raw), do: clamp_limit(raw)

  @doc "The default (and maximum) page size — the keyset batch bound."
  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  defp clamp_limit(n) when is_integer(n), do: n |> min(@max_limit) |> max(1)
  defp clamp_limit(_), do: @default_limit

  defp maybe_scope_workspace(query, ws_id) when is_binary(ws_id),
    do: from(e in query, where: e.workspace_id == ^ws_id)

  # The empty-scope sentinel (task-5ca36b127acf9cbd, class task-3e2a70930c6df723).
  #
  # `BarkparkWeb.ScopeHelpers.scope_opts/1` emits `:shared_only` whenever an
  # HTTP request resolved NO workspace, and `TasksController.events/2` hands
  # that value straight to `replay_since/3`. It means the SHARED layer
  # (`workspace_id IS NULL`) — never "every tenant".
  #
  # Before this clause the atom failed the `is_binary/1` guard above and fell
  # into the permissive catch-all, so the feed went workspace-BLIND and
  # replayed every co-dataset tenant's task mutations. That is the fail-open
  # shape the sentinel exists to retire: the guard-plus-permissive-fallback
  # pair cannot distinguish "no tenant resolved" from "an internal caller wants
  # everything", and the wide reading won for both.
  #
  # Byte-for-byte the arm the correct modules already carry —
  # `Content.Scope.scope_to_workspace/3` (scope.ex:162) and this feed's own
  # SSE twin `Content.EventLog.replay_since/4` (event_log.ex:92), which this
  # module is explicitly modelled on. Ordered BEFORE the catch-all and after
  # the binary clause; all three are disjoint.
  defp maybe_scope_workspace(query, :shared_only),
    do: from(e in query, where: is_nil(e.workspace_id))

  # `nil` stays EXACTLY as it was: unfiltered, the deliberate global read for
  # internal / back-compat callers. Widening or narrowing it is not this
  # change's to make — only a REQUEST can produce `:shared_only`, which is
  # what separates the two intents.
  defp maybe_scope_workspace(query, _), do: query
end
