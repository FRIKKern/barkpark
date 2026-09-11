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

  ## The typed payload (`:payload` — OPT-IN)

  A task write path may stamp its own map into the event's `document` alongside
  the Envelope-shaped view of the row (`Tasks.Internal.insert_mutation_event!/5`
  merges `extra_document`). `task.staged` is the one that matters for recovery:
  `stage.ex` writes `%{"staged" => %{"note" => …, "superseded_note" => …, …}}`,
  where `superseded_note` is the disposition reason the stage DISPLACED. That
  is the only durable copy of a clobbered note — and until this option existed
  the feed dropped it on the floor, so `bp task stage --help`'s promise that "a
  superseded note is recoverable from `bp task events`" was FALSE: the projection
  never selected `document` at all.

  With `payload: true` each row gains a `:payload` key carrying ONLY the typed
  stamps — never the Envelope half, so the row's whole `content` blob and the
  `caller_token_id` audit stamp stay out of the feed. A row whose event stamped
  none carries no `:payload` key at all.

  ### The projection is DERIVED, not a hand-kept list of verbs

  It used to be a literal whitelist — `~w(staged reparented fenced
  lease_expired)` — and that list was the defect: `Tasks.Landed` had been
  stamping a `landed_mark` (`{landed, criterion, flipped}`) since it shipped,
  and because nobody added the word to this module every single `task.landed`
  event in the backlog reached the wire with an EMPTY payload. All 20 of them,
  measured 2026-09-06 across 81,564 events. `bp task landed` is the one verb
  that writes with no claim, no worker id and no epoch, so its event is the
  ONLY durable account of which criterion a landing notice flipped — and the
  recovery channel was blind for exactly that verb.

  A whitelist makes silence the default for every future verb, so the whitelist
  is gone. The payload is now `document` MINUS two lists that live NEXT TO THE
  WRITER that produces them:

    * `Tasks.Internal.envelope_keys/0` — the Envelope-shaped view
      `Internal.envelope_document/1` writes into EVERY task mutation event
      (`doc_id`/`type`/`title`/`status`/`content`/`rev`). It is the one place
      that shape is defined, and `TtlSweeper`'s two hand-rolled inserts build
      from it too, so there is no second envelope to drift.
    * `Tasks.Internal.audit_keys/0` — `caller_stamp/1`'s `caller_token_id`.

  Everything else in `document` got there because a task write path merged its
  own typed stamp through `insert_mutation_event!/5`'s `extra_document`. That
  is the definition of a typed payload, so that is what is projected. A NEW
  verb's stamp is on the feed the moment it is written; nothing has to be
  remembered here.

  The size property the opt-in exists to protect is unchanged, because it was
  never the LIST that bounded the bytes — it is the Envelope subtraction. The
  row's whole `content` blob is an envelope key and stays out either way, and a
  typed stamp is a handful of scalars plus (for `staged`) the notes the
  recovery sweep is there to read.

  ## Why OPT-IN and not always-on

  Two free-text notes ride in one `staged` stamp, and notes of 1228 characters
  are attested on this very row's history. A default page is 500 events, so a
  default-on payload would add up to ~1 MB to a body that every statusline /
  TUI / deck poller fetches on a tick, to carry a field only a recovery sweep
  reads. Opt-in leaves every existing poller's response BYTE-IDENTICAL: the
  option defaults to false and the query is the same one it always was.
  """

  import Ecto.Query

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo
  alias Barkpark.Tasks.Internal

  @task_type "task"

  # The keys a payload row must NEVER carry, taken from the WRITER that puts
  # them there (see the moduledoc). Everything else in `document` is a typed
  # `extra_document` stamp and IS the payload — so a new verb's stamp needs no
  # edit here to become visible.
  @non_payload_keys Internal.envelope_keys() ++ Internal.audit_keys()

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
    * `:payload` — `true` adds the typed payload stamp (`:payload`) to each row
      that has one; see the moduledoc. Defaults to `false`, in which case the
      projection and the returned maps are byte-for-byte what they always were.
    * `:doc_id` — when a non-nil binary, restrict to the events of that ONE
      task. The per-row audit narrowing (`bp task events <id>`,
      `GET /v1/tasks/events?doc_id=…`): one row's whole mutation history in
      commit order, without paging the global backlog to find it. Composes
      with `since`/`limit`/`payload` — it is another where-clause on the same
      keyset query, so the cursor contract is unchanged. nil → unscoped.
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
    payload? = Keyword.get(opts, :payload, false) == true
    doc_id = Keyword.get(opts, :doc_id)

    rows =
      from(e in MutationEvent,
        where: e.dataset == ^dataset and e.type == ^@task_type and e.id > ^since,
        order_by: [asc: e.id],
        limit: ^limit
      )
      |> maybe_scope_doc(doc_id)
      |> maybe_scope_workspace(workspace_id)
      |> select_shape(payload?)
      |> Repo.all()

    if payload?, do: Enum.map(rows, &project_payload/1), else: rows
  end

  # The lean shape (default) and the lean shape PLUS the raw `document`, which
  # `project_payload/1` immediately narrows to the whitelist. `document` is
  # selected only under the opt-in, so the default read moves the same bytes off
  # Postgres it always did.
  defp select_shape(query, false) do
    from(e in query,
      select: %{id: e.id, event: e.mutation, doc_id: e.doc_id, rev: e.rev, at: e.inserted_at}
    )
  end

  defp select_shape(query, true) do
    from(e in query,
      select: %{
        id: e.id,
        event: e.mutation,
        doc_id: e.doc_id,
        rev: e.rev,
        at: e.inserted_at,
        document: e.document
      }
    )
  end

  # `document` never reaches the wire — it is replaced by the typed stamps
  # under `:payload` (everything the writer merged that is not envelope and not
  # audit), and dropped entirely when the event stamped none (a plain
  # `task.claimed` row is then IDENTICAL to its default-shape self).
  defp project_payload(row) do
    document = Map.get(row, :document)
    row = Map.delete(row, :document)

    typed =
      case document do
        map when is_map(map) -> Map.drop(map, @non_payload_keys)
        _ -> %{}
      end

    if map_size(typed) == 0, do: row, else: Map.put(row, :payload, typed)
  end

  @doc """
  The keys the `:payload` projection subtracts from an event's `document`.

  Exposed so a test can ask this module what it excludes and check that against
  what the WRITERS actually merge, instead of re-listing verbs by hand.
  """
  @spec non_payload_keys() :: [String.t()]
  def non_payload_keys, do: @non_payload_keys

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

  # ─── THE PER-DOC NARROWING (tlv-bl-events-actor-attribution) ─────────────
  #
  # `mutation_events.doc_id` is the task the event is about, and it is already
  # projected onto every feed row — so an auditor asking "what happened to THIS
  # row" was reduced to replaying the global stream and filtering client-side.
  # On a ledger whose backlog is 81,564+ events at a 500-row page that is ~163
  # requests to answer a one-row question, and the answer is only as complete
  # as the caller's patience: a sweep that stops early reads an absence it
  # manufactured. This clause is that filter, pushed to Postgres.
  #
  # It composes rather than replaces: `since` still bounds the keyset, so
  # `--since <last id> <doc_id>` is a per-row TAIL, and the cursor a caller
  # resumes from is still the global monotonic PK.
  #
  # Deliberately NOT a new route: the feed's shape, scoping, clamp and cursor
  # contract are all owned here, and a `/v1/tasks/:doc_id/events` twin would
  # have to re-derive every one of them (and would mount ahead of
  # `/tasks/:doc_id`'s own family). A where-clause has no second contract to
  # drift.
  defp maybe_scope_doc(query, doc_id) when is_binary(doc_id) and doc_id != "",
    do: from(e in query, where: e.doc_id == ^doc_id)

  defp maybe_scope_doc(query, _), do: query

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
