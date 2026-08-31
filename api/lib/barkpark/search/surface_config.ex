defmodule Barkpark.Search.SurfaceConfig do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Barkpark.Search.Highlighter

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "search_surface_config" do
    # Per-workspace attribution (charter D45/D49). NULL = the workspace-agnostic
    # global default row (what `seed_defaults!/0` writes and the anonymous search
    # read path reads); a real workspace_id = that tenant's own config. Server-set
    # from the resolved scope, never cast from a caller PUT.
    field :workspace_id, :binary_id
    field :surface, :string
    field :scope, :string
    field :searchable_fields, {:array, :map}, default: []
    field :typo_policy, :map, default: %{}
    field :zero_hit_strategy, :string, default: "drop_tokens"
    field :highlight_fields, {:array, :string}, default: []

    timestamps(type: :utc_datetime_usec)
  end

  # Only these four are settable from a caller PUT; surface + scope are server-set.
  @castable [:searchable_fields, :typo_policy, :zero_hit_strategy, :highlight_fields]

  # The recovery strategies `Barkpark.Search.QueryPipeline` actually implements.
  # Anything else used to be STORED and then behave like "none": `try_drop_tokens/5`
  # and `try_typo_widen/5` both guard on the literal names, so a config saying
  # `"aggressive"` returned 200, read back `"aggressive"`, and quietly disabled
  # every recovery pass. A strategy the pipeline cannot run is refused here.
  @zero_hit_strategies ~w(none drop_tokens typo_widen)

  # The `typo_policy` keys a retriever actually reads. A key outside this set has
  # no reader by definition, so accepting it means storing a knob that does
  # nothing and echoing it back on the next GET as if it had taken — exactly
  # what `min_len_2typo` did from the day it was introduced (48fe5985bf, May
  # 2026) until this change dropped it from the defaults.
  @typo_policy_keys ~w(enabled min_len_1typo similarity_threshold similarity_threshold_relaxed)

  @doc """
  Validated changeset for the caller-settable config fields.

  Uses `cast/3`, NOT `Ecto.Changeset.change/2`. `change/2` does NOT validate —
  it accepts a wrong-typed value verbatim (`valid?` stays true); the mismatch
  then surfaces as an uncaught `Ecto.ChangeError` at `Repo.insert/update` dump
  time (`Ecto.Type.dump(:map, "aggressive") == :error`) — a 500. `cast/3` instead
  rejects the value up front as a changeset error the caller renders as 422. So a
  well-typed-but-wrong JSON value — e.g. `"aggressive"` (string) for the `:map`
  `typo_policy` field, or `"title"` (string) for the `{:array, :string}`
  `highlight_fields` — is refused cleanly instead of crashing the endpoint (and
  instead of ever persisting a malformed `typo_policy`).
  """
  def changeset(config, attrs) do
    config
    |> cast(attrs, @castable)
    |> validate_inclusion(:zero_hit_strategy, @zero_hit_strategies,
      message: "must be one of: " <> Enum.join(@zero_hit_strategies, ", ")
    )
    |> validate_typo_policy()
    |> validate_highlight_fields()
    # Defense in depth (constraints-are-truth): the DB carries TWO partial UNIQUE
    # indexes (charter D57) — `(surface, scope) WHERE workspace_id IS NULL`
    # (search_surface_config_surface_scope_idx, the global-default rows) and
    # `(workspace_id, surface, scope)` (…_workspace_surface_scope_idx, the
    # per-tenant rows). The upsert write path guards the concurrent-first-write
    # race with ON CONFLICT, but any path that does a plain `Repo.insert/2` on a
    # duplicate must get a clean {:error, changeset} (rendered 422) instead of a
    # raw Ecto.ConstraintError (a 500). Map BOTH so either domain's duplicate
    # surfaces as a changeset error.
    |> unique_constraint([:surface, :scope],
      name: :search_surface_config_surface_scope_idx
    )
    |> unique_constraint([:workspace_id, :surface, :scope],
      name: :search_surface_config_workspace_surface_scope_idx
    )
  end

  # A `typo_policy` is only worth storing if every key in it reaches a reader
  # and carries a value that reader can use. Both halves used to be unchecked:
  # an unknown key was persisted and echoed back on the next GET (the caller's
  # only feedback said their setting had taken), and a well-formed map with
  # `"enabled" => "yes"` read as enabled because the reader compares against
  # `false`. Refusing here is the one place a caller can still be told.
  defp validate_typo_policy(changeset) do
    validate_change(changeset, :typo_policy, fn :typo_policy, policy ->
      case policy do
        %{} = policy ->
          Enum.flat_map(@typo_policy_keys, &key_errors(policy, &1)) ++ unknown_key_errors(policy)

        _ ->
          [typo_policy: "must be an object"]
      end
    end)
  end

  # task-5cf80a99ecd52bf2: `highlight_fields` used to be cast with no check
  # against what the highlighter can actually render. A value outside the
  # surface's known field set stored cleanly (200) and crashed the NEXT
  # search request in `Barkpark.Search.Highlighter.media_field_text/3` — a
  # `FunctionClauseError` on a totally unrelated caller, since that function
  # had no catch-all. This is the WRITE-side half of the fix (the primary
  # one — it stops the row ever being corrupted); `media_field_text/3` also
  # grew a catch-all (defence in depth) for rows written before this gate
  # existed. `Highlighter.media_highlight_field?/1` and
  # `document_highlight_field?/1` are the single source of truth for what
  # each surface can render — kept in the Highlighter module so a new field
  # clause there and its write-time acceptance can never drift apart.
  defp validate_highlight_fields(changeset) do
    surface = get_field(changeset, :surface)

    validate_change(changeset, :highlight_fields, fn :highlight_fields, fields ->
      case Enum.reject(fields, &highlightable?(surface, &1)) do
        [] ->
          []

        bad ->
          [
            highlight_fields: "not a highlightable #{surface} field: " <> Enum.join(bad, ", ")
          ]
      end
    end)
  end

  defp highlightable?("media", field), do: Highlighter.media_highlight_field?(field)
  defp highlightable?("documents", field), do: Highlighter.document_highlight_field?(field)
  # An unset/unrecognized surface (e.g. a bare %SurfaceConfig{} in a unit
  # test that never assigns :surface) has no known field set to check
  # against — permissive, matching cast/3's behaviour before this change.
  defp highlightable?(_other_surface, _field), do: true

  defp unknown_key_errors(policy) do
    case policy
         |> Map.keys()
         |> Enum.map(&to_string/1)
         |> Enum.reject(&(&1 in @typo_policy_keys)) do
      [] ->
        []

      unknown ->
        [
          typo_policy:
            "has no reader for " <>
              Enum.join(Enum.sort(unknown), ", ") <>
              " (accepted keys: " <> Enum.join(@typo_policy_keys, ", ") <> ")"
        ]
    end
  end

  defp key_errors(policy, "enabled") do
    case fetch_key(policy, "enabled") do
      :absent -> []
      {:ok, v} when is_boolean(v) -> []
      {:ok, _} -> [typo_policy: "enabled must be a boolean"]
    end
  end

  defp key_errors(policy, "min_len_1typo") do
    case fetch_key(policy, "min_len_1typo") do
      :absent -> []
      {:ok, v} when is_integer(v) and v > 0 -> []
      {:ok, _} -> [typo_policy: "min_len_1typo must be a positive integer"]
    end
  end

  defp key_errors(policy, threshold) do
    case fetch_key(policy, threshold) do
      :absent -> []
      {:ok, v} when is_number(v) and v >= 0 and v <= 1 -> []
      {:ok, _} -> [typo_policy: threshold <> " must be a number between 0 and 1"]
    end
  end

  defp fetch_key(policy, key) do
    cond do
      Map.has_key?(policy, key) ->
        {:ok, Map.get(policy, key)}

      Map.has_key?(policy, String.to_existing_atom(key)) ->
        {:ok, Map.get(policy, String.to_existing_atom(key))}

      true ->
        :absent
    end
  rescue
    ArgumentError -> :absent
  end
end
