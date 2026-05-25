defmodule Barkpark.Repo.Migrations.BackfillDefaultTenancy do
  use Ecto.Migration

  # Idempotent, re-runnable backfill. Seeds a Default Workspace + Default
  # Project, then assigns them to every NULL tenancy column added in
  # 20260527110100. Guarded so a second run is a no-op:
  #   * inserts guarded by NOT EXISTS / ON CONFLICT DO NOTHING
  #   * updates only touch WHERE workspace_id IS NULL rows
  # down/0 is a safe no-op — the columns themselves are dropped by the
  # column-add migration's own down, so we must not assume they still exist.
  @ws_and_project ~w(
    documents
    revisions
    mutation_events
    media_files
    schema_definitions
    webhooks
    search_intel_events
    search_intel_crystals
    search_intel_merge_patterns
    search_synonyms
  )

  def up do
    # 1. Default Workspace (slug unique) — guarded insert.
    repo().query!(
      """
      INSERT INTO workspaces (id, slug, name, inserted_at, updated_at)
      SELECT gen_random_uuid(), 'default', 'Default Workspace', now(), now()
      WHERE NOT EXISTS (SELECT 1 FROM workspaces WHERE slug = 'default')
      """,
      []
    )

    # 2. Default Project under it (unique on workspace_id, slug) — guarded.
    repo().query!(
      """
      INSERT INTO projects (id, workspace_id, slug, name, inserted_at, updated_at)
      SELECT gen_random_uuid(), w.id, 'default', 'Default Project', now(), now()
      FROM workspaces w
      WHERE w.slug = 'default'
        AND NOT EXISTS (
          SELECT 1 FROM projects p
          WHERE p.workspace_id = w.id AND p.slug = 'default'
        )
      """,
      []
    )

    flush()

    %{rows: [[ws_id, project_id]]} =
      repo().query!(
        """
        SELECT w.id, p.id
        FROM workspaces w
        JOIN projects p ON p.workspace_id = w.id AND p.slug = 'default'
        WHERE w.slug = 'default'
        """,
        []
      )

    # 3. Assign default ws + project to every un-tenanted row.
    for table_name <- @ws_and_project do
      repo().query!(
        """
        UPDATE #{table_name}
        SET workspace_id = $1, project_id = $2
        WHERE workspace_id IS NULL
        """,
        [ws_id, project_id]
      )
    end

    repo().query!(
      """
      UPDATE api_tokens
      SET workspace_id = $1
      WHERE workspace_id IS NULL
      """,
      [ws_id]
    )
  end

  # Reverting the backfill is a no-op: the FK columns are owned (and dropped)
  # by 20260527110100's down, and we never want to delete the Default rows on
  # a partial rollback. Leaving data in place is the safe choice.
  def down, do: :ok
end
