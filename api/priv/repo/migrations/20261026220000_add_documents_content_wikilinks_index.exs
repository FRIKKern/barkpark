defmodule Barkpark.Repo.Migrations.AddDocumentsContentWikilinksIndex do
  use Ecto.Migration

  @moduledoc """
  A GIN index over the ids a PortableDoc wikilink names, so GROQ
  `references()` finds a body link through an index instead of a jsonpath
  walk over every document of the type (task-b1eb62967525ad1b; design:
  /papers/references-body-links-design).

      CREATE INDEX CONCURRENTLY documents_content_wikilinks_idx ON documents
        USING GIN ((jsonb_path_query_array(content,
          'strict $.** ? (@.type == "wikilink").keyvalue() ? (@.key == "docId" || @.key == "target").value')))
        WITH (gin_pending_list_limit = 128)

  ## The gap

  Sanity counts a link inside Portable Text (a markDef's `_ref`) for
  `references()`. Barkpark stores a body link as `{type: "wikilink", docId,
  target}`, which `documents_content_refs_idx` (the `_ref` expression) does
  not see. The jsonpath probe that closed the gap without an index scanned
  every row of the type: on 10k posts with 3.7 kB bodies, 139 ms for one
  lookup (Seq Scan), and run-perf's gate measured p95 380 to 680 ms against a
  100 ms budget.

  ## The expression

  The `docId` and `target` of every wikilink at any depth of `content`, as a
  JSON array. `Barkpark.Groq.DocumentSource` repeats it word for word,
  because Postgres uses an expression index only for the same expression.
  `jsonb_path_query_array` without `_tz` is IMMUTABLE. The index matches a
  wikilink in any field; the evaluator then re-checks `references()` on the
  document the caller may read, so a link in a field the caller cannot read
  never counts.

  ## Measured (local, 10k posts, 4% linking)

  Built in 171 ms (about 17 µs a row), 40 kB for 400 links. A typed lookup
  is a Bitmap Index Scan in 0.10 ms; OR-ed with the `_ref` arm it is a
  BitmapOr of the two indexes in 0.13 ms. A 1,112-row UPDATE took 625 ms with
  the index and 682 ms without, inside run-to-run noise.

  ## Expand only

  Additive: `references()` stays correct without it, only slower.
  CONCURRENTLY builds without an `ACCESS EXCLUSIVE` lock on the live
  `documents` table and cannot run inside a transaction, hence the two flags.
  The pending list is bounded at 128 kB, as
  `20261019150100_bound_documents_gin_pending_lists.exs` explains. A failed
  concurrent build leaves an INVALID index that `IF NOT EXISTS` will not
  replace; drop it with `DROP INDEX CONCURRENTLY
  documents_content_wikilinks_idx` and run the statement again.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS documents_content_wikilinks_idx ON documents
      USING GIN ((jsonb_path_query_array(content, 'strict $.** ? (@.type == "wikilink").keyvalue() ? (@.key == "docId" || @.key == "target").value')))
      WITH (gin_pending_list_limit = 128)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS documents_content_wikilinks_idx")
  end
end
