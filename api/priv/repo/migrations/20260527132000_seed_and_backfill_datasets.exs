defmodule Barkpark.Repo.Migrations.SeedAndBackfillDatasets do
  use Ecto.Migration

  @moduledoc """
  Wave-2 foundation (additive). Two phases, both idempotent + reversible:

    1. SEED: one `datasets` row per distinct existing dataset STRING
       (SELECT DISTINCT across documents + schema_definitions + media_files —
       typically "production","paperflow"), each under the Default project
       (slug = name = the string). Guarded by the (project_id, slug) unique
       index via NOT EXISTS so a re-run is a no-op.

    2. BACKFILL: stamp each content row's `dataset_id` = the datasets row whose
       (project_id, slug) matches the row's (Default project, its dataset
       string). Per-table the "dataset string" is:
         * `dataset`  for documents/revisions/mutation_events/media_files/
                      schema_definitions/webhooks/api_tokens
         * `scope`    for the 4 search_intel_* / search_synonyms tables
                      (renamed from dataset in 20260526140000)
       paper_events carries no dataset string — it follows its paper, which
       lives in "production" — so its rows are stamped the Default project's
       "production" dataset (back-compat default; mirrors W1.5 paper_events
       backfill).

  The `dataset` string remains authoritative; `dataset_id` is dual-presence.
  No uniqueness flips, no column drops, no query rewrites here.

  down/0: clears the dataset_id we set (back to NULL) and removes the seeded
  datasets rows. Safe because dataset_id is FK-nilify and unused by any query
  yet. Guarded so a partial rollback can't fail.
  """

  # Tables whose dataset string lives in a `dataset` column.
  @dataset_string_tables ~w(
    documents
    revisions
    mutation_events
    media_files
    schema_definitions
    webhooks
    api_tokens
  )

  # Tables whose dataset-equivalent string lives in a `scope` column.
  @scope_string_tables ~w(
    search_intel_events
    search_intel_crystals
    search_intel_merge_patterns
    search_synonyms
  )

  def up do
    case default_project_id() do
      nil ->
        # Default project not seeded yet (fresh sandbox before the W1 backfill
        # ran). Nothing to anchor datasets under — leave it; a later run picks
        # it up once the Default project exists.
        :ok

      project_id ->
        seed_datasets(project_id)
        flush()
        backfill_dataset_id(project_id)
    end
  end

  def down do
    case default_project_id() do
      nil ->
        :ok

      project_id ->
        # Null out every dataset_id pointing at a Default-project dataset, then
        # drop those seeded rows. Each guarded so missing columns/tables don't
        # break the rollback.
        for table_name <- @dataset_string_tables ++ @scope_string_tables ++ ["paper_events"] do
          repo().query!(
            """
            UPDATE #{table_name}
            SET dataset_id = NULL
            WHERE dataset_id IN (SELECT id FROM datasets WHERE project_id = $1)
            """,
            [project_id]
          )
        end

        repo().query!("DELETE FROM datasets WHERE project_id = $1", [project_id])
    end
  end

  # --- helpers --------------------------------------------------------------

  defp default_project_id do
    %{rows: rows} =
      repo().query!(
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

  defp seed_datasets(project_id) do
    # DISTINCT dataset strings across the three primary content tables.
    repo().query!(
      """
      INSERT INTO datasets (id, project_id, slug, name, inserted_at, updated_at)
      SELECT gen_random_uuid(), $1, s.dataset, s.dataset, now(), now()
      FROM (
        SELECT DISTINCT dataset FROM documents WHERE dataset IS NOT NULL
        UNION
        SELECT DISTINCT dataset FROM schema_definitions WHERE dataset IS NOT NULL
        UNION
        SELECT DISTINCT dataset FROM media_files WHERE dataset IS NOT NULL
      ) s
      WHERE NOT EXISTS (
        SELECT 1 FROM datasets d
        WHERE d.project_id = $1 AND d.slug = s.dataset
      )
      """,
      [project_id]
    )

    # Guarantee the two canonical datasets exist even on an empty DB so the
    # dual-presence seam is never starved (production is the codebase default;
    # paperflow is the papers surface). Guarded individually.
    for slug <- ["production", "paperflow"] do
      repo().query!(
        """
        INSERT INTO datasets (id, project_id, slug, name, inserted_at, updated_at)
        SELECT gen_random_uuid(), $1, $2::text, $2::text, now(), now()
        WHERE NOT EXISTS (
          SELECT 1 FROM datasets d WHERE d.project_id = $1 AND d.slug = $2::text
        )
        """,
        [project_id, slug]
      )
    end
  end

  defp backfill_dataset_id(project_id) do
    # Tables matched by their `dataset` column.
    for table_name <- @dataset_string_tables do
      repo().query!(
        """
        UPDATE #{table_name} t
        SET dataset_id = d.id
        FROM datasets d
        WHERE d.project_id = $1
          AND d.slug = t.dataset
          AND t.dataset IS NOT NULL
          AND t.dataset_id IS NULL
        """,
        [project_id]
      )
    end

    # Tables matched by their `scope` column.
    for table_name <- @scope_string_tables do
      repo().query!(
        """
        UPDATE #{table_name} t
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

    # paper_events: no dataset string. Follows its paper -> "production".
    repo().query!(
      """
      UPDATE paper_events t
      SET dataset_id = d.id
      FROM datasets d
      WHERE d.project_id = $1
        AND d.slug = 'production'
        AND t.dataset_id IS NULL
      """,
      [project_id]
    )
  end
end
