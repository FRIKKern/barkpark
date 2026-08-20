defmodule Barkpark.Repo.Migrations.HardenEpicAssignmentLedger do
  use Ecto.Migration

  @completed_evidence_check "status <> 'completed' OR (evidence IS NOT NULL AND evidence_revision IS NOT NULL AND length(trim(evidence)) > 0 AND length(trim(evidence_revision)) > 0)"

  def up do
    drop constraint(:epic_assignment_results, :epic_assignment_results_completed_evidence)

    create constraint(:epic_assignment_results, :epic_assignment_results_completed_evidence,
             check: @completed_evidence_check
           )

    create unique_index(:epic_assignments, [:replaces_assignment_id],
             name: :epic_assignments_replaces_assignment_index,
             where: "replaces_assignment_id IS NOT NULL"
           )

    execute """
    ALTER TABLE epic_assignment_results
      DROP CONSTRAINT epic_assignment_results_assignment_id_fkey,
      ADD CONSTRAINT epic_assignment_results_assignment_id_fkey
        FOREIGN KEY (assignment_id) REFERENCES epic_assignments(id) ON DELETE CASCADE;
    """

    execute """
    ALTER TABLE epic_assignments
      DROP CONSTRAINT epic_assignments_workspace_id_fkey,
      ADD CONSTRAINT epic_assignments_workspace_id_fkey
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE;
    """

    execute cascade_aware_immutability_function()
  end

  def down do
    execute strict_immutability_function()

    execute """
    ALTER TABLE epic_assignment_results
      DROP CONSTRAINT epic_assignment_results_assignment_id_fkey,
      ADD CONSTRAINT epic_assignment_results_assignment_id_fkey
        FOREIGN KEY (assignment_id) REFERENCES epic_assignments(id) ON DELETE RESTRICT;
    """

    execute """
    ALTER TABLE epic_assignments
      DROP CONSTRAINT epic_assignments_workspace_id_fkey,
      ADD CONSTRAINT epic_assignments_workspace_id_fkey
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE RESTRICT;
    """

    drop_if_exists index(:epic_assignments, [:replaces_assignment_id],
                     name: :epic_assignments_replaces_assignment_index
                   )

    drop constraint(:epic_assignment_results, :epic_assignment_results_completed_evidence)

    create constraint(:epic_assignment_results, :epic_assignment_results_completed_evidence,
             check:
               "status <> 'completed' OR (length(trim(evidence)) > 0 AND length(trim(evidence_revision)) > 0)"
           )
  end

  defp cascade_aware_immutability_function do
    """
    CREATE OR REPLACE FUNCTION barkpark_epic_ledger_immutable()
    RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
        RETURN OLD;
      END IF;

      RAISE EXCEPTION '% is append-only (% forbidden)', TG_TABLE_NAME, TG_OP;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp strict_immutability_function do
    """
    CREATE OR REPLACE FUNCTION barkpark_epic_ledger_immutable()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION '% is append-only (% forbidden)', TG_TABLE_NAME, TG_OP;
    END;
    $$ LANGUAGE plpgsql;
    """
  end
end
