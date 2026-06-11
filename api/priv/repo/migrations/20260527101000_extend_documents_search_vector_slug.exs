defmodule Barkpark.Repo.Migrations.ExtendDocumentsSearchVectorSlug do
  use Ecto.Migration

  def up do
    execute("DROP INDEX IF EXISTS documents_search_vector_idx")
    execute("ALTER TABLE documents DROP COLUMN IF EXISTS search_vector")

    execute("""
    ALTER TABLE documents
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      to_tsvector(
        'english',
        coalesce(title, '') || ' ' || coalesce(content->>'slug', '')
      )
    ) STORED
    """)

    execute("CREATE INDEX documents_search_vector_idx ON documents USING GIN (search_vector)")
  end

  def down do
    execute("DROP INDEX IF EXISTS documents_search_vector_idx")
    execute("ALTER TABLE documents DROP COLUMN IF EXISTS search_vector")

    execute("""
    ALTER TABLE documents
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (to_tsvector('english', coalesce(title, ''))) STORED
    """)

    execute("CREATE INDEX documents_search_vector_idx ON documents USING GIN (search_vector)")
  end
end
