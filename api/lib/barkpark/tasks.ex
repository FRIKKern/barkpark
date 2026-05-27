defmodule Barkpark.Tasks do
  @moduledoc """
  W7a step 1 — Task-document schema on the existing `documents` substrate.

  Tasks, Goals, Phases, and Events live as rows in the `documents` table,
  scoped by the shipped workspace/project/dataset tenancy primitives. This
  module owns:

    * the four schema definitions (`task`, `goal`, `phase`, `event`) the
      seeds.exs and `Plugins.Bootstrap` paths register so they appear in
      the `schema_definitions` table alongside `post`/`page`/`paper`;
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
        "parent_id" => "<phase-or-goal-doc-id>" # optional string (hierarchy)
      }

  For `kind:goal`: `goal_slug` (required string).
  For `kind:phase`: `phase_name` (required string), `parent` (the goal doc_id).
  For `kind:event`: `event_kind` (required string), `payload` (optional map).

  The validator enforces only what is REQUIRED + the enum shape of the five
  string fields; everything else is shape-checked permissively (the
  authoritative `task_edges` table arrives in W7-02). The plan calls this
  "the tightened contract — what the four live readers actually consume."
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.{Document, Scope, SchemaDefinition}
  alias Barkpark.Repo
  alias Barkpark.Tasks.Edge

  @lifecycle_statuses ~w(open in_progress blocked done cancelled)
  @kinds ~w(goal phase task event)

  @doc "The five lifecycle-status string values a task document may carry."
  @spec lifecycle_statuses() :: [String.t()]
  def lifecycle_statuses, do: @lifecycle_statuses

  @doc "The four `content.kind` discriminator values."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  # ─── Schema definitions (registered via seeds.exs + Plugins.Bootstrap) ─────

  @doc """
  Returns the four `%SchemaDefinition{}` structs the W7 substrate needs:
  `task`, `goal`, `phase`, `event`.

  Each struct mirrors the shape the existing `paper` schema uses (a flat
  field list with `name/title/type`), so Studio + the existing schema
  catalogue endpoints render them with zero extra work. The actual
  contract for `content` is enforced by `validate_task_content/1` —
  the schema field list here exists so the four document kinds are
  first-class types in the `schema_definitions` table, queryable like
  `post` / `page` / `paper`.

  `dataset` defaults to `"production"` — matching every other seed schema.
  """
  @spec schema_definitions(String.t()) :: [SchemaDefinition.t()]
  def schema_definitions(dataset \\ "production") do
    [
      task_schema(dataset),
      goal_schema(dataset),
      phase_schema(dataset),
      event_schema(dataset)
    ]
  end

  @doc "Just the `task` schema struct (callers that only need one)."
  @spec task_schema(String.t()) :: SchemaDefinition.t()
  def task_schema(dataset \\ "production") do
    %SchemaDefinition{
      name: "task",
      title: "Task",
      icon: "✅",
      visibility: "public",
      dataset: dataset,
      fields: [
        %{"name" => "title", "title" => "Title", "type" => "string"},
        %{"name" => "kind", "title" => "Kind", "type" => "string"},
        %{"name" => "lifecycle_status", "title" => "Lifecycle", "type" => "string"},
        %{"name" => "priority", "title" => "Priority", "type" => "number"},
        %{"name" => "assignee", "title" => "Assignee", "type" => "string"},
        %{"name" => "dependencies", "title" => "Dependencies", "type" => "array"},
        %{"name" => "claim", "title" => "Claim", "type" => "object"},
        %{"name" => "parent_id", "title" => "Parent", "type" => "string"}
      ]
    }
  end

  @doc "Just the `goal` schema struct."
  @spec goal_schema(String.t()) :: SchemaDefinition.t()
  def goal_schema(dataset \\ "production") do
    %SchemaDefinition{
      name: "goal",
      title: "Goal",
      icon: "🎯",
      visibility: "public",
      dataset: dataset,
      fields: [
        %{"name" => "title", "title" => "Title", "type" => "string"},
        %{"name" => "kind", "title" => "Kind", "type" => "string"},
        %{"name" => "goal_slug", "title" => "Slug", "type" => "string"},
        %{"name" => "papers", "title" => "Papers", "type" => "array"}
      ]
    }
  end

  @doc "Just the `phase` schema struct."
  @spec phase_schema(String.t()) :: SchemaDefinition.t()
  def phase_schema(dataset \\ "production") do
    %SchemaDefinition{
      name: "phase",
      title: "Phase",
      icon: "📋",
      visibility: "public",
      dataset: dataset,
      fields: [
        %{"name" => "title", "title" => "Title", "type" => "string"},
        %{"name" => "kind", "title" => "Kind", "type" => "string"},
        %{"name" => "phase_name", "title" => "Phase", "type" => "string"},
        %{"name" => "parent", "title" => "Parent goal", "type" => "string"}
      ]
    }
  end

  @doc "Just the `event` schema struct."
  @spec event_schema(String.t()) :: SchemaDefinition.t()
  def event_schema(dataset \\ "production") do
    %SchemaDefinition{
      name: "event",
      title: "Event",
      icon: "🟢",
      visibility: "public",
      dataset: dataset,
      fields: [
        %{"name" => "title", "title" => "Title", "type" => "string"},
        %{"name" => "kind", "title" => "Kind", "type" => "string"},
        %{"name" => "event_kind", "title" => "Event kind", "type" => "string"},
        %{"name" => "payload", "title" => "Payload", "type" => "object"},
        %{"name" => "parent", "title" => "Parent", "type" => "string"}
      ]
    }
  end

  # ─── Validation ────────────────────────────────────────────────────────────

  @doc """
  Validates the `content` map of a `type:task` document against the §1
  field contract.

  Returns `:ok` on success or `{:error, errors :: map()}` where the map's
  keys are the field names (`"kind"`, `"lifecycle_status"`, ...) and the
  values are lists of human-readable error messages — mirroring the
  shape `Barkpark.Content.Validation.validate/3` returns.

  Required fields: `kind` (must equal `"task"`), `lifecycle_status` (must
  be one of `lifecycle_statuses/0`).

  Shape-checked when present: `priority` (integer 0..4), `assignee`
  (string), `dependencies` (list of strings), `parent_id` (string),
  `claim` (map).

  This validator is **task-specific**. Goal/phase/event documents have
  their own (lighter) shape, validated by `validate_kind_content/2`.
  """
  @spec validate_task_content(map() | nil) :: :ok | {:error, map()}
  def validate_task_content(content), do: validate_kind_content("task", content)

  @doc """
  Validates `content` against the shape for the given `kind`. Dispatches
  to the per-kind validator; unknown kinds are rejected.

  Used by the document-write paths (`Content.create_document/4`,
  `Content.upsert_document/4`) when the `type` argument equals one of
  `kinds/0`.
  """
  @spec validate_kind_content(String.t(), map() | nil) :: :ok | {:error, map()}
  def validate_kind_content(kind, content) when kind in @kinds do
    content = content || %{}

    errors =
      %{}
      |> validate_kind_field(kind, content)
      |> validate_kind_specific(kind, content)

    if errors == %{}, do: :ok, else: {:error, errors}
  end

  def validate_kind_content(other, _content) do
    {:error, %{"kind" => ["unknown kind #{inspect(other)}; must be one of #{inspect(@kinds)}"]}}
  end

  # The shared "content.kind == <type>" check — every kind must self-identify.
  defp validate_kind_field(errors, expected_kind, content) do
    case Map.get(content, "kind") || Map.get(content, :kind) do
      ^expected_kind ->
        errors

      nil ->
        Map.put(errors, "kind", ["is required"])

      other ->
        Map.put(errors, "kind", [
          "expected #{inspect(expected_kind)}, got #{inspect(other)}"
        ])
    end
  end

  # Per-kind required + shape checks. Kept tight per the plan: only what the
  # four live readers consume.

  defp validate_kind_specific(errors, "task", content) do
    errors
    |> require_string_in(content, "lifecycle_status", @lifecycle_statuses)
    |> check_optional_priority(content)
    |> check_optional_string(content, "assignee")
    |> check_optional_string(content, "parent_id")
    |> check_optional_string_list(content, "dependencies")
    |> check_optional_map(content, "claim")
  end

  defp validate_kind_specific(errors, "goal", content) do
    errors
    |> require_string(content, "goal_slug")
    |> check_optional_string_list(content, "papers")
  end

  defp validate_kind_specific(errors, "phase", content) do
    errors
    |> require_string(content, "phase_name")
    |> check_optional_string(content, "parent")
  end

  defp validate_kind_specific(errors, "event", content) do
    errors
    |> require_string(content, "event_kind")
    |> check_optional_map(content, "payload")
    |> check_optional_string(content, "parent")
  end

  # ─── Per-field micro-validators ────────────────────────────────────────────

  defp require_string(errors, content, key) do
    case Map.get(content, key) || Map.get(content, String.to_atom(key)) do
      v when is_binary(v) and byte_size(v) > 0 -> errors
      nil -> Map.put(errors, key, ["is required"])
      other -> Map.put(errors, key, ["must be a non-empty string, got #{inspect(other)}"])
    end
  end

  defp require_string_in(errors, content, key, allowed) do
    case Map.get(content, key) || Map.get(content, String.to_atom(key)) do
      v when is_binary(v) ->
        if v in allowed do
          errors
        else
          Map.put(errors, key, [
            "must be one of #{inspect(allowed)}, got #{inspect(v)}"
          ])
        end

      nil ->
        Map.put(errors, key, ["is required (one of #{inspect(allowed)})"])

      other ->
        Map.put(errors, key, ["must be a string, got #{inspect(other)}"])
    end
  end

  defp check_optional_string(errors, content, key) do
    case Map.get(content, key) || Map.get(content, String.to_atom(key)) do
      nil -> errors
      v when is_binary(v) -> errors
      other -> Map.put(errors, key, ["must be a string when set, got #{inspect(other)}"])
    end
  end

  defp check_optional_string_list(errors, content, key) do
    case Map.get(content, key) || Map.get(content, String.to_atom(key)) do
      nil ->
        errors

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          errors
        else
          Map.put(errors, key, ["must be a list of strings, got #{inspect(list)}"])
        end

      other ->
        Map.put(errors, key, ["must be a list when set, got #{inspect(other)}"])
    end
  end

  defp check_optional_priority(errors, content) do
    case Map.get(content, "priority") || Map.get(content, :priority) do
      nil -> errors
      v when is_integer(v) and v >= 0 and v <= 4 -> errors
      other -> Map.put(errors, "priority", ["must be an integer 0..4 when set, got #{inspect(other)}"])
    end
  end

  defp check_optional_map(errors, content, key) do
    case Map.get(content, key) || Map.get(content, String.to_atom(key)) do
      nil -> errors
      v when is_map(v) -> errors
      other -> Map.put(errors, key, ["must be a map when set, got #{inspect(other)}"])
    end
  end

  # ─── W7a step 2: typed dep graph (CRUD over `task_edges`) ─────────────────

  @doc """
  Edge kinds in this codebase today. `blocks` is the ready-query primitive;
  `discovered-from` carries the goal-path rail's walk-back lineage.
  """
  @spec edge_kinds() :: [String.t()]
  def edge_kinds, do: Edge.kinds()

  @doc """
  Add a dependency edge: `child` blocks on `parent`.

  Mirrors `bd dep add <child> <parent>` — the FIRST argument depends on the
  SECOND. The edge is stored as `from_id = child_id, to_id = parent_id`
  so the W7-03 ready query can scan a candidate's outbound `blocks` edges
  to find its blockers.

  ## Arguments
    * `child_id`  — binary_id of the dependent document (the task that's
      blocked on something).
    * `parent_id` — binary_id of the blocker document.
    * `kind`      — `:blocks` (default), `:"discovered-from"`, or the
      string form `"blocks"` / `"discovered-from"`. Other strings are
      rejected by the changeset.

  ## Idempotency

  Re-adding the same `(from, to, kind)` triple is a no-op — the migration's
  unique index plus `on_conflict: :nothing` swallows the duplicate without
  raising. The returned `{:ok, edge}` carries the EXISTING edge when the
  insert was a no-op (fetched in a second query so callers always get a
  populated struct).

  Returns `{:ok, %Edge{}}` on success, `{:error, %Ecto.Changeset{}}` on
  validation failure (missing FK target, self-edge, unknown kind).
  """
  @spec add_dep(binary(), binary(), atom() | String.t()) ::
          {:ok, Edge.t()} | {:error, Ecto.Changeset.t()}
  def add_dep(child_id, parent_id, kind \\ :blocks) do
    kind_str = normalize_kind(kind)

    attrs = %{from_id: child_id, to_id: parent_id, kind: kind_str}
    changeset = Edge.changeset(%Edge{}, attrs)

    if changeset.valid? do
      # `on_conflict: :nothing` + the unique index = idempotent insert.
      # When the row already exists Postgres skips the INSERT but Ecto still
      # returns `{:ok, %Edge{}}` with the changeset's would-be values (the
      # `id` is the autogenerated one Ecto stamped on the cast struct, NOT
      # the existing row's id). To return the canonical edge — same id on
      # repeat calls — we always read the row back by its unique tuple.
      case Repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: [:from_id, :to_id, :kind]
           ) do
        {:ok, %Edge{}} ->
          {:ok, fetch_edge!(child_id, parent_id, kind_str)}

        {:error, %Ecto.Changeset{} = cs} ->
          {:error, cs}
      end
    else
      {:error, changeset}
    end
  end

  @doc """
  Remove the `(child_id, parent_id, kind)` edge. Always returns `:ok` —
  removing an absent edge is a no-op (matches `bd dep rm`'s tolerance,
  and keeps the close-time `unblock_dependents` flow simple in W7-04).
  """
  @spec remove_dep(binary(), binary(), atom() | String.t()) :: :ok
  def remove_dep(child_id, parent_id, kind) do
    kind_str = normalize_kind(kind)

    from(e in Edge,
      where: e.from_id == ^child_id and e.to_id == ^parent_id and e.kind == ^kind_str
    )
    |> Repo.delete_all()

    :ok
  end

  @doc """
  The documents `task_id` depends on — the blockers, the `to_id` side of
  every outbound edge. The W7-03 ready query is a `NOT EXISTS` over this
  set; this function is the higher-level read for orchestrator surfaces
  (Goal-path rail, build pre-flight, debug `bd dep ls`).

  ## Options
    * `:kind` — filter to one kind (atom or string). Default: `:blocks`.
      Pass `:all` to return edges of every kind.

  Returns a list of `%Document{}` in insertion order of the edge.
  """
  @spec dependencies(binary(), keyword()) :: [Document.t()]
  def dependencies(task_id, opts \\ []) do
    kind_opt = Keyword.get(opts, :kind, :blocks)

    from(d in Document,
      join: e in Edge,
      as: :edge,
      on: e.to_id == d.id,
      where: e.from_id == ^task_id,
      order_by: e.inserted_at,
      select: d
    )
    |> maybe_filter_edge_kind(kind_opt)
    |> Repo.all()
  end

  @doc """
  The documents that depend on `task_id` — the dependents, the `from_id`
  side of every inbound edge. Called when `task_id` closes, to find which
  rows might be newly ready (the W7-04 close→unblock sweep).

  ## Options
    * `:kind` — filter to one kind (atom or string). Default: `:blocks`.
      Pass `:all` to return edges of every kind.
  """
  @spec dependents(binary(), keyword()) :: [Document.t()]
  def dependents(task_id, opts \\ []) do
    kind_opt = Keyword.get(opts, :kind, :blocks)

    from(d in Document,
      join: e in Edge,
      as: :edge,
      on: e.from_id == d.id,
      where: e.to_id == ^task_id,
      order_by: e.inserted_at,
      select: d
    )
    |> maybe_filter_edge_kind(kind_opt)
    |> Repo.all()
  end

  @doc """
  Low-level query: every edge touching `task_id` on either side.

  ## Options
    * `:direction` — `:outbound` (default — `from_id == task_id`),
      `:inbound` (`to_id == task_id`), or `:both`.
    * `:kind` — filter to one kind (atom or string), or `:all` (default).
  """
  @spec edges(binary(), keyword()) :: [Edge.t()]
  def edges(task_id, opts \\ []) do
    direction = Keyword.get(opts, :direction, :outbound)
    kind_opt = Keyword.get(opts, :kind, :all)

    base =
      case direction do
        :outbound ->
          from(e in Edge, as: :edge, where: e.from_id == ^task_id)

        :inbound ->
          from(e in Edge, as: :edge, where: e.to_id == ^task_id)

        :both ->
          from(e in Edge,
            as: :edge,
            where: e.from_id == ^task_id or e.to_id == ^task_id
          )
      end

    base
    |> maybe_filter_edge_kind(kind_opt)
    |> Repo.all()
  end

  defp maybe_filter_edge_kind(query, :all), do: query

  defp maybe_filter_edge_kind(query, kind) do
    kind_str = normalize_kind(kind)
    from [edge: e] in query, where: e.kind == ^kind_str
  end

  # The caller may pass `:blocks` / `:"discovered-from"` / `"blocks"` /
  # `"discovered-from"` — internally we always use the string column value.
  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_kind(kind) when is_binary(kind), do: kind

  defp fetch_edge!(from_id, to_id, kind) do
    Repo.one!(
      from e in Edge,
        where: e.from_id == ^from_id and e.to_id == ^to_id and e.kind == ^kind
    )
  end

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
  shape. The orchestrator surfaces the active phase as a slug from
  `<repo>/.paperflow/active-phase`; reading the row's `documents.id`
  uuid every time the statusline composes would be wasted DB chatter.
  """
  @spec ready(keyword()) :: [Document.t()]
  def ready(opts \\ []) do
    opts
    |> ready_query()
    |> Repo.all()
  end

  @doc """
  Claim ONE ready task atomically.

  This is the **skeleton** that proves `FOR UPDATE SKIP LOCKED` works on
  the document substrate (Gate-A foundation). It is NOT the full claim
  semantics — expected-`rev` CAS, lease tokens, epoch bumps, fencing
  metadata, advisory locks, and the `mutation_events` op-log entry are
  all deferred to W7-04. What this function DOES guarantee today:

    * runs inside a `Repo.transaction/1`;
    * `SELECT … FOR UPDATE SKIP LOCKED LIMIT 1` over the ready query
      (the row is locked for the duration of the transaction; concurrent
      callers skip it and pick the next one);
    * flips `content.lifecycle_status` from `"open"` (or `"blocked"`) to
      `"in_progress"` and stamps `content.assignee = worker_id`;
    * returns `{:ok, %Document{}}` on success or `{:ok, nil}` when
      nothing is ready (NOT `{:error, ...}` — `nil` is the documented
      "the queue was empty" return so the build skill can loop without
      a try/catch).

  ## Why this proves the concurrency primitive

  Two concurrent BEGIN/SELECT FOR UPDATE SKIP LOCKED/UPDATE/COMMIT
  blocks against the same ready-queue cannot grab the same row —
  Postgres' SKIP LOCKED guarantees A's row is invisible to B until A
  commits. After A commits, A's row's `lifecycle_status` is
  `"in_progress"`, so the ready query no longer matches it. The
  concurrency test in `tasks_ready_test.exs` runs this 20× with
  `Task.async_stream` to pin the behaviour.

  ## Arguments
    * `worker_id` — string identifier for the claimer (agent / worker
      label). Stamped into `content.assignee`.
    * `opts` — same as `ready/1`. `:phase_id` is recommended (a phase-
      agnostic claim works but is rarely what an orchestrator wants).
  """
  @spec claim(String.t(), keyword()) :: {:ok, Document.t() | nil} | {:error, term()}
  def claim(worker_id, opts \\ []) when is_binary(worker_id) do
    # ONE transaction: row-lock pick + status flip + return.
    Repo.transaction(fn ->
      case opts
           |> ready_query()
           |> from(limit: 1, lock: "FOR UPDATE SKIP LOCKED")
           |> Repo.one() do
        nil ->
          nil

        %Document{} = doc ->
          new_content =
            doc.content
            |> Map.put("lifecycle_status", "in_progress")
            |> Map.put("assignee", worker_id)

          doc
          |> Ecto.Changeset.change(content: new_content)
          |> Repo.update!()
      end
    end)
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
        where:
          fragment("?->>'lifecycle_status'", d.content) in ^@ready_lifecycle_statuses,
        where:
          not exists(
            from e in Edge,
              join: b in Document,
              on: b.id == e.to_id,
              where:
                e.from_id == parent_as(:doc).id and
                  e.kind == "blocks" and
                  fragment("COALESCE(?->>'lifecycle_status', '')", b.content) != "done",
              select: 1
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
    |> Scope.scope_to_workspace_or_global(workspace_id, project_id)
  end

  defp maybe_filter_dataset(query, nil), do: query

  defp maybe_filter_dataset(query, dataset) when is_binary(dataset) do
    from [doc: d] in query, where: d.dataset == ^dataset
  end

  defp maybe_filter_phase(query, nil), do: query

  defp maybe_filter_phase(query, phase_id) when is_binary(phase_id) do
    from [doc: d] in query,
      where: fragment("?->>'parent_id'", d.content) == ^phase_id
  end
end
