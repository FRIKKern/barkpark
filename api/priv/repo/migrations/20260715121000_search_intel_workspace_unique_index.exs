defmodule Barkpark.Repo.Migrations.SearchIntelWorkspaceUniqueIndex do
  use Ecto.Migration

  @moduledoc """
  W7 Intel-tenancy FIX: add `workspace_id` to the `search_intel_crystals` and
  `search_intel_merge_patterns` uniqueness so two tenants that share a scope
  STRING can no longer be folded into ONE summed roll-up row.

  ## The bleed this closes (VF2, RUN-proven)

  The crystallizer resolves a crystal/merge-pattern's `dataset_id` from its
  `scope` STRING (`Barkpark.Tenancy.default_project_dataset_id/1` get-or-creates
  ONE dataset per scope slug under the seeded Default project). Two workspaces
  that both own the universally-shared `"production"` slug therefore resolve to
  the SAME `dataset_id`, so the flipped `(surface, dataset_id, …)` unique index
  from 20260527134000 keyed BOTH tenants onto one physical row: 3 workspace-A +
  4 workspace-B searches under `(documents, production)` crystallized into ONE
  crystal `search_count=7, workspace_id=nil`, and the merge patterns summed.

  `workspace_id` (already a column on both tables since 20260527110100) is the
  real tenant discriminator. The crystallizer now stamps it and threads it into
  the upsert get_by keys; this migration makes the DB agree.

  ## Two-partial NULL/non-null split

  Postgres treats NULLs as DISTINCT in a unique index, so a single index with
  `workspace_id` in the key would STOP deduping the legacy `workspace_id IS NULL`
  rows (the pre-tenancy / unscoped arm). We keep those two regimes separate:

    * `workspace_id IS NOT NULL` → key includes `workspace_id`, so each tenant's
      roll-up gets its own row on a shared `(surface, dataset_id, …)`.
    * `workspace_id IS NULL` → key OMITS `workspace_id` (identical columns to the
      dropped 134000 index), preserving the exact global-legacy dedup the
      unscoped/back-compat callers relied on.

  Mirrors the surface-config per-workspace split (charter D45/D49). Fully
  reversible: the `dataset` / `scope` strings and `dataset_id` are untouched.

  ## CONCURRENCY NOTE

  In PRODUCTION these builds would run `CREATE INDEX CONCURRENTLY` /
  `DROP INDEX CONCURRENTLY` under `@disable_ddl_transaction true` to avoid a
  table lock on a live table. For test/dev the plain in-transaction form is fine
  (small data, no live traffic) — matching 20260527134000's precedent.
  """

  def up do
    # ── search_intel_crystals ────────────────────────────────────────────────
    create unique_index(
             :search_intel_crystals,
             [
               :surface,
               :dataset_id,
               :period,
               :period_start,
               :query_normalized,
               :filter_fingerprint,
               :workspace_id
             ],
             where: "workspace_id IS NOT NULL",
             name: :search_intel_crystals_ws_unique_idx
           )

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
             where: "workspace_id IS NULL",
             name: :search_intel_crystals_null_ws_unique_idx
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

    # ── search_intel_merge_patterns ──────────────────────────────────────────
    create unique_index(
             :search_intel_merge_patterns,
             [
               :surface,
               :dataset_id,
               :period,
               :period_start,
               :from_fingerprint,
               :to_fingerprint,
               :pattern_type,
               :workspace_id
             ],
             where: "workspace_id IS NOT NULL",
             name: :search_intel_merge_patterns_ws_unique_idx
           )

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
             where: "workspace_id IS NULL",
             name: :search_intel_merge_patterns_null_ws_unique_idx
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

  def down do
    # Restore the single dataset_id-keyed uniques (20260527134000 state), then
    # drop the two-partial split. Safe: no rows or columns were mutated.
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

    drop_if_exists unique_index(:search_intel_crystals, [],
                     name: :search_intel_crystals_ws_unique_idx
                   )

    drop_if_exists unique_index(:search_intel_crystals, [],
                     name: :search_intel_crystals_null_ws_unique_idx
                   )

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

    drop_if_exists unique_index(:search_intel_merge_patterns, [],
                     name: :search_intel_merge_patterns_ws_unique_idx
                   )

    drop_if_exists unique_index(:search_intel_merge_patterns, [],
                     name: :search_intel_merge_patterns_null_ws_unique_idx
                   )
  end
end
