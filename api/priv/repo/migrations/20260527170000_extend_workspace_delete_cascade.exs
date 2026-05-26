defmodule Barkpark.Repo.Migrations.ExtendWorkspaceDeleteCascade do
  use Ecto.Migration

  @moduledoc """
  EXTENDED CASCADE (obhg P0 + 0f7g P1 follow-up to 4lsn/160000).

  ## What 160000 left open

  Migration 20260527160000 flipped the three scope FKs (workspace_id /
  project_id / dataset_id) on the four content-bearing tables (documents /
  revisions / media_files / schema_definitions) from `:nilify_all` to
  `:delete_all`. Good for the four content tables — closed the
  orphan-resurfaces-under-Default leak.

  But 20260527110100 + 20260527120000 + 20260527131000 added scope FKs to
  SEVEN MORE tables that 160000 did NOT touch:

    * webhooks                       (ws+project from 110100, dataset from 131000)
    * mutation_events                (ws+project from 110100, dataset from 131000)
    * search_intel_events            (ws+project from 110100, dataset from 131000)
    * search_intel_crystals          (ws+project from 110100, dataset from 131000)
    * search_intel_merge_patterns    (ws+project from 110100, dataset from 131000)
    * search_synonyms                (ws+project from 110100, dataset from 131000)
    * paper_events                   (ws+project from 120000,  dataset from 131000)

  All seven still carry `:nilify_all` on their scope FKs. So deleting a
  workspace SET-NULLs their scope columns while their `dataset` STRING
  survives — the SAME orphan-resurfaces-under-Default leak 160000 was meant
  to close, just on the OTHER half of the schema. Webhooks especially:
  a deleted-workspace webhook with workspace_id=NULL stays alive and would
  fire on Default mutations.

  ## What this migration does

  Flips those 21 FKs (7 tables × 3 scope cols) from `:nilify_all` to
  `:delete_all`. These tables have NO app-side side effects on row delete —
  events / search rows / webhooks are just rows — so SQL cascade is the right
  primitive. Side-effect cleanup for media_files (File.rm / Cdn.invalidate /
  Plugins.Registry.run_after_media_delete) lives in
  `Barkpark.Tenancy.delete_workspace/1`, which fires BEFORE Repo.delete on the
  workspace; the SQL CASCADE on media_files (160000) is the belt-and-suspenders
  backstop. See moduledoc on `Barkpark.Tenancy.delete_workspace/1`.

  ## up/0 — nilify_all -> delete_all on all 21 FKs
  ## down/0 — the precise inverse: delete_all -> nilify_all

  Implemented as raw `ALTER TABLE` DDL (DROP CONSTRAINT + ADD CONSTRAINT)
  mirroring 160000, so `apply_up/1` / `apply_down/1` can drive the body
  against a sandbox connection from a plain test.
  """

  # {table, column, referenced_table}. All scope FKs use Ecto-default name
  # (`<table>_<column>_fkey`), verified via pg_constraint catalog.
  @fks [
    {"webhooks", "workspace_id", "workspaces"},
    {"webhooks", "project_id", "projects"},
    {"webhooks", "dataset_id", "datasets"},
    {"mutation_events", "workspace_id", "workspaces"},
    {"mutation_events", "project_id", "projects"},
    {"mutation_events", "dataset_id", "datasets"},
    {"search_intel_events", "workspace_id", "workspaces"},
    {"search_intel_events", "project_id", "projects"},
    {"search_intel_events", "dataset_id", "datasets"},
    {"search_intel_crystals", "workspace_id", "workspaces"},
    {"search_intel_crystals", "project_id", "projects"},
    {"search_intel_crystals", "dataset_id", "datasets"},
    {"search_intel_merge_patterns", "workspace_id", "workspaces"},
    {"search_intel_merge_patterns", "project_id", "projects"},
    {"search_intel_merge_patterns", "dataset_id", "datasets"},
    {"search_synonyms", "workspace_id", "workspaces"},
    {"search_synonyms", "project_id", "projects"},
    {"search_synonyms", "dataset_id", "datasets"},
    {"paper_events", "workspace_id", "workspaces"},
    {"paper_events", "project_id", "projects"},
    {"paper_events", "dataset_id", "datasets"}
  ]

  def up, do: do_swap(repo(), "CASCADE")
  def down, do: do_swap(repo(), "SET NULL")

  def apply_up(repo \\ Barkpark.Repo), do: do_swap(repo, "CASCADE")
  def apply_down(repo \\ Barkpark.Repo), do: do_swap(repo, "SET NULL")

  defp do_swap(repo, action) do
    for {table, column, ref} <- @fks do
      constraint = "#{table}_#{column}_fkey"

      repo.query!("ALTER TABLE #{table} DROP CONSTRAINT #{constraint}", [])

      repo.query!(
        """
        ALTER TABLE #{table}
        ADD CONSTRAINT #{constraint}
        FOREIGN KEY (#{column}) REFERENCES #{ref}(id)
        ON DELETE #{action}
        """,
        []
      )
    end

    :ok
  end
end
