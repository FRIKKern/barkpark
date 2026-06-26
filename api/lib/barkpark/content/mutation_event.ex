defmodule Barkpark.Content.MutationEvent do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "mutation_events" do
    field :dataset, :string
    field :type, :string
    field :doc_id, :string
    field :mutation, :string
    field :rev, :string
    field :previous_rev, :string
    field :document, :map

    # Origin tag (P2 push). Local writes carry "api"/"studio"/"cli"/"worker";
    # PULL-applied writes carry "sync" so the push outbox EXCLUDES them
    # (echo-suppression — a pulled mutation must never be pushed back).
    field :source, :string, default: "api"

    belongs_to :workspace, Barkpark.Tenancy.Workspace, type: :binary_id
    belongs_to :project, Barkpark.Tenancy.Project, type: :binary_id

    # W2 additive seam. `:dataset_entity` — the legacy `dataset` STRING field
    # still owns `:dataset` (dual presence). FK column is `dataset_id`.
    belongs_to :dataset_entity, Barkpark.Tenancy.Dataset,
      foreign_key: :dataset_id,
      type: :binary_id

    field :inserted_at, :utc_datetime_usec
  end
end
