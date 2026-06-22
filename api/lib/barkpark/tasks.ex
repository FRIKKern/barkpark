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

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.{Document, MutationEvent, Scope, SchemaDefinition}
  alias Barkpark.Repo
  alias Barkpark.Tasks.Edge
  alias Barkpark.Tasks.Edges
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

  @closed_lifecycle_statuses ~w(done cancelled blocked)

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

  @ready_default_limit 50
  @ready_lifecycle_statuses ~w(open blocked)

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
  def ready(opts \\ []) do
    opts
    |> ready_query()
    |> Repo.all()
  end

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
  def claim(worker_id, opts \\ []) when is_binary(worker_id) do
    result =
      Repo.transaction(fn ->
        case opts
             |> ready_query()
             |> from(limit: 1, lock: "FOR UPDATE SKIP LOCKED")
             |> Repo.one() do
          nil ->
            {:ok, nil}

          %Document{} = doc ->
            do_claim(doc, worker_id)
        end
      end)

    case result do
      {:ok, {:ok, nil}} ->
        {:ok, nil}

      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
  def claim_by_id(doc_id, worker_id, opts \\ [])
      when is_binary(doc_id) and is_binary(worker_id) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    resources = opts |> Keyword.get(:resources, []) |> normalize_resources()

    result =
      Repo.transaction(fn ->
        # 1. Advisory lock (per-doc_id) — serializes concurrent targeted
        #    claims for the same row. Matches the close-side lock key shape:
        #    `"task:" <> task_id`. We don't yet know the row's uuid so the
        #    key is keyed off doc_id, which is unique within tenancy.
        #    Resource-carrying claims ALSO take a global resources lock so two
        #    concurrent claims of different tasks cannot both pass the overlap
        #    scan and land conflicting resource sets.
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:" <> doc_id])

        if resources != [] do
          _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task-resources"])
        end

        with {:ok, doc} <- fetch_task_by_doc_id(doc_id, workspace_id, project_id),
             :ok <- check_ready_for_targeted_claim(doc),
             :ok <- check_deps_satisfied(doc),
             :ok <- check_resources_free(resources, doc.id, workspace_id, project_id) do
          do_claim(doc, worker_id, resources)
        end
      end)

    case result do
      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Everything is a task: the TARGETED `claim_by_id`/close paths fetch by
  # doc_id on `type == "task"`. Root/container tasks (a former "goal"/"phase")
  # are tasks too, so a single type filter covers them. The READY-QUEUE claim
  # (`claim/2` → `ready_query/1`) shares this `type == "task"` filter.
  #
  # Resolution rule: try the exact `doc_id` first. When no row is found AND
  # the caller did NOT already supply a `drafts.` prefix, retry with
  # `"drafts." <> doc_id`. Tasks created via the mutate endpoint always land
  # as `drafts.<id>`; the fallback lets callers use the bare id without
  # publishing first. An explicit `drafts.` prefix is treated as exact —
  # the fallback is never applied in reverse.
  #
  # Disambiguation: if both `t1` and `drafts.t1` exist (published + live
  # draft), the exact match on `t1` wins — the caller gets the published row.
  defp fetch_task_by_doc_id(doc_id, workspace_id, project_id) do
    case fetch_task_exact_locked(doc_id, workspace_id, project_id) do
      {:ok, _} = hit ->
        hit

      {:error, :not_found} ->
        if String.starts_with?(doc_id, "drafts.") do
          {:error, :not_found}
        else
          fetch_task_exact_locked("drafts." <> doc_id, workspace_id, project_id)
        end
    end
  end

  defp fetch_task_exact_locked(doc_id, workspace_id, project_id) do
    base =
      from(d in Document,
        where: d.doc_id == ^doc_id and d.type == "task",
        lock: "FOR UPDATE"
      )

    query =
      base
      |> then(fn q ->
        if is_nil(workspace_id), do: q, else: from(d in q, where: d.workspace_id == ^workspace_id)
      end)
      |> then(fn q ->
        if is_nil(project_id), do: q, else: from(d in q, where: d.project_id == ^project_id)
      end)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %Document{} = doc -> {:ok, doc}
    end
  end

  defp check_ready_for_targeted_claim(%Document{content: content}) do
    case Map.get(content || %{}, "lifecycle_status") do
      s when s in @ready_lifecycle_statuses -> :ok
      _ -> {:error, :not_ready}
    end
  end

  defp check_deps_satisfied(%Document{} = doc) do
    deps = dependencies(doc.id, kind: :blocks)

    all_done? =
      Enum.all?(deps, fn %Document{content: c} ->
        Map.get(c || %{}, "lifecycle_status") == "done"
      end)

    if all_done?, do: :ok, else: {:error, :blocked_by_unsatisfied_deps}
  end

  # ─── Resource claims (the Beads file-claim successor, 2026-06-11) ─────────
  #
  # The single biggest label family in the frozen Beads corpus was
  # `file-claim:<path>` (275 of 436 issues) — parallel writers fencing off
  # files. The port rides the EXISTING claim object: a targeted claim may
  # carry `resources: ["a.go", …]` (arbitrary opaque strings; exact-match
  # semantics, no globbing in v1). The overlap scan refuses the claim with
  # `resource_conflict` + the holders when any requested string is held by
  # another LIVE (in_progress) claim in the same tenancy. Because resources
  # live INSIDE content.claim, every existing release path frees them for
  # free: close clears the claim, the 300s lease sweep clears the claim —
  # no manual label cleanup, which was Beads' file-claim weak spot.

  # Accepts a list, or a single comma-separated string — the latter is what
  # `bp task claim <id> <w> --set resources=a.go,b.go` delivers today via the
  # generic --set body mechanism (string-valued), so resource claims work
  # from every shipped binary with no client change.
  defp normalize_resources(resources) when is_binary(resources),
    do: resources |> String.split(",") |> normalize_resources()

  defp normalize_resources(resources) when is_list(resources) do
    resources
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_resources(_), do: []

  defp check_resources_free([], _doc_uuid, _workspace_id, _project_id), do: :ok

  defp check_resources_free(resources, doc_uuid, workspace_id, project_id) do
    holders =
      from(d in Document,
        where: d.type == "task" and d.id != ^doc_uuid,
        where: fragment("?->>'lifecycle_status'", d.content) == "in_progress",
        where: fragment("jsonb_exists_any(?->'claim'->'resources', ?)", d.content, ^resources),
        select: %{doc_id: d.doc_id, content: d.content}
      )
      |> then(fn q ->
        if is_nil(workspace_id), do: q, else: from(d in q, where: d.workspace_id == ^workspace_id)
      end)
      |> then(fn q ->
        if is_nil(project_id), do: q, else: from(d in q, where: d.project_id == ^project_id)
      end)
      |> Repo.all()

    case holders do
      [] ->
        :ok

      holders ->
        conflicts =
          Enum.map(holders, fn %{doc_id: did, content: c} ->
            claim = Map.get(c || %{}, "claim") || %{}
            held = Map.get(claim, "resources") || []

            %{
              doc_id: did,
              worker: Map.get(claim, "worker"),
              resources: Enum.filter(resources, &(&1 in held))
            }
          end)

        {:error, {:resource_conflict, conflicts}}
    end
  end

  defp do_claim(%Document{} = doc, worker_id, resources \\ []) do
    observed_rev = doc.rev
    new_rev = generate_rev()
    next_epoch = current_epoch(doc) + 1
    ts_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    new_claim =
      %{
        "worker" => worker_id,
        "ts_iso" => ts_iso,
        "epoch" => next_epoch
      }
      |> then(fn claim ->
        if resources == [], do: claim, else: Map.put(claim, "resources", resources)
      end)

    new_content =
      doc.content
      |> Map.put("lifecycle_status", "in_progress")
      |> Map.put("assignee", worker_id)
      |> Map.put("claim", new_claim)

    # Expected-version CAS: WHERE id = ? AND rev = <observed_rev>.
    # update_all returns {rows_affected, _}. 0 → another caller won.
    {rows, _} =
      from(d in Document, where: d.id == ^doc.id and d.rev == ^observed_rev)
      |> Repo.update_all(
        set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
      )

    case rows do
      1 ->
        updated = %{doc | content: new_content, rev: new_rev}
        ev = insert_mutation_event!(updated, @event_task_claimed, observed_rev)
        {:ok, updated, [task_broadcast(updated, @event_task_claimed, ev, observed_rev)]}

      0 ->
        {:error, :stale_claim}
    end
  end

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

  defp task_broadcast(%Document{} = doc, kind, %MutationEvent{} = ev, previous_rev) do
    %{doc: doc, kind: kind, event_id: ev.id, previous_rev: previous_rev}
  end

  defp emit_broadcasts(broadcasts) when is_list(broadcasts) do
    Enum.each(broadcasts, fn %{doc: doc, kind: kind, event_id: eid, previous_rev: prev} ->
      Content.broadcast_document_mutation(doc, kind, event_id: eid, previous_rev: prev)
    end)

    :ok
  end

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
  def close(task_id, worker_id, opts \\ []) when is_binary(worker_id) do
    observed_epoch = Keyword.fetch!(opts, :observed_epoch)
    new_status = Keyword.get(opts, :lifecycle_status, "done")
    observed_rev_opt = Keyword.get(opts, :observed_rev)
    reason = Keyword.get(opts, :reason)

    cond do
      new_status not in @closed_lifecycle_statuses ->
        {:error, {:invalid_lifecycle, new_status}}

      true ->
        do_close_txn(task_id, worker_id, observed_epoch, observed_rev_opt, new_status, reason)
    end
  end

  defp do_close_txn(task_id, worker_id, observed_epoch, observed_rev_opt, new_status, reason) do
    result =
      Repo.transaction(fn ->
        # 1. Advisory lock — per-task. hashtext('task:' || doc_id) gives a
        #    deterministic int4 key; pg_advisory_xact_lock takes an int4 or
        #    bigint and auto-releases at COMMIT/ROLLBACK.
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{task_id}"])

        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            observed_rev = observed_rev_opt || doc.rev

            # Already-terminal guard. Under the advisory lock, a serialized
            # 2nd+ caller reads the row AFTER the winner committed → sees
            # `lifecycle_status` already in a terminal state. Without this
            # the default-observed-rev path would let every caller "succeed"
            # in turn (CAS passes against the just-read rev). Treat the
            # already-terminal row as a lost race; the explicit-rev CAS
            # path below still wins/loses on rev when callers pass their
            # own observation.
            cond do
              observed_rev_opt == nil and
                  Map.get(doc.content, "lifecycle_status") in @closed_lifecycle_statuses ->
                {:error, :stale_claim}

              true ->
                with :ok <- check_fencing(doc, observed_epoch),
                     {:ok, updated} <-
                       apply_close_update(doc, worker_id, observed_rev, new_status, reason) do
                  ev = insert_mutation_event!(updated, @event_task_closed, observed_rev)
                  unblocked = cascade_unblock_dependents!(updated)

                  {:ok, updated,
                   [task_broadcast(updated, @event_task_closed, ev, observed_rev) | unblocked]}
                end
            end
        end
      end)

    case result do
      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
  def relabel_by_id(task_id, add, remove)
      when is_binary(task_id) and is_list(add) and is_list(remove) do
    result =
      Repo.transaction(fn ->
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{task_id}"])

        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            observed_rev = doc.rev
            current = labels_of(doc.content)
            add = Enum.filter(add, &is_binary/1)
            remove = MapSet.new(Enum.filter(remove, &is_binary/1))

            # Union add (append new, preserve order), then drop the remove set.
            next =
              (current ++ add)
              |> Enum.uniq()
              |> Enum.reject(&MapSet.member?(remove, &1))

            new_content = Map.put(doc.content, "labels", next)
            new_rev = generate_rev()

            {rows, _} =
              from(d in Document, where: d.id == ^doc.id and d.rev == ^observed_rev)
              |> Repo.update_all(
                set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
              )

            case rows do
              1 ->
                updated = %{doc | content: new_content, rev: new_rev}
                ev = insert_mutation_event!(updated, @event_task_relabeled, observed_rev)

                {:ok, updated, [task_broadcast(updated, @event_task_relabeled, ev, observed_rev)]}

              0 ->
                {:error, :stale_claim}
            end
        end
      end)

    case result do
      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # content.labels is a free-form JSON array (the W7 mirror writes goals/phases
  # with [kind, goal] etc.; tasks may have none). Defensive: coerce non-list /
  # missing to [].
  defp labels_of(%{"labels" => labels}) when is_list(labels), do: labels
  defp labels_of(_), do: []

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
  def update_paper_refs_by_id(task_id, add_slugs, remove_slugs)
      when is_binary(task_id) and is_list(add_slugs) and is_list(remove_slugs) do
    result =
      Repo.transaction(fn ->
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{task_id}"])

        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            observed_rev = doc.rev
            current = papers_of(doc.content)
            add = Enum.filter(add_slugs, &is_binary/1)
            remove = MapSet.new(Enum.filter(remove_slugs, &is_binary/1))

            # Union add (append new, preserve order), then drop the remove set.
            next =
              (current ++ add)
              |> Enum.uniq()
              |> Enum.reject(&MapSet.member?(remove, &1))

            new_content = Map.put(doc.content, "papers", next)
            new_rev = generate_rev()

            {rows, _} =
              from(d in Document, where: d.id == ^doc.id and d.rev == ^observed_rev)
              |> Repo.update_all(
                set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
              )

            case rows do
              1 ->
                updated = %{doc | content: new_content, rev: new_rev}
                ev = insert_mutation_event!(updated, @event_task_referenced, observed_rev)

                {:ok, updated,
                 [task_broadcast(updated, @event_task_referenced, ev, observed_rev)]}

              0 ->
                {:error, :stale_claim}
            end
        end
      end)

    case result do
      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # content.papers is a JSON array of paper slugs. Defensive: coerce non-list /
  # missing to [].
  defp papers_of(%{"papers" => papers}) when is_list(papers), do: papers
  defp papers_of(_), do: []

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
  defp check_fencing(%Document{content: content}, observed_epoch) do
    case content do
      %{"claim" => %{"epoch" => row_epoch}} when row_epoch == observed_epoch -> :ok
      %{"claim" => %{"epoch" => _}} -> {:error, :fenced_off}
      # No claim lease — nothing to fence against, close cleanly.
      _ -> :ok
    end
  end

  defp apply_close_update(%Document{} = doc, worker_id, observed_rev, new_status, reason) do
    new_rev = generate_rev()
    ts_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    # Stamp close metadata into the claim lease when one exists (work-tasks).
    # A never-claimed root/container task has no claim — close it without
    # inventing one; we only flip lifecycle_status. `Map.update/4`'s default
    # is used verbatim (NOT run through the fun), so a no-claim doc would
    # otherwise get a bare `claim => %{}`; the explicit branch keeps the doc
    # shape honest.
    new_content =
      case doc.content do
        %{"claim" => claim} when is_map(claim) ->
          updated_claim =
            claim
            |> Map.put("closed_by", worker_id)
            |> Map.put("closed_at", ts_iso)

          doc.content
          |> Map.put("lifecycle_status", new_status)
          |> Map.put("claim", updated_claim)

        _ ->
          Map.put(doc.content, "lifecycle_status", new_status)
      end

    # Dossier close rationale (tsk-dossier-cli): one scalar write riding the
    # close call — far cheaper for an agent than a separate mutate round-trip
    # to fill outcome. Blank reasons never overwrite an existing value.
    new_content =
      case reason do
        r when is_binary(r) and r != "" -> Map.put(new_content, "close_reason", r)
        _ -> new_content
      end

    {rows, _} =
      from(d in Document, where: d.id == ^doc.id and d.rev == ^observed_rev)
      |> Repo.update_all(
        set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
      )

    case rows do
      1 -> {:ok, %{doc | content: new_content, rev: new_rev}}
      0 -> {:error, :stale_claim}
    end
  end

  # After a task flips to `done`, walk every inbound `blocks` edge and flip
  # the dependent's `lifecycle_status` from "blocked"→"open" IFF every one of
  # ITS blockers is now `done`. We do this in the same advisory-lock-guarded
  # transaction so two concurrent closes that both unblock the same
  # dependent can't double-flip it.
  #
  # Returns one broadcast bundle per flipped dependent (possibly []) so the
  # caller can announce the unblocks on PubSub after its transaction commits.
  defp cascade_unblock_dependents!(%Document{content: %{"lifecycle_status" => "done"}} = parent) do
    parent
    |> Map.fetch!(:id)
    |> dependents(kind: :blocks)
    |> Enum.flat_map(fn %Document{} = dep ->
      if all_blockers_done?(dep) and Map.get(dep.content, "lifecycle_status") == "blocked" do
        new_rev = generate_rev()
        new_content = Map.put(dep.content, "lifecycle_status", "open")

        {1, _} =
          from(d in Document, where: d.id == ^dep.id and d.rev == ^dep.rev)
          |> Repo.update_all(
            set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
          )

        unblocked = %{dep | content: new_content, rev: new_rev}
        ev = insert_mutation_event!(unblocked, @event_task_mutated, dep.rev)
        [task_broadcast(unblocked, @event_task_mutated, ev, dep.rev)]
      else
        []
      end
    end)
  end

  defp cascade_unblock_dependents!(_non_done_parent), do: []

  defp all_blockers_done?(%Document{} = dep) do
    dep.id
    |> dependencies(kind: :blocks)
    |> Enum.all?(fn %Document{content: c} ->
      Map.get(c, "lifecycle_status") == "done"
    end)
  end

  defp current_epoch(%Document{content: %{"claim" => %{"epoch" => e}}}) when is_integer(e), do: e
  defp current_epoch(_), do: 0

  # Mutation-events insert. The existing `mutation_events` schema (used by
  # the document spine) is reused verbatim — the `mutation` text column
  # carries our `task.claimed` / `task.closed` / `task.mutated` kinds, the
  # `document` map carries an Envelope-shaped view of the post-update row.
  # Tenancy stamps mirror `Content.save_event/5` so workspace-scoped
  # `recent_activity` reads surface task ops.
  defp insert_mutation_event!(%Document{} = doc, kind, previous_rev) do
    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: doc.dataset,
      type: doc.type,
      doc_id: doc.doc_id,
      mutation: kind,
      rev: doc.rev,
      previous_rev: previous_rev,
      document: %{
        "doc_id" => doc.doc_id,
        "type" => doc.type,
        "title" => doc.title,
        "status" => doc.status,
        "content" => doc.content,
        "rev" => doc.rev
      },
      workspace_id: doc.workspace_id,
      project_id: doc.project_id,
      dataset_id: doc.dataset_id,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  # New rev token, same shape as `Content.generate_rev/0`. Kept private here
  # so `Tasks` does not depend on a private function in another module.
  defp generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

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

  # The shared query the read-only `ready/1` and the row-locked `claim/2`
  # both ride on. Keeping ONE definition is what makes the
  # "claim returns exactly what ready would have picked" contract a
  # property of the code, not a documentation promise.
  defp ready_query(opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    dataset = Keyword.get(opts, :dataset)
    phase_id = Keyword.get(opts, :phase_id)
    limit = Keyword.get(opts, :limit, @ready_default_limit)

    base =
      from(d in Document,
        as: :doc,
        where: d.type == "task",
        where: fragment("?->>'kind'", d.content) == "task",
        where: fragment("?->>'lifecycle_status'", d.content) in ^@ready_lifecycle_statuses,
        where:
          not exists(
            from(e in Edge,
              join: b in Document,
              on: b.id == e.to_id,
              where:
                e.from_id == parent_as(:doc).id and
                  e.kind == "blocks" and
                  fragment("COALESCE(?->>'lifecycle_status', '')", b.content) != "done",
              select: 1
            )
          ),
        order_by: [
          asc_nulls_last: fragment("(?->>'priority')::int", d.content),
          asc: d.inserted_at
        ],
        limit: ^limit
      )

    base
    |> maybe_filter_dataset(dataset)
    |> maybe_filter_phase(phase_id)
    |> Scope.scope_to_workspace(workspace_id, project_id)
  end

  defp maybe_filter_dataset(query, nil), do: query

  defp maybe_filter_dataset(query, dataset) when is_binary(dataset) do
    from([doc: d] in query, where: d.dataset == ^dataset)
  end

  defp maybe_filter_phase(query, nil), do: query

  defp maybe_filter_phase(query, phase_id) when is_binary(phase_id) do
    from([doc: d] in query,
      where: fragment("?->>'parent_id'", d.content) == ^phase_id
    )
  end
end
