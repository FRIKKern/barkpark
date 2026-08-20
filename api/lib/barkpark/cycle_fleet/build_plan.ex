defmodule Barkpark.CycleFleet.BuildPlan do
  @moduledoc "Immutable post-pilot capacity and build-plan seal for one cycle wave."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @digest_format ~r/^[0-9a-f]{64}$/

  schema "cycle_build_plans" do
    belongs_to :wave, Barkpark.CycleFleet.Wave
    field :proven_batch_capacity, :integer
    field :plan, :map, default: %{}
    field :plan_digest, :string
    field :inventory_digest, :string
    field :chosen_format, :string
    field :pilot_evidence, :string
    field :pilot_evidence_revision, :string
    field :failure_rate, :float
    field :failure_threshold, :float
    field :golden_fixtures, {:array, :string}, default: []
    field :quality_rubric, :map, default: %{}
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @spec insert_changeset(map()) :: Ecto.Changeset.t()
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :wave_id,
      :proven_batch_capacity,
      :plan,
      :plan_digest,
      :inventory_digest,
      :chosen_format,
      :pilot_evidence,
      :pilot_evidence_revision,
      :failure_rate,
      :failure_threshold,
      :golden_fixtures,
      :quality_rubric
    ])
    |> validate_required([
      :wave_id,
      :proven_batch_capacity,
      :plan,
      :plan_digest,
      :inventory_digest,
      :chosen_format,
      :pilot_evidence,
      :pilot_evidence_revision,
      :failure_rate,
      :failure_threshold,
      :golden_fixtures,
      :quality_rubric
    ])
    |> validate_number(:proven_batch_capacity, greater_than: 0)
    |> validate_number(:failure_rate, greater_than_or_equal_to: 0)
    |> validate_number(:failure_threshold, greater_than_or_equal_to: 0)
    |> validate_format(:plan_digest, @digest_format)
    |> validate_format(:inventory_digest, @digest_format)
    |> validate_length(:chosen_format, min: 1)
    |> validate_length(:pilot_evidence, min: 1)
    |> validate_length(:pilot_evidence_revision, min: 1)
    |> validate_length(:golden_fixtures, min: 1)
    |> validate_change(:quality_rubric, fn :quality_rubric, rubric ->
      if is_map(rubric) and map_size(rubric) > 0,
        do: [],
        else: [quality_rubric: "must contain the frozen quality rubric"]
    end)
    |> validate_failure_threshold()
    |> foreign_key_constraint(:wave_id)
    |> unique_constraint(:wave_id, name: :cycle_build_plans_wave_index)
    |> check_constraint(:proven_batch_capacity, name: :cycle_build_plans_capacity)
    |> check_constraint(:plan_digest, name: :cycle_build_plans_plan_digest)
    |> check_constraint(:inventory_digest, name: :cycle_build_plans_inventory_digest)
    |> check_constraint(:failure_rate, name: :cycle_build_plans_failure_rate)
  end

  defp validate_failure_threshold(changeset) do
    rate = get_field(changeset, :failure_rate)
    threshold = get_field(changeset, :failure_threshold)

    if is_number(rate) and is_number(threshold) and rate > threshold,
      do: add_error(changeset, :failure_rate, "exceeds the frozen pilot threshold"),
      else: changeset
  end
end
