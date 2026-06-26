defmodule BarkparkCloud.Registry.AgentEvent do
  @moduledoc """
  One entry in a Barkpark's append-only agent event stream — the audit trail of
  what the on-box agent reported (a health beat, a status flip, a backup run, a
  TLS renewal). Belongs to one Barkpark.

  Append-only: there is `inserted_at` but NO `updated_at`. An event is a fact at
  a point in time; it is written once and never mutated. `payload` is a free map
  stored as jsonb, so each `type` can carry whatever shape it needs without a
  schema migration per event kind.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ~w(health status backup tls)

  # Append-only stream: stamp inserted_at, never updated_at.
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "agent_events" do
    field :type, :string
    field :payload, :map, default: %{}

    belongs_to :barkpark, BarkparkCloud.Registry.Barkpark

    timestamps()
  end

  @type t :: %__MODULE__{}

  def types, do: @types

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:type, :payload, :barkpark_id])
    |> validate_required([:type, :barkpark_id])
    |> validate_inclusion(:type, @types)
    |> assoc_constraint(:barkpark)
  end
end
