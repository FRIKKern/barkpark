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

  alias Barkpark.Content.SchemaDefinition

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
end
