defmodule Barkpark.Content.Revision do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "revisions" do
    field :doc_id, :string
    field :type, :string
    field :dataset, :string, default: "production"
    field :title, :string
    field :status, :string
    field :content, :map
    field :action, :string

    belongs_to :workspace, Barkpark.Tenancy.Workspace, type: :binary_id
    belongs_to :project, Barkpark.Tenancy.Project, type: :binary_id

    # W2 additive seam. `:dataset_entity` — the legacy `dataset` STRING field
    # still owns `:dataset` (dual presence). FK column is `dataset_id`.
    belongs_to :dataset_entity, Barkpark.Tenancy.Dataset,
      foreign_key: :dataset_id,
      type: :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [
      :doc_id,
      :type,
      :dataset,
      :dataset_id,
      :title,
      :status,
      :content,
      :action,
      :workspace_id,
      :project_id
    ])
    |> validate_required([:doc_id, :type, :action])
  end
end
