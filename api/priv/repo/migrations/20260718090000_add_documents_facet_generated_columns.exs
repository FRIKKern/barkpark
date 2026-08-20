defmodule Barkpark.Repo.Migrations.AddDocumentsFacetGeneratedColumns do
  use Ecto.Migration

  @moduledoc """
  search-latency slice b (task-2da0f8ab1580d7d6). Un-poison the slug-ILIKE match
  arm + the author/category facet GROUP BYs by moving the three scalar `content`
  keys the search pipeline touches per keystroke out of the giant `content` jsonb
  and into narrow GENERATED STORED text columns.

  ## Why (measured, guerrilla barkpark_prod 2026-07-18)

  The D55 trgm expression index on `content->>'slug'` does NOT help: the planner
  bitmap-scans `documents_type_dataset_index` (~349 candidates) then
  FILTER-evaluates every OR arm per row; `similarity()` is unindexable so a
  BitmapOr can never form (that index was created CONCURRENTLY, EXPLAIN-verified
  unused, and dropped). The real poison is the per-row DETOAST of the ~88KB
  `content` jsonb that `content->>'slug'` forces on every candidate: +1,501
  buffers per predicate eval (4286 vs 2785 without the slug arm). The author /
  category facet GROUP BYs re-detoast `content` again — and the whole predicate
  is re-evaluated 4-5x per keystroke (retrieve + count + facet GROUP BYs).

  A GENERATED STORED column materializes the scalar at write time into a narrow
  text column that reads WITHOUT touching the TOAST-ed `content`. The expressions
  are copied VERBATIM from the query sites so behavior is identical by
  construction:

    * `slug_text`     = `coalesce(content->>'slug', '')` — exactly the predicate's
      `coalesce(?->>'slug', '')` arm (`documents_retriever` where_match).
    * `author_text`   = `content->>'author'`   — exactly the `author` facet GROUP BY.
    * `category_text` = `content->>'category'`  — exactly the `category` facet GROUP BY.

  No index is added: the win is eliminating the detoast, not the (proven-unusable)
  index — the planner keeps its `documents_type_dataset_index` bitmap scan, now
  filtering a narrow column instead of detoasting jsonb per row.

  ## Prod-safety

  `ADD COLUMN ... GENERATED ALWAYS AS (...) STORED` rewrites the whole table
  (unlike a plain nullable ADD COLUMN, which is metadata-only) — Postgres must
  compute the stored value for every existing row. `documents` is 73MB / ~2.5k
  rows on prod, so the rewrite completes in seconds under the ACCESS EXCLUSIVE
  lock; acceptable. instance-deploy.sh runs `ecto.migrate` on the idle slot
  before the Caddy flip, so this lands automatically on deploy (no manual step).
  Same shape/risk as the existing `search_vector` GENERATED column
  (20260527101000).

  Additive + reversible: `down/0` drops the three columns; `content` is untouched.
  """

  def up do
    execute("""
    ALTER TABLE documents
    ADD COLUMN slug_text text
    GENERATED ALWAYS AS (coalesce(content->>'slug', '')) STORED
    """)

    execute("""
    ALTER TABLE documents
    ADD COLUMN author_text text
    GENERATED ALWAYS AS (content->>'author') STORED
    """)

    execute("""
    ALTER TABLE documents
    ADD COLUMN category_text text
    GENERATED ALWAYS AS (content->>'category') STORED
    """)
  end

  def down do
    execute("ALTER TABLE documents DROP COLUMN IF EXISTS slug_text")
    execute("ALTER TABLE documents DROP COLUMN IF EXISTS author_text")
    execute("ALTER TABLE documents DROP COLUMN IF EXISTS category_text")
  end
end
