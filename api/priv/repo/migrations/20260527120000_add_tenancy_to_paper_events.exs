defmodule Barkpark.Repo.Migrations.AddTenancyToPaperEvents do
  use Ecto.Migration

  @moduledoc """
  W1.5-C: scope the paperflow document surface by workspace/project.

  `paper_events` was created (20260526180000) BEFORE the Wave-1 tenancy
  retrofit (20260527110100) and so was left out of the `@ws_and_project`
  column-add list. A paper_event's scope = its goal's workspace/project, but
  paperflow's ingest still sends FLAT (no workspace), so these columns are
  NULLABLE and default to the seeded Default workspace/project on backfill.

  Rollout-safe: both FK columns NULLABLE (NULL = unscoped / back-compat read).
  The backfill is guarded — it runs only when the Default workspace exists and
  derives each row's scope from the paper it belongs to when a clean
  documents-by-slug join exists, else falls back to Default.
  """

  def up do
    alter table(:paper_events) do
      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :nilify_all)

      add :project_id,
          references(:projects, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:paper_events, [:workspace_id])
    create index(:paper_events, [:project_id])

    flush()

    # Backfill in two passes:
    #   1. Derive scope from the paper the event belongs to (paper_slug ==
    #      documents.doc_id, type 'paper') when that paper carries a scope.
    #   2. Anything still NULL → the seeded Default workspace/project.
    repo().query!(
      """
      UPDATE paper_events pe
      SET workspace_id = d.workspace_id, project_id = d.project_id
      FROM documents d
      WHERE pe.paper_slug IS NOT NULL
        AND d.doc_id = pe.paper_slug
        AND d.type = 'paper'
        AND d.workspace_id IS NOT NULL
        AND pe.workspace_id IS NULL
      """,
      []
    )

    %{rows: rows} =
      repo().query!(
        """
        SELECT w.id, p.id
        FROM workspaces w
        JOIN projects p ON p.workspace_id = w.id AND p.slug = 'default'
        WHERE w.slug = 'default'
        """,
        []
      )

    case rows do
      [[ws_id, project_id]] ->
        repo().query!(
          """
          UPDATE paper_events
          SET workspace_id = $1, project_id = $2
          WHERE workspace_id IS NULL
          """,
          [ws_id, project_id]
        )

      _ ->
        # No Default seeded yet (fresh sandbox before the backfill migration) —
        # leave rows unscoped; resolve_write_scope stamps Default on next write.
        :ok
    end
  end

  def down do
    drop index(:paper_events, [:project_id])
    drop index(:paper_events, [:workspace_id])

    alter table(:paper_events) do
      remove :workspace_id
      remove :project_id
    end
  end
end
