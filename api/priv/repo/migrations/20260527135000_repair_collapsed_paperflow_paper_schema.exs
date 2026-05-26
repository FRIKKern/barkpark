defmodule Barkpark.Repo.Migrations.RepairCollapsedPaperflowPaperSchema do
  use Ecto.Migration

  @moduledoc """
  Wave-2 REPAIR (now a guarded no-op): compensate the EARLIER collapse DESIGN
  that grouped `schema_definitions` by `(name, project_id)` and would have
  DELETED the paperflow `paper` row.

  ## Why this is a no-op against the SHIPPED collapse

  This migration was written against an earlier `20260527133000` design that
  grouped by `(name, project_id)`. Under that design two `paper` rows — one
  `production` (seeded by `20260524120000`), one `paperflow` (seeded by
  `20260524131000`), both stamped with the same Default `project_id` — fell
  into one `(paper, Default)` group, and the collapse deleted the paperflow row,
  leaving only the production survivor. After `20260527134000` flipped schema
  uniqueness to `(name, dataset_id)`, the paperflow `paper` schema would then be
  permanently unresolvable. This migration re-created it.

  But the SHIPPED `20260527133000_collapse_duplicate_schema_definitions` groups
  by `(name, dataset_id)` — the SAME key the `20260527134000` flip uses — NOT
  by `(name, project_id)`. The two `paper` rows carry DISTINCT `dataset_id`s
  (production -> production dataset, paperflow -> paperflow dataset), so they
  fall into SEPARATE single-row groups, no collapse is attempted, and BOTH
  survive (the shipped 133000's own docstring spells this out). The paperflow
  row is therefore never deleted, and this repair finds it already present.

  ## What this does (idempotent + guarded)

  Re-insert the `paper` schema row scoped to the `paperflow` dataset, cloning
  the `production` paper row's definition and re-scoping only the `dataset`
  STRING + `dataset_id` FK to paperflow. We INSERT only when the
  `(name = "paper", dataset_id = <paperflow_id>)` row is MISSING. Against the
  shipped 133000 the paperflow row is always present, so the NOT EXISTS guard
  matches nothing and this is a no-op. It is RETAINED for any DB that was
  migrated against the pre-fix `(name, project_id)` 133000, where the paperflow
  row WAS deleted — there this migration restores it on the next migrate.

  Raw SQL — clone via `INSERT ... SELECT` so every column (including ones added
  by later migrations: layout/prefill/workspace_id/project_id/cors_origins/…)
  is carried verbatim from the survivor without naming each. At this migration's
  point in history the full live `schema_definitions` shape exists, so a
  `SELECT *`-style clone is safe; we override only `id`, `dataset`, `dataset_id`,
  and the timestamps.

  ## Reversibility

  `down/0` deletes the paperflow `paper` row this migration created — but ONLY
  the one whose `dataset_id` matches the paperflow dataset. This is the precise
  inverse of `up/0`. It does not touch the production survivor. (Against the
  shipped 133000, `up/0` created nothing, so `down/0` deleting the paperflow row
  it didn't create would be over-broad — but the paperflow row's `dataset_id`
  is the paperflow dataset, and the production survivor's is the production
  dataset, so down only ever removes the paperflow-scoped row. Re-running the
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
  # is present (idempotent + re-run safe; against the shipped 133000 the
  # paperflow row is always present, so this never inserts). gen_random_uuid()
  # gives the clone a fresh id; `dataset`/`dataset_id` are overridden to
  # paperflow; timestamps are refreshed. Every OTHER column is copied verbatim
  # from the survivor. The production survivor is matched by name + dataset
  # string only — NOT requiring dataset_id non-null — so a production row stamped
  # with a NULL dataset_id (e.g. seeded before the 132000 backfill on a
  # standalone `mix run seeds.exs`) is still a valid clone source. The ORDER BY
  # prefers a non-null, lexically-first dataset_id for determinism.
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
        ORDER BY (s.dataset_id IS NOT NULL) DESC, s.dataset_id ASC, s.id ASC
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
