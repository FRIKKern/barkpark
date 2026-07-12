defmodule Barkpark.Repo.Migrations.AddDocumentsMainTagIndex do
  use Ecto.Migration

  @moduledoc """
  btree expression index for `filter[main_tag]` equality (authoring-excellence
  D7/D20).

  `main_tag` is denormalized onto `content` at the publish chokepoint (and
  backfilled by 20260712120000) precisely so the filter can be an INDEXED
  text equality. The public wire `filter[main_tag]=<tag>` rides the generic
  eq op (`content->>'main_tag' = ?` — `Content.Query.apply_field_op/4`, zero
  new operators), and a btree on the SAME expression serves it:

      CREATE INDEX ... ON documents ((content->>'main_tag'))

  A jsonb argmax predicate over `tags` was rejected (charter D7): the
  existing `jsonb_path_ops` GIN (20260702130000) serves containment only, so
  every argmax read would seq-scan.

  ## Concurrency

  `CREATE INDEX CONCURRENTLY` (and the matching concurrent `DROP` in `down`)
  builds without an `ACCESS EXCLUSIVE` lock on the live `documents` table.
  CONCURRENTLY cannot run inside a transaction, so this migration sets
  `@disable_ddl_transaction true` and `@disable_migration_lock true` (the
  migration lock would otherwise re-open a transaction around the statement).
  Purely additive, fully reversible — same template as 20260702130000.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS documents_content_main_tag_idx
      ON documents ((content->>'main_tag'))
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS documents_content_main_tag_idx")
  end
end
