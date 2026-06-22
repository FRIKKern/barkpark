defmodule Barkpark.Repo.Migrations.DropVestigialPaperflowDataset do
  use Ecto.Migration

  @moduledoc """
  Remove the vestigial `paperflow` dataset under the Default project.

  Papers moved to the `production` dataset in 20260524120000, and the paper
  schema is now registered there (`Plugins.Bulldocs.register_schemas/1` →
  `dataset: "production"`). The `paperflow` datasets row — guaranteed by the
  seed loop in 20260527132000 — is now dead: nothing in lib targets the
  `"paperflow"` dataset string, and only a leftover `schema_definitions` paper
  row lingers in it.

  SAFETY: this is GUARDED. It removes the dataset only when no real content
  (documents / media_files) uses the `"paperflow"` dataset string. If any does,
  the migration is a no-op and logs a notice — so it can never orphan or hide a
  document (the dataset_id FK is `nilify_all`, which would make a row invisible).
  The lone dead `schema_definitions` paper row is registry metadata, not content,
  so it is cleared as part of the cleanup.

  Idempotent (NOT EXISTS / guarded counts) and reversible: down/0 re-seeds the
  `paperflow` datasets row under the Default project, mirroring 20260527132000.
  """

  def up do
    with project_id when is_binary(project_id) <- default_project_id() do
      content =
        count("documents", "paperflow") + count("media_files", "paperflow")

      if content > 0 do
        IO.puts(
          "[drop_paperflow] SKIP — #{content} content row(s) still use dataset \"paperflow\"; " <>
            "leaving the dataset in place to avoid orphaning them."
        )
      else
        # Clear the dead paper schema row registered against the old dataset
        # string (the live one lives in "production").
        repo().query!(~s|DELETE FROM schema_definitions WHERE dataset = 'paperflow'|, [])

        # Defensive: NULL any stray dataset_id pointing at the row (there should
        # be none — content is empty), then drop the datasets row itself.
        repo().query!(
          """
          UPDATE documents SET dataset_id = NULL
          WHERE dataset_id IN (
            SELECT id FROM datasets WHERE project_id = $1 AND slug = 'paperflow'
          )
          """,
          [project_id]
        )

        repo().query!(
          ~s|DELETE FROM datasets WHERE project_id = $1 AND slug = 'paperflow'|,
          [project_id]
        )
      end
    else
      _ -> :ok
    end
  end

  def down do
    # Reversible: re-seed the paperflow datasets row (mirrors 20260527132000).
    with project_id when is_binary(project_id) <- default_project_id() do
      repo().query!(
        """
        INSERT INTO datasets (id, project_id, slug, name, inserted_at, updated_at)
        SELECT gen_random_uuid(), $1, 'paperflow', 'paperflow', now(), now()
        WHERE NOT EXISTS (
          SELECT 1 FROM datasets d WHERE d.project_id = $1 AND d.slug = 'paperflow'
        )
        """,
        [project_id]
      )
    else
      _ -> :ok
    end
  end

  defp count(table, dataset) do
    %{rows: [[n]]} = repo().query!("SELECT count(*) FROM #{table} WHERE dataset = $1", [dataset])
    n
  end

  defp default_project_id do
    %{rows: rows} =
      repo().query!(
        """
        SELECT p.id FROM projects p
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
end
