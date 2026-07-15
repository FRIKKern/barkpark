defmodule Barkpark.Repo.Migrations.CreateCycleWaves do
  use Ecto.Migration

  def up do
    create table(:cycle_waves, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_id, references(:workspaces, type: :uuid), null: false
      add :project_id, references(:projects, type: :uuid)
      add :epic_id, :text, null: false
      add :wave_id, :text, null: false
      add :profile, :text, null: false
      add :inventory, {:array, :map}, null: false, default: []
      add :inventory_digest, :text, null: false
      add :plan, :map, null: false, default: %{}
      add :plan_digest, :text, null: false
      add :experiment_contract, :map, null: false, default: %{}
      add :scale_contract, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:cycle_waves, [:workspace_id, :project_id, :epic_id, :wave_id],
             where: "project_id IS NOT NULL",
             name: :cycle_waves_project_scope_index
           )

    create unique_index(:cycle_waves, [:workspace_id, :epic_id, :wave_id],
             where: "project_id IS NULL",
             name: :cycle_waves_flat_scope_index
           )

    create unique_index(:projects, [:id, :workspace_id], name: :projects_id_workspace_id_index)

    execute """
    ALTER TABLE cycle_waves
    ADD CONSTRAINT cycle_waves_project_workspace_fkey
    FOREIGN KEY (project_id, workspace_id)
    REFERENCES projects(id, workspace_id)
    ON DELETE RESTRICT
    """

    create constraint(:cycle_waves, :cycle_waves_profile,
             check: "profile IN ('epic', 'legendary')"
           )

    create constraint(:cycle_waves, :cycle_waves_inventory_digest,
             check: "inventory_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:cycle_waves, :cycle_waves_plan_digest,
             check: "plan_digest ~ '^[0-9a-f]{64}$'"
           )

    execute """
    CREATE OR REPLACE FUNCTION barkpark_validate_cycle_wave_inventory() RETURNS trigger AS $$
    BEGIN
      IF jsonb_typeof(to_jsonb(NEW.inventory)) IS DISTINCT FROM 'array' OR
         EXISTS (
           SELECT 1
           FROM jsonb_array_elements(to_jsonb(NEW.inventory)) inventory_unit
           WHERE jsonb_typeof(inventory_unit) <> 'object' OR
                 jsonb_typeof(inventory_unit->'unit_id') IS DISTINCT FROM 'string' OR
                 btrim(inventory_unit->>'unit_id') = '' OR
                 btrim(inventory_unit->>'unit_id') <> inventory_unit->>'unit_id'
         ) THEN
        RAISE EXCEPTION 'cycle wave inventory must contain only objects with unpadded non-empty unit_id strings'
          USING ERRCODE = 'check_violation';
      END IF;

      IF (
        SELECT count(*) FROM jsonb_array_elements(to_jsonb(NEW.inventory))
      ) <> (
        SELECT count(DISTINCT inventory_unit->>'unit_id')
        FROM jsonb_array_elements(to_jsonb(NEW.inventory)) inventory_unit
      ) THEN
        RAISE EXCEPTION 'cycle wave inventory unit_id strings must be unique'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NEW.profile = 'legendary' AND
         jsonb_array_length(to_jsonb(NEW.inventory)) < 15 THEN
        RAISE EXCEPTION 'legendary cycle wave inventory must contain at least 15 entries'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER aa_cycle_waves_validate_inventory
    BEFORE INSERT OR UPDATE ON cycle_waves
    FOR EACH ROW EXECUTE FUNCTION barkpark_validate_cycle_wave_inventory();
    """

    create table(:cycle_build_plans, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :wave_id, references(:cycle_waves, type: :uuid, on_delete: :restrict), null: false
      add :proven_batch_capacity, :integer, null: false
      add :plan, :map, null: false, default: %{}
      add :plan_digest, :text, null: false
      add :inventory_digest, :text, null: false
      add :chosen_format, :text, null: false
      add :pilot_evidence, :text, null: false
      add :pilot_evidence_revision, :text, null: false
      add :failure_rate, :float, null: false
      add :failure_threshold, :float, null: false
      add :golden_fixtures, {:array, :text}, null: false, default: []
      add :quality_rubric, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:cycle_build_plans, [:wave_id], name: :cycle_build_plans_wave_index)

    create constraint(:cycle_build_plans, :cycle_build_plans_capacity,
             check: "proven_batch_capacity > 0"
           )

    create constraint(:cycle_build_plans, :cycle_build_plans_plan_digest,
             check: "plan_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:cycle_build_plans, :cycle_build_plans_inventory_digest,
             check: "inventory_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:cycle_build_plans, :cycle_build_plans_failure_rate,
             check:
               "failure_rate >= 0 AND failure_threshold >= 0 AND failure_rate <= failure_threshold"
           )

    alter table(:epic_assignments) do
      add :cycle_wave_id, references(:cycle_waves, type: :uuid, on_delete: :restrict)
    end

    create index(:epic_assignments, [:cycle_wave_id])

    drop index(:epic_assignments, [:workspace_id, :epic_id, :wave_id, :assignment_id],
           name: :epic_assignments_scope_assignment_index
         )

    create unique_index(:epic_assignments, [:workspace_id, :epic_id, :wave_id, :assignment_id],
             where: "cycle_wave_id IS NULL",
             name: :epic_assignments_scope_assignment_index
           )

    create unique_index(:epic_assignments, [:cycle_wave_id, :assignment_id],
             where: "cycle_wave_id IS NOT NULL",
             name: :epic_assignments_cycle_assignment_index
           )

    create constraint(:epic_assignments, :epic_assignments_legendary_wave,
             check:
               "(phase <> 'experiment' AND agent_type NOT IN ('legendary-experimenter', 'legendary-builder')) OR cycle_wave_id IS NOT NULL"
           )

    drop constraint(:epic_assignments, :epic_assignments_phase)

    create constraint(:epic_assignments, :epic_assignments_phase,
             check: "phase IN ('survey', 'verify', 'experiment', 'build', 'review')"
           )

    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM epic_assignments
        WHERE replaces_assignment_id IS NOT NULL
        GROUP BY replaces_assignment_id
        HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION 'cannot enforce linear retry lineage: sibling replacements exist';
      END IF;
    END;
    $$;
    """

    execute """
    ALTER TABLE epic_assignments
    DROP CONSTRAINT epic_assignments_replaces_assignment_id_fkey,
    ADD CONSTRAINT epic_assignments_replaces_assignment_id_fkey
      FOREIGN KEY (replaces_assignment_id)
      REFERENCES epic_assignments(id)
      ON DELETE NO ACTION
      DEFERRABLE INITIALLY IMMEDIATE
    """

    execute """
    CREATE OR REPLACE FUNCTION barkpark_validate_cycle_assignment() RETURNS trigger AS $$
    DECLARE
      cycle_profile text;
      cycle_workspace uuid;
      cycle_epic text;
      cycle_wave text;
      expected_agent text;
      expected_effort text;
      planned_count integer;
      live_count integer;
      sealed_capacity integer;
      predecessor_status text;
      predecessor_cycle_wave uuid;
      predecessor_workspace uuid;
      predecessor_epic text;
      predecessor_wave text;
      predecessor_phase text;
      predecessor_agent text;
    BEGIN
      IF NEW.cycle_wave_id IS NULL THEN
        RETURN NEW;
      END IF;

      SELECT profile, workspace_id, epic_id, wave_id
        INTO cycle_profile, cycle_workspace, cycle_epic, cycle_wave
        FROM cycle_waves WHERE id = NEW.cycle_wave_id
        FOR UPDATE;

      IF NOT FOUND OR cycle_workspace <> NEW.workspace_id OR
         cycle_epic <> NEW.epic_id OR cycle_wave <> NEW.wave_id THEN
        RAISE EXCEPTION 'cycle assignment scope does not match its immutable wave'
          USING ERRCODE = 'check_violation';
      END IF;

      expected_agent := CASE NEW.phase
        WHEN 'survey' THEN 'epic-surveyor'
        WHEN 'verify' THEN 'epic-verifier'
        WHEN 'review' THEN 'code-reviewer'
        WHEN 'experiment' THEN
          CASE WHEN cycle_profile = 'legendary' THEN 'legendary-experimenter' END
        WHEN 'build' THEN
          CASE WHEN cycle_profile = 'legendary' THEN 'legendary-builder' ELSE 'epic-builder' END
      END;

      IF expected_agent IS NULL OR NEW.agent_type <> expected_agent THEN
        RAISE EXCEPTION 'assignment agent type is not admitted by the cycle profile'
          USING ERRCODE = 'check_violation';
      END IF;

      expected_effort := CASE NEW.phase
        WHEN 'survey' THEN 'medium'
        WHEN 'verify' THEN 'medium'
        WHEN 'experiment' THEN 'medium'
        WHEN 'review' THEN 'high'
        WHEN 'build' THEN CASE WHEN cycle_profile = 'epic' THEN 'high' ELSE 'medium' END
      END;

      IF expected_effort IS NULL OR NEW.effort <> expected_effort THEN
        RAISE EXCEPTION 'assignment effort is not admitted by the cycle profile'
          USING ERRCODE = 'check_violation';
      END IF;

      IF cycle_profile = 'legendary' AND NEW.phase = 'build' AND NOT EXISTS (
        SELECT 1 FROM cycle_build_plans WHERE wave_id = NEW.cycle_wave_id
      ) THEN
        RAISE EXCEPTION 'legendary build assignment requires a sealed build plan'
          USING ERRCODE = 'check_violation';
      END IF;

      IF cycle_profile = 'legendary' AND NEW.phase = 'experiment' AND EXISTS (
        SELECT 1 FROM cycle_build_plans WHERE wave_id = NEW.cycle_wave_id
      ) THEN
        RAISE EXCEPTION 'experiment assignments are closed after the build plan is sealed'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NEW.replaces_assignment_id IS NOT NULL THEN
        SELECT r.status, predecessor.cycle_wave_id, predecessor.workspace_id,
               predecessor.epic_id, predecessor.wave_id, predecessor.phase,
               predecessor.agent_type
          INTO predecessor_status, predecessor_cycle_wave, predecessor_workspace,
               predecessor_epic, predecessor_wave, predecessor_phase,
               predecessor_agent
        FROM epic_assignments predecessor
        LEFT JOIN epic_assignment_results r ON r.assignment_id = predecessor.id
        WHERE predecessor.id = NEW.replaces_assignment_id;

        IF predecessor_status IS NULL OR predecessor_status NOT IN ('failed', 'cancelled') THEN
          RAISE EXCEPTION 'replacement predecessor must be failed or cancelled'
            USING ERRCODE = 'check_violation';
        END IF;

        IF predecessor_cycle_wave IS DISTINCT FROM NEW.cycle_wave_id OR
           predecessor_workspace IS DISTINCT FROM NEW.workspace_id OR
           predecessor_epic IS DISTINCT FROM NEW.epic_id OR
           predecessor_wave IS DISTINCT FROM NEW.wave_id OR
           predecessor_phase IS DISTINCT FROM NEW.phase OR
           predecessor_agent IS DISTINCT FROM NEW.agent_type THEN
          RAISE EXCEPTION 'replacement predecessor must match cycle wave, scope, phase, and agent type'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSE
        SELECT COALESCE(
          (SELECT (plan->NEW.phase->>'planned')::integer
           FROM cycle_build_plans WHERE wave_id = NEW.cycle_wave_id),
          (SELECT (plan->NEW.phase->>'planned')::integer
           FROM cycle_waves WHERE id = NEW.cycle_wave_id)
        ) INTO planned_count;

        SELECT count(*) INTO live_count
        FROM epic_assignments candidate
        WHERE candidate.cycle_wave_id = NEW.cycle_wave_id
          AND candidate.phase = NEW.phase
          AND NOT EXISTS (
            SELECT 1 FROM epic_assignments replacement
            WHERE replacement.replaces_assignment_id = candidate.id
          );

        IF planned_count IS NULL OR (
          live_count >= planned_count AND NOT EXISTS (
            SELECT 1 FROM epic_assignments replay
            WHERE replay.cycle_wave_id = NEW.cycle_wave_id
              AND replay.assignment_id = NEW.assignment_id
          )
        ) THEN
          RAISE EXCEPTION 'cycle phase assignment capacity is exhausted'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      -- This common block intentionally runs for both initial and replacement snapshots.
      IF NEW.phase = 'build' THEN
        SELECT proven_batch_capacity INTO sealed_capacity
        FROM cycle_build_plans WHERE wave_id = NEW.cycle_wave_id;

        IF jsonb_typeof(NEW.snapshot->'unit_ids') IS DISTINCT FROM 'array' OR
           jsonb_array_length(NEW.snapshot->'unit_ids') = 0 THEN
          RAISE EXCEPTION 'build assignment unit_ids must be a non-empty array'
            USING ERRCODE = 'check_violation';
        END IF;

        IF sealed_capacity IS NOT NULL AND
           jsonb_array_length(NEW.snapshot->'unit_ids') > sealed_capacity THEN
          RAISE EXCEPTION 'build assignment exceeds proven batch capacity'
            USING ERRCODE = 'check_violation';
        END IF;

        IF EXISTS (
          SELECT 1 FROM jsonb_array_elements(NEW.snapshot->'unit_ids') unit
          WHERE jsonb_typeof(unit) <> 'string' OR
                btrim(unit #>> '{}') = '' OR
                btrim(unit #>> '{}') <> (unit #>> '{}')
        ) THEN
          RAISE EXCEPTION 'build assignment unit_ids must contain only unpadded non-empty strings'
            USING ERRCODE = 'check_violation';
        END IF;

        IF (
          SELECT count(*) FROM jsonb_array_elements(NEW.snapshot->'unit_ids')
        ) <> (
          SELECT count(DISTINCT unit #>> '{}')
          FROM jsonb_array_elements(NEW.snapshot->'unit_ids') unit
        ) THEN
          RAISE EXCEPTION 'build assignment unit_ids must be unique'
            USING ERRCODE = 'check_violation';
        END IF;

        IF EXISTS (
          SELECT unit #>> '{}'
          FROM jsonb_array_elements(NEW.snapshot->'unit_ids') unit
          EXCEPT
          SELECT inventory_unit->>'unit_id'
          FROM cycle_waves wave,
               jsonb_array_elements(to_jsonb(wave.inventory)) inventory_unit
          WHERE wave.id = NEW.cycle_wave_id
        ) THEN
          RAISE EXCEPTION 'build assignment unit_ids must belong to cycle inventory'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER epic_assignments_validate_cycle
    BEFORE INSERT OR UPDATE ON epic_assignments
    FOR EACH ROW EXECUTE FUNCTION barkpark_validate_cycle_assignment();
    """

    execute """
    CREATE OR REPLACE FUNCTION barkpark_validate_cycle_build_result() RETURNS trigger AS $$
    DECLARE
      assignment_phase text;
      assignment_cycle_wave uuid;
      assignment_units jsonb;
      outcome_units jsonb;
    BEGIN
      SELECT phase, cycle_wave_id, snapshot->'unit_ids'
        INTO assignment_phase, assignment_cycle_wave, assignment_units
      FROM epic_assignments WHERE id = NEW.assignment_id;

      IF NEW.status <> 'completed' OR assignment_phase <> 'build' OR
         assignment_cycle_wave IS NULL THEN
        RETURN NEW;
      END IF;

      IF jsonb_typeof(NEW.payload->'completed_unit_ids') IS DISTINCT FROM 'array' OR
         jsonb_typeof(NEW.payload->'stalled_unit_ids') IS DISTINCT FROM 'array' OR
         jsonb_typeof(NEW.payload->'excluded_unit_ids') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'completed build result outcomes must be typed arrays'
          USING ERRCODE = 'check_violation';
      END IF;

      outcome_units := (NEW.payload->'completed_unit_ids') ||
                       (NEW.payload->'stalled_unit_ids') ||
                       (NEW.payload->'excluded_unit_ids');

      IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(outcome_units) unit
        WHERE jsonb_typeof(unit) <> 'string' OR
              btrim(unit #>> '{}') = '' OR
              btrim(unit #>> '{}') <> (unit #>> '{}')
      ) THEN
        RAISE EXCEPTION 'completed build result outcomes must contain only unpadded non-empty strings'
          USING ERRCODE = 'check_violation';
      END IF;

      IF (
        SELECT count(*) FROM jsonb_array_elements(outcome_units)
      ) <> (
        SELECT count(DISTINCT unit #>> '{}') FROM jsonb_array_elements(outcome_units) unit
      ) THEN
        RAISE EXCEPTION 'completed build result outcomes must not overlap'
          USING ERRCODE = 'check_violation';
      END IF;

      IF EXISTS (
        (SELECT unit #>> '{}' FROM jsonb_array_elements(outcome_units) unit
         EXCEPT
         SELECT unit #>> '{}' FROM jsonb_array_elements(assignment_units) unit)
        UNION ALL
        (SELECT unit #>> '{}' FROM jsonb_array_elements(assignment_units) unit
         EXCEPT
         SELECT unit #>> '{}' FROM jsonb_array_elements(outcome_units) unit)
      ) THEN
        RAISE EXCEPTION 'completed build result outcomes must exactly partition assignment units'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER epic_assignment_results_validate_cycle_build
    BEFORE INSERT OR UPDATE ON epic_assignment_results
    FOR EACH ROW EXECUTE FUNCTION barkpark_validate_cycle_build_result();
    """

    execute """
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

    execute """
    CREATE TRIGGER cycle_waves_no_update_delete
    BEFORE UPDATE OR DELETE ON cycle_waves
    FOR EACH ROW EXECUTE FUNCTION barkpark_epic_ledger_immutable();
    """

    execute """
    CREATE TRIGGER cycle_build_plans_no_update_delete
    BEFORE UPDATE OR DELETE ON cycle_build_plans
    FOR EACH ROW EXECUTE FUNCTION barkpark_epic_ledger_immutable();
    """

    execute """
    CREATE FUNCTION barkpark_teardown_cycle_ledger() RETURNS trigger AS $$
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

    execute "REVOKE ALL ON FUNCTION barkpark_teardown_cycle_ledger() FROM PUBLIC;"

    execute """
    CREATE TRIGGER workspaces_teardown_cycle_ledger
    BEFORE DELETE ON workspaces
    FOR EACH ROW EXECUTE FUNCTION barkpark_teardown_cycle_ledger();
    """

    execute """
    CREATE TRIGGER projects_teardown_cycle_ledger
    BEFORE DELETE ON projects
    FOR EACH ROW EXECUTE FUNCTION barkpark_teardown_cycle_ledger();
    """
  end

  @doc false
  def rollback_blockers(repo \\ Barkpark.Repo) do
    %{rows: [[waves, plans, assignments]]} =
      repo.query!(
        """
        SELECT
          (SELECT count(*) FROM cycle_waves),
          (SELECT count(*) FROM cycle_build_plans),
          (SELECT count(*) FROM epic_assignments WHERE cycle_wave_id IS NOT NULL)
        """,
        []
      )

    %{
      cycle_waves: waves,
      cycle_build_plans: plans,
      cycle_bound_assignments: assignments,
      safe?: waves == 0 and plans == 0 and assignments == 0
    }
  end

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM cycle_waves) OR
         EXISTS (SELECT 1 FROM cycle_build_plans) OR
         EXISTS (SELECT 1 FROM epic_assignments WHERE cycle_wave_id IS NOT NULL) THEN
        RAISE EXCEPTION 'cycle ledger rollback is irreversible after cycle waves, build plans, or cycle-bound assignments exist';
      END IF;
    END;
    $$;
    """

    execute "DROP TRIGGER IF EXISTS projects_teardown_cycle_ledger ON projects;"
    execute "DROP TRIGGER IF EXISTS workspaces_teardown_cycle_ledger ON workspaces;"
    execute "DROP FUNCTION IF EXISTS barkpark_teardown_cycle_ledger();"

    execute "DROP TRIGGER IF EXISTS epic_assignment_results_validate_cycle_build ON epic_assignment_results;"
    execute "DROP FUNCTION IF EXISTS barkpark_validate_cycle_build_result();"
    execute "DROP TRIGGER IF EXISTS epic_assignments_validate_cycle ON epic_assignments;"
    execute "DROP FUNCTION IF EXISTS barkpark_validate_cycle_assignment();"
    execute "DROP TRIGGER IF EXISTS aa_cycle_waves_validate_inventory ON cycle_waves;"
    execute "DROP FUNCTION IF EXISTS barkpark_validate_cycle_wave_inventory();"
    execute "DROP TRIGGER IF EXISTS cycle_waves_no_update_delete ON cycle_waves;"
    execute "DROP TRIGGER IF EXISTS cycle_build_plans_no_update_delete ON cycle_build_plans;"

    drop constraint(:epic_assignments, :epic_assignments_legendary_wave)

    execute "ALTER TABLE cycle_waves DROP CONSTRAINT IF EXISTS cycle_waves_project_workspace_fkey;"

    execute """
    ALTER TABLE epic_assignments
    DROP CONSTRAINT epic_assignments_replaces_assignment_id_fkey,
    ADD CONSTRAINT epic_assignments_replaces_assignment_id_fkey
      FOREIGN KEY (replaces_assignment_id)
      REFERENCES epic_assignments(id)
      ON DELETE RESTRICT
      NOT DEFERRABLE
    """

    drop_if_exists index(:epic_assignments, [:cycle_wave_id, :assignment_id],
                     name: :epic_assignments_cycle_assignment_index
                   )

    drop_if_exists index(:epic_assignments, [:cycle_wave_id],
                     name: :epic_assignments_cycle_wave_id_index
                   )

    drop_if_exists index(:epic_assignments, [:workspace_id, :epic_id, :wave_id, :assignment_id],
                     name: :epic_assignments_scope_assignment_index
                   )

    drop constraint(:epic_assignments, :epic_assignments_phase)

    create constraint(:epic_assignments, :epic_assignments_phase,
             check: "phase IN ('survey', 'verify', 'build', 'review')"
           )

    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM epic_assignments
        GROUP BY workspace_id, epic_id, wave_id, assignment_id
        HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION 'cycle ledger rollback is irreversible after cycle-scoped logical assignment ids diverge';
      END IF;
    END;
    $$;
    """

    alter table(:epic_assignments) do
      remove :cycle_wave_id
    end

    create unique_index(
             :epic_assignments,
             [:workspace_id, :epic_id, :wave_id, :assignment_id],
             name: :epic_assignments_scope_assignment_index
           )

    drop table(:cycle_build_plans)
    drop table(:cycle_waves)

    drop_if_exists index(:projects, [:id, :workspace_id], name: :projects_id_workspace_id_index)

    execute """
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
end
