defmodule Barkpark.EpicFleet.Assignment do
  @moduledoc """
  Immutable snapshot of one typed Epic Cycle child assignment.

  Assignments are insert-only. The database rejects updates and deletes so the
  policy and evidence expectations observed at dispatch cannot drift later.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @phases ~w(survey verify experiment build review)
  @efforts ~w(medium high)
  @digest_format ~r/^[0-9a-f]{64}$/

  schema "epic_assignments" do
    belongs_to :workspace, Barkpark.Tenancy.Workspace
    field :epic_id, :string
    field :wave_id, :string
    field :assignment_id, :string
    field :phase, :string
    field :agent_type, :string
    field :effort, :string
    field :snapshot, :map, default: %{}
    field :snapshot_digest, :string
    field :unit_ids, {:array, :string}, read_after_writes: true
    field :inventory_digest, :string, read_after_writes: true
    belongs_to :cycle_wave, Barkpark.CycleFleet.Wave
    belongs_to :replaces_assignment, __MODULE__
    has_one :result, Barkpark.EpicFleet.Result
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc "Insert-only changeset for a frozen assignment snapshot."
  @spec insert_changeset(map()) :: Ecto.Changeset.t()
  def insert_changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :workspace_id,
      :epic_id,
      :wave_id,
      :assignment_id,
      :phase,
      :agent_type,
      :effort,
      :snapshot,
      :snapshot_digest,
      :cycle_wave_id,
      :replaces_assignment_id
    ])
    |> validate_required([
      :workspace_id,
      :epic_id,
      :wave_id,
      :assignment_id,
      :phase,
      :agent_type,
      :effort,
      :snapshot,
      :snapshot_digest
    ])
    |> validate_inclusion(:phase, @phases)
    |> validate_inclusion(:effort, @efforts)
    |> validate_format(:snapshot_digest, @digest_format)
    |> validate_not_self_replacement()
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:cycle_wave_id)
    |> foreign_key_constraint(:replaces_assignment_id)
    |> unique_constraint([:workspace_id, :epic_id, :wave_id, :assignment_id],
      name: :epic_assignments_scope_assignment_index
    )
    |> unique_constraint([:cycle_wave_id, :assignment_id],
      name: :epic_assignments_cycle_assignment_index
    )
    |> unique_constraint(:replaces_assignment_id,
      name: :epic_assignments_replaces_assignment_index
    )
    |> check_constraint(:phase, name: :epic_assignments_phase)
    |> check_constraint(:effort, name: :epic_assignments_effort)
    |> check_constraint(:snapshot_digest, name: :epic_assignments_snapshot_digest)
    |> check_constraint(:replaces_assignment_id,
      name: :epic_assignments_not_self_replacement
    )
    |> check_constraint(:cycle_wave_id, name: :epic_assignments_legendary_wave)
  end

  @doc "Compatibility name for callers that construct an insertion changeset."
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs), do: insert_changeset(attrs)

  @doc "The phases admitted by the durable Epic fleet contract."
  @spec phases() :: [String.t()]
  def phases, do: @phases

  @doc "The effort values admitted by assignment snapshots."
  @spec efforts() :: [String.t()]
  def efforts, do: @efforts

  defp validate_not_self_replacement(changeset) do
    case {get_field(changeset, :id), get_field(changeset, :replaces_assignment_id)} do
      {id, id} when not is_nil(id) ->
        add_error(changeset, :replaces_assignment_id, "cannot replace itself")

      _ ->
        changeset
    end
  end
end
