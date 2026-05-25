defmodule Barkpark.Search.Event do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "search_intel_events" do
    field :surface, :string
    field :scope, :string
    field :event_type, :string, default: "search"
    field :query, :string, default: ""
    field :query_normalized, :string, default: ""
    field :filters, :map, default: %{}
    field :result_count, :integer, default: 0
    field :zero_hits, :boolean, default: false
    field :actor_key, :string, default: "anon"
    field :duration_ms, :integer
    field :quality, :string, default: "accepted"
    field :reject_reason, :string
    field :parent_event_id, :binary_id
    field :source, :string, default: "api"
    field :session_key, :string
    field :tags, {:array, :string}, default: []
    field :metadata, :map, default: %{}
    field :object_id, :string
    field :position, :integer
    field :query_event_id, :binary_id

    belongs_to :workspace, Barkpark.Tenancy.Workspace, type: :binary_id
    belongs_to :project, Barkpark.Tenancy.Project, type: :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
