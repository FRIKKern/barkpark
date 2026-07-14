defmodule Barkpark.Repo.Migrations.DataKeysWorkspaceAttribution do
  use Ecto.Migration

  # bpb-datakeys-write-path-workspace-attribution (Wave-5, charter D51-D54).
  #
  # SUPERSEDES #3065 (bpb-shared-slug-dek-export-gap), which re-keyed the
  # one-active partial unique index from `(scope)` to `(workspace_id, scope)
  # WHERE active` WITHOUT accounting for NULL workspace_id: Postgres treats NULLs
  # as DISTINCT in a unique index, so two ACTIVE rows with workspace_id NULL for
  # the same scope stopped colliding — breaking the LOW-18 invariant
  # ("exactly one ACTIVE DEK per scope") that `DataKeys.active_dek/2` relies on
  # (CryptoTest LOW-18 at crypto_test.exs:214 went red). This migration is the
  # CORRECT attribution: it gives `data_keys` a per-workspace identity AND keeps
  # LOW-18 green for the NULL-workspace (legacy/dormant) rows, and it wires the
  # runtime write-path that STAMPS `workspace_id` (the D44/D45 work #3065
  # deferred).
  #
  # `data_keys` is EMPTY today (no `encrypted: true` field is declared anywhere,
  # so nothing has ever written it) — forward-only, no backfill, no re-key of
  # existing rows.
  #
  # 1. Nullable `workspace_id` FK to `workspaces`. `on_delete: :delete_all`
  #    matches the E1 cascade convention (roles / share_links / access_grants),
  #    so a workspace teardown cascade-sweeps ONLY its own DEKs — a sibling
  #    workspace's DEK under the SAME shared slug survives. The exporter then
  #    copies `data_keys` through the standard E1 `WHERE workspace_id = $ws`
  #    path, so an attributed shared-slug DEK travels correctly. NULLABLE by
  #    design: a NULL-workspace legacy/dormant DEK is intentionally excluded from
  #    a per-workspace bundle (the D44 forward-guard).
  #
  # 2. Candidate-A two-partial-index one-active enforcement (charter D52):
  #    DROP the single `(scope) WHERE active` index and CREATE TWO partial unique
  #    indexes so exactly-one-active holds in BOTH attribution regimes:
  #      * `(scope) WHERE active AND workspace_id IS NULL` — preserves LOW-18 for
  #        the NULL-workspace rows (the FieldCipher direct / legacy path), where a
  #        `(workspace_id, scope)` index would NOT collide (NULLs distinct).
  #      * `(workspace_id, scope) WHERE active AND workspace_id IS NOT NULL` —
  #        one active DEK per (workspace, scope), so workspace A and workspace B
  #        may each hold an active DEK for the shared `"dataset:production"` scope.
  #
  # 3. Re-key the `(scope, version)` unique index to `(workspace_id, scope,
  #    version)` (charter D53, folds #3061): with attribution, workspace A and
  #    workspace B must each be able to mint a version-1 DEK for the shared
  #    scope, which a `(scope, version)` unique index made impossible
  #    (`:unique_violation` on the second workspace's v1). ADDITIVE: the table
  #    is empty, no data moved.
  def change do
    alter table(:data_keys) do
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all)
    end

    create index(:data_keys, [:workspace_id])

    # D52 — Candidate-A: two partial one-active indexes (LOW-18 preserved).
    drop unique_index(:data_keys, [:scope], name: :data_keys_one_active_per_scope)

    create unique_index(:data_keys, [:scope],
             where: "active AND workspace_id IS NULL",
             name: :data_keys_one_active_per_scope
           )

    create unique_index(:data_keys, [:workspace_id, :scope],
             where: "active AND workspace_id IS NOT NULL",
             name: :data_keys_one_active_per_scope_ws
           )

    # D53 — re-key (scope, version) → (workspace_id, scope, version) (folds #3061).
    drop unique_index(:data_keys, [:scope, :version], name: :data_keys_scope_version_index)

    create unique_index(:data_keys, [:workspace_id, :scope, :version],
             name: :data_keys_ws_scope_version_index
           )
  end
end
