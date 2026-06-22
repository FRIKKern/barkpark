defmodule Barkpark.Tenancy.Dataset do
  @moduledoc """
  Wave-2: a Dataset is a first-class entity living under exactly one Project
  (the layer below Workspace -> Project). It promotes the plain `dataset`
  STRING that every content table carries ("production" default) into a
  row. Slug is unique within its Project.

  Additive seam only: the `dataset` string stays authoritative for reads and
  uniqueness; `dataset_id` rides alongside until later W2 steps flip over.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "datasets" do
    field :slug, :string
    field :name, :string

    belongs_to :project, Barkpark.Tenancy.Project

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(dataset, attrs) do
    dataset
    |> cast(attrs, [:slug, :name, :project_id])
    |> validate_required([:slug, :name, :project_id])
    |> validate_length(:slug, min: 1, max: 63)
    |> validate_length(:name, min: 1, max: 255)
    |> assoc_constraint(:project)
    |> unique_constraint([:slug, :project_id],
      name: :datasets_project_id_slug_index,
      message: "already exists in this project"
    )
  end
end
