defmodule Barkpark.Repo.Migrations.AddDocumentsGroqPushdownIndexes do
  use Ecto.Migration

  @moduledoc """
  Two GIN indexes on `documents.content` that let the GROQ endpoint answer
  `references()` and field conditions from an index instead of a scan of the
  whole type (task-762bd2e834fa5abe).

      CREATE INDEX CONCURRENTLY documents_content_refs_idx ON documents
        USING GIN ((jsonb_path_query_array(content, 'strict $.** ? (exists(@._ref))._ref')))

      CREATE INDEX CONCURRENTLY documents_content_path_ops_idx ON documents
        USING GIN (content jsonb_path_ops)

  ## documents_content_refs_idx

  The `_ref` value of every object at any depth of `content`, as a JSON array.
  `Barkpark.Groq.DocumentSource` matches `references($id)` with
  `<that expression> ?| ARRAY[$id]`. Postgres uses an expression index only
  when the query repeats the expression exactly, so the fragment in
  `DocumentSource.references_any/1` and the text above must stay identical.
  `jsonb_path_query_array` without a `_tz` suffix is IMMUTABLE, which an index
  expression requires.

  The index is on the document row, so a draft row and a published row are
  indexed separately, in the same transaction as the write that changes them.
  The edges table (`Barkpark.Content.Edges`) is not used: it holds only
  references in fields the schema declares as references, so it misses the
  nested `_ref` values of imported content that `references()` must find.

  ## documents_content_path_ops_idx

  Serves the `content @> {...}` containment probes GROQ already sends for
  `a.b == "x"`, `a in [...]` and now `"x" in a[].b`. Without it such a probe
  narrows only inside a `_type` filter; a query with no `_type`, such as a
  redirect lookup on `slugHistory[].value`, scanned every document.
  `jsonb_path_ops` supports only `@>` and is smaller than the default
  operator class.

  ## Expand only

  Both are additive. CONCURRENTLY builds without an `ACCESS EXCLUSIVE` lock on
  the live `documents` table and cannot run inside a transaction, hence the
  two flags. `down` drops them concurrently.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS documents_content_refs_idx ON documents
      USING GIN ((jsonb_path_query_array(content, 'strict $.** ? (exists(@._ref))._ref')))
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS documents_content_path_ops_idx ON documents
      USING GIN (content jsonb_path_ops)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS documents_content_path_ops_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS documents_content_refs_idx")
  end
end
