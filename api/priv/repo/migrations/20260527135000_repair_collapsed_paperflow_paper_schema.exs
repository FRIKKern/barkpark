defmodule Barkpark.Repo.Migrations.RepairCollapsedPaperflowPaperSchema do
  use Ecto.Migration

  @moduledoc """
  Wave-2 REPAIR: restore the per-dataset `paper` schema row that the collapse
  migration (20260527133000) wrongly deleted.

  ## The data-loss bug

  `20260527133000_collapse_duplicate_schema_definitions` grouped
  `schema_definitions` by `(name, project_id)` and treated `dataset` /
  `dataset_id` as NON-substantive. Two byte-identical `paper` rows existed —
  one in the `production` dataset (seeded by `20260524120000`), one in the
  `paperflow` dataset (seeded by `20260524131000`) — both stamped with the same
  Default `project_id`. The collapse saw a `(paper, Default)` group of >1,
  judged the rows byte-identical (they differ ONLY in `dataset`/`dataset_id`),
  and DELETED the `paperflow` row, keeping the `production` survivor.

  But `20260527134000_flip_uniqueness_to_dataset_id` then flipped schema
  uniqueness to `(name, dataset_id)` — schemas are DATASET-scoped, a project
  legitimately holds the same NAME in distinct datasets. After the flip,
  `Content.get_schema("paper", "paperflow")` resolves the paperflow dataset's
  `dataset_id` and filters
  `dataset_id == <paperflow_id> OR (dataset_id IS NULL AND dataset = "paperflow")`.
  The lone survivor carries `dataset_id = <production_id>` / `dataset =
  "production"`, so it matches NEITHER branch — the paperflow `paper` schema
  is permanently unresolvable and nothing recreates it.

  ## What this does (idempotent + guarded)

  Re-insert the `paper` schema row scoped to the `paperflow` dataset, cloning
  the surviving `production` paper row's definition and re-scoping only the
  `dataset` STRING + `dataset_id` FK to paperflow. We INSERT only when the
  `(name = "paper", dataset_id = <paperflow_id>)` row is MISSING, so this
  compensates BOTH a fresh `ecto.reset` (collapse ran, this re-adds) AND an
  already-migrated DB (this runs on the next migrate). A re-run is a no-op.

  Raw SQL — clone via `INSERT ... SELECT` so every column (including ones added
  by later migrations: layout/prefill/workspace_id/project_id/cors_origins/…)
  is carried verbatim from the survivor without naming each. At this migration's
  point in history the full live `schema_definitions` shape exists, so a
  `SELECT *`-style clone is safe; we override only `id`, `dataset`, `dataset_id`,
  and the timestamps.

  ## Reversibility

  `down/0` deletes the paperflow `paper` row this migration created — but ONLY
  the one whose `dataset_id` matches the paperflow dataset. This is the precise
  inverse of `up/0`. It does not touch the production survivor. (Re-running the
  collapse `down` is the separate path that restores its own backup; this
  migration owns only the paperflow re-creation.)
  """

  def up do
    flush()

    case {default_project_id(), paperflow_dataset_id()} do
      {project_id, paperflow_id}
      when is_binary(project_id) and is_binary(paperflow_id) ->
        restore_paperflow_paper_schema(project_id, paperflow_id)

      _ ->
        # No Default project or no paperflow dataset anchored yet — nothing to
        # repair against. A later migrate run picks it up once both exist.
        :ok
    end
  end

  def down do
    flush()

    case paperflow_dataset_id() do
      paperflow_id when is_binary(paperflow_id) ->
        repo().query!(
          "DELETE FROM schema_definitions WHERE name = 'paper' AND dataset_id = $1",
          [uuid(paperflow_id)]
        )

      _ ->
        :ok
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # Clone the surviving production `paper` row, re-scoped to paperflow. Guarded
  # by NOT EXISTS on (name, dataset_id) so it is a no-op once the paperflow row
  # is present (idempotent + re-run safe). gen_random_uuid() gives the clone a
  # fresh id; `dataset`/`dataset_id` are overridden to paperflow; timestamps are
  # refreshed. Every OTHER column is copied verbatim from the survivor, so the
  # paperflow schema is a faithful mirror of the production one.
  defp restore_paperflow_paper_schema(project_id, paperflow_id) do
    repo().query!(
      """
      INSERT INTO schema_definitions
      SELECT (
        jsonb_populate_record(
          NULL::schema_definitions,
          src.survivor || jsonb_build_object(
            'id', gen_random_uuid(),
            'dataset', 'paperflow',
            'dataset_id', $2::uuid,
            'inserted_at', now(),
            'updated_at', now()
          )
        )
      ).*
      FROM (
        SELECT to_jsonb(s.*) AS survivor
        FROM schema_definitions s
        WHERE s.name = 'paper'
          AND s.dataset = 'production'
          AND s.project_id = $1
          AND s.dataset_id IS NOT NULL
        ORDER BY s.id ASC
        LIMIT 1
      ) src
      WHERE NOT EXISTS (
        SELECT 1 FROM schema_definitions e
        WHERE e.name = 'paper' AND e.dataset_id = $2::uuid
      )
      """,
      [uuid(project_id), uuid(paperflow_id)]
    )
  end

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
      [[id]] -> uuid_to_string(id)
      _ -> nil
    end
  end

  defp paperflow_dataset_id do
    case default_project_id() do
      nil ->
        nil

      project_id ->
        %{rows: rows} =
          repo().query!(
            "SELECT id FROM datasets WHERE project_id = $1 AND slug = 'paperflow' LIMIT 1",
            [uuid(project_id)]
          )

        case rows do
          [[id]] -> uuid_to_string(id)
          _ -> nil
        end
    end
  end

  # Postgrex returns uuids as 16-byte binaries; normalize to the string form so
  # the helpers pass a canonical value back into `$n::uuid` casts.
  defp uuid_to_string(bin) when is_binary(bin) and byte_size(bin) == 16,
    do: Ecto.UUID.cast!(bin)

  defp uuid_to_string(str) when is_binary(str), do: str

  # Accept either the 16-byte binary or the string form; dump to the binary
  # Postgrex wants for a parameter.
  defp uuid(bin) when is_binary(bin) and byte_size(bin) == 16, do: bin

  defp uuid(str) when is_binary(str) do
    {:ok, dumped} = Ecto.UUID.dump(str)
    dumped
  end
end
