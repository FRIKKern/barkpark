defmodule Barkpark.Search.SurfaceConfig do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "search_surface_config" do
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
    cast(config, attrs, @castable)
  end
end
