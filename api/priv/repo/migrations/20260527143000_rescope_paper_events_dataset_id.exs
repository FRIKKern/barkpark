defmodule Barkpark.Repo.Migrations.RescopePaperEventsDatasetId do
  use Ecto.Migration

  @moduledoc """
  CORRECTIVE (84bn). The Wave-2 backfill (20260527132000:182-193) stamped
  EVERY `paper_events.dataset_id` to the Default project's `production` dataset
  UNCONDITIONALLY (`WHERE dataset_id IS NULL`, no per-row scope). But the
  earlier W1.5 backfill (20260527120000:37-49) had already derived each
  paper_event's `workspace_id`/`project_id` from its paper's actual scope
  (paper_slug -> documents.doc_id, type 'paper'). So a paper_event can carry

      project_id  = <a NON-Default project>
      dataset_id  = <the Default project's production dataset>

  — a `dataset` that belongs to a DIFFERENT project than the row's own
  `project_id`. That is a structurally-impossible scope tuple (a Dataset
  belongs_to exactly one Project; 20260527130000). Latent today because every
  paper currently lives in the Default project, but wrong the moment a paper is
  authored under a non-Default project.

  ## up/0 — re-resolve from each row's OWN project + its paper's dataset string

  Mirror the W1.5 join: paper_event -> its paper document (paper_slug = doc_id,
  type 'paper') -> that document's `dataset` STRING. Then resolve
  `(paper_events.project_id, that dataset string)` -> the `datasets` row under
  THAT project. We ONLY touch rows whose CURRENT dataset_id points at a dataset
  in a project OTHER than the row's own project_id — the mismatched ones. A
  correct row (dataset's project == the row's project) is left untouched, which
  makes a re-run a no-op (idempotent).

  Two passes:

    1. PAPER-DERIVED: for mismatched rows that DO join to a paper, set
       dataset_id to the datasets row under the row's OWN project_id whose slug
       = the paper's dataset string. (When that project has no datasets row for
       that string, pass 1 leaves the row for pass 2.)

    2. ORPHAN FALLBACK: for any STILL-mismatched row that does not join to a
       paper (or whose own project lacks the resolved dataset), fall back to the
       Default project's `production` dataset — preserving the prior backfill's
       behaviour for orphans. Guarded on the Default project existing.

  Every statement is a direct `repo().query!` (no buffered DDL/alters), so no
  `flush()` is needed between passes — the snapshot is committed before the
  UPDATEs read/replace it.

  ## down/0 — restore the pre-correction dataset_id

  up/0 snapshots the prior `(id, dataset_id)` of every row it is ABOUT to change
  into `paper_events_dataset_rescope_backup` (created idempotently) BEFORE the
  UPDATEs. down/0 restores from that snapshot and drops it. If the snapshot is
  absent (a partial / out-of-order rollback), down/0 is a documented no-op
  rather than a destructive guess — the prior value isn't otherwise derivable
  once corrected.
  """

  @backup_table "paper_events_dataset_rescope_backup"

  # `up`/`down` run inside the migrator (repo() bound by the runner). `apply_up`
  # / `apply_down` let a test drive the same body against an explicit repo /
  # sandbox connection — every SQL call is routed through these so neither path
  # depends on the runner's `flush()`.
  def up, do: do_up(repo())
  def down, do: do_down(repo())

  def apply_up(repo \\ Barkpark.Repo), do: do_up(repo)
  def apply_down(repo \\ Barkpark.Repo), do: do_down(repo)

  # --- up -------------------------------------------------------------------

  defp do_up(repo) do
    # 1. Snapshot the rows we are about to change so down/0 can restore exactly.
    #    Rebuilt fresh each up so a re-run reflects the CURRENT mismatched set.
    repo.query!("DROP TABLE IF EXISTS #{@backup_table}", [])

    repo.query!(
      """
      CREATE TABLE #{@backup_table} (
        id uuid PRIMARY KEY,
        dataset_id uuid
      )
      """,
      []
    )

    repo.query!(
      """
      INSERT INTO #{@backup_table} (id, dataset_id)
      SELECT pe.id, pe.dataset_id
      FROM paper_events pe
      JOIN datasets cur ON cur.id = pe.dataset_id
      WHERE pe.project_id IS NOT NULL
        AND cur.project_id <> pe.project_id
      """,
      []
    )

    # 2. PAPER-DERIVED re-resolution. For each MISMATCHED row that joins to its
    #    paper document, resolve the datasets row under the row's OWN project_id
    #    whose slug = the paper's dataset string. Postgres requires the joined
    #    documents/datasets in the FROM list with the correlation in WHERE.
    repo.query!(
      """
      UPDATE paper_events pe
      SET dataset_id = own.id
      FROM datasets cur, documents doc, datasets own
      WHERE pe.dataset_id = cur.id
        AND pe.project_id IS NOT NULL
        AND cur.project_id <> pe.project_id
        AND pe.paper_slug IS NOT NULL
        AND doc.doc_id = pe.paper_slug
        AND doc.type = 'paper'
        AND doc.dataset IS NOT NULL
        AND own.project_id = pe.project_id
        AND own.slug = doc.dataset
      """,
      []
    )

    # 3. ORPHAN FALLBACK. Any row STILL mismatched (no paper join, or its own
    #    project has no datasets row for the paper's dataset string) falls back
    #    to the Default project's `production` dataset — preserving the prior
    #    backfill's behaviour for orphans. Guarded on Default existing.
    case default_production_dataset_id(repo) do
      nil ->
        :ok

      default_production_id ->
        repo.query!(
          """
          UPDATE paper_events pe
          SET dataset_id = $1
          FROM datasets cur
          WHERE pe.dataset_id = cur.id
            AND pe.project_id IS NOT NULL
            AND cur.project_id <> pe.project_id
          """,
          [default_production_id]
        )
    end
  end

  # --- down -----------------------------------------------------------------

  defp do_down(repo) do
    # Restore from the up-time snapshot when present; otherwise a documented
    # no-op (the pre-correction value isn't derivable once corrected).
    %{rows: [[exists]]} =
      repo.query!(
        "SELECT to_regclass($1) IS NOT NULL",
        ["public.#{@backup_table}"]
      )

    if exists do
      repo.query!(
        """
        UPDATE paper_events pe
        SET dataset_id = b.dataset_id
        FROM #{@backup_table} b
        WHERE b.id = pe.id
        """,
        []
      )

      repo.query!("DROP TABLE IF EXISTS #{@backup_table}", [])
    else
      :ok
    end
  end

  # --- helpers --------------------------------------------------------------

  defp default_production_dataset_id(repo) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT d.id
        FROM datasets d
        JOIN projects p ON p.id = d.project_id
        JOIN workspaces w ON w.id = p.workspace_id
        WHERE w.slug = 'default' AND p.slug = 'default' AND d.slug = 'production'
        """,
        []
      )

    case rows do
      [[dataset_id]] -> dataset_id
      _ -> nil
    end
  end
end
