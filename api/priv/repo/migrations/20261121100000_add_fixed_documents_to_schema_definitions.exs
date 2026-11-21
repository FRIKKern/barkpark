defmodule Barkpark.Repo.Migrations.AddFixedDocumentsToSchemaDefinitions do
  @moduledoc """
  `fixed_documents` on a schema (task-f4c80d82cc25b19b): the ids of a type's
  fixed set of documents. No new document of the type may be created and a
  listed one may not be deleted (`Barkpark.Content.FixedDocuments`). NULL
  (every existing schema) is today's behaviour. Additive and nullable: no
  backfill, no default, no rewrite of existing rows. `change` reverses to a
  column drop.
  """
  use Ecto.Migration

  def change do
    alter table(:schema_definitions) do
      add :fixed_documents, {:array, :string}
    end
  end
end
