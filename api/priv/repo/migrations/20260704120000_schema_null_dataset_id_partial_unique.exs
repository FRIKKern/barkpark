defmodule Barkpark.Repo.Migrations.SchemaNullDatasetIdPartialUnique do
  use Ecto.Migration

  @moduledoc """
  LOW fix (drafts.loop-low-schema-null-dataset-race): close the schema
  uniqueness hole for rows whose `dataset_id` is NULL.

  ## The hole

  The W2 flip (`20260527134000`) made `(name, dataset_id)` the schema-uniqueness
  key. But `dataset_id` is only stamped when a write resolves a `project_id`
  (`Barkpark.Content.WriteScope.resolve_dataset_id_for_write/2` returns nil
  otherwise). In a FLAT deployment — no tenancy, plugins off — no project
  resolves, so EVERY `schema_definitions` row carries `dataset_id IS NULL`.

  Postgres treats each NULL as DISTINCT in a unique index, so
  `schema_definitions_name_dataset_id_index` gives ZERO protection to those
  rows: two schemas with the same `name` and NULL `dataset_id` both satisfy it.
  `Barkpark.Content.Schema.upsert_schema/3` is a read-then-write (get_schema →
  insert-or-update) with no DB backstop, so two concurrent creates of the same
  schema name both miss the read and both insert → duplicate `post` schemas.

  ## The fix

  A PARTIAL unique index keyed on the `dataset` STRING mirror, scoped to exactly
  the rows the `dataset_id` index cannot cover:

      CREATE UNIQUE INDEX ... ON schema_definitions (name, dataset)
      WHERE dataset_id IS NULL

  This restores the pre-flip `(name, dataset)` guarantee for NULL-dataset_id
  rows WITHOUT re-globalising it: the two indexes are complementary (one covers
  `dataset_id IS NOT NULL` by id, this covers `dataset_id IS NULL` by string),
  and keying on the `dataset` STRING keeps two legitimately-distinct datasets
  (e.g. "post" in `production` vs `test`, both id-less) from colliding.

  The `SchemaDefinition` changeset gains a matching `unique_constraint` so a
  racing insert maps to `{:error, changeset}` (422) instead of raising
  `Ecto.ConstraintError` (500).

  ## Existing duplicates

  If two NULL-dataset_id rows already share `(name, dataset)` the CREATE would
  fail. `20260527133000` already collapsed byte-identical NULL-dataset dupes;
  any surviving pair is a genuine conflict an orchestrator must resolve. This
  migration surfaces it (index build raises) rather than papering over it.

  ## Concurrency note

  In PRODUCTION this would run `CREATE UNIQUE INDEX CONCURRENTLY` under
  `@disable_ddl_transaction true`. For test/dev the plain in-transaction build
  is used (small data, no live traffic) — mirroring `20260527134000`.
  """

  def up do
    create unique_index(:schema_definitions, [:name, :dataset],
             where: "dataset_id IS NULL",
             name: :schema_definitions_name_dataset_null_dataset_id_index
           )
  end

  def down do
    drop_if_exists unique_index(:schema_definitions, [:name, :dataset],
                     where: "dataset_id IS NULL",
                     name: :schema_definitions_name_dataset_null_dataset_id_index
                   )
  end
end
