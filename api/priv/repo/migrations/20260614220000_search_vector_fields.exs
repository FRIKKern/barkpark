defmodule Barkpark.Repo.Migrations.SearchVectorFields do
  use Ecto.Migration

  # Relevance fix (field weighting): the prior generated `search_vector`
  # weighted title 'A' and everything else (body, author, category, slug — all
  # folded in via jsonb_to_tsvector) 'D'. That made an author/category name only
  # *findable*, never *rankable* — searching an author's name ranked any doc that
  # merely mentions them above the docs they actually wrote. This BOOSTS the
  # high-signal structured fields out of the 'D' body bucket:
  #
  #   title           → 'A'  (unchanged, top weight)
  #   content.author  → 'B'  (boosted from the 'D' body bucket)
  #   content.category→ 'B'  (boosted from the 'D' body bucket)
  #   content.slug    → 'C'  ('simple' config — the english stemmer mangles
  #                           hyphenated slugs; 'simple' keeps them intact)
  #   body strings    → 'D'  (jsonb_to_tsvector, unchanged low weight)
  #
  # ts_rank's default weights {A:1.0, B:0.4, C:0.2, D:0.1} now let an author or
  # category name rank well, not merely match. Postgres engine only — Indx
  # already weights structured fields via BM25F.
  def up do
    execute("DROP INDEX IF EXISTS documents_search_vector_idx")
    execute("ALTER TABLE documents DROP COLUMN IF EXISTS search_vector")

    execute("""
    ALTER TABLE documents
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
      setweight(to_tsvector('english', coalesce(content->>'author', '')), 'B') ||
      setweight(to_tsvector('english', coalesce(content->>'category', '')), 'B') ||
      setweight(to_tsvector('simple', coalesce(content->>'slug', '')), 'C') ||
      setweight(
        jsonb_to_tsvector('english', coalesce(content, '{}'::jsonb), '["string"]'),
        'D'
      )
    ) STORED
    """)

    execute("CREATE INDEX documents_search_vector_idx ON documents USING GIN (search_vector)")
  end

  # Revert to the 20260614210000 expression (title 'A' / body 'D').
  def down do
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
end
