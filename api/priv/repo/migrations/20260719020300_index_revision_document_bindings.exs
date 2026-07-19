defmodule Barkpark.Repo.Migrations.IndexRevisionDocumentBindings do
  use Ecto.Migration

  def change do
    create_if_not_exists index(:revisions, [:document_id])
  end
end
