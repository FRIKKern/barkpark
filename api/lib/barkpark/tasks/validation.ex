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

  @lifecycle_statuses ~w(open in_progress blocked done cancelled)
  @kinds ~w(task)

  @doc "The five lifecycle-status string values a task document may carry."
  @spec lifecycle_statuses() :: [String.t()]
  def lifecycle_statuses, do: @lifecycle_statuses

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
  `claim` (map) — plus the dossier fields: `description` / `design` /
  `design_doc` / `due_at` / `blocked_reason` / `close_reason` / `retro`
  (strings), `papers` / `attachments` (lists of strings), `labels` /
  `history` (lists), `estimate` / `outcome` / `history_summary` (maps),
  `worklog` / `acceptance_criteria` (lists of maps). Top-level shape only,
  never sub-keys — the claim-map precedent.
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
    # Dossier fields — shape-only-when-present, following the claim
    # precedent (top-level shape, NO sub-key enforcement). Sub-key
    # contracts live in the schema field descriptions (agent-facing,
    # serialized in the capabilities manifest). Keeping these loose keeps
    # every existing writer (the `bp task` CLI, engine CAS updates, legacy
    # docs) green.
    |> check_optional_string(content, "description")
    |> check_optional_string(content, "design")
    |> check_optional_string(content, "design_doc")
    |> check_optional_string(content, "due_at")
    |> check_optional_string(content, "blocked_reason")
    |> check_optional_string(content, "close_reason")
    |> check_optional_string(content, "retro")
    |> check_optional_string_list(content, "papers")
    |> check_optional_string_list(content, "attachments")
    # any-element lists: reads already tolerate legacy W7-mirror label
    # lists, and history elements are compactor-owned event maps —
    # don't over-constrain either.
    |> check_optional_list(content, "labels")
    |> check_optional_list(content, "history")
    |> check_optional_map(content, "estimate")
    |> check_optional_map(content, "outcome")
    |> check_optional_map(content, "history_summary")
    |> check_optional_map_list(content, "worklog")
    |> check_optional_map_list(content, "acceptance_criteria")
  end

  # ─── Per-field micro-validators ────────────────────────────────────────────

  # Fetch a field by its string key, falling back to the atom key — via
  # `Map.fetch` so a legitimately-present `false` is NOT masked by `||`
  # (which treats `false` as absent and lets an invalid value pass the
  # type check). `String.to_atom` is safe: keys are fixed literals here.
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
end
