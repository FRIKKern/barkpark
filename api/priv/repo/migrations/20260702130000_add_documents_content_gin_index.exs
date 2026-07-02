defmodule Barkpark.Repo.Migrations.AddDocumentsContentGinIndex do
  use Ecto.Migration

  @moduledoc """
  GIN index on `documents.content` to serve the sheet write-through's JSONB
  containment probe (barkpark — sheets write-amplification / writethrough-gin).

  ## The gap

  `Barkpark.Content.Sheets.sheet_embed_targets/2` (content/sheets.ex ~80-102)
  finds every paper embedding a given sheet with a containment WHERE:

      where:
        fragment("? @> ?", d.content, ^embed_a) or
          fragment("? @> ?", d.content, ^embed_b)

  where each `embed` is `%{"blocks" => [%{"type" => "sheet", "ref" => id}]}`.
  This runs on EVERY debounced persist of an actively-edited sheet
  (`Sheets.Session` flushes every 2s of typing or 25 ops, plus on terminate) —
  see `refresh_sheet_embeds`. Before this migration the ONLY GIN indexes on
  `documents` were on `search_vector` and `title` (20260526181000); nothing
  covered `content`, so the `@>` probe was a SEQUENTIAL SCAN over every
  document row, on every flush, scaling with total document count.

  ## The fix — GIN with the `jsonb_path_ops` operator class

      CREATE INDEX CONCURRENTLY documents_content_path_idx
        ON documents USING GIN (content jsonb_path_ops)

  ### Why `jsonb_path_ops` and not the default `jsonb_ops`

  The query does ONLY containment (`@>`). `jsonb_path_ops` supports `@>`
  natively and is the operator class purpose-built for it: it hashes whole
  key→value *paths* into single index entries, so the index is materially
  smaller and its `@>` lookups are faster than the default `jsonb_ops` (which
  indexes every key and every value separately to also serve `?`/`?|`/`?&`
  key-existence — operators this query never uses). The tradeoff is that
  `jsonb_path_ops` cannot serve those key-existence operators; we don't need
  them here, so it is strictly the better fit. If a future query needs
  key-existence on `content`, add a separate `jsonb_ops` index rather than
  widening this one.

  ### Plan flip (verified on a seeded dev DB)

  `EXPLAIN` on `sheet_embed_targets`' shape goes from `Seq Scan on documents`
  (filter: content @> …) to a `Bitmap Index Scan on documents_content_path_idx`
  under a `Bitmap Heap Scan`. No application-code change — the query at
  content/sheets.ex is untouched; the planner simply picks the new index.

  ## Concurrency

  `CREATE INDEX CONCURRENTLY` (and the matching concurrent `DROP` in `down`)
  builds the index without an `ACCESS EXCLUSIVE` lock on the live, large
  `documents` table. CONCURRENTLY cannot run inside a transaction, so this
  migration sets `@disable_ddl_transaction true` and `@disable_migration_lock
  true` (the migration lock would otherwise re-open a transaction around the
  statement). Purely additive, fully reversible.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS documents_content_path_idx
      ON documents USING GIN (content jsonb_path_ops)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS documents_content_path_idx")
  end
end
