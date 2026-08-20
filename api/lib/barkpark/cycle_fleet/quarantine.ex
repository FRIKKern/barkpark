defmodule Barkpark.CycleFleet.Quarantine do
  @moduledoc "Immutable evidence that a registered CycleFleet correction is unsafe to promote."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cycle_correction_quarantines" do
    field :root_wave_id, :binary_id
    field :correction_wave_id, :binary_id
    field :workspace_id, :binary_id
    field :project_id, :binary_id
    field :epic_id, :string
    field :idempotency_key, :string
    field :reason, :string
    field :actor, :map
    field :evidence, :string
    field :evidence_revision, :string
    field :correction_receipt, :map
    field :correction_receipt_digest, :string
    field :event_payload, :map
    field :event_digest, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :root_wave_id,
      :correction_wave_id,
      :workspace_id,
      :project_id,
      :epic_id,
      :idempotency_key,
      :reason,
      :actor,
      :evidence,
      :evidence_revision,
      :correction_receipt,
      :correction_receipt_digest,
      :event_payload,
      :event_digest
    ])
    |> validate_required([
      :root_wave_id,
      :correction_wave_id,
      :workspace_id,
      :project_id,
      :epic_id,
      :idempotency_key,
      :reason,
      :actor,
      :evidence,
      :evidence_revision,
      :correction_receipt,
      :correction_receipt_digest,
      :event_payload,
      :event_digest
    ])
    |> validate_format(:correction_receipt_digest, ~r/^[0-9a-f]{64}$/)
    |> validate_format(:event_digest, ~r/^[0-9a-f]{64}$/)
    |> unique_constraint([:root_wave_id, :idempotency_key],
      name: :cycle_correction_quarantines_idempotency_index
    )
  end
end
