defmodule Barkpark.Repo.Migrations.FlipUniquenessToDatasetId do
  use Ecto.Migration

  @moduledoc """
  Wave-2 uniqueness FLIP: make `dataset_id` the authoritative scoping leaf for
  the content + media + search-intel uniqueness constraints, swapping it in for
  the `dataset` STRING (and, for schemas, for `dataset` → `project_id`). The
  `dataset` STRING column STAYS on every table — it is now a denormalized mirror
  (safety net), NOT the uniqueness key. No column drops; fully reversible.

  `dataset_id` is already backfilled on all rows (20260527132000) and the W2
  dual-write (Barkpark.Content / Barkpark.Media `put_scope_attrs`) keeps the
  string + id consistent on every new/updated row, so the flipped indexes can't
  collide on existing data.

  ## The key win — lifted cross-workspace limit on documents

  The old `(doc_id, type, dataset)` unique index was GLOBAL: two workspaces could
  never each hold a document with the same `doc_id` + `type`, because the
  `dataset` STRING was shared across workspaces. `dataset_id` is project- (and
  thus workspace-) scoped, so `(doc_id, type, dataset_id)` LETS two workspaces
  each own their own `doc_id` + `type` row — they get distinct dataset_ids and
  coexist. That is the headline reason for the flip.

  ## Indexes flipped (ADD new, then DROP old — string column itself kept)

    * documents:           (doc_id, type, dataset)        -> (doc_id, type, dataset_id)
    * schema_definitions:   (name, dataset)               -> (name, dataset_id)
                            (schemas are DATASET-scoped: a project can hold the
                            same schema NAME in distinct datasets — the
                            dataset_id leaf keeps them from colliding)
    * media_files:          (path, dataset)               -> (path, dataset_id)
    * search_synonyms:      (surface, scope, ...)         -> (surface, dataset_id, ...)
    * search_intel_crystals:(surface, scope, ...)         -> (surface, dataset_id, ...)
    * search_intel_merge_patterns:(surface, scope, ...)   -> (surface, dataset_id, ...)

  ## CONCURRENCY NOTE

  In PRODUCTION these index builds would run `CREATE INDEX CONCURRENTLY` (and the
  drops `DROP INDEX CONCURRENTLY`) inside `@disable_ddl_transaction true` /
  `@disable_migration_lock true` to avoid taking a table lock on a live table.
  For test/dev a plain in-transaction `create unique_index` / `drop` is fine and
  is what we use here — the data set is small and there is no live traffic.

  The new index names are pinned explicitly so the Ecto changeset
  `unique_constraint/2` calls (Document / SchemaDefinition / MediaFile) map their
  error to the right constraint.
  """

  def up do
    # ── documents: (doc_id, type, dataset) -> (doc_id, type, dataset_id) ──────
    create unique_index(:documents, [:doc_id, :type, :dataset_id],
             name: :documents_doc_id_type_dataset_id_index
           )

    drop_if_exists unique_index(:documents, [:doc_id, :type, :dataset],
                     name: :documents_doc_id_type_dataset_index
                   )

    # ── schema_definitions: (name, dataset) -> (name, dataset_id) ────────────
    create unique_index(:schema_definitions, [:name, :dataset_id],
             name: :schema_definitions_name_dataset_id_index
           )

    drop_if_exists unique_index(:schema_definitions, [:name, :dataset],
                     name: :schema_definitions_name_dataset_index
                   )

    # ── media_files: (path, dataset) -> (path, dataset_id) ───────────────────
    create unique_index(:media_files, [:path, :dataset_id],
             name: :media_files_path_dataset_id_index
           )

    drop_if_exists unique_index(:media_files, [:path, :dataset],
                     name: :media_files_path_dataset_index
                   )

    # ── search_synonyms: swap `scope` -> `dataset_id` in the composite key ───
    create unique_index(
             :search_synonyms,
             [:surface, :dataset_id, :from_query, :to_query, :kind],
             name: :search_synonyms_dataset_id_unique_idx
           )

    drop_if_exists unique_index(
                     :search_synonyms,
                     [:surface, :scope, :from_query, :to_query, :kind],
                     name: :search_synonyms_unique_idx
                   )

    # ── search_intel_crystals: swap `scope` -> `dataset_id` ──────────────────
    create unique_index(
             :search_intel_crystals,
             [
               :surface,
               :dataset_id,
               :period,
               :period_start,
               :query_normalized,
               :filter_fingerprint
             ],
             name: :search_intel_crystals_dataset_id_unique_idx
           )

    drop_if_exists unique_index(
                     :search_intel_crystals,
                     [
                       :surface,
                       :scope,
                       :period,
                       :period_start,
                       :query_normalized,
                       :filter_fingerprint
                     ],
                     name: :search_intel_crystals_unique_idx
                   )

    # ── search_intel_merge_patterns: swap `scope` -> `dataset_id` ────────────
    create unique_index(
             :search_intel_merge_patterns,
             [
               :surface,
               :dataset_id,
               :period,
               :period_start,
               :from_fingerprint,
               :to_fingerprint,
               :pattern_type
             ],
             name: :search_intel_merge_patterns_dataset_id_unique_idx
           )

    drop_if_exists unique_index(
                     :search_intel_merge_patterns,
                     [
                       :surface,
                       :scope,
                       :period,
                       :period_start,
                       :from_fingerprint,
                       :to_fingerprint,
                       :pattern_type
                     ],
                     name: :search_intel_merge_patterns_unique_idx
                   )
  end

  def down do
    # Reverse: recreate the STRING/`scope`-based uniques, then drop the
    # dataset_id ones. Safe because the `dataset` / `scope` strings were never
    # dropped — the mirror is intact.

    # documents
    create unique_index(:documents, [:doc_id, :type, :dataset],
             name: :documents_doc_id_type_dataset_index
           )

    drop_if_exists unique_index(:documents, [:doc_id, :type, :dataset_id],
                     name: :documents_doc_id_type_dataset_id_index
                   )

    # schema_definitions
    create unique_index(:schema_definitions, [:name, :dataset],
             name: :schema_definitions_name_dataset_index
           )

    drop_if_exists unique_index(:schema_definitions, [:name, :dataset_id],
                     name: :schema_definitions_name_dataset_id_index
                   )

    # media_files
    create unique_index(:media_files, [:path, :dataset], name: :media_files_path_dataset_index)

    drop_if_exists unique_index(:media_files, [:path, :dataset_id],
                     name: :media_files_path_dataset_id_index
                   )

    # search_synonyms
    create unique_index(
             :search_synonyms,
             [:surface, :scope, :from_query, :to_query, :kind],
             name: :search_synonyms_unique_idx
           )

    drop_if_exists unique_index(
                     :search_synonyms,
                     [:surface, :dataset_id, :from_query, :to_query, :kind],
                     name: :search_synonyms_dataset_id_unique_idx
                   )

    # search_intel_crystals
    create unique_index(
             :search_intel_crystals,
             [:surface, :scope, :period, :period_start, :query_normalized, :filter_fingerprint],
             name: :search_intel_crystals_unique_idx
           )

    drop_if_exists unique_index(
                     :search_intel_crystals,
                     [
                       :surface,
                       :dataset_id,
                       :period,
                       :period_start,
                       :query_normalized,
                       :filter_fingerprint
                     ],
                     name: :search_intel_crystals_dataset_id_unique_idx
                   )

    # search_intel_merge_patterns
    create unique_index(
             :search_intel_merge_patterns,
             [
               :surface,
               :scope,
               :period,
               :period_start,
               :from_fingerprint,
               :to_fingerprint,
               :pattern_type
             ],
             name: :search_intel_merge_patterns_unique_idx
           )

    drop_if_exists unique_index(
                     :search_intel_merge_patterns,
                     [
                       :surface,
                       :dataset_id,
                       :period,
                       :period_start,
                       :from_fingerprint,
                       :to_fingerprint,
                       :pattern_type
                     ],
                     name: :search_intel_merge_patterns_dataset_id_unique_idx
                   )
  end
end
