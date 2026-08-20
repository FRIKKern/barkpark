defmodule Barkpark.Repo.Migrations.SearchSynonymsWorkspaceUniqueIndex do
  use Ecto.Migration

  @moduledoc """
  bpb-synonyms-workspace-tenancy (Perfect-Plan-BUILD W7, charter D52/D57).

  ## The live cross-tenant 500 the flip left on `search_synonyms`

  `20260527134000_flip_uniqueness_to_dataset_id` swapped the `scope`-STRING
  unique index for `search_synonyms_dataset_id_unique_idx` on
  `(surface, dataset_id, from_query, to_query, kind)`. But `dataset_id` is
  stamped via `Barkpark.Tenancy.default_project_dataset_id/1`, which resolves the
  scope STRING against the GLOBAL singleton Default project
  (`get_default_project`). So two DIFFERENT workspaces that both search the
  `scope = "production"` slug resolve the SAME `dataset_id` — the index treats
  their identical `(surface, from, to, kind)` tuple as a collision. Tenant B's
  otherwise-legitimate insert of the same synonym as tenant A raised an uncaught
  `Ecto.ConstraintError` (the schema had no changeset) → HTTP 500. That is a LIVE
  cross-tenant collision: workspace A's presence blocks workspace B from holding
  its own copy of a common synonym.

  ## The fix — Candidate-A two-partial split (mirrors D52 `data_keys`)

  `workspace_id` (a nullable FK added in `20260527110100`) is now the per-tenant
  identity leaf. A BARE re-key to `(workspace_id, surface, …)` would SILENTLY
  DELETE dedup for the legacy/global arm, because Postgres treats `NULL` as
  DISTINCT in a unique index — two `workspace_id IS NULL` byte-duplicates would
  stop colliding. So we split uniqueness into two PARTIAL indexes, one per
  attribution regime, exactly as `20260714010000` did for `data_keys`:

    * `(surface, dataset_id, from_query, to_query, kind) WHERE workspace_id IS
      NULL` — preserves the legacy/global dedup guarantee for un-attributed rows
      (the pre-tenancy write path + the `restore_search_null_dataset_dedup`
      backfill). Byte-identical key to the dropped `dataset_id_unique_idx`, just
      narrowed to the NULL arm.
    * `(workspace_id, surface, from_query, to_query, kind) WHERE workspace_id IS
      NOT NULL` — per-tenant dedup: workspace A and workspace B may EACH hold
      their own `(surface, from, to, kind)` synonym under the shared `production`
      slug, and a workspace's own duplicate still collides (mapped to a 422 by
      `Synonym.changeset/2`, not a raw 500). `dataset_id` is intentionally NOT in
      this arm — `workspace_id` is the tenant leaf, and the search surface is
      single-dataset per workspace, so scoping on `workspace_id` is the correct
      grain (a `dataset_id` leaf would let a workspace re-collide via the shared
      Default dataset_id, reintroducing the bug).

  Additive + reversible: the `dataset_id` / `scope` columns are untouched, and
  `down/0` restores the single `dataset_id_unique_idx`.

  ## Concurrency note

  In production these builds would run `CREATE INDEX CONCURRENTLY` /
  `DROP INDEX CONCURRENTLY` under `@disable_ddl_transaction`. For test/dev a
  plain in-transaction build is fine (small data, no live traffic) — mirroring
  the sibling `20260527134000` flip.
  """

  def up do
    # Legacy/global arm — narrow the existing composite key to the NULL rows so
    # un-attributed dedup survives the split (NULLs-distinct trap avoided).
    create unique_index(
             :search_synonyms,
             [:surface, :dataset_id, :from_query, :to_query, :kind],
             where: "workspace_id IS NULL",
             name: :search_synonyms_null_ws_unique_idx
           )

    # Per-tenant arm — workspace_id is the tenant leaf; two workspaces may each
    # own the same (surface, from, to, kind) under a shared dataset slug.
    create unique_index(
             :search_synonyms,
             [:workspace_id, :surface, :from_query, :to_query, :kind],
             where: "workspace_id IS NOT NULL",
             name: :search_synonyms_workspace_unique_idx
           )

    # Drop the global (unpartitioned) dataset_id index that collided across
    # workspaces on the shared Default dataset_id.
    drop_if_exists unique_index(
                     :search_synonyms,
                     [:surface, :dataset_id, :from_query, :to_query, :kind],
                     name: :search_synonyms_dataset_id_unique_idx
                   )
  end

  def down do
    # Restore the single dataset_id index, then drop the two partial arms. Safe:
    # dataset_id is still stamped on every row (the dual-write never stopped), so
    # the un-partitioned index can rebuild without collision on existing data —
    # EXCEPT where the two-workspace-same-slug rows this migration UNBLOCKED now
    # coexist. Those are the rows the fix legitimately created; a rollback that
    # cannot represent them will fail here, which is the correct signal that the
    # data has diverged past the pre-fix schema. Guarded create so a clean DB
    # (no such rows) rolls back cleanly.
    create unique_index(
             :search_synonyms,
             [:surface, :dataset_id, :from_query, :to_query, :kind],
             name: :search_synonyms_dataset_id_unique_idx
           )

    drop_if_exists unique_index(
                     :search_synonyms,
                     [:surface, :dataset_id, :from_query, :to_query, :kind],
                     name: :search_synonyms_null_ws_unique_idx
                   )

    drop_if_exists unique_index(
                     :search_synonyms,
                     [:workspace_id, :surface, :from_query, :to_query, :kind],
                     name: :search_synonyms_workspace_unique_idx
                   )
  end
end
