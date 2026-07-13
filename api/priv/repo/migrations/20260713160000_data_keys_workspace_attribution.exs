defmodule Barkpark.Repo.Migrations.DataKeysWorkspaceAttribution do
  use Ecto.Migration

  # bpb-shared-slug-dek-export-gap (Wave-4, charter D42/D43).
  #
  # W3 (#3036) narrowed the workspace-bundle export + teardown sweep of the
  # bare `scope`-keyed `data_keys` table to the PROJECT-QUALIFIED (workspace-
  # EXCLUSIVE) dataset-slug set, so a SHARED slug (every tenant gets a
  # `"production"` dataset — unique only per `(project_id, slug)`) can no longer
  # cross-tenant leak on export or cross-tenant over-delete on teardown. The
  # cost: a shared-slug per-dataset DEK is now LEFT OUT of a single-workspace
  # bundle — a documented D4 "zero silent loss" exception, because `data_keys`
  # carried NO way to attribute a `"dataset:production"` DEK to one workspace.
  #
  # This restores D4 completeness by giving `data_keys` a per-workspace identity:
  # a NULLABLE `workspace_id` FK to `workspaces`. `on_delete: :delete_all` matches
  # the E1 cascade convention (rbac roles / share_links / access_grants), so a
  # workspace teardown cascade-sweeps ONLY its own DEKs — a sibling workspace's
  # DEK under the SAME shared slug survives (the #3036 non-over-deletion
  # invariant). The exporter then copies `data_keys` through the standard E1
  # `WHERE workspace_id = $ws` path, so an attributed shared-slug DEK travels
  # correctly.
  #
  # NULLABLE by design: the table is EMPTY today (no `encrypted: true` field is
  # declared anywhere yet, so nothing writes it) and the runtime write-path that
  # will STAMP `workspace_id` is a separate backlog task (D44/D45). A NULL-
  # workspace legacy/dormant DEK is intentionally excluded from a per-workspace
  # bundle until that path is wired (the D44 forward-guard).
  #
  # The one-active-per-scope partial unique index is re-keyed from `(scope)` to
  # `(workspace_id, scope)`: with attribution, workspace A and workspace B may
  # each hold an ACTIVE DEK for the shared `"dataset:production"` scope, which a
  # scope-only unique index would have made impossible. ADDITIVE: the table is
  # empty, no data moved.
  def change do
    alter table(:data_keys) do
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all)
    end

    create index(:data_keys, [:workspace_id])

    drop unique_index(:data_keys, [:scope], name: :data_keys_one_active_per_scope)

    create unique_index(:data_keys, [:workspace_id, :scope],
             where: "active",
             name: :data_keys_one_active_per_scope
           )
  end
end
