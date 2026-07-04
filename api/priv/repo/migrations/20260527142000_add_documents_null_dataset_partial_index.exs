defmodule Barkpark.Repo.Migrations.AddDocumentsNullDatasetPartialIndex do
  use Ecto.Migration

  @moduledoc """
  Partial index for the NULL-`dataset_id` LEGACY arm of the W2 NULL-tolerant
  read scope (barkpark-1u0b / finder-perf P3). Complements — does not duplicate —
  the m9b4 composite (20260527141000).

  ## The gap m9b4 left

  `Barkpark.Content.Query.scope_to_dataset/3` builds an OR scope:

      d.dataset_id == ^id
      or (is_nil(d.dataset_id) and d.dataset == ^dataset)   # the LEGACY arm

  woven into `Barkpark.Content.Query.list_documents/3`'s envelope:

      where d.type == ^type
      and  (<the OR above>)
      and  d.workspace_id == ^workspace_id
      [and d.project_id == ^project_id]

  Postgres plans an OR across two columns as a BitmapOr of two index paths. The
  m9b4 composite `(workspace_id, project_id, type, dataset_id)` serves the
  DOMINANT `dataset_id == ^id` arm. The LEGACY arm —
  `is_nil(dataset_id) and dataset == ^dataset` — has NO supporting index since
  the Wave-2 flip (20260527134000) DROPPED the old `(type, dataset)` STRING
  btree. So that arm filter-scans for the rows that are still NULL.

  Once the backfill (20260527132000) + W2 dual-write have stamped most rows the
  LEGACY arm matches ~nothing — but the planner must still establish that for
  the NULL set, and pays scan breadth proportional to however many rows remain
  NULL (workspace-only writes, pre-tenancy fixtures, non-Default-project rows
  the backfill skipped).

  ## The fix — a PARTIAL index, not a second full one

      create index(:documents, [:type, :dataset], where: "dataset_id IS NULL")

  ### Why partial (`WHERE dataset_id IS NULL`)

  The index physically holds ONLY the NULL-`dataset_id` rows — the shrinking
  legacy set. It costs nothing on the dominant non-NULL rows (no entries, no
  write amplification for them) and stays tiny as the backfill drains the NULL
  set. A full second `(type, dataset)` btree on ALL rows would re-add exactly
  the index the flip deliberately dropped — wasteful, since the non-NULL rows
  are already served by m9b4's dataset_id leaf.

  ### Why `(type, dataset)` and not bare `(dataset)`

  The LEGACY arm never runs alone: the read ANDs `d.type == ^type` (the
  outermost equality, content.ex line 110) before the dataset scope. Leading
  the partial index with `type` lets the planner range-scan the NULL set by the
  type equality FIRST, then narrow by the `dataset` STRING equality — both
  equality predicates served by the index, matching the real WHERE. A bare
  `(dataset)` index would resolve the string but force a `type` filter-scan
  inside the (small but non-empty) NULL set. workspace_id/project_id are left
  off the partial key: within the already-tiny NULL set they add little
  selectivity over (type, dataset), and keeping the key narrow keeps the index
  small and cheap to maintain.

  ### Complement, not duplicate

    * m9b4 (20260527141000): `(workspace_id, project_id, type, dataset_id)`,
      FULL table — serves the `dataset_id == ^id` arm (the dominant path).
    * this:                  `(type, dataset) WHERE dataset_id IS NULL`,
      PARTIAL — serves the `is_nil(dataset_id) and dataset == ^dataset` arm.

  The two index paths are exactly the two arms of the BitmapOr; neither overlaps
  the other's column set or row set.

  ## Concurrency note

  In PRODUCTION this build would run `CREATE INDEX CONCURRENTLY` inside
  `@disable_ddl_transaction true` / `@disable_migration_lock true` to avoid a
  table lock on the live `documents` table. For test/dev a plain in-transaction
  `create index` is used here — matching the local convention set by the Wave-2
  flip (20260527134000) and the m9b4 composite (20260527141000) on this same
  table. Purely additive, fully reversible.
  """

  def up do
    create index(:documents, [:type, :dataset],
             where: "dataset_id IS NULL",
             name: :documents_type_dataset_null_dataset_id_index
           )
  end

  def down do
    drop_if_exists index(:documents, [:type, :dataset],
                     where: "dataset_id IS NULL",
                     name: :documents_type_dataset_null_dataset_id_index
                   )
  end
end
