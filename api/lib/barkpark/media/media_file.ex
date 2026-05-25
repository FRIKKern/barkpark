defmodule Barkpark.Media.MediaFile do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "media_files" do
    field :filename, :string
    field :original_name, :string
    field :path, :string
    field :mime_type, :string
    field :size, :integer
    field :dataset, :string, default: "production"

    belongs_to :workspace, Barkpark.Tenancy.Workspace, type: :binary_id
    belongs_to :project, Barkpark.Tenancy.Project, type: :binary_id

    # W2 additive seam. `:dataset_entity` — the legacy `dataset` STRING field
    # still owns `:dataset` (dual presence). FK column is `dataset_id`.
    belongs_to :dataset_entity, Barkpark.Tenancy.Dataset,
      foreign_key: :dataset_id,
      type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(media_file, attrs) do
    media_file
    |> cast(attrs, [
      :filename,
      :original_name,
      :path,
      :mime_type,
      :size,
      :dataset,
      :workspace_id,
      :project_id,
      :dataset_id
    ])
    |> validate_required([:filename, :original_name, :path])
    # W2 uniqueness flip: blob identity is now (path, dataset_id). The `dataset`
    # STRING constraint is dropped at the DB level; the string stays as a mirror.
    |> unique_constraint([:path, :dataset_id],
      name: :media_files_path_dataset_id_index
    )
  end
end
