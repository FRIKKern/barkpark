defmodule Barkpark.Media.SearchMergePattern do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "media_search_merge_patterns" do
    field :dataset, :string
    field :period, :string
    field :period_start, :date
    field :from_fingerprint, :string
    field :to_fingerprint, :string
    field :pattern_type, :string
    field :transition_count, :integer, default: 0
    field :success_count, :integer, default: 0

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
