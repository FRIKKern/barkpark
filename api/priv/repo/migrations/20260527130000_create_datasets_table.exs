defmodule Barkpark.Repo.Migrations.CreateDatasetsTable do
  use Ecto.Migration

  @moduledoc """
  Wave-2 foundation (additive seam only): promote the `dataset` STRING to a
  first-class entity. A Dataset belongs to a Project (the layer below
  Workspace -> Project added in Wave 1). Slug is unique within its Project.

  This migration ONLY creates the table. Seeding (one row per distinct
  existing dataset string under the Default project) and the nullable
  `dataset_id` FK columns + backfill land in the sibling migrations
  20260527131000 / 20260527132000. The `dataset` string stays authoritative
  for now — `dataset_id` is added alongside (dual presence), no uniqueness
  flips, no query rewrites, no column drops.
  """
  def change do
    create table(:datasets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id,
          references(:projects, type: :binary_id, on_delete: :delete_all),
          null: false

      add :slug, :string, null: false
      add :name, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:datasets, [:project_id, :slug])
  end
end
