defmodule Barkpark.Repo.Migrations.AddRevToRevisions do
  use Ecto.Migration

  @moduledoc """
  [rev-hash-has-no-read] Give the `_rev` hash a read.

  The envelope publishes `"_rev" => doc.rev` on every document read, and
  acceptance criteria cite that hash to name the exact revision they sealed.
  But `revisions` carried no `rev` column, so the hash was structurally
  unresolvable: the only surfaced single-revision read (`get_revision/3`,
  behind `GET /v1/data/revision/:dataset/:id`) keys on the revision row's own
  UUID and rejected a non-UUID outright. A revision a seal cited was neither
  live nor retrievable.

  NULLABLE by necessity: pre-existing history rows never recorded the hash, so
  it cannot be backfilled — those rows stay unresolvable by `_rev` and keep
  working by UUID exactly as before. Only revisions written from here on carry
  it. That limit is stated in `paper_revision_rev_lookup_test.exs` rather than
  papered over. There is NO backfill here, chunked or otherwise: the value a
  backfill would write does not exist anywhere to be read.

  ## Why this migration is only the column

  `ADD COLUMN <name> varchar` with NO default and NO constraint is a
  catalog-only change in PostgreSQL 11+: it takes an ACCESS EXCLUSIVE lock for
  the duration of the catalog write alone, never rewrites the heap, and is safe
  inside the migrator's transaction against a live `revisions` table under load.

  The lookup index is DELIBERATELY NOT here. A plain `CREATE INDEX` on
  `revisions` takes a SHARE lock that blocks every INSERT into the table for the
  whole build — and prod's `barkpark` role carries `statement_timeout = 60s`, so
  on a loaded 2-core box the build is killed mid-flight and takes this
  transaction (and the column with it) down. The index is built CONCURRENTLY in
  the sibling migration `20260902120100_add_revisions_rev_index.exs`, following
  `20260902001000`'s pattern exactly.
  """

  def change do
    alter table(:revisions) do
      add :rev, :string
    end
  end
end
