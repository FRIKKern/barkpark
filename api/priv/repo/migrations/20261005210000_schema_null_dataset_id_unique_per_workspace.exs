defmodule Barkpark.Repo.Migrations.SchemaNullDatasetIdUniquePerWorkspace do
  use Ecto.Migration

  @moduledoc """
  Split the NULL-dataset_id schema uniqueness index by owner
  (task-be5eaec4a5b9e524).

  `20260704120000` made `(name, dataset)` unique across EVERY row whose
  `dataset_id` is NULL, whoever owns it. A workspace with no project writes its
  schemas with a NULL `dataset_id`, so two such workspaces could not both hold
  a `post`, and once plugin schemas install as shared rows (`workspace_id`
  NULL, `dataset_id` NULL) no such workspace could hold a schema with a plugin
  type's name either.

  Two indexes replace it:

    * shared rows (`workspace_id IS NULL`): `(name, dataset)` stays unique, under
      the same index name, so the flat-deployment guarantee and the changeset's
      `unique_constraint` are unchanged;
    * workspace rows: `(workspace_id, name, dataset)` is unique, so each
      workspace keeps one row per name.

  Both are narrower than the old index, so no existing data can fail the build.
  `down` restores the old index and fails if two owners now share a name.
  """

  def up do
    drop_if_exists unique_index(:schema_definitions, [:name, :dataset],
                     name: :schema_definitions_name_dataset_null_dataset_id_index
                   )

    create unique_index(:schema_definitions, [:name, :dataset],
             where: "dataset_id IS NULL AND workspace_id IS NULL",
             name: :schema_definitions_name_dataset_null_dataset_id_index
           )

    create unique_index(:schema_definitions, [:workspace_id, :name, :dataset],
             where: "dataset_id IS NULL AND workspace_id IS NOT NULL",
             name: :schema_definitions_ws_name_dataset_null_dataset_id_index
           )
  end

  def down do
    drop_if_exists unique_index(:schema_definitions, [:workspace_id, :name, :dataset],
                     name: :schema_definitions_ws_name_dataset_null_dataset_id_index
                   )

    drop_if_exists unique_index(:schema_definitions, [:name, :dataset],
                     name: :schema_definitions_name_dataset_null_dataset_id_index
                   )

    create unique_index(:schema_definitions, [:name, :dataset],
             where: "dataset_id IS NULL",
             name: :schema_definitions_name_dataset_null_dataset_id_index
           )
  end
end
