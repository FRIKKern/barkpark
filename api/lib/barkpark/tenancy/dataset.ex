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

  # Deliberately WIDER than the Workspace/Project sibling format by one
  # character: `_`. A dataset slug is not admin-authored like those — it is
  # auto-created from the free-form `dataset` STRING on the first write that
  # names it (Content.WriteScope.resolve_dataset_id_for_write/2), and
  # underscored dataset strings are in active use. Matching the siblings
  # exactly would not refuse such a write; it would silently degrade it to
  # `dataset_id: NULL` (the resolver swallows a changeset error), pushing the
  # row onto the NULL-dataset_id partial unique index. This class matches the
  # dataset-slug guard already in FinderLive.
  @slug_format ~r/^[a-z0-9][a-z0-9_-]*$/

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
    |> validate_format(:slug, @slug_format,
      message: "must be lowercase alphanumeric with hyphens or underscores"
    )
    |> assoc_constraint(:project)
    |> unique_constraint([:slug, :project_id],
      name: :datasets_project_id_slug_index,
      message: "already exists in this project"
    )
  end
end
