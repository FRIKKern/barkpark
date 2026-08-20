defmodule Barkpark.ChatHosts.ExecutionEvent do
  @moduledoc "Durable, idempotent audit record for a fenced host event or approval."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "chat_execution_events" do
    belongs_to :lease, Barkpark.ChatHosts.ExecutionLease
    belongs_to :host, Barkpark.ChatHosts.RegisteredHost
    belongs_to :workspace, Barkpark.Tenancy.Workspace
    field :cursor, :integer
    field :idempotency_key, :string
    field :kind, :string
    field :payload, :map, default: %{}
    field :projected_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :lease_id,
      :host_id,
      :workspace_id,
      :cursor,
      :idempotency_key,
      :kind,
      :payload,
      :projected_at
    ])
    |> validate_required([
      :lease_id,
      :host_id,
      :workspace_id,
      :cursor,
      :idempotency_key,
      :kind
    ])
    |> validate_number(:cursor, greater_than: 0)
    |> unique_constraint([:lease_id, :cursor])
    |> unique_constraint([:lease_id, :idempotency_key])
  end
end
