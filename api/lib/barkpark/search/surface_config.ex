defmodule Barkpark.Search.SurfaceConfig do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

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
end
