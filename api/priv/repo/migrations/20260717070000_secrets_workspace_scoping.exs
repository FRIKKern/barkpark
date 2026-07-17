defmodule Barkpark.Repo.Migrations.SecretsWorkspaceScoping do
  use Ecto.Migration

  # Connectors W21 (charter D191–D195) — the run-secrets tenant wall.
  #
  # The secrets store was FLAT INSTANCE-GLOBAL: PK on `name` (20260629140000),
  # no tenant column, `list/0` returning every row. A Postgres PK is total, so
  # keeping `name` as PK forbids the per-tenant `UNIQUE(workspace_id, name)`
  # arm AND ships a cross-tenant ENUMERATION ORACLE (ws-A's
  # `put("slack_bot_token")` collides with ws-B's globally-unique name — A
  # learns B holds it). D191 therefore ratified the surrogate-PK two-tier
  # shape, run-proven live at Verify (migration clean, coexistence count=3,
  # per-arm dup rejection):
  #
  #   * PK moves to a surrogate `id :binary_id` (gen_random_uuid() backfill —
  #     built-in PG13+; prod's single real row `ingest_token` auto-backfills
  #     and stays global). `name` demotes to an ordinary NOT NULL column.
  #   * Nullable `workspace_id` FK → workspaces, `on_delete: :delete_all`
  #     (D192 — the data_keys 20260714010000 / E1-cascade majority law; a live
  #     credential has zero reason to outlive its tenant, and a never-cascaded
  #     orphan encrypted secret is a growing forgotten-secret surface).
  #     NO workspace_id backfill: every existing row IS genuinely
  #     instance-global. Data-nondestructive — zero rows deleted, zero values
  #     touched.
  #   * Two partial unique indexes replace the PK's uniqueness:
  #       - secrets_global_name_index  UNIQUE(name) WHERE workspace_id IS NULL
  #         (byte-identical to today's global-arm uniqueness)
  #       - secrets_workspace_name_index UNIQUE(workspace_id, name)
  #         WHERE workspace_id IS NOT NULL
  #         (per-tenant arm — the same name may coexist per workspace + global)
  #   * secrets_audit gains the workspace dimension (D195): nullable
  #     workspace_id, same FK, indexed [workspace_id, inserted_at] mirroring
  #     the existing [name, inserted_at].
  #
  # CI exercises `up` only; `down` is written for completeness (verified by
  # hand — `mix ecto.rollback` misreported at Verify, trust `psql \d secrets`).
  def up do
    execute "ALTER TABLE secrets DROP CONSTRAINT secrets_pkey"

    alter table(:secrets) do
      add :id, :binary_id
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all)
    end

    execute "UPDATE secrets SET id = gen_random_uuid() WHERE id IS NULL"
    execute "ALTER TABLE secrets ALTER COLUMN id SET NOT NULL"
    execute "ALTER TABLE secrets ADD PRIMARY KEY (id)"

    create unique_index(:secrets, [:name],
             where: "workspace_id IS NULL",
             name: :secrets_global_name_index
           )

    create unique_index(:secrets, [:workspace_id, :name],
             where: "workspace_id IS NOT NULL",
             name: :secrets_workspace_name_index
           )

    alter table(:secrets_audit) do
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all)
    end

    create index(:secrets_audit, [:workspace_id, :inserted_at])
  end

  def down do
    drop index(:secrets_audit, [:workspace_id, :inserted_at])

    alter table(:secrets_audit) do
      remove :workspace_id
    end

    drop unique_index(:secrets, [:workspace_id, :name], name: :secrets_workspace_name_index)
    drop unique_index(:secrets, [:name], name: :secrets_global_name_index)

    # Rolling back strands any workspace-scoped rows in a name-PK world where
    # the same name may repeat — delete the scoped tier (it cannot be
    # represented flat) before restoring the original PK.
    execute "DELETE FROM secrets WHERE workspace_id IS NOT NULL"

    execute "ALTER TABLE secrets DROP CONSTRAINT secrets_pkey"

    alter table(:secrets) do
      remove :workspace_id
      remove :id
    end

    execute "ALTER TABLE secrets ADD PRIMARY KEY (name)"
  end
end
