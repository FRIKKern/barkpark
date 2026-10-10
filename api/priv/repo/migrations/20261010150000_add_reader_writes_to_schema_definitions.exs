defmodule Barkpark.Repo.Migrations.AddReaderWritesToSchemaDefinitions do
  @moduledoc """
  `reader_writes` on a schema (task-97702b326b8bfd6d): which writes a READ seat
  may make on documents of this type, e.g. a Studio comment type
  `{"create": true, "patchFields": ["state", "resolvedAt", "resolvedBy"]}`.
  NULL (every existing schema) means readers write nothing, as before.
  """
  use Ecto.Migration

  def change do
    alter table(:schema_definitions) do
      add :reader_writes, :map
    end
  end
end
