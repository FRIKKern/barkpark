defmodule Barkpark.Search.SurfaceConfig do
  @moduledoc false
  use Ecto.Schema

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
end
