defmodule Barkpark.Repo.Migrations.AddAssignmentRuntimeAttempts do
  use Ecto.Migration

  def up do
    create table(:epic_assignment_runtime_attempts, primary_key: false) do
      add :assignment_id,
          references(:epic_assignments, type: :uuid, on_delete: :delete_all),
          primary_key: true

      add :task_id, references(:documents, type: :uuid, on_delete: :restrict), null: false

      add :session_id,
          references(:chat_sessions, type: :uuid, on_delete: :restrict),
          null: false

      add :task_worker_id, :text, null: false
      add :task_epoch, :bigint, null: false
      add :task_work_digest, :text, null: false
      add :provider, :text, null: false
      add :execution_target, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:epic_assignment_runtime_attempts, [:session_id],
             name: :epic_assignment_runtime_attempts_session_index
           )

    create constraint(
             :epic_assignment_runtime_attempts,
             :epic_assignment_runtime_attempts_provider,
             check: "provider = 'codex'"
           )

    create constraint(
             :epic_assignment_runtime_attempts,
             :epic_assignment_runtime_attempts_execution_target,
             check: "execution_target = 'managed'"
           )

    create constraint(
             :epic_assignment_runtime_attempts,
             :epic_assignment_runtime_attempts_task_epoch,
             check: "task_epoch > 0"
           )

    create constraint(
             :epic_assignment_runtime_attempts,
             :epic_assignment_runtime_attempts_task_work_digest,
             check: "task_work_digest ~ '^[0-9a-f]{16}$'"
           )

    drop constraint(
           :epic_assignment_runtime_attempts,
           :epic_assignment_runtime_attempts_task_id_fkey
         )

    execute """
    ALTER TABLE epic_assignment_runtime_attempts
    ADD CONSTRAINT epic_assignment_runtime_attempts_task_id_fkey
    FOREIGN KEY (task_id)
    REFERENCES documents(id)
    ON DELETE NO ACTION
    DEFERRABLE INITIALLY DEFERRED;
    """

    execute guarded_immutability_function()
    execute guarded_teardown_function()

    execute """
    CREATE TRIGGER epic_assignment_runtime_attempts_no_update_delete
    BEFORE UPDATE OR DELETE ON epic_assignment_runtime_attempts
    FOR EACH ROW EXECUTE FUNCTION barkpark_epic_ledger_immutable();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS epic_assignment_runtime_attempts_no_update_delete ON epic_assignment_runtime_attempts;"
    execute previous_immutability_function()
    execute previous_teardown_function()
    drop table(:epic_assignment_runtime_attempts)
  end

  # Workspace teardown deletes documents before its workspace trigger runs.
  # The deferred Task FK preserves ordinary referential protection while the
  # same transaction reaches guarded ledger teardown. Assignment deletion owns
  # the cascade; direct attempt UPDATE/DELETE remains append-only.
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
          WHEN 'epic_assignment_runtime_attempts' THEN
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
        DELETE FROM epic_assignment_runtime_attempts attempt
        USING epic_assignments assignment, cycle_waves wave
        WHERE attempt.assignment_id = assignment.id
          AND assignment.cycle_wave_id = wave.id
          AND wave.project_id = OLD.id;

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
        DELETE FROM epic_assignment_runtime_attempts attempt
        USING epic_assignments assignment
        WHERE attempt.assignment_id = assignment.id
          AND assignment.workspace_id = OLD.id;

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

  # Rolling this candidate migration back must leave the exact guarded
  # assignment-task teardown installed by 20260715001200.
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
end
