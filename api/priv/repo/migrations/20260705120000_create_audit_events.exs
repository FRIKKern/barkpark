defmodule Barkpark.Repo.Migrations.CreateAuditEvents do
  @moduledoc """
  era-w1-audit-bus — the tenant-wide, append-only, tamper-evident audit log.

  Generalizes the two drifted narrow trails (`plugin_settings_audit`,
  `secrets_audit` — three different column names for the same concepts) into
  ONE `audit_events` table. Rows form a per-workspace sha256 hash chain
  (`hash = sha256(prev_hash <> canonical(row))`) so any silent tampering with
  history is detectable. Append-only is enforced at the DB layer by a trigger
  that rejects UPDATE/DELETE (TRUNCATE is left permitted so the Ecto sandbox
  can reset the table between tests).
  """
  use Ecto.Migration

  def up do
    create table(:audit_events) do
      # implicit bigserial :id — monotonic insert order = chain order.
      add :category, :string, null: false
      add :action, :string, null: false
      add :subject, :string
      add :actor_type, :string
      add :actor_id, :string
      add :workspace_id, :binary_id
      add :project_id, :binary_id
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false
      # prev_hash is NULL only for the genesis row of a workspace chain.
      add :prev_hash, :string
      add :hash, :string, null: false
    end

    # Per-tenant timeline, category filter, and subject lookup.
    create index(:audit_events, [:workspace_id, :id])
    create index(:audit_events, [:category, :occurred_at])
    create index(:audit_events, [:subject, :occurred_at])
    # A duplicate hash means a replay or a forked chain — reject it.
    create unique_index(:audit_events, [:hash])

    # Append-only teeth at the DB layer (both narrow trails lacked this).
    # UPDATE/DELETE are rejected; TRUNCATE is intentionally NOT blocked so the
    # Ecto SQL sandbox can reset the table between tests.
    execute """
    CREATE OR REPLACE FUNCTION barkpark_audit_events_immutable()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'audit_events is append-only (% forbidden)', TG_OP;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER audit_events_no_update_delete
    BEFORE UPDATE OR DELETE ON audit_events
    FOR EACH ROW EXECUTE FUNCTION barkpark_audit_events_immutable();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS audit_events_no_update_delete ON audit_events;"
    execute "DROP FUNCTION IF EXISTS barkpark_audit_events_immutable();"
    drop table(:audit_events)
  end
end
