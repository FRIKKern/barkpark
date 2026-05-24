defmodule Barkpark.Media.SearchEvent do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "media_search_events" do
    field :dataset, :string
    field :query, :string, default: ""
    field :filters, :map, default: %{}
    field :result_count, :integer, default: 0
    field :zero_hits, :boolean, default: false
    field :actor_key, :string, default: "anon"
    field :duration_ms, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
