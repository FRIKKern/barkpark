defmodule Barkpark.Repo.Migrations.CreateEpicAssignments do
  use Ecto.Migration

  def up do
    create table(:epic_assignments, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_id, references(:workspaces, type: :uuid), null: false
      add :epic_id, :text, null: false
      add :wave_id, :text, null: false
      add :assignment_id, :text, null: false
      add :phase, :text, null: false
      add :agent_type, :text, null: false
      add :effort, :text, null: false
      add :snapshot, :map, null: false, default: %{}
      add :snapshot_digest, :text, null: false

      add :replaces_assignment_id,
          references(:epic_assignments, type: :uuid, on_delete: :restrict)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(
             :epic_assignments,
             [:workspace_id, :epic_id, :wave_id, :assignment_id],
             name: :epic_assignments_scope_assignment_index
           )

    create index(:epic_assignments, [:workspace_id, :epic_id, :wave_id, :phase])
    create index(:epic_assignments, [:replaces_assignment_id])

    create constraint(:epic_assignments, :epic_assignments_phase,
             check: "phase IN ('survey', 'verify', 'build', 'review')"
           )

    create constraint(:epic_assignments, :epic_assignments_effort,
             check: "effort IN ('medium', 'high')"
           )

    create constraint(:epic_assignments, :epic_assignments_snapshot_digest,
             check: "snapshot_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:epic_assignments, :epic_assignments_not_self_replacement,
             check: "replaces_assignment_id IS NULL OR replaces_assignment_id <> id"
           )

    create table(:epic_assignment_results, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :assignment_id,
          references(:epic_assignments, type: :uuid, on_delete: :restrict),
          null: false

      add :idempotency_key, :text, null: false
      add :status, :text, null: false
      add :summary, :text
      add :evidence, :text
      add :evidence_revision, :text
      add :evidence_digest, :text, null: false
      add :payload, :map, null: false, default: %{}
      add :payload_digest, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:epic_assignment_results, [:assignment_id],
             name: :epic_assignment_results_assignment_index
           )

    create unique_index(:epic_assignment_results, [:assignment_id, :idempotency_key],
             name: :epic_assignment_results_idempotency_index
           )

    create constraint(:epic_assignment_results, :epic_assignment_results_status,
             check: "status IN ('completed', 'failed', 'cancelled')"
           )

    create constraint(:epic_assignment_results, :epic_assignment_results_evidence_digest,
             check: "evidence_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:epic_assignment_results, :epic_assignment_results_payload_digest,
             check: "payload_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:epic_assignment_results, :epic_assignment_results_completed_evidence,
             check:
               "status <> 'completed' OR (evidence IS NOT NULL AND evidence_revision IS NOT NULL AND length(trim(evidence)) > 0 AND length(trim(evidence_revision)) > 0)"
           )

    execute """
    CREATE OR REPLACE FUNCTION barkpark_epic_ledger_immutable()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION '% is append-only (% forbidden)', TG_TABLE_NAME, TG_OP;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER epic_assignments_no_update_delete
    BEFORE UPDATE OR DELETE ON epic_assignments
    FOR EACH ROW EXECUTE FUNCTION barkpark_epic_ledger_immutable();
    """

    execute """
    CREATE TRIGGER epic_assignment_results_no_update_delete
    BEFORE UPDATE OR DELETE ON epic_assignment_results
    FOR EACH ROW EXECUTE FUNCTION barkpark_epic_ledger_immutable();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS epic_assignment_results_no_update_delete ON epic_assignment_results;"
    execute "DROP TRIGGER IF EXISTS epic_assignments_no_update_delete ON epic_assignments;"
    execute "DROP FUNCTION IF EXISTS barkpark_epic_ledger_immutable();"
    drop table(:epic_assignment_results)
    drop table(:epic_assignments)
  end
end
