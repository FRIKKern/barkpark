defmodule Barkpark.CycleFleet.ReleaseGate do
  @moduledoc "Immutable two-stage release admissions and server-owned reader captures."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cycle_release_gate_admissions" do
    field :stage, :string
    field :root_wave_id, :binary_id
    field :parent_wave_id, :binary_id
    field :target_wave_id, :binary_id
    field :reserved_target_revision, :binary_id
    field :workspace_id, :binary_id
    field :project_id, :binary_id
    field :epic_id, :string
    field :target_wave_key, :string
    field :idempotency_key, :string
    field :challenge_id, :binary_id
    field :evidence_bundle, :map
    field :receipt, :map
    field :bundle_digest, :string
    field :receipt_digest, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(attrs) do
    required =
      ~w(stage root_wave_id parent_wave_id reserved_target_revision workspace_id project_id epic_id target_wave_key idempotency_key evidence_bundle receipt bundle_digest receipt_digest)a

    %__MODULE__{}
    |> cast(attrs, required ++ [:target_wave_id, :challenge_id])
    |> validate_required(required)
    |> validate_inclusion(:stage, ~w(open activate))
    |> validate_format(:bundle_digest, ~r/^[0-9a-f]{64}$/)
    |> validate_format(:receipt_digest, ~r/^[0-9a-f]{64}$/)
    |> unique_constraint([:root_wave_id, :stage, :idempotency_key],
      name: :cycle_release_gate_admissions_replay_index
    )
  end

  defmodule Challenge do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    schema "cycle_release_gate_challenges" do
      field :target_wave_id, :binary_id
      field :workspace_id, :binary_id
      field :project_id, :binary_id
      field :epic_id, :string
      field :nonce, :string
      field :request, :map
      field :request_digest, :string
      field :claimed_at, :utc_datetime_usec
      field :completed_at, :utc_datetime_usec
      field :failed_at, :utc_datetime_usec
      field :failure, :string
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    def changeset(attrs) do
      %__MODULE__{}
      |> cast(
        attrs,
        ~w(target_wave_id workspace_id project_id epic_id nonce request request_digest)a
      )
      |> validate_required(
        ~w(target_wave_id workspace_id project_id epic_id nonce request request_digest)a
      )
      |> validate_format(:request_digest, ~r/^[0-9a-f]{64}$/)
    end
  end

  defmodule PaperCandidate do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    schema "cycle_release_paper_candidates" do
      field :target_wave_id, :binary_id
      field :role, :string
      field :document_id, :binary_id
      field :doc_id, :string
      field :base_document_rev, :string
      field :base_current_revision_id, :binary_id
      field :base_released_revision_id, :binary_id
      field :title, :string
      field :status, :string
      field :content, :map
      field :content_digest, :string
      field :source_digest, :string
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    def changeset(attrs) do
      required =
        ~w(target_wave_id role document_id doc_id base_document_rev base_current_revision_id base_released_revision_id title status content content_digest source_digest)a

      %__MODULE__{}
      |> cast(attrs, required)
      |> validate_required(required)
      |> validate_inclusion(:role, ~w(campaign successor))
      |> validate_inclusion(:status, ~w(published))
      |> validate_format(:content_digest, ~r/^[0-9a-f]{64}$/)
      |> validate_format(:source_digest, ~r/^[0-9a-f]{64}$/)
      |> unique_constraint([:target_wave_id, :role])
    end
  end

  defmodule Capture do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id

    schema "cycle_release_gate_captures" do
      field :challenge_id, :binary_id
      field :name, :string
      field :producer, :string
      field :raw_bytes, :binary
      field :byte_count, :integer
      field :content_digest, :string
      field :provenance, :map
      field :provenance_digest, :string
      field :verdict, :map
      field :verdict_digest, :string
      field :server_signature, :string
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    def changeset(attrs) do
      required =
        ~w(challenge_id name producer raw_bytes byte_count content_digest provenance provenance_digest verdict verdict_digest server_signature)a

      %__MODULE__{}
      |> cast(attrs, required)
      |> validate_required(required)
      |> validate_number(:byte_count, greater_than: 0, less_than_or_equal_to: 4_194_304)
      |> validate_format(:content_digest, ~r/^[0-9a-f]{64}$/)
      |> validate_format(:provenance_digest, ~r/^[0-9a-f]{64}$/)
      |> validate_format(:verdict_digest, ~r/^[0-9a-f]{64}$/)
      |> validate_format(:server_signature, ~r/^[0-9a-f]{64}$/)
      |> unique_constraint([:challenge_id, :name])
    end
  end

  defmodule Consumption do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    schema "cycle_release_gate_consumptions" do
      field :admission_id, :binary_id, primary_key: true
      field :wave_id, :binary_id
      field :kind, :string
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    def changeset(attrs) do
      %__MODULE__{}
      |> cast(attrs, ~w(admission_id wave_id kind)a)
      |> validate_required(~w(admission_id wave_id kind)a)
      |> validate_inclusion(:kind, ~w(open activate))
    end
  end
end
