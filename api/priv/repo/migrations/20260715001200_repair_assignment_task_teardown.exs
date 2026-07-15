defmodule Barkpark.Repo.Migrations.RepairAssignmentTaskTeardown do
  use Ecto.Migration

  def up do
    drop constraint(:epic_assignment_tasks, :epic_assignment_tasks_assignment_id_fkey)
    drop constraint(:epic_assignment_tasks, :epic_assignment_tasks_task_id_fkey)

    execute """
    ALTER TABLE epic_assignment_tasks
    ADD CONSTRAINT epic_assignment_tasks_assignment_id_fkey
    FOREIGN KEY (assignment_id)
    REFERENCES epic_assignments(id)
    ON DELETE CASCADE;
    """

    execute """
    ALTER TABLE epic_assignment_tasks
    ADD CONSTRAINT epic_assignment_tasks_task_id_fkey
    FOREIGN KEY (task_id)
    REFERENCES documents(id)
    ON DELETE NO ACTION
    DEFERRABLE INITIALLY DEFERRED;
    """

    execute guarded_immutability_function()
    execute guarded_teardown_function()
  end

  def down do
    drop constraint(:epic_assignment_tasks, :epic_assignment_tasks_assignment_id_fkey)
    drop constraint(:epic_assignment_tasks, :epic_assignment_tasks_task_id_fkey)

    execute """
    ALTER TABLE epic_assignment_tasks
    ADD CONSTRAINT epic_assignment_tasks_assignment_id_fkey
    FOREIGN KEY (assignment_id)
    REFERENCES epic_assignments(id)
    ON DELETE RESTRICT;
    """

    execute """
    ALTER TABLE epic_assignment_tasks
    ADD CONSTRAINT epic_assignment_tasks_task_id_fkey
    FOREIGN KEY (task_id)
    REFERENCES documents(id)
    ON DELETE RESTRICT;
    """

    execute previous_immutability_function()
    execute previous_teardown_function()
  end

  # Workspace teardown deletes documents before it deletes the workspace row.
  # Deferring the Task FK keeps a bound Task protected for ordinary transactions
  # while allowing the same teardown transaction to remove the assignment (and
  # cascade its binding) before commit. The shared append-only trigger permits
  # that cascade only while the existing cycle-teardown guard is active.
  defp guarded_immutability_function do
    """
    CREATE OR REPLACE FUNCTION barkpark_epic_ledger_immutable()
    RETURNS trigger AS $$
    DECLARE
      teardown_workspace text;
      row_workspace uuid;
    BEGIN
      teardown_workspace := current_setting('barkpark.cycle_teardown_workspace', true);

      IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 AND
         TG_TABLE_NAME IN ('epic_benchmark_experiments', 'epic_benchmark_attempts') THEN
        RETURN OLD;
      END IF;

      IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 AND teardown_workspace <> '' THEN
        CASE TG_TABLE_NAME
          WHEN 'cycle_waves' THEN
            row_workspace := OLD.workspace_id;
          WHEN 'cycle_build_plans' THEN
            SELECT workspace_id INTO row_workspace FROM cycle_waves WHERE id = OLD.wave_id;
          WHEN 'epic_assignments' THEN
            row_workspace := OLD.workspace_id;
          WHEN 'epic_assignment_results' THEN
            SELECT workspace_id INTO row_workspace
            FROM epic_assignments WHERE id = OLD.assignment_id;
          WHEN 'epic_assignment_tasks' THEN
            SELECT workspace_id INTO row_workspace
            FROM epic_assignments WHERE id = OLD.assignment_id;
        END CASE;

        IF row_workspace::text = teardown_workspace THEN
          RETURN OLD;
        END IF;
      END IF;

      RAISE EXCEPTION '% is append-only (% forbidden)', TG_TABLE_NAME, TG_OP;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp previous_immutability_function do
    """
    CREATE OR REPLACE FUNCTION barkpark_epic_ledger_immutable()
    RETURNS trigger AS $$
    DECLARE
      teardown_workspace text;
      row_workspace uuid;
    BEGIN
      teardown_workspace := current_setting('barkpark.cycle_teardown_workspace', true);

      IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 AND
         TG_TABLE_NAME IN ('epic_benchmark_experiments', 'epic_benchmark_attempts') THEN
        RETURN OLD;
      END IF;

      IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 AND teardown_workspace <> '' THEN
        CASE TG_TABLE_NAME
          WHEN 'cycle_waves' THEN
            row_workspace := OLD.workspace_id;
          WHEN 'cycle_build_plans' THEN
            SELECT workspace_id INTO row_workspace FROM cycle_waves WHERE id = OLD.wave_id;
          WHEN 'epic_assignments' THEN
            row_workspace := OLD.workspace_id;
          WHEN 'epic_assignment_results' THEN
            SELECT workspace_id INTO row_workspace
            FROM epic_assignments WHERE id = OLD.assignment_id;
        END CASE;

        IF row_workspace::text = teardown_workspace THEN
          RETURN OLD;
        END IF;
      END IF;

      RAISE EXCEPTION '% is append-only (% forbidden)', TG_TABLE_NAME, TG_OP;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp guarded_teardown_function do
    """
    CREATE OR REPLACE FUNCTION barkpark_teardown_cycle_ledger() RETURNS trigger AS $$
    DECLARE
      teardown_workspace uuid;
    BEGIN
      IF TG_TABLE_NAME = 'projects' THEN
        SELECT workspace_id INTO teardown_workspace FROM projects WHERE id = OLD.id;
      ELSE
        teardown_workspace := OLD.id;
      END IF;

      PERFORM set_config('barkpark.cycle_teardown_workspace', teardown_workspace::text, true);
      SET CONSTRAINTS epic_assignments_replaces_assignment_id_fkey DEFERRED;

      IF TG_TABLE_NAME = 'projects' THEN
        DELETE FROM epic_assignment_results result
        USING epic_assignments assignment, cycle_waves wave
        WHERE result.assignment_id = assignment.id
          AND assignment.cycle_wave_id = wave.id
          AND wave.project_id = OLD.id;

        DELETE FROM epic_assignment_tasks binding
        USING epic_assignments assignment, cycle_waves wave
        WHERE binding.assignment_id = assignment.id
          AND assignment.cycle_wave_id = wave.id
          AND wave.project_id = OLD.id;

        DELETE FROM epic_assignments assignment
        USING cycle_waves wave
        WHERE assignment.cycle_wave_id = wave.id
          AND wave.project_id = OLD.id;

        DELETE FROM cycle_build_plans plan
        USING cycle_waves wave
        WHERE plan.wave_id = wave.id
          AND wave.project_id = OLD.id;

        DELETE FROM cycle_waves WHERE project_id = OLD.id;
      ELSE
        DELETE FROM epic_assignment_results result
        USING epic_assignments assignment
        WHERE result.assignment_id = assignment.id
          AND assignment.workspace_id = OLD.id;

        DELETE FROM epic_assignment_tasks binding
        USING epic_assignments assignment
        WHERE binding.assignment_id = assignment.id
          AND assignment.workspace_id = OLD.id;

        DELETE FROM epic_assignments WHERE workspace_id = OLD.id;

        DELETE FROM cycle_build_plans plan
        USING cycle_waves wave
        WHERE plan.wave_id = wave.id
          AND wave.workspace_id = OLD.id;

        DELETE FROM cycle_waves WHERE workspace_id = OLD.id;
      END IF;

      SET CONSTRAINTS epic_assignments_replaces_assignment_id_fkey IMMEDIATE;
      PERFORM set_config('barkpark.cycle_teardown_workspace', '', true);
      RETURN OLD;
    EXCEPTION WHEN OTHERS THEN
      SET CONSTRAINTS epic_assignments_replaces_assignment_id_fkey IMMEDIATE;
      PERFORM set_config('barkpark.cycle_teardown_workspace', '', true);
      RAISE;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  defp previous_teardown_function do
    """
    CREATE OR REPLACE FUNCTION barkpark_teardown_cycle_ledger() RETURNS trigger AS $$
    DECLARE
      teardown_workspace uuid;
    BEGIN
      IF TG_TABLE_NAME = 'projects' THEN
        SELECT workspace_id INTO teardown_workspace FROM projects WHERE id = OLD.id;
      ELSE
        teardown_workspace := OLD.id;
      END IF;

      PERFORM set_config('barkpark.cycle_teardown_workspace', teardown_workspace::text, true);
      SET CONSTRAINTS epic_assignments_replaces_assignment_id_fkey DEFERRED;

      IF TG_TABLE_NAME = 'projects' THEN
        DELETE FROM epic_assignment_results result
        USING epic_assignments assignment, cycle_waves wave
        WHERE result.assignment_id = assignment.id
          AND assignment.cycle_wave_id = wave.id
          AND wave.project_id = OLD.id;

        DELETE FROM epic_assignments assignment
        USING cycle_waves wave
        WHERE assignment.cycle_wave_id = wave.id
          AND wave.project_id = OLD.id;

        DELETE FROM cycle_build_plans plan
        USING cycle_waves wave
        WHERE plan.wave_id = wave.id
          AND wave.project_id = OLD.id;

        DELETE FROM cycle_waves WHERE project_id = OLD.id;
      ELSE
        DELETE FROM epic_assignment_results result
        USING epic_assignments assignment
        WHERE result.assignment_id = assignment.id
          AND assignment.workspace_id = OLD.id;

        DELETE FROM epic_assignments WHERE workspace_id = OLD.id;

        DELETE FROM cycle_build_plans plan
        USING cycle_waves wave
        WHERE plan.wave_id = wave.id
          AND wave.workspace_id = OLD.id;

        DELETE FROM cycle_waves WHERE workspace_id = OLD.id;
      END IF;

      SET CONSTRAINTS epic_assignments_replaces_assignment_id_fkey IMMEDIATE;
      PERFORM set_config('barkpark.cycle_teardown_workspace', '', true);
      RETURN OLD;
    EXCEPTION WHEN OTHERS THEN
      SET CONSTRAINTS epic_assignments_replaces_assignment_id_fkey IMMEDIATE;
      PERFORM set_config('barkpark.cycle_teardown_workspace', '', true);
      RAISE;
    END;
    $$ LANGUAGE plpgsql;
    """
  end
end
