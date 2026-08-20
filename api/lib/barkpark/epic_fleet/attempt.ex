defmodule Barkpark.EpicFleet.Attempt do
  @moduledoc "Append-only execution attempt with typed benchmark cost observations."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(completed failed timeout contaminated cancelled)
  @cost_states ~w(observed unsupported missing invalid)
  @digest_format ~r/^[0-9a-f]{64}$/

  schema "epic_benchmark_attempts" do
    belongs_to :experiment, Barkpark.EpicFleet.Experiment
    field :attempt_id, :string
    field :replaces_attempt_id, :string
    field :ordinal, :integer
    field :treatment, :string
    field :status, :string
    field :costs, :map, default: %{}
    field :provenance, :map, default: %{}
    field :payload, :map, default: %{}
    field :attempt_digest, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc "Insertion changeset for an immutable benchmark attempt."
  @spec insert_changeset(map()) :: Ecto.Changeset.t()
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :experiment_id,
      :attempt_id,
      :replaces_attempt_id,
      :ordinal,
      :treatment,
      :status,
      :costs,
      :provenance,
      :payload,
      :attempt_digest
    ])
    |> validate_required([
      :experiment_id,
      :attempt_id,
      :ordinal,
      :treatment,
      :status,
      :costs,
      :provenance,
      :payload,
      :attempt_digest
    ])
    |> validate_number(:ordinal, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> validate_format(:attempt_digest, @digest_format)
    |> validate_not_self_replacement()
    |> validate_costs()
    |> foreign_key_constraint(:experiment_id)
    |> unique_constraint([:experiment_id, :attempt_id],
      name: :epic_benchmark_attempts_experiment_id_index
    )
    |> unique_constraint(:replaces_attempt_id,
      name: :epic_benchmark_attempts_replaces_once_index
    )
    |> check_constraint(:ordinal, name: :epic_benchmark_attempts_ordinal)
    |> check_constraint(:status, name: :epic_benchmark_attempts_status)
    |> check_constraint(:costs, name: :epic_benchmark_attempts_costs)
    |> check_constraint(:attempt_digest, name: :epic_benchmark_attempts_digest)
    |> check_constraint(:replaces_attempt_id,
      name: :epic_benchmark_attempts_not_self_replacement
    )
  end

  @doc "The terminal attempt outcome vocabulary."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The exhaustive typed cost-state vocabulary."
  @spec cost_states() :: [String.t()]
  def cost_states, do: @cost_states

  @doc "Validate a string-keyed map of metric envelopes."
  @spec valid_costs?(term()) :: boolean()
  def valid_costs?(costs) when is_map(costs) and map_size(costs) > 0 do
    Enum.all?(costs, fn
      {metric, value} when is_binary(metric) and metric != "" and is_map(value) ->
        valid_cost?(value)

      _ ->
        false
    end)
  end

  def valid_costs?(_costs), do: false

  defp validate_costs(changeset) do
    validate_change(changeset, :costs, fn :costs, costs ->
      if valid_costs?(costs), do: [], else: [costs: "must contain typed metric states"]
    end)
  end

  defp valid_cost?(%{"state" => "observed", "value" => value}) when is_number(value), do: true

  defp valid_cost?(%{"state" => state, "reason" => reason})
       when state in ~w(unsupported missing invalid) and is_binary(reason) and reason != "",
       do: true

  defp valid_cost?(_value), do: false

  defp validate_not_self_replacement(changeset) do
    if get_field(changeset, :attempt_id) == get_field(changeset, :replaces_attempt_id) do
      add_error(changeset, :replaces_attempt_id, "cannot replace itself")
    else
      changeset
    end
  end
end
