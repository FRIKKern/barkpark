defmodule Barkpark.Repo.Migrations.AddDocumentsScopedListIndex do
  use Ecto.Migration

  @moduledoc """
  Add the composite index that matches the post-tenancy-flip scoped
  list-by-type read shape (barkpark-m9b4 / finder-perf).

  ## The gap

  `Barkpark.Content.list_documents/3` (content.ex) builds this WHERE in pipe
  order:

      where d.type == ^type                                          # line 110
      and  (d.dataset_id == ^id                                      # scope_to_dataset
            or (is_nil(d.dataset_id) and d.dataset == ^dataset))     #   NULL-tolerant arm
      and  d.workspace_id == ^workspace_id                           # scope_to_workspace
      [and d.project_id == ^project_id]                              #   when project given

  After the Wave-2 uniqueness flip (20260527134000) the only `type`-leading
  composite is the OLD `(type, dataset)` STRING btree (20260412090737) — and
  `dataset` is no longer the scoping leaf. The new `dataset_id` index is
  single-column (20260527131000) and low-selectivity; the post-flip UNIQUE
  `(doc_id, type, dataset_id)` leads with `doc_id`, so it can't serve a
  `type` + `dataset_id` list scan. A scoped list-by-type therefore leans on
  the single-col `dataset_id` index and then filter-scans by `type`.

  ## The fix

  A composite btree ordered to match the read envelope's equality predicates:

      (workspace_id, project_id, type, dataset_id)

  workspace_id leads (the hard tenant boundary, highest selectivity), then
  project_id, then type, then the dataset_id leaf — so a fully-scoped
  list-by-type (the hot path) is an index range scan, and a workspace-only
  list (project_id absent) still uses the leading prefix.

  The NULL-tolerant OR arm `(dataset_id IS NULL and dataset == ^dataset)` is a
  shrinking legacy back-compat set; the composite serves the dominant
  `dataset_id == ^id` arm. A partial index for the NULL arm (finder P3) is left
  as a separate decision — not warranted alongside this win.

  ## Concurrency note

  In PRODUCTION this build would run `CREATE INDEX CONCURRENTLY` inside
  `@disable_ddl_transaction true` / `@disable_migration_lock true` to avoid a
  table lock on the live `documents` table. For test/dev a plain in-transaction
  `create index` is used here — matching the local convention set by the
  Wave-2 flip migration (20260527134000) on this same table. Purely additive,
  fully reversible.
  """

  def up do
    create index(:documents, [:workspace_id, :project_id, :type, :dataset_id],
             name: :documents_workspace_project_type_dataset_id_index
           )
  end

  def down do
    drop_if_exists index(:documents, [:workspace_id, :project_id, :type, :dataset_id],
                     name: :documents_workspace_project_type_dataset_id_index
                   )
  end
end
