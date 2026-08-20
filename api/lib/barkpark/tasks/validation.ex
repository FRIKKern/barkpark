defmodule Barkpark.Tasks.Validation do
  @moduledoc """
  Content-shape validation for `kind:task` documents — extracted from
  `Barkpark.Tasks` (behaviour-preserving facade split).

  Owns the §1 field contract: the lifecycle-status enum, the `content.kind`
  discriminator, and the per-field shape checks the document-write paths
  (`Content.create_document/4`, `Content.upsert_document/4`) call before
  insert/update when `type == "task"`.

  Pure functions only — no DB access, no aliases. `Barkpark.Tasks`
  `defdelegate`s the public entry points (`validate_task_content/1`,
  `validate_kind_content/2`) and the two constant readers
  (`lifecycle_statuses/0`, `kinds/0`) here so callers are unchanged.
  """

  # The five original states first (open in_progress blocked done cancelled),
  # then the two thought states appended (considering researching). Order is
  # load-bearing for readers that render a ladder; the append keeps every
  # existing index stable. "OPEN MEANS READY" is held by construction — only
  # open|blocked is claimable (`claimable_statuses/0` below, the ONE source the
  # queue.ex/claim.ex allowlists derive from), and the two new states are
  # simply not in that allowlist.
  @lifecycle_statuses ~w(open in_progress blocked done cancelled considering researching)

  # The claimability allowlist — which lifecycle states `ready` lists and
  # `claim`/`claim_by_id` will take. `blocked` is claim-equivalent to `open`
  # by DECISION (spd-b24 intended-soft ruling): blocking is advisory metadata,
  # not a hard primitive — the readiness gates (blocks-edges +
  # content.dependencies) are what actually hold work back.
  @claimable_statuses ~w(open blocked)
  @kinds ~w(task)

  # The advertised `outcome.resolution` enum — mirrors the schema select
  # options (schema.ex, task field "outcome" → "resolution"). Strict and
  # always-on (charter D23): a present off-enum value — including "" — is
  # rejected; absent/nil stays fine. No grandfathering: the guerrilla census
  # found every live value already on-enum.
  @outcome_resolutions ~w(shipped fixed partial wont_do duplicate superseded discarded)

  alias Barkpark.Tasks.{ExecutionPolicy, QueueGate}

  @doc "The seven lifecycle-status string values a task document may carry."
  @spec lifecycle_statuses() :: [String.t()]
  def lifecycle_statuses, do: @lifecycle_statuses

  # @canonical capability:task-claimable-statuses aka:ready,allowlist,open-blocked,claim-equivalent doc:docs/setup/TASK-SYSTEM.md
  @doc "The lifecycle-status values a task may be claimed from (ready allowlist)."
  @spec claimable_statuses() :: [String.t()]
  def claimable_statuses, do: @claimable_statuses

  @doc "The `content.kind` discriminator values (only `task`)."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

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
  `claim` (map), `engagement` (map — the thought-state object companion) —
  plus the dossier fields: `description` / `design` /
  `design_doc` / `due_at` / `blocked_reason` / `close_reason` / `retro`
  (strings), `papers` / `attachments` (lists of strings), `labels` /
  `history` (lists), `estimate` / `history_summary` (maps), `outcome`
  (map; its `resolution`, when present, must be on the advertised enum),
  `worklog` / `acceptance_criteria` (lists of maps). `execution_policy` and
  `queue_gate` are the two strict nested versioned contracts; other dossier
  composites retain top-level-only shape checks.
  """
  @spec validate_task_content(map() | nil) :: :ok | {:error, map()}
  def validate_task_content(content), do: validate_kind_content("task", content)

  @doc """
  Validates `content` against the shape for the given `kind`. Dispatches
  to the per-kind validator; unknown kinds are rejected.

  Used by the document-write paths (`Content.create_document/4`,
  `Content.upsert_document/4`) when the `type` argument equals `"task"`.
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
    case fetch(content, "kind") do
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

  # Required + shape checks for `task`. Kept tight per the plan: only what the
  # live readers consume.

  defp validate_kind_specific(errors, "task", content) do
    errors
    |> require_string_in(content, "lifecycle_status", @lifecycle_statuses)
    |> check_optional_priority(content)
    |> check_optional_string(content, "assignee")
    |> check_optional_string(content, "parent_id")
    |> check_optional_string_list(content, "dependencies")
    |> check_optional_map(content, "claim")
    # Engagement companion map (task-lifecycle-visibility): the object a thought
    # state carries — %{object: "research"|"build", holder, ts, note}. Thought is
    # not contended work, so this is shape-only (top-level map), NO CAS epochs —
    # the claim-map precedent. The honesty-lease TTL sweeper (separate slice)
    # clears a stale engagement; validation only guards the shape.
    |> check_optional_map(content, "engagement")
    # Dossier fields — shape-only-when-present, following the claim
    # precedent (top-level shape, NO sub-key enforcement). Sub-key
    # contracts live in the schema field descriptions (agent-facing,
    # serialized in the capabilities manifest). Keeping these loose keeps
    # every existing writer (the `bp task` CLI, engine CAS updates, legacy
    # docs) green.
    |> check_optional_string(content, "description")
    |> check_optional_map(content, "brief")
    |> check_optional_string(content, "design")
    |> check_optional_string(content, "design_doc")
    |> check_optional_string(content, "due_at")
    |> check_optional_string(content, "blocked_reason")
    |> check_optional_string(content, "close_reason")
    |> check_optional_string(content, "retro")
    |> check_optional_string_list(content, "papers")
    |> check_optional_string_list(content, "attachments")
    # Find-or-create gate (task-obsession): ids the author declared distinct
    # from near-duplicate candidates — the escape hatch AND the persisted,
    # queryable rejection trail (Barkpark.Tasks.Dedup).
    |> check_optional_string_list(content, "distinct_from")
    # any-element lists: reads already tolerate legacy W7-mirror label
    # lists, and history elements are compactor-owned event maps —
    # don't over-constrain either.
    |> check_optional_list(content, "labels")
    |> check_optional_list(content, "history")
    |> check_optional_map(content, "estimate")
    |> check_outcome(content)
    # Land digest (task-obsession layer 3): what the task changed —
    # %{"prs","files","capability_slugs"}. Written at close; read by the CI
    # re-land check. Top-level shape only (map), per the claim precedent.
    |> check_optional_map(content, "landed")
    |> check_optional_map(content, "history_summary")
    |> check_optional_map_list(content, "worklog")
    |> check_optional_map_list(content, "acceptance_criteria")
    |> check_execution_policy(content)
    |> check_queue_gate(content)
  end

  # ─── Per-field micro-validators ────────────────────────────────────────────

  # Fetch a field by its string key, falling back to the atom key — via
  # `Map.fetch` so a legitimately-present `false` is NOT masked by `||`
  # (which treats `false` as absent and lets an invalid value pass the
  # type check). `String.to_atom` is safe: keys are fixed literals here.
  # Reachability: every call site passes a literal field name, so the atom table
  # can only ever gain the fixed set spelled in this module — never a client key.
  # sobelow_skip ["DOS.StringToAtom"]
  defp fetch(content, key) do
    case Map.fetch(content, key) do
      {:ok, v} -> v
      :error -> Map.get(content, String.to_atom(key))
    end
  end

  defp require_string_in(errors, content, key, allowed) do
    case fetch(content, key) do
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
    case fetch(content, key) do
      nil -> errors
      v when is_binary(v) -> errors
      other -> Map.put(errors, key, ["must be a string when set, got #{inspect(other)}"])
    end
  end

  defp check_optional_string_list(errors, content, key) do
    case fetch(content, key) do
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
    case fetch(content, "priority") do
      nil ->
        errors

      v when is_integer(v) and v >= 0 and v <= 4 ->
        errors

      other ->
        Map.put(errors, "priority", ["must be an integer 0..4 when set, got #{inspect(other)}"])
    end
  end

  defp check_optional_map(errors, content, key) do
    case fetch(content, key) do
      nil -> errors
      v when is_map(v) -> errors
      other -> Map.put(errors, key, ["must be a map when set, got #{inspect(other)}"])
    end
  end

  defp check_optional_list(errors, content, key) do
    case fetch(content, key) do
      nil -> errors
      v when is_list(v) -> errors
      other -> Map.put(errors, key, ["must be a list when set, got #{inspect(other)}"])
    end
  end

  defp check_optional_map_list(errors, content, key) do
    case fetch(content, key) do
      nil ->
        errors

      list when is_list(list) ->
        if Enum.all?(list, &is_map/1) do
          errors
        else
          Map.put(errors, key, ["must be a list of maps, got #{inspect(list)}"])
        end

      other ->
        Map.put(errors, key, ["must be a list when set, got #{inspect(other)}"])
    end
  end

  # `outcome` map with a validated `resolution` enum (charter D23). Top-level
  # shape mirrors check_optional_map (kept separate — that helper has seven
  # unrelated call sites); when the map carries a "resolution" (string key —
  # HTTP content is string-keyed) the value must be on the advertised enum.
  # Absent/nil resolution is fine; any present off-enum value — including
  # `""` — rejects. Other keys (summary, commits, actual_size, …) stay
  # shape-unchecked here, per the claim-map precedent.
  defp check_outcome(errors, content) do
    case fetch(content, "outcome") do
      nil ->
        errors

      outcome when is_map(outcome) ->
        case Map.get(outcome, "resolution") do
          nil ->
            errors

          v when is_binary(v) ->
            if v in @outcome_resolutions do
              errors
            else
              Map.put(errors, "outcome", [
                "resolution must be one of #{inspect(@outcome_resolutions)}, got #{inspect(v)}"
              ])
            end

          other ->
            Map.put(errors, "outcome", [
              "resolution must be one of #{inspect(@outcome_resolutions)}, got #{inspect(other)}"
            ])
        end

      other ->
        Map.put(errors, "outcome", ["must be a map when set, got #{inspect(other)}"])
    end
  end

  defp check_execution_policy(errors, content) do
    case ExecutionPolicy.validate(fetch(content, "execution_policy")) do
      :ok -> errors
      {:error, policy_errors} -> Map.put(errors, "execution_policy", policy_errors)
    end
  end

  defp check_queue_gate(errors, content) do
    case QueueGate.validate(fetch(content, "queue_gate")) do
      :ok -> errors
      {:error, gate_errors} -> Map.put(errors, "queue_gate", gate_errors)
    end
  end
end
