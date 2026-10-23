defmodule Barkpark.Repo.Migrations.AddDocumentsContentRefsTrgmIndex do
  use Ecto.Migration

  @moduledoc """
  A trigram index over the text of the `_ref` values in `documents.content`,
  so `contains` on an array of references reads an index instead of every
  document of the type.

      CREATE INDEX CONCURRENTLY documents_content_refs_trgm_idx ON documents
        USING GIN ((jsonb_path_query_array(content, 'strict $.** ? (exists(@._ref))._ref')::text)
        gin_trgm_ops) WITH (gin_pending_list_limit = 128)

  ## The gap

  `filter[bokbasen.themaCodes][contains]=thema.LBB` keeps a product holding a
  reference whose id contains `thema.LBB`. The test reads each product's
  `content`, which Postgres decompresses row by row: on the gyldendal-no
  catalogue (18,000 products) it took 0.9 s warm and 6 to 7 s cold to keep 42.

  ## The expression

  The `_ref` of every object at any depth of `content` as a JSON array, the
  expression of `documents_content_refs_idx`, cast to text. A reference id
  that contains a text appears in that JSON text, so
  `Barkpark.Content.Query` tests `<expression> ILIKE '%text%'` before reading
  the field, and this index answers it. The query repeats the expression word
  for word, because Postgres uses an expression index only for the same
  expression. `jsonb_path_query_array` without `_tz` and the jsonb-to-text
  cast are IMMUTABLE.

  ## Size

  Over 18,000 synthetic products with one to five references each and 30,000
  other documents, the index measured 1.1 MB, against 2.6 MB for
  `documents_content_refs_idx` and 72 MB for `documents_content_path_idx`. It
  holds only reference ids, so it is built without the disk check the refs
  index carries.

  The pending list is bounded at 128 kB from the start, for the reason
  `20261019150100_bound_documents_gin_pending_lists.exs` gives: every scan
  reads the whole list.

  ## Expand only

  The index is additive; `contains` stays correct without it. CONCURRENTLY
  builds without an `ACCESS EXCLUSIVE` lock on the live `documents` table and
  cannot run inside a transaction, hence the two flags. `pg_trgm` exists since
  `20260526181000_add_documents_search_vector.exs`. A failed concurrent build
  leaves an INVALID index that `IF NOT EXISTS` will not replace; drop it with
  `DROP INDEX CONCURRENTLY documents_content_refs_trgm_idx` and run the
  statement again.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS documents_content_refs_trgm_idx ON documents
      USING GIN ((jsonb_path_query_array(content, 'strict $.** ? (exists(@._ref))._ref')::text)
      gin_trgm_ops) WITH (gin_pending_list_limit = 128)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS documents_content_refs_trgm_idx")
  end
end
