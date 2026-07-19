defmodule Barkpark.CycleFleet.Promotion do
  @moduledoc "Schemas and linked-chain readers for immutable correction promotion events."

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Repo

  defmodule Root do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:root_wave_id, :binary_id, autogenerate: false}
    @foreign_key_type :binary_id

    schema "cycle_correction_roots" do
      field :workspace_id, :binary_id
      field :project_id, :binary_id
      field :epic_id, :string
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    def insert_changeset(attrs) do
      %__MODULE__{}
      |> cast(attrs, [:root_wave_id, :workspace_id, :project_id, :epic_id])
      |> validate_required([:root_wave_id, :workspace_id, :project_id, :epic_id])
    end
  end

  defmodule Target do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:wave_id, :binary_id, autogenerate: false}
    @foreign_key_type :binary_id

    schema "cycle_correction_targets" do
      field :root_wave_id, :binary_id
      field :previous_wave_id, :binary_id
      field :workspace_id, :binary_id
      field :project_id, :binary_id
      field :epic_id, :string
      field :correction_receipt, :map
      field :correction_receipt_digest, :string
      field :semantic_digest, :string
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    def insert_changeset(attrs) do
      %__MODULE__{}
      |> cast(attrs, [
        :wave_id,
        :root_wave_id,
        :previous_wave_id,
        :workspace_id,
        :project_id,
        :epic_id,
        :correction_receipt,
        :correction_receipt_digest,
        :semantic_digest
      ])
      |> validate_required([
        :wave_id,
        :root_wave_id,
        :previous_wave_id,
        :workspace_id,
        :project_id,
        :epic_id,
        :correction_receipt,
        :correction_receipt_digest,
        :semantic_digest
      ])
      |> validate_format(:correction_receipt_digest, ~r/^[0-9a-f]{64}$/)
      |> validate_format(:semantic_digest, ~r/^[0-9a-f]{64}$/)
      |> unique_constraint(:wave_id)
      |> unique_constraint([:root_wave_id, :previous_wave_id],
        name: :cycle_correction_targets_previous_child_index
      )
    end
  end

  defmodule Event do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    schema "cycle_correction_promotion_events" do
      field :admission_id, :binary_id
      field :release_gate_admission_id, :binary_id
      field :release_materialization, :map
      field :root_wave_id, :binary_id
      field :target_wave_id, :binary_id
      field :previous_event_id, :binary_id
      field :restore_event_id, :binary_id
      field :workspace_id, :binary_id
      field :project_id, :binary_id
      field :epic_id, :string
      field :action, :string
      field :idempotency_key, :string
      field :actor, :map
      field :evidence, :string
      field :evidence_revision, :string
      field :gate_receipt, :map
      field :event_payload, :map
      field :event_digest, :string
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    def insert_changeset(attrs) do
      %__MODULE__{}
      |> cast(attrs, [
        :root_wave_id,
        :admission_id,
        :release_gate_admission_id,
        :release_materialization,
        :target_wave_id,
        :previous_event_id,
        :restore_event_id,
        :workspace_id,
        :project_id,
        :epic_id,
        :action,
        :idempotency_key,
        :actor,
        :evidence,
        :evidence_revision,
        :gate_receipt,
        :event_payload,
        :event_digest
      ])
      |> validate_required([
        :root_wave_id,
        :target_wave_id,
        :workspace_id,
        :project_id,
        :epic_id,
        :action,
        :idempotency_key,
        :actor,
        :evidence,
        :evidence_revision,
        :event_payload,
        :event_digest
      ])
      |> validate_inclusion(:action, ["promote", "rollback"])
      |> validate_format(:event_digest, ~r/^[0-9a-f]{64}$/)
      |> unique_constraint([:root_wave_id, :idempotency_key],
        name: :cycle_correction_promotion_events_idempotency_index
      )
      |> unique_constraint(:previous_event_id,
        name: :cycle_correction_promotion_events_previous_child_index
      )
    end
  end

  defmodule Admission do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    schema "cycle_correction_admissions" do
      field :root_wave_id, :binary_id
      field :target_wave_id, :binary_id
      field :workspace_id, :binary_id
      field :project_id, :binary_id
      field :epic_id, :string
      field :idempotency_key, :string
      field :reconciliation_digest, :string
      field :fleet_digest, :string
      field :b1_scope_receipt, :map
      field :b1_scope_receipt_digest, :string
      field :b1_experiment_id, :binary_id
      field :b1_ledger_digest, :string
      field :b1_bytes_digest, :string
      field :paper_document_id, :binary_id
      field :paper_revision_id, :binary_id
      field :paper_doc_id, :string
      field :paper_content_digest, :string
      field :gate_receipt, :map
      field :gate_receipt_digest, :string
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    def insert_changeset(attrs) do
      required =
        ~w(root_wave_id target_wave_id workspace_id project_id epic_id idempotency_key reconciliation_digest fleet_digest b1_scope_receipt b1_scope_receipt_digest b1_experiment_id b1_ledger_digest b1_bytes_digest paper_document_id paper_revision_id paper_doc_id paper_content_digest gate_receipt gate_receipt_digest)a

      %__MODULE__{}
      |> cast(attrs, required)
      |> validate_required(required)
      |> validate_format(:reconciliation_digest, ~r/^[0-9a-f]{64}$/)
      |> validate_format(:fleet_digest, ~r/^[0-9a-f]{64}$/)
      |> validate_format(:b1_scope_receipt_digest, ~r/^[0-9a-f]{64}$/)
      |> validate_format(:b1_ledger_digest, ~r/^[0-9a-f]{64}$/)
      |> validate_format(:b1_bytes_digest, ~r/^[0-9a-f]{64}$/)
      |> validate_format(:paper_content_digest, ~r/^[0-9a-f]{64}$/)
      |> validate_format(:gate_receipt_digest, ~r/^[0-9a-f]{64}$/)
      |> unique_constraint([:root_wave_id, :idempotency_key],
        name: :cycle_correction_admissions_idempotency_index
      )
    end
  end

  defmodule PublicSmoke do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    schema "cycle_release_public_smokes" do
      belongs_to :promotion_event, Barkpark.CycleFleet.Promotion.Event
      field :root_wave_id, :binary_id
      field :target_wave_id, :binary_id
      field :state, :string
      field :request, :map
      field :proof, :map
      field :proof_digest, :string
      field :failure, :map
      field :compensation_event_id, :binary_id
      timestamps(type: :utc_datetime_usec)
    end

    def insert_changeset(attrs) do
      %__MODULE__{}
      |> cast(attrs, [
        :promotion_event_id,
        :root_wave_id,
        :target_wave_id,
        :state,
        :request,
        :proof,
        :proof_digest,
        :failure,
        :compensation_event_id
      ])
      |> validate_required([
        :promotion_event_id,
        :root_wave_id,
        :target_wave_id,
        :state,
        :request
      ])
      |> validate_inclusion(:state, ~w(pending pass failed compensated))
      |> validate_format(:proof_digest, ~r/^[0-9a-f]{64}$/)
      |> unique_constraint(:promotion_event_id)
    end
  end

  alias __MODULE__.{Event, Root}

  @spec lock_root(Ecto.UUID.t()) :: Root.t() | nil
  def lock_root(root_wave_id) do
    Repo.one(from root in Root, where: root.root_wave_id == ^root_wave_id, lock: "FOR UPDATE")
  end

  @spec event_by_key(Ecto.UUID.t(), String.t()) :: Event.t() | nil
  def event_by_key(root_wave_id, key),
    do: Repo.get_by(Event, root_wave_id: root_wave_id, idempotency_key: key)

  @spec head(Ecto.UUID.t()) :: Event.t() | nil
  def head(root_wave_id) do
    Repo.one(
      from event in Event,
        left_join: child in Event,
        on: child.previous_event_id == event.id,
        where: event.root_wave_id == ^root_wave_id and is_nil(child.id),
        select: event
    )
  end

  @spec chain(Ecto.UUID.t()) :: {:ok, [Event.t()]} | {:error, :promotion_chain_corrupt}
  def chain(root_wave_id) do
    events = Repo.all(from event in Event, where: event.root_wave_id == ^root_wave_id)
    genesis = Enum.filter(events, &is_nil(&1.previous_event_id))
    children = Enum.group_by(events, & &1.previous_event_id)

    with true <- length(genesis) <= 1,
         true <-
           Enum.all?(children, fn {parent, rows} -> is_nil(parent) or length(rows) == 1 end),
         {:ok, chain} <- follow(genesis, children, []) do
      if length(chain) == length(events),
        do: {:ok, chain},
        else: {:error, :promotion_chain_corrupt}
    else
      _ -> {:error, :promotion_chain_corrupt}
    end
  end

  defp follow([], _children, acc), do: {:ok, Enum.reverse(acc)}

  defp follow([event], children, acc) do
    case Map.get(children, event.id, []) do
      [] -> {:ok, Enum.reverse([event | acc])}
      [child] -> follow([child], children, [event | acc])
      _ -> {:error, :promotion_chain_corrupt}
    end
  end
end
