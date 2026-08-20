defmodule Barkpark.CycleFleet.Wave do
  @moduledoc "Immutable launch contract for one Epic or Legendary cycle wave."

  use Ecto.Schema
  import Ecto.Changeset

  alias Barkpark.CycleFleet.Profile

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @digest_format ~r/^[0-9a-f]{64}$/

  schema "cycle_waves" do
    belongs_to :workspace, Barkpark.Tenancy.Workspace
    belongs_to :project, Barkpark.Tenancy.Project
    field :epic_id, :string
    field :wave_id, :string
    field :profile, :string
    field :inventory, {:array, :map}, default: []
    field :inventory_digest, :string
    field :plan, :map, default: %{}
    field :plan_digest, :string
    field :experiment_contract, :map, default: %{}
    field :scale_contract, :map, default: %{}
    belongs_to :correction_of_wave, __MODULE__
    field :correction_of, :map
    field :correction_of_digest, :string
    field :release_gate_required, :boolean, read_after_writes: true
    has_one :build_plan, Barkpark.CycleFleet.BuildPlan
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @spec insert_changeset(map()) :: Ecto.Changeset.t()
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :workspace_id,
      :project_id,
      :epic_id,
      :wave_id,
      :profile,
      :inventory,
      :inventory_digest,
      :plan,
      :plan_digest,
      :experiment_contract,
      :scale_contract,
      :correction_of_wave_id,
      :correction_of,
      :correction_of_digest
    ])
    |> validate_required([
      :workspace_id,
      :epic_id,
      :wave_id,
      :profile,
      :inventory,
      :inventory_digest,
      :plan,
      :plan_digest
    ])
    |> validate_inclusion(:profile, Profile.names())
    |> validate_format(:inventory_digest, @digest_format)
    |> validate_format(:plan_digest, @digest_format)
    |> validate_format(:correction_of_digest, @digest_format)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:project_id, name: :cycle_waves_project_workspace_fkey)
    |> foreign_key_constraint(:correction_of_wave_id)
    |> unique_constraint([:workspace_id, :project_id, :epic_id, :wave_id],
      name: :cycle_waves_project_scope_index
    )
    |> unique_constraint([:workspace_id, :epic_id, :wave_id],
      name: :cycle_waves_flat_scope_index
    )
    |> check_constraint(:profile, name: :cycle_waves_profile)
    |> check_constraint(:inventory_digest, name: :cycle_waves_inventory_digest)
    |> check_constraint(:plan_digest, name: :cycle_waves_plan_digest)
    |> check_constraint(:correction_of, name: :cycle_waves_correction_all_or_none)
    |> check_constraint(:correction_of_digest, name: :cycle_waves_correction_digest)
    |> check_constraint(:correction_of, name: :cycle_waves_correction_version)
    |> check_constraint(:correction_of_wave_id, name: :cycle_waves_correction_not_self)
  end
end
