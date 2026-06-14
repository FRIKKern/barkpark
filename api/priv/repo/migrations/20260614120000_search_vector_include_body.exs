defmodule Barkpark.Repo.Migrations.SearchVectorIncludeBody do
  use Ecto.Migration

  # Bring the Postgres engine to parity with Indx's `body` field: the generated
  # `search_vector` covered only `title` + `content->>'slug'`, so Postgres
  # full-text search missed paper/post body content. `jsonb_to_tsvector(…,
  # '["string"]')` extracts every string value from the content JSONB (block
  # bodies included), so body text becomes searchable. Title stays as its own
  # to_tsvector so title weighting/behaviour is unchanged.
  def up do
    execute("DROP INDEX IF EXISTS documents_search_vector_idx")
    execute("ALTER TABLE documents DROP COLUMN IF EXISTS search_vector")

    execute("""
    ALTER TABLE documents
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      to_tsvector('english', coalesce(title, '')) ||
      jsonb_to_tsvector('english', coalesce(content, '{}'::jsonb), '["string"]')
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
    GENERATED ALWAYS AS (
      to_tsvector(
        'english',
        coalesce(title, '') || ' ' || coalesce(content->>'slug', '')
      )
    ) STORED
    """)

    execute("CREATE INDEX documents_search_vector_idx ON documents USING GIN (search_vector)")
  end
end
