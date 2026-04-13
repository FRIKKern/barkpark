defmodule Barkpark.Repo.Migrations.AddRevToDocuments do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS pgcrypto", "DROP EXTENSION IF EXISTS pgcrypto"

    alter table(:documents) do
      add :rev, :text
    end

    create index(:documents, [:rev])

    # Backfill existing rows with a ULID each
    execute(
      fn ->
        repo().query!(
          "UPDATE documents SET rev = encode(gen_random_bytes(16), 'hex') WHERE rev IS NULL"
        )
      end,
      fn -> :ok end
    )

    alter table(:documents) do
      modify :rev, :text, null: false
    end
  end
end
