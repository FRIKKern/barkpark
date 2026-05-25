defmodule Barkpark.Search.Crystal do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "search_intel_crystals" do
    field :surface, :string
    field :scope, :string
    field :period, :string
    field :period_start, :date
    field :query_normalized, :string, default: ""
    field :filter_fingerprint, :string, default: ""
    field :search_count, :integer, default: 0
    field :zero_hit_count, :integer, default: 0
    field :success_count, :integer, default: 0
    field :unique_actors, :integer, default: 0
    field :avg_result_count, :float, default: 0.0
    field :avg_duration_ms, :float, default: 0.0
    field :rejected_count, :integer, default: 0
    field :click_count, :integer, default: 0
    field :ctr, :float, default: 0.0

    belongs_to :workspace, Barkpark.Tenancy.Workspace, type: :binary_id
    belongs_to :project, Barkpark.Tenancy.Project, type: :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
