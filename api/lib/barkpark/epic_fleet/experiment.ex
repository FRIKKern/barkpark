defmodule Barkpark.EpicFleet.Experiment do
  @moduledoc "Append-only manifest for one Epic or Legendary benchmark experiment."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @phases ~w(epic legendary)
  @artifact_formats ~w(barkpark-epic-benchmark-v1 barkpark-epic-benchmark-v2)
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
    field :artifact_format, :string, default: "barkpark-epic-benchmark-v1"
    field :retrieval_attribution, :map
    field :retrieval_attribution_digest, :string
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
      :manifest_digest,
      :artifact_format,
      :retrieval_attribution,
      :retrieval_attribution_digest
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
    |> validate_inclusion(:artifact_format, @artifact_formats)
    |> validate_format(:retrieval_attribution_digest, @digest_format)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint([:workspace_id, :epic_id, :wave_id, :experiment_id],
      name: :epic_benchmark_experiments_scope_id_index
    )
    |> check_constraint(:phase, name: :epic_benchmark_experiments_phase)
    |> check_constraint(:protocol_version,
      name: :epic_benchmark_experiments_protocol_version
    )
    |> check_constraint(:manifest_digest, name: :epic_benchmark_experiments_manifest_digest)
    |> check_constraint(:artifact_format,
      name: :epic_benchmark_experiments_artifact_format
    )
    |> check_constraint(:retrieval_attribution,
      name: :epic_benchmark_experiments_retrieval_attribution
    )
  end

  @doc "The supported experiment phase vocabulary."
  @spec phases() :: [String.t()]
  def phases, do: @phases

  @doc "The byte-level benchmark artifact formats."
  @spec artifact_formats() :: [String.t()]
  def artifact_formats, do: @artifact_formats
end
