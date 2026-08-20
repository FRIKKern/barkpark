defmodule Barkpark.EpicFleet.Result do
  @moduledoc """
  Append-only terminal result for an Epic assignment.

  Exactly one result may exist for an assignment. Replays reconcile against a
  server-computed payload digest through `Barkpark.EpicFleet.record_result/3`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @terminal_states ~w(completed failed cancelled)
  @digest_format ~r/^[0-9a-f]{64}$/

  schema "epic_assignment_results" do
    belongs_to :assignment, Barkpark.EpicFleet.Assignment
    field :idempotency_key, :string
    field :status, :string
    field :summary, :string
    field :evidence, :string
    field :evidence_revision, :string
    field :evidence_digest, :string
    field :payload, :map, default: %{}
    field :payload_digest, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc "Insert-only changeset for a terminal result."
  @spec insert_changeset(map()) :: Ecto.Changeset.t()
  def insert_changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :assignment_id,
      :idempotency_key,
      :status,
      :summary,
      :evidence,
      :evidence_revision,
      :evidence_digest,
      :payload,
      :payload_digest
    ])
    |> validate_required([
      :assignment_id,
      :idempotency_key,
      :status,
      :evidence_digest,
      :payload,
      :payload_digest
    ])
    |> validate_inclusion(:status, @terminal_states)
    |> validate_length(:idempotency_key, min: 1)
    |> validate_format(:evidence_digest, @digest_format)
    |> validate_format(:payload_digest, @digest_format)
    |> validate_completed_evidence()
    |> foreign_key_constraint(:assignment_id)
    |> unique_constraint(:assignment_id, name: :epic_assignment_results_assignment_index)
    |> unique_constraint([:assignment_id, :idempotency_key],
      name: :epic_assignment_results_idempotency_index
    )
    |> check_constraint(:status, name: :epic_assignment_results_status)
    |> check_constraint(:evidence_digest, name: :epic_assignment_results_evidence_digest)
    |> check_constraint(:payload_digest, name: :epic_assignment_results_payload_digest)
    |> check_constraint(:evidence, name: :epic_assignment_results_completed_evidence)
  end

  @doc "Compatibility name for callers that construct an insertion changeset."
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs), do: insert_changeset(attrs)

  @doc "The exhaustive terminal state vocabulary. Absence is represented by no row."
  @spec terminal_states() :: [String.t()]
  def terminal_states, do: @terminal_states

  defp validate_completed_evidence(changeset) do
    if get_field(changeset, :status) == "completed" do
      changeset
      |> validate_required([:evidence, :evidence_revision])
      |> validate_length(:evidence, min: 1)
      |> validate_length(:evidence_revision, min: 1)
    else
      changeset
    end
  end
end
