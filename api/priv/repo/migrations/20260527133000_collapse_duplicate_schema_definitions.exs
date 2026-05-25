defmodule Barkpark.Repo.Migrations.CollapseDuplicateSchemaDefinitions do
  use Ecto.Migration

  @moduledoc """
  Wave-2 GATE: collapse duplicate `schema_definitions` rows so the planned
  uniqueness flip to `(name, project_id)` (grill decision #3 — schemas are
  project-scoped: one shared catalog per project) won't collide.

  ## Why duplicates exist

  The convergence migrations seeded the `paper` schema TWICE under different
  dataset STRINGS:

    * `20260524120000_move_papers_to_production` seeds it in `production`.
    * `20260524131000_papers_as_documents` seeds it in `paperflow` (plus any
      dataset that has papers).

  Both inserts carry IDENTICAL substantive content (same fields, title, icon,
  visibility). Each is keyed by the `(name, dataset)` unique index, so both
  rows coexist. Wave-1's Default-tenancy backfill (`20260527110200`) then
  stamped BOTH rows with the SAME Default `project_id`. Result: two rows that
  share `(name="paper", project_id=<Default>)` but differ only by their
  `dataset` string — a collision-in-waiting for the `(name, project_id)` flip.

  ## What this does (GUARDED + REVERSIBLE)

  1. Find every `(name, project_id)` group with >1 row.
  2. For each group, compare the rows' SUBSTANTIVE content — every column
     EXCEPT `id`, `dataset`, `dataset_id`, `inserted_at`, `updated_at`. If any
     two rows in a group DIFFER substantively, RAISE — we refuse to destroy
     data and surface the conflict for an orchestrator decision.
  3. For each byte-identical group, KEEP one survivor (prefer the row whose
     `dataset = 'production'`; otherwise the lexicographically smallest id for
     determinism) and DELETE the redundant rows.

  No DB-level FK references `schema_definitions.id` (schemas are resolved by
  `(name, dataset)` string in `Content.get_schema/3` / `list_schemas/2`, and
  the in-app `schema_id` is the schema NAME, not the row id), so deleting a
  redundant row orphans nothing — no repointing is required.

  Idempotent: once collapsed, no `(name, project_id)` group has >1 row, so the
  second run finds nothing and is a no-op.

  ## Reversibility

  Before deleting, every doomed row is snapshotted (full row, via `to_jsonb`)
  into a sidecar table `collapsed_schema_definitions_backup`. `down/0` restores
  the snapshotted rows verbatim (id and all) and drops the sidecar table, so
  the collapse is fully reversible while the backup survives.

  This migration does NOT flip the uniqueness constraint (that is the next W2
  step), does NOT drop the `dataset` string, and does NOT rewrite any query.
  It ONLY removes redundant duplicate rows.
  """

  # Substantive columns — everything that defines what the schema IS. A group
  # is "byte-identical" iff all rows share the same tuple of these values.
  # Deliberately EXCLUDES id / dataset / dataset_id / inserted_at / updated_at.
  @substantive_columns ~w(
    name
    title
    icon
    visibility
    fields
    cors_origins
    actions
    groups
    desk_groups
    initial_values
    cross_validations
    layout
    prefill
    workspace_id
    project_id
  )

  @backup_table "collapsed_schema_definitions_backup"

  def up do
    flush()

    # Snapshot table for reversibility — holds a full jsonb copy of every row
    # we delete (created up-front; harmless if no rows are collapsed).
    repo().query!(
      """
      CREATE TABLE IF NOT EXISTS #{@backup_table} (
        id uuid PRIMARY KEY,
        row jsonb NOT NULL,
        collapsed_at timestamptz NOT NULL DEFAULT now()
      )
      """,
      []
    )

    # Every (name, project_id) group with more than one row. We treat
    # project_id IS NULL as its own group bucket (no Default project anchored
    # yet) — those rows can still collide on the future index where both are
    # NULL, but Postgres unique indexes treat NULLs as distinct, so a NULL
    # group is harmless; we still collapse identical NULL-project dupes for
    # cleanliness.
    %{rows: group_rows} =
      repo().query!(
        """
        SELECT name, project_id
        FROM schema_definitions
        GROUP BY name, project_id
        HAVING count(*) > 1
        """,
        []
      )

    Enum.each(group_rows, fn [name, project_id] ->
      collapse_group(name, project_id)
    end)
  end

  def down do
    flush()

    # Restore every snapshotted row verbatim. jsonb_populate_record rebuilds
    # the schema_definitions row from the captured jsonb (id and all). Guarded
    # by NOT EXISTS so a partial rollback can't double-insert.
    if backup_table_exists?() do
      repo().query!(
        """
        INSERT INTO schema_definitions
        SELECT (jsonb_populate_record(NULL::schema_definitions, b.row)).*
        FROM #{@backup_table} b
        WHERE NOT EXISTS (
          SELECT 1 FROM schema_definitions s WHERE s.id = b.id
        )
        """,
        []
      )

      execute("DROP TABLE IF EXISTS #{@backup_table}")
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp collapse_group(name, project_id) do
    {where_clause, params} = group_filter(name, project_id)

    %{rows: rows, columns: columns} =
      repo().query!(
        """
        SELECT *
        FROM schema_definitions
        WHERE #{where_clause}
        ORDER BY (dataset = 'production') DESC, id ASC
        """,
        params
      )

    # The survivor is the first row after the ORDER BY (production-first, then
    # smallest id). All others are candidates for deletion.
    [survivor | redundant] = Enum.map(rows, fn r -> Enum.zip(columns, r) |> Map.new() end)

    # Guard: refuse to delete unless every redundant row is substantively
    # identical to the survivor. A substantive difference means these are NOT
    # true duplicates — stop and surface for an orchestrator decision.
    Enum.each(redundant, fn row ->
      diff = substantive_diff(survivor, row)

      unless diff == [] do
        raise """
        Refusing to collapse schema_definitions group #{inspect({name, project_id})}:
        rows differ in substantive columns and are NOT byte-identical duplicates.
        Survivor id=#{survivor["id"]} (dataset=#{survivor["dataset"]});
        conflicting id=#{row["id"]} (dataset=#{row["dataset"]}).
        Differing columns: #{inspect(diff)}.
        This migration only collapses byte-identical duplicates — resolve this
        conflict by hand (an orchestrator decision) before re-running.
        """
      end
    end)

    # Snapshot + delete each redundant row.
    Enum.each(redundant, fn row ->
      id = row["id"]

      repo().query!(
        """
        INSERT INTO #{@backup_table} (id, row)
        SELECT id, to_jsonb(s.*) FROM schema_definitions s WHERE s.id = $1
        ON CONFLICT (id) DO NOTHING
        """,
        [uuid(id)]
      )

      repo().query!("DELETE FROM schema_definitions WHERE id = $1", [uuid(id)])
    end)
  end

  # WHERE fragment that selects exactly the rows of one group, handling the
  # NULL project_id case (which `= $2` would never match).
  defp group_filter(name, nil), do: {"name = $1 AND project_id IS NULL", [name]}
  defp group_filter(name, project_id), do: {"name = $1 AND project_id = $2", [name, uuid(project_id)]}

  # Return the list of substantive columns where survivor and row differ.
  # Comparison is on the raw decoded values Postgrex returns (jsonb -> maps,
  # uuid -> binary), so equality is structural / byte-level.
  defp substantive_diff(survivor, row) do
    Enum.filter(@substantive_columns, fn col ->
      Map.get(survivor, col) != Map.get(row, col)
    end)
  end

  # Postgrex returns/accepts uuids as 16-byte binaries. Pass them straight
  # through (they arrive that way from SELECT *), or cast a string form.
  defp uuid(bin) when is_binary(bin) and byte_size(bin) == 16, do: bin

  defp uuid(str) when is_binary(str) do
    {:ok, dumped} = Ecto.UUID.dump(str)
    dumped
  end

  defp backup_table_exists? do
    %{rows: [[exists]]} =
      repo().query!("SELECT to_regclass('public.#{@backup_table}') IS NOT NULL", [])

    exists
  end
end
