defmodule Barkpark.EpicFleet.Experiment do
  @moduledoc """Append-only manifest for one Epic or Legendary benchmark experiment."""

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @phases ~w(epic legendary)
  @digest_format ~r/^[0-9a-f]{64}$/

  schema "epic_benchmark_experiments" do
    belongs_to :workspace, Barkpark.Tenancy.Workspace
    field :epic_id, :string
    field :wave_id, :string
    field :experiment_id, :string
    field :phase, :string
    field :protocol_version, :integer
    field :manifest, :map, default: %{}
    field :manifest_digest, :string
    has_many :attempts, Barkpark.EpicFleet.Attempt
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc "Insertion changeset for an immutable experiment manifest."
  @spec insert_changeset(map()) :: Ecto.Changeset.t()
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :workspace_id,
      :epic_id,
      :wave_id,
      :experiment_id,
      :phase,
      :protocol_version,
      :manifest,
      :manifest_digest
    ])
    |> validate_required([
      :workspace_id,
      :epic_id,
      :wave_id,
      :experiment_id,
      :phase,
      :protocol_version,
      :manifest,
      :manifest_digest
    ])
    |> validate_inclusion(:phase, @phases)
    |> validate_number(:protocol_version, greater_than: 0)
    |> validate_format(:manifest_digest, @digest_format)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint([:workspace_id, :epic_id, :wave_id, :experiment_id],
      name: :epic_benchmark_experiments_scope_id_index
    )
    |> check_constraint(:phase, name: :epic_benchmark_experiments_phase)
    |> check_constraint(:protocol_version,
      name: :epic_benchmark_experiments_protocol_version
    )
    |> check_constraint(:manifest_digest, name: :epic_benchmark_experiments_manifest_digest)
  end

  @doc "The supported experiment phase vocabulary."
  @spec phases() :: [String.t()]
  def phases, do: @phases
end
