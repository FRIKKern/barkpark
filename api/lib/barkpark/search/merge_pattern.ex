defmodule Barkpark.Search.MergePattern do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "search_intel_merge_patterns" do
    field :surface, :string
    field :scope, :string
    field :period, :string
    field :period_start, :date
    field :from_fingerprint, :string
    field :to_fingerprint, :string
    field :pattern_type, :string
    field :transition_count, :integer, default: 0
    field :success_count, :integer, default: 0

    belongs_to :workspace, Barkpark.Tenancy.Workspace, type: :binary_id
    belongs_to :project, Barkpark.Tenancy.Project, type: :binary_id
    belongs_to :dataset, Barkpark.Tenancy.Dataset, type: :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
