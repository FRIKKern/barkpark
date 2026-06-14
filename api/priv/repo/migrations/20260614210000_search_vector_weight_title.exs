defmodule Barkpark.Repo.Migrations.SearchVectorWeightTitle do
  use Ecto.Migration

  # Relevance fix: the generated `search_vector` concatenated title + body
  # lexemes with NO weight, so every lexeme defaulted to 'D' and `ts_rank`
  # could not tell a title match from body noise — a query like "fork" ranked
  # a long CLI handbook (which mentions "fork" several times in its body) above
  # the paper literally titled "Fork reconciliation…". Weighting title lexemes
  # 'A' (and body 'D') makes ts_rank's default weights {A:1.0 … D:0.1} put a
  # title hit ~10x a body hit, so the on-topic doc ranks first. Body text stays
  # fully searchable (just lower-weighted). Indx already weights title above
  # body (BM25F), so this only affects the Postgres engine.
  def up do
    execute("DROP INDEX IF EXISTS documents_search_vector_idx")
    execute("ALTER TABLE documents DROP COLUMN IF EXISTS search_vector")

    execute("""
    ALTER TABLE documents
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
      setweight(
        jsonb_to_tsvector('english', coalesce(content, '{}'::jsonb), '["string"]'),
        'D'
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
    GENERATED ALWAYS AS (
      to_tsvector('english', coalesce(title, '')) ||
      jsonb_to_tsvector('english', coalesce(content, '{}'::jsonb), '["string"]')
    ) STORED
    """)

    execute("CREATE INDEX documents_search_vector_idx ON documents USING GIN (search_vector)")
  end
end
