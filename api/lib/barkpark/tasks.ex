defmodule Barkpark.Tasks do
  @moduledoc """
  W7a step 1 — Task-document schema on the existing `documents` substrate.

  Tasks live as rows in the `documents` table, scoped by the shipped
  workspace/project/dataset tenancy primitives. Everything is a task: a
  goal/epic is just a root task, a phase is just a task with children, and
  a rail is the chronological child tasks of a task. This module owns:

    * the single `task` schema definition the seeds.exs and
      `Plugins.Bootstrap` paths register so it appears in the
      `schema_definitions` table alongside `post`/`page`/`paper`;
    * the **lifecycle status** axis for task documents — a separate axis
      from the existing `documents.status` (Sanity draft/published flow);
    * a `validate_task_content/1` validator the document write paths call
      before insert/update when `type == "task"`.

  ## Status-axis decision (per plan §1 "Status widening")

  The plan offered two options. This module picks **option (b)** — store
  the task lifecycle on a NEW jsonb field `content.lifecycle_status`,
  leave `documents.status` alone for the existing draft/published flow.

  Rationale:

    * `documents.status` already mixes two orthogonal axes (Sanity
      `draft/published/archived` + project-type `active/planning/completed`).
      Adding `open/in_progress/blocked/done/cancelled` would mix a third
      axis and force every reader pattern-matching on `status` to know
      which one applies.
    * Future Tasks API + Studio dual-reads of the SAME task row need both
      axes independently: a task can be a `documents.status="draft"` (not
      yet visible in published reads) while carrying
      `content.lifecycle_status="open"` (orchestrator-claimable).
    * Minimal schema diff: no enum widening, no string-list to keep in
      sync across changeset + Studio. The DB-level guarantee is a
      conditional check constraint on `content->>'lifecycle_status'`
      that fires only for `type='task'` rows (see migration
      `20260528100000_w7a_task_schema`).
    * Reversible cleanly: the migration's `down/0` drops the constraint.

  ## Field contract for `kind:task` (per plan §1)

      content: %{
        "kind" => "task",                       # required, must equal "task"
        "lifecycle_status" => "open",           # required, one of the 5 below
        "priority" => 0..4,                     # optional integer, 0..4 inclusive
        "assignee" => "<token-id>" | nil,       # optional string
        "dependencies" => ["<doc_id>", ...],    # optional array of strings
        "claim" => %{                           # optional map (claim primitives, W7-04)
          "worker" => "<id>",
          "ts_iso" => "2026-05-27T11:23:45Z",
          "epoch"  => 1
        },
        "parent_id" => "<parent-task-doc-id>"   # optional string (hierarchy)
      }

  The validator enforces only what is REQUIRED + the enum shape of the five
  string fields; everything else is shape-checked permissively (the
  authoritative `task_edges` table arrives in W7-02). The plan calls this
  "the tightened contract — what the live readers actually consume."

  The **task-dossier** schema (see `task_schema/1`) additionally declares
  optional working-memory fields — `description`, `design`, `design_doc`,
  `acceptance_criteria`, `estimate`, `due_at`, `labels`, `worklog`,
  `blocked_reason`, `attachments`, `outcome`, `close_reason`, `retro`,
  `papers`, `history`, `history_summary` — all shape-checked
  top-level-only when present, never required. The engine reads none of
  them; they are agent/human working memory on the same row.
  """

  alias Barkpark.Content.{Document, SchemaDefinition}
  alias Barkpark.Tasks.Edge
  alias Barkpark.Tasks.Edges
  alias Barkpark.Tasks.{Claim, Close, Mutations, Queue}
  alias Barkpark.Tasks.Schema
  alias Barkpark.Tasks.Validation

  # W7-04 mutation_events kinds. Routed into the existing `mutation` text column
  # so the spine, webhooks, and listen endpoint surface task ops alongside
  # document ops without a schema change.
  @event_task_claimed "task.claimed"
  @event_task_closed "task.closed"
  @event_task_mutated "task.mutated"
  # tt5: file-claim label support. Emitted when content.labels changes via
  # relabel_by_id/3 (the bd-shim's `update --add-label/--remove-label` path).
  @event_task_relabeled "task.relabeled"
  # Phase A: task→paper reference support. Emitted when content.papers changes
  # via update_paper_refs_by_id/3 (the `/v1/tasks/:doc_id/papers` path).
  @event_task_referenced "task.referenced"


  @doc "The five lifecycle-status string values a task document may carry."
  @spec lifecycle_statuses() :: [String.t()]
  defdelegate lifecycle_statuses, to: Validation

  @doc "The `content.kind` discriminator values (only `task`)."
  @spec kinds() :: [String.t()]
  defdelegate kinds, to: Validation

  # ─── Schema definitions (extracted → Barkpark.Tasks.Schema) ───────────────

  @doc """
  Returns the `%SchemaDefinition{}` list the W7 substrate needs.
  `dataset` defaults to `"production"`.
  See `Barkpark.Tasks.Schema.schema_definitions/1`.
  """
  @spec schema_definitions(String.t()) :: [SchemaDefinition.t()]
  def schema_definitions(dataset \\ "production"), do: Schema.schema_definitions(dataset)

  @doc """
  Just the `task` schema struct (callers that only need one).
  `dataset` defaults to `"production"`.
  See `Barkpark.Tasks.Schema.task_schema/1`.
  """
  @spec task_schema(String.t()) :: SchemaDefinition.t()
  def task_schema(dataset \\ "production"), do: Schema.task_schema(dataset)

  # ─── Validation (extracted → Barkpark.Tasks.Validation) ─────────────────────

  @doc """
  Validates the `content` map of a `type:task` document against the §1
  field contract. See `Barkpark.Tasks.Validation.validate_task_content/1`.
  """
  @spec validate_task_content(map() | nil) :: :ok | {:error, map()}
  defdelegate validate_task_content(content), to: Validation

  @doc """
  Validates `content` against the shape for the given `kind`.
  See `Barkpark.Tasks.Validation.validate_kind_content/2`.
  """
  @spec validate_kind_content(String.t(), map() | nil) :: :ok | {:error, map()}
  defdelegate validate_kind_content(kind, content), to: Validation

  # ─── W7a step 2: typed dep graph (extracted → Barkpark.Tasks.Edges) ──────

  @doc """
  Edge kinds in this codebase today. See `Barkpark.Tasks.Edges.edge_kinds/0`.
  """
  @spec edge_kinds() :: [String.t()]
  defdelegate edge_kinds, to: Edges

  @doc """
  Add a dependency edge: `child` blocks on `parent`. `kind` defaults to
  `:blocks`. See `Barkpark.Tasks.Edges.add_dep/3`.
  """
  @spec add_dep(binary(), binary(), atom() | String.t()) ::
          {:ok, Edge.t()} | {:error, Ecto.Changeset.t()}
  def add_dep(child_id, parent_id, kind \\ :blocks), do: Edges.add_dep(child_id, parent_id, kind)

  @doc """
  Remove the `(child_id, parent_id, kind)` edge.
  See `Barkpark.Tasks.Edges.remove_dep/3`.
  """
  @spec remove_dep(binary(), binary(), atom() | String.t()) :: :ok
  defdelegate remove_dep(child_id, parent_id, kind), to: Edges

  @doc """
  The documents `task_id` depends on — the blockers.
  `opts` defaults to `[]`. See `Barkpark.Tasks.Edges.dependencies/2`.
  """
  @spec dependencies(binary(), keyword()) :: [Document.t()]
  def dependencies(task_id, opts \\ []), do: Edges.dependencies(task_id, opts)

  @doc """
  The documents that depend on `task_id` — the dependents.
  `opts` defaults to `[]`. See `Barkpark.Tasks.Edges.dependents/2`.
  """
  @spec dependents(binary(), keyword()) :: [Document.t()]
  def dependents(task_id, opts \\ []), do: Edges.dependents(task_id, opts)

  @doc """
  Low-level query: every edge touching `task_id` on either side.
  `opts` defaults to `[]`. See `Barkpark.Tasks.Edges.edges/2`.
  """
  @spec edges(binary(), keyword()) :: [Edge.t()]
  def edges(task_id, opts \\ []), do: Edges.edges(task_id, opts)

  # ─── W7a step 3: dependency-aware, phase-scoped ready-queue + claim ───────
  # ready/1 → Tasks.Queue · claim/2 + claim_by_id/3 → Tasks.Claim (defdelegated).

  @doc """
  The ready-queue: task documents that are `claim/2`-eligible right now.

  A task is **ready** when ALL of these hold:

    * `type = "task"` AND `content->>'kind' = "task"` (defense in depth — the
      W7-01 validator already enforces it but the read path doesn't trust
      the application boundary);
    * `content->>'lifecycle_status'` ∈ `{"open", "blocked"}` (not
      `in_progress` / `done` / `cancelled`);
    * the task is in the **active phase** (when `:phase_id` is given,
      `content->>'parent_id' = <phase_doc_id>`; without the opt the
      result is phase-agnostic — handy for testing and for the dock's
      "everything ready in this workspace" feed);
    * **every outbound `blocks` edge points at a `done` document** —
      authoritative dep graph from `task_edges`; per W7-02 the FKs are
      on `documents.id` (uuid) NOT `documents.doc_id` (string), so the
      join is `e.to_id = b.id` (NOT `e.to_doc = b.doc_id` as the plan's
      illustrative SQL suggested);
    * the row is scoped to the caller's workspace/project (per the W2
      hard tenant boundary — `nil` workspace fails CLOSED via
      `Scope.scope_to_workspace_or_global/3`).

  The query is ordered by `content.priority` ASC (NULLS LAST) then
  `inserted_at` ASC — deterministic, lowest priority number first
  (mirroring `bd ready`'s priority semantics where 0 is highest).

  ## Options
    * `:workspace_id` — binary uuid. Required for tenant-scoped reads.
      A nil/missing value fails CLOSED (returns `[]`) per the W2 contract.
    * `:project_id`   — binary uuid. Narrows further within the workspace.
    * `:dataset`      — string dataset name. When omitted, no dataset
      filter is applied (matches `Content.list_documents/3`'s default).
    * `:phase_id`     — string doc_id of the parent phase document. When
      omitted, returns ready tasks across all phases in scope.
    * `:limit`        — integer max rows. Default
      #{@ready_default_limit}.

  Returns a list of `%Document{}` structs.

  ## Why string `phase_id` and not the uuid

  The W7-01 contract pins `content.parent_id` as the parent's `doc_id`
  string (e.g. `"phase-build-a1b2"`), mirroring `bd`'s `--parent <slug>`
  shape. The orchestrator surfaces the active phase as a slug;
  reading the row's `documents.id` uuid every time the statusline
  composes would be wasted DB chatter.
  """
  @spec ready(keyword()) :: [Document.t()]
  defdelegate ready(opts \\ []), to: Queue

  @doc """
  Claim ONE ready task atomically — W7-04 full primitives.

  Four guarantees, all tested in `tasks_claim_test.exs`:

    1. **Expected-version CAS** via `documents.rev`. The UPDATE WHERE clause
       carries `rev = <observed_rev>`; if Postgres reports 0 rows affected,
       another caller won and we return `{:error, :stale_claim}`. `rev` is
       the existing opaque-string mutation-spine identifier; every write in
       this module bumps it via `generate_rev/0`, matching the rest of the
       `Content` module's CAS surface (`ensure_rev/2`). A separate integer
       version column would mean a schema migration and a second source of
       truth — the existing `rev` already increments on every upsert per the
       W2 work and is the contract `Tasks.close/3` enforces.

    2. **Fencing epoch** bumped on EVERY claim and stored at
       `content.claim.epoch` (per the W7-01 field contract). The previous
       claim's epoch (if any) +1 becomes the new epoch; a brand-new claim
       starts at 1. Returned in `content.claim.epoch` so callers can pass it
       back to `close/3` / mutation paths; mismatch → `{:error, :fenced_off}`.
       This is the only protection against a stale-but-not-crashed worker
       writing after the TTL sweep (W7-05) takes its claim away.

    3. **Durable-then-ack** — a `mutation_events` row of kind `"task.claimed"`
       is INSERTED in the SAME transaction as the claim UPDATE, BEFORE the
       function returns. If the caller crashes between getting the doc and
       starting work, the claim is still durable + observable in the
       `mutation_events` log + sweepable by TTL (W7-05).

    4. **Concurrency** — `SELECT … FOR UPDATE SKIP LOCKED LIMIT 1` (the W7-03
       skeleton) still drives row selection; the new CAS guards against the
       reread-after-row-unlock race that SKIP LOCKED alone cannot prevent
       (a caller that picked a row before another caller's commit landed).

  ## Returns
    * `{:ok, %Document{}}` — claimed; `content.claim` carries `worker`,
      `ts_iso`, `epoch` (and the row's new `rev`).
    * `{:ok, nil}` — the ready queue was empty.
    * `{:error, :stale_claim}` — the row we picked was updated by another
      caller between our SELECT and our UPDATE (CAS failed).

  ## Arguments
    * `worker_id` — string identifier for the claimer (agent / worker
      label). Stamped into `content.claim.worker` and `content.assignee`.
    * `opts` — same as `ready/1`. `:phase_id` is recommended.
  """
  @spec claim(String.t(), keyword()) ::
          {:ok, Document.t() | nil} | {:error, :stale_claim}
  defdelegate claim(worker_id, opts \\ []), to: Claim

  @doc """
  Claim a SPECIFIC task by `doc_id` — targeted claim, the W7b counterpart to
  the queue-based `claim/2`.

  Why a separate primitive: `claim/2` picks the next ready row (queue semantics
  — caller doesn't name a row). `bd`'s `bd update <id> --claim` is targeted —
  caller DOES name a row. The bd-shim cannot translate one to the other
  without a wasted listAll() roundtrip plus losing semantics (the row the
  shim picks might not be the row the bd caller named). w7-08 wires this
  primitive so the shim's `bd update <id> --claim` semantics are preserved.

  Same advisory-lock + CAS-on-rev + epoch bump + durable mutation_event
  pattern as `claim/2`'s `do_claim`, but for ONE specific doc — and with
  explicit pre-flight checks for the four error modes:

    * `:not_found` — no doc with this `doc_id` under the caller's tenancy
    * `:not_ready` — lifecycle_status not in [`open`, `blocked`]
    * `:blocked_by_unsatisfied_deps` — has outbound `blocks` edges whose
      target's lifecycle_status is not `done`
    * `:stale_claim` — CAS lost (extremely rare under the advisory lock)

  ## Arguments
    * `doc_id`     — string doc_id of the target (e.g. `"paper-5wk"`).
    * `worker_id`  — string identifier for the claimer.
    * `opts`
      * `:workspace_id` (required for tenant scoping)
      * `:project_id`   (optional further narrowing)

  Returns `{:ok, %Document{}}` on success or `{:error, atom}`.
  """
  @spec claim_by_id(String.t(), String.t(), keyword()) ::
          {:ok, Document.t()}
          | {:error, :not_found | :not_ready | :blocked_by_unsatisfied_deps | :stale_claim}
  defdelegate claim_by_id(doc_id, worker_id, opts \\ []), to: Claim

  # claim/2, claim_by_id/3 + their helpers (fetch/check/resource-overlap/do_claim)
  # → Tasks.Claim (defdelegated). ready/1 + ready_query/1 → Tasks.Queue.


  # ─── Post-commit PubSub (barkpark realtime parity for task ops) ────────────
  #
  # Every CAS write path in this module bypasses Content's canonical write
  # path (`tap_broadcast/5`), so without these the SSE listen endpoint and
  # StudioLive never see a claim/close/relabel live — only doc CRUD
  # broadcast. The fix: build a broadcast bundle INSIDE the transaction
  # (where the freshly-inserted `mutation_events` row id is known — the
  # listen controller drops messages without an `event_id`), and fire it via
  # `Content.broadcast_document_mutation/3` AFTER the transaction commits
  # (broadcasting inside the txn would let subscribers read uncommitted
  # state). Content stays the single owner of the topic shapes.

  # task_broadcast/4 + emit_broadcasts/1 → Tasks.Internal (imported above).

  @doc """
  Close (terminate) a claimed task — W7-04 full primitives.

  Five things, in one Postgres transaction:

    1. **Advisory lock** — `pg_advisory_xact_lock(hashtext('task:' || doc_id))`
       serializes ALL concurrent close attempts on the same task; one wins,
       the rest queue inside the lock and then fail CAS (because the winner
       already bumped `rev`). Per-task scope — closes on DIFFERENT tasks do
       NOT block each other.

    2. **Fencing check** — the caller must pass its observed epoch; mismatch
       (or no claim record) → `{:error, :fenced_off}` so the dead worker's
       late writes are rejected after a TTL sweep / re-claim.

    3. **Expected-version CAS** — `rev = <observed_rev>` guard, same as
       `claim/2`. 0 rows affected → `{:error, :stale_claim}`.

    4. **Cascading unblock** — every dependent (inbound `blocks` edge) whose
       full blocker set is now `done` flips its `lifecycle_status` from
       `"blocked"` to `"open"` in the same transaction. The advisory lock
       guarantees we are the only writer flipping the parent on this txn, so
       the recomputation we do for each dependent is consistent.

    5. **Durable-then-ack** — one `mutation_events` row of kind `"task.closed"`
       for the task itself, plus one `"task.mutated"` row per dependent
       whose `lifecycle_status` changed. All committed before the function
       returns.

  ## Arguments
    * `task_id` — `documents.id` (uuid) of the task being closed.
    * `worker_id` — string. Stamped on the event row.
    * `opts`
      * `:observed_epoch` (required integer) — the epoch the worker saw on
        claim. Must match the row's current `content.claim.epoch`.
      * `:observed_rev` (optional string) — when given, also CAS-guards on
        `documents.rev`. Defaults to the row's rev as read inside the txn
        AFTER the advisory lock (which is the natural CAS point under the
        per-task serialization).
      * `:lifecycle_status` (default `"done"`) — one of `done`/`cancelled`/
        `blocked`.
      * `:reason` (optional string) — persisted as `content.close_reason`,
        the dossier's one-line close rationale (`bd close --reason`'s
        landing slot, tsk-dossier-cli). Ignored when blank.

  ## Returns
    * `{:ok, %Document{}}` — closed successfully; the returned doc carries
      the new `content.lifecycle_status` and bumped `rev`.
    * `{:error, :not_found}` — no such task.
    * `{:error, :fenced_off}` — observed epoch ≠ row epoch.
    * `{:error, :stale_claim}` — CAS failed (extremely rare under the
      advisory lock, but covered for defense in depth).
    * `{:error, {:invalid_lifecycle, status}}` — disallowed terminal status.
  """
  @spec close(binary(), String.t(), keyword()) ::
          {:ok, Document.t()}
          | {:error, :not_found | :fenced_off | :stale_claim | {:invalid_lifecycle, term()}}
  defdelegate close(task_id, worker_id, opts \\ []), to: Close

  @doc """
  tt5: add/remove `content.labels` entries on a single task, advisory-lock +
  CAS-on-rev guarded, emitting a `task.relabeled` mutation_event. Powers the
  bd-shim's `bd update <id> --add-label/--remove-label` translation (which in
  turn backs paper-claim-files' `file-claim:<path>` ownership labels).

  `add` and `remove` are lists of exact label strings. The result is a union
  add (dedup-preserving) minus the remove set. Idempotent: re-adding an
  existing label or removing an absent one is a no-op on that label.

  Returns `{:ok, doc}` (always re-reads + persists, even on a no-op set —
  the rev bump + event keep the relabel observable), or `{:error, :not_found}`
  / `{:error, :stale_claim}`.
  """
  @spec relabel_by_id(binary(), [binary()], [binary()]) ::
          {:ok, Document.t()} | {:error, term()}
  defdelegate relabel_by_id(task_id, add, remove), to: Mutations

  @doc """
  Phase A: add/remove `content.papers` entries (paper slugs) on a single task,
  advisory-lock + CAS-on-rev guarded, emitting a `task.referenced`
  mutation_event. Mirrors `relabel_by_id/3` byte-for-byte — the only difference
  is the content key (`"papers"`) and the event kind.

  `add_slugs` and `remove_slugs` are lists of exact paper-slug strings. The
  result is a union add (dedup-preserving) minus the remove set. Idempotent:
  re-adding an existing paper ref or removing an absent one is a no-op on that
  ref.

  Returns `{:ok, doc}` (always re-reads + persists, even on a no-op set —
  the rev bump + event keep the change observable), or `{:error, :not_found}`
  / `{:error, :stale_claim}`.
  """
  @spec update_paper_refs_by_id(binary(), [binary()], [binary()]) ::
          {:ok, Document.t()} | {:error, term()}
  defdelegate update_paper_refs_by_id(task_id, add_slugs, remove_slugs), to: Mutations

  # Fencing applies only to tasks that carry a claim lease. Work-tasks are
  # claimed before close, so they have `content.claim.epoch` and the observed
  # epoch must match (the dead-worker guard).
  #
  # Generalized (everything-is-a-task): a task with NO claim record has no
  # lease to fence against, so it closes gracefully (return `:ok`). This is
  # what lets a never-claimed root/container task (a former "goal"/"phase")
  # close via this same path — the close is keyed on the absence of a lease,
  # not on the doc type. A task WITH a claim ALWAYS requires the epoch to
  # match — the fencing guarantee for real claimed work is unchanged.
  # close/3 + its internals (do_close_txn, check_fencing, apply_close_update,
  # cascade_unblock_dependents!, all_blockers_done?) → Tasks.Close (defdelegated).
  # CAS primitives (current_epoch/insert_mutation_event!/generate_rev) → Tasks.Internal.

  @doc "The mutation_events kinds emitted by this module."
  @spec event_kinds() :: %{
          claimed: String.t(),
          closed: String.t(),
          mutated: String.t(),
          relabeled: String.t(),
          referenced: String.t()
        }
  def event_kinds do
    %{
      claimed: @event_task_claimed,
      closed: @event_task_closed,
      mutated: @event_task_mutated,
      relabeled: @event_task_relabeled,
      referenced: @event_task_referenced
    }
  end

end
