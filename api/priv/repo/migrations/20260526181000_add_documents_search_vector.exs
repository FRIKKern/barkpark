defmodule Barkpark.Repo.Migrations.AddDocumentsSearchVector do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    execute("""
    ALTER TABLE documents
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (to_tsvector('english', coalesce(title, ''))) STORED
    """)

    execute(
      "CREATE INDEX documents_search_vector_idx ON documents USING GIN (search_vector)",
      "DROP INDEX IF EXISTS documents_search_vector_idx"
    )

    execute(
      "CREATE INDEX documents_title_trgm_idx ON documents USING GIN (title gin_trgm_ops)",
      "DROP INDEX IF EXISTS documents_title_trgm_idx"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS documents_title_trgm_idx")
    execute("DROP INDEX IF EXISTS documents_search_vector_idx")
    execute("ALTER TABLE documents DROP COLUMN IF EXISTS search_vector")
  end
end
