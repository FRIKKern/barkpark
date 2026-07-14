defmodule Barkpark.Repo.Migrations.AddWorkspaceIdToSearchSurfaceConfig do
  use Ecto.Migration

  # Close the LIVE cross-tenant config-overwrite bleed (charter D45/D49, Slice A
  # of Wave 5). `search_surface_config` was keyed on a bare, project-ambiguous
  # `scope` slug (the dataset segment, default "production"), so EXACTLY ONE
  # physical row existed for a `(surface, scope)` regardless of tenant — workspace
  # A's admin `PUT …/search/:dataset/settings` overwrote workspace B's config on
  # the shared "production" scope, spanning BOTH the documents and media surfaces.
  #
  # The runtime key becomes `(workspace_id, surface, scope)`. A nullable FK keeps
  # the table classifiable as E1 (information_schema column presence) so the
  # workspace bundle exports/deletes it via the `WHERE workspace_id = $ws` path
  # and the SQL CASCADE tears its rows down on workspace teardown, while the
  # workspace-agnostic seed defaults (`SurfaceConfigs.seed_defaults!/0`) stay as
  # NULL-workspace rows the anonymous search read path continues to read.
  #
  # UNIQUENESS INVARIANT PRESERVED (charter D57, mirroring the Slice C / D52
  # Candidate-A shape). A single `(workspace_id, surface, scope)` index would
  # LOSE the "at most one config per (surface, scope)" guarantee for NULL-
  # workspace rows, because Postgres treats NULL as distinct from NULL in a
  # standard unique index — so two concurrent NULL-workspace first-config PUTs
  # (the fresh-DB flat-route case, before a Default Workspace is seeded) could
  # both insert, and `get_by(surface, scope, workspace_id: nil)` would then raise
  # "expected at most one" (a 500) — the exact race `surface_config_race_test`
  # guards. So we split the domain into TWO partial unique indexes:
  #
  #   * NULL-workspace rows keep the ORIGINAL index name+shape as a partial
  #     `(surface, scope) WHERE workspace_id IS NULL` — the race guard and the
  #     changeset's existing `unique_constraint(name: …_surface_scope_idx)` stay
  #     intact for the workspace-agnostic path.
  #   * Stamped rows get `(workspace_id, surface, scope)` — per-workspace
  #     uniqueness (effective only for non-NULL workspace_id).
  def change do
    alter table(:search_surface_config) do
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: true
    end

    # Replace the bare (surface, scope) unique index with a partial that scopes
    # it to the NULL-workspace (global default) rows only. Keep the original name
    # so the changeset unique_constraint mapping and the race guard keep working.
    drop unique_index(:search_surface_config, [:surface, :scope],
           name: :search_surface_config_surface_scope_idx
         )

    create unique_index(:search_surface_config, [:surface, :scope],
             where: "workspace_id IS NULL",
             name: :search_surface_config_surface_scope_idx
           )

    # Per-workspace uniqueness for stamped rows. Full index (not partial) so the
    # upsert's ON CONFLICT can target it by column list without an index
    # predicate; it only *enforces* uniqueness for non-NULL workspace_id (NULLs
    # are covered by the partial index above).
    create unique_index(:search_surface_config, [:workspace_id, :surface, :scope],
             name: :search_surface_config_workspace_surface_scope_idx
           )
  end
end
