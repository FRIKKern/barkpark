defmodule Barkpark.Repo.Migrations.RestoreSearchNullDatasetDedup do
  use Ecto.Migration

  @moduledoc """
  Restore dedup for the NULL-`dataset_id` LEGACY arm on the three search tables
  whose uniqueness was flipped in 20260527134000 (barkpark-vwu5).

  ## The gap the flip left

  The 134000 flip swapped the `scope`-STRING unique indexes on
  `search_synonyms` / `search_intel_crystals` / `search_intel_merge_patterns`
  for `(surface, dataset_id, …)` ones. But the 132000 backfill only stamps
  `dataset_id` when a row's `scope` STRING matches a DOCUMENT dataset slug
  (seeded from DISTINCT `dataset` across documents/schema_definitions/
  media_files). Search `scope` values that are NOT document datasets
  (surface-specific scopes) got NO seeded dataset row, so their `dataset_id`
  stayed NULL.

  Postgres treats NULLs as DISTINCT in a unique index, so the flipped
  `(surface, dataset_id, …)` index does NOT dedupe rows whose `dataset_id` is
  NULL. The old `scope`-STRING uniqueness guarantee was dropped with nothing
  replacing it for those rows — pre-dual-write rows whose scope isn't a doc
  dataset could hold unlimited byte-duplicate tuples.

  ## The fix — OPTION A: backfill `dataset_id` for ALL distinct `scope` values

  This mirrors exactly what the going-forward W2 dual-write already does:
  `Barkpark.Search.Synonyms.put_dataset_id/2` →
  `Barkpark.Tenancy.default_project_dataset_id/1` → `get_or_create_dataset/2`
  get-or-creates a `datasets` row for ANY `scope` string under the Default
  project and stamps `dataset_id` alongside `scope` on every NEW row. We
  retroactively do the same for legacy rows: seed a `datasets` row per distinct
  `scope` on each search table, then stamp `dataset_id` on the NULL rows.

  This converges legacy rows onto the SAME `(surface, dataset_id, …)` index the
  flip introduced and the SAME dataset rows the dual-write creates — no second
  uniqueness regime, no permanent NULL arm. `scope` is NOT NULL on all three
  tables (created NOT NULL in 20260525140000 / 20260526182000), so every legacy
  row gets a deterministic stamp.

  Reads are unaffected: the search read path
  (`Synonyms.list/2`, `candidates/3`, `search_terms/3`) filters purely on the
  `scope` STRING (`s.surface == ^surface and s.scope == ^scope`) — it never
  touches `dataset_id`, which is write-only dual-presence here.

  ## Step 1 — dedupe existing byte-duplicate NULL rows FIRST

  Before stamping, collapse any existing byte-duplicate NULL-`dataset_id` rows
  (rows sharing the full uniqueness tuple) down to one — otherwise the backfill
  would stamp two rows the same `dataset_id`, immediately violating the flipped
  unique index. We keep the OLDEST row per tuple (lowest inserted_at, then
  lowest id as a tiebreak) and delete the rest. Only TRUE byte-duplicates on the
  uniqueness key are removed — legitimately-distinct rows are untouched.

  The dedupe is scoped to `dataset_id IS NULL` rows: the non-NULL rows are
  already protected by the live `(surface, dataset_id, …)` unique index and
  cannot hold duplicates.

  ## Idempotency + reversibility

  Idempotent: the dedupe matches nothing on a clean re-run (dups already gone);
  the seed is `WHERE NOT EXISTS` guarded; the backfill only touches
  `dataset_id IS NULL` rows (already-stamped rows are skipped). Re-running up/0
  is a no-op once it has run.

  down/0: null out the `dataset_id` we set on rows whose dataset slug matches a
  distinct search scope that is NOT a document-dataset slug, then drop the
  search-only seeded `datasets` rows (those whose slug appears as a search scope
  but NOT as a documents/schema_definitions/media_files dataset string). It
  cannot un-collapse deleted byte-duplicates — that data was true noise, by
  definition identical to a surviving row — so the rollback restores the index
  state and the dataset table, not the deleted duplicate rows. Guarded so a
  partial rollback can't fail.
  """

  # (table, full uniqueness tuple from the 134000 flip with dataset_id swapped
  #  back to the legacy scope STRING — i.e. the columns that define a "true
  #  byte-duplicate" for the legacy NULL arm).
  @search_tables [
    {"search_synonyms", ~w(surface scope from_query to_query kind)},
    {"search_intel_crystals",
     ~w(surface scope period period_start query_normalized filter_fingerprint)},
    {"search_intel_merge_patterns",
     ~w(surface scope period period_start from_fingerprint to_fingerprint pattern_type)}
  ]

  def up, do: apply_up(repo())
  def down, do: apply_down(repo())

  @doc """
  Run the restore against `repo`. Exposed for tests so the body executes on the
  caller's (sandbox) connection rather than a migrator-spawned task that the SQL
  sandbox hasn't `allow`-ed. Production callers go through `up/0`.
  """
  def apply_up(repo \\ Barkpark.Repo) do
    case default_project_id(repo) do
      nil ->
        # Default project not seeded yet (fresh sandbox before the W1 backfill).
        # Nothing to anchor datasets under — leave it; a later run picks it up.
        :ok

      project_id ->
        for {table, key_cols} <- @search_tables do
          dedupe_null_duplicates(repo, table, key_cols)
        end

        for {table, _key_cols} <- @search_tables do
          seed_scope_datasets(repo, project_id, table)
        end

        for {table, _key_cols} <- @search_tables do
          backfill_dataset_id(repo, project_id, table)
        end

        :ok
    end
  end

  @doc """
  Reverse the restore against `repo`. Exposed for tests; production callers go
  through `down/0`.
  """
  def apply_down(repo \\ Barkpark.Repo) do
    case default_project_id(repo) do
      nil ->
        :ok

      project_id ->
        # Null out the dataset_id on search rows whose dataset is a search-only
        # scope (slug present as a search scope but NOT as a documents /
        # schema_definitions / media_files dataset string), then drop those
        # search-only seeded datasets rows. Doc-dataset scopes (stamped by
        # 132000) are left intact — they are not ours to revert.
        for {table, _key_cols} <- @search_tables do
          repo.query!(
            """
            UPDATE #{table} t
            SET dataset_id = NULL
            WHERE t.dataset_id IN (
              SELECT d.id FROM datasets d
              WHERE d.project_id = $1
                AND d.slug NOT IN (
                  SELECT dataset FROM documents WHERE dataset IS NOT NULL
                  UNION SELECT dataset FROM schema_definitions WHERE dataset IS NOT NULL
                  UNION SELECT dataset FROM media_files WHERE dataset IS NOT NULL
                )
            )
            """,
            [project_id]
          )
        end

        # Drop the datasets rows that were seeded for search-only scopes — only
        # those that (a) belong to the Default project, (b) are NOT a doc-dataset
        # slug, and (c) are no longer referenced by ANY content/search row.
        repo.query!(
          """
          DELETE FROM datasets d
          WHERE d.project_id = $1
            AND d.slug NOT IN (
              SELECT dataset FROM documents WHERE dataset IS NOT NULL
              UNION SELECT dataset FROM schema_definitions WHERE dataset IS NOT NULL
              UNION SELECT dataset FROM media_files WHERE dataset IS NOT NULL
            )
            AND d.slug IN (
              SELECT scope FROM search_synonyms WHERE scope IS NOT NULL
              UNION SELECT scope FROM search_intel_crystals WHERE scope IS NOT NULL
              UNION SELECT scope FROM search_intel_merge_patterns WHERE scope IS NOT NULL
            )
            AND NOT EXISTS (
              SELECT 1 FROM search_synonyms x WHERE x.dataset_id = d.id
              UNION ALL SELECT 1 FROM search_intel_crystals x WHERE x.dataset_id = d.id
              UNION ALL SELECT 1 FROM search_intel_merge_patterns x WHERE x.dataset_id = d.id
            )
          """,
          [project_id]
        )

        :ok
    end
  end

  # --- helpers --------------------------------------------------------------

  defp default_project_id(repo) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT p.id
        FROM projects p
        JOIN workspaces w ON w.id = p.workspace_id
        WHERE w.slug = 'default' AND p.slug = 'default'
        """,
        []
      )

    case rows do
      [[project_id]] -> project_id
      _ -> nil
    end
  end

  # Collapse byte-duplicate NULL-dataset_id rows: keep the OLDEST row per
  # uniqueness tuple (lowest inserted_at, then lowest id), delete the rest.
  # Only NULL-dataset_id rows are eligible — non-NULL rows are already protected
  # by the live (surface, dataset_id, …) unique index.
  defp dedupe_null_duplicates(repo, table, key_cols) do
    partition = Enum.join(key_cols, ", ")

    repo.query!(
      """
      DELETE FROM #{table} t
      USING (
        SELECT id,
               row_number() OVER (
                 PARTITION BY #{partition}
                 ORDER BY inserted_at ASC, id ASC
               ) AS rn
        FROM #{table}
        WHERE dataset_id IS NULL
      ) dup
      WHERE t.id = dup.id AND dup.rn > 1
      """,
      []
    )
  end

  # Seed one datasets row (under the Default project) per distinct `scope` on
  # this search table. slug = name = scope. NOT EXISTS guarded → re-run safe,
  # and a scope already seeded by 132000 (a doc-dataset scope) is a no-op.
  defp seed_scope_datasets(repo, project_id, table) do
    repo.query!(
      """
      INSERT INTO datasets (id, project_id, slug, name, inserted_at, updated_at)
      SELECT gen_random_uuid(), $1, s.scope, s.scope, now(), now()
      FROM (SELECT DISTINCT scope FROM #{table} WHERE scope IS NOT NULL) s
      WHERE NOT EXISTS (
        SELECT 1 FROM datasets d
        WHERE d.project_id = $1 AND d.slug = s.scope
      )
      """,
      [project_id]
    )
  end

  # Stamp dataset_id on the NULL rows by matching scope → datasets.slug under the
  # Default project. Only touches dataset_id IS NULL rows (already-stamped rows
  # are skipped → idempotent + leaves the 132000 doc-dataset stamps alone).
  defp backfill_dataset_id(repo, project_id, table) do
    repo.query!(
      """
      UPDATE #{table} t
      SET dataset_id = d.id
      FROM datasets d
      WHERE d.project_id = $1
        AND d.slug = t.scope
        AND t.scope IS NOT NULL
        AND t.dataset_id IS NULL
      """,
      [project_id]
    )
  end
end
