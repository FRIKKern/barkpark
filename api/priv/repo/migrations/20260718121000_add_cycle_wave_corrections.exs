defmodule Barkpark.Repo.Migrations.AddCycleWaveCorrections do
  use Ecto.Migration

  def up do
    alter table(:cycle_waves) do
      add :correction_of_wave_id,
          references(:cycle_waves, type: :uuid, on_delete: :restrict)

      add :correction_of, :map
      add :correction_of_digest, :text
    end

    create unique_index(:cycle_waves, [:correction_of_wave_id],
             name: :cycle_waves_correction_of_wave_index
           )

    create constraint(:cycle_waves, :cycle_waves_correction_all_or_none,
             check: """
             (correction_of_wave_id IS NULL AND correction_of IS NULL AND correction_of_digest IS NULL)
             OR
             (correction_of_wave_id IS NOT NULL AND correction_of IS NOT NULL AND correction_of_digest IS NOT NULL)
             """
           )

    create constraint(:cycle_waves, :cycle_waves_correction_digest,
             check: "correction_of_digest IS NULL OR correction_of_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:cycle_waves, :cycle_waves_correction_version,
             check: "correction_of IS NULL OR correction_of->>'version' = 'correction_of-v1'"
           )

    create constraint(:cycle_waves, :cycle_waves_correction_not_self,
             check: "correction_of_wave_id IS NULL OR correction_of_wave_id <> id"
           )

    execute """
    CREATE FUNCTION barkpark_seal_cycle_correction_parent() RETURNS trigger AS $$
    DECLARE
      parent cycle_waves%ROWTYPE;
      effective_plan_digest text;
      effective_plan jsonb;
      expected_ancestry jsonb;
    BEGIN
      IF NEW.correction_of_wave_id IS NULL THEN
        RETURN NEW;
      END IF;

      SELECT * INTO parent FROM cycle_waves
      WHERE id = NEW.correction_of_wave_id FOR UPDATE;

      IF NOT FOUND OR parent.workspace_id IS DISTINCT FROM NEW.workspace_id OR
         parent.project_id IS DISTINCT FROM NEW.project_id OR
         parent.epic_id IS DISTINCT FROM NEW.epic_id OR
         parent.wave_id IS NOT DISTINCT FROM NEW.wave_id THEN
        RAISE EXCEPTION 'correction parent must be a different wave in the same exact cycle scope'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT COALESCE(plan.plan_digest, parent.plan_digest), COALESCE(plan.plan, parent.plan)
      INTO effective_plan_digest, effective_plan
      FROM cycle_waves wave
      LEFT JOIN cycle_build_plans plan ON plan.wave_id = wave.id
      WHERE wave.id = parent.id;

      WITH RECURSIVE lineage AS (
        SELECT parent.id, parent.wave_id, parent.correction_of_wave_id, 0 AS depth
        UNION ALL
        SELECT ancestor.id, ancestor.wave_id, ancestor.correction_of_wave_id, lineage.depth + 1
        FROM cycle_waves ancestor
        JOIN lineage ON ancestor.id = lineage.correction_of_wave_id
      )
      SELECT jsonb_agg(
        jsonb_build_object('wave_id', wave_id, 'wave_revision', id::text)
        ORDER BY depth DESC
      ) INTO expected_ancestry
      FROM lineage;

      IF jsonb_typeof(NEW.correction_of) IS DISTINCT FROM 'object' OR
         jsonb_typeof(NEW.correction_of->'prior') IS DISTINCT FROM 'object' OR
         jsonb_typeof(NEW.correction_of->'ancestry') IS DISTINCT FROM 'array' OR
         jsonb_array_length(NEW.correction_of->'ancestry') = 0 OR
         NEW.correction_of->'ancestry' IS DISTINCT FROM expected_ancestry OR
         NEW.correction_of->'ancestry'->(jsonb_array_length(NEW.correction_of->'ancestry') - 1)->>'wave_id'
           IS DISTINCT FROM parent.wave_id OR
         NEW.correction_of->'ancestry'->(jsonb_array_length(NEW.correction_of->'ancestry') - 1)->>'wave_revision'
           IS DISTINCT FROM parent.id::text OR
         jsonb_typeof(NEW.correction_of->'targets') IS DISTINCT FROM 'array' OR
         jsonb_array_length(NEW.correction_of->'targets') = 0 OR
         jsonb_typeof(NEW.correction_of->'changes') IS DISTINCT FROM 'array' OR
         jsonb_array_length(NEW.correction_of->'changes') = 0 OR
         jsonb_typeof(NEW.correction_of->'before_counts') IS DISTINCT FROM 'object' OR
         jsonb_typeof(NEW.correction_of->'delta') IS DISTINCT FROM 'object' OR
         jsonb_typeof(NEW.correction_of->'after_counts') IS DISTINCT FROM 'object' OR
         NEW.correction_of->>'inventory_count' IS DISTINCT FROM jsonb_array_length(to_jsonb(parent.inventory))::text OR
         NEW.correction_of->'prior'->>'wave_revision' IS DISTINCT FROM parent.id::text OR
         NEW.correction_of->'prior'->>'workspace_id' IS DISTINCT FROM parent.workspace_id::text OR
         NEW.correction_of->'prior'->>'project_id' IS DISTINCT FROM parent.project_id::text OR
         NEW.correction_of->'prior'->>'epic_id' IS DISTINCT FROM parent.epic_id OR
         NEW.correction_of->'prior'->>'wave_id' IS DISTINCT FROM parent.wave_id OR
         NEW.correction_of->'prior'->>'inventory_digest' IS DISTINCT FROM parent.inventory_digest OR
         NEW.correction_of->'prior'->>'effective_plan_digest' IS DISTINCT FROM effective_plan_digest OR
         NEW.correction_of->'prior'->>'reconciliation_digest' IS NULL OR
         NEW.correction_of->'prior'->>'reconciliation_digest' !~ '^[0-9a-f]{64}$' OR
         EXISTS (
           SELECT 1 FROM jsonb_array_elements(NEW.correction_of->'targets') target
           WHERE jsonb_typeof(target) IS DISTINCT FROM 'object' OR
             target->>'assignment_id' IS NULL OR
             target->>'assignment_revision' IS NULL OR
             target->>'assignment_revision' !~ '^[0-9a-f-]{36}$' OR
             target->>'snapshot_digest' IS NULL OR target->>'snapshot_digest' !~ '^[0-9a-f]{64}$' OR
             target->>'result_revision' IS NULL OR
             target->>'result_revision' !~ '^[0-9a-f-]{36}$' OR
             target->>'payload_digest' IS NULL OR target->>'payload_digest' !~ '^[0-9a-f]{64}$' OR
             target->>'semantic_status' IS DISTINCT FROM 'invalid' OR
             NOT EXISTS (
               SELECT 1
               FROM epic_assignments assignment
               JOIN epic_assignment_results result ON result.assignment_id = assignment.id
               WHERE assignment.cycle_wave_id IN (
                   SELECT (entry->>'wave_revision')::uuid
                   FROM jsonb_array_elements(expected_ancestry) entry
                 ) AND
                 assignment.phase = 'build' AND
                 assignment.id::text = target->>'assignment_revision' AND
                 assignment.assignment_id = target->>'assignment_id' AND
                 assignment.snapshot_digest = target->>'snapshot_digest' AND
                 result.id::text = target->>'result_revision' AND
                 result.payload_digest = target->>'payload_digest' AND
                 result.evidence_revision IS NOT DISTINCT FROM target->>'evidence_revision' AND
                 result.payload->>'semantic_receipt_index_hash'
                   IS NOT DISTINCT FROM target->>'semantic_receipt_index_hash'
             )
         ) OR
         EXISTS (
           SELECT 1 FROM jsonb_array_elements(NEW.correction_of->'changes') change
           WHERE jsonb_typeof(change) IS DISTINCT FROM 'object' OR
             change->>'unit_id' IS NULL OR change->>'assignment_id' IS NULL OR
             change->>'assignment_revision' IS NULL OR
             change->>'assignment_revision' !~ '^[0-9a-f-]{36}$' OR
             change->>'before' NOT IN ('shipped', 'stalled', 'excluded') OR
             change->>'after' NOT IN ('shipped', 'stalled', 'excluded') OR
             change->>'before' IS NOT DISTINCT FROM change->>'after'
         ) OR
         EXISTS (
           SELECT 1 FROM jsonb_array_elements(NEW.correction_of->'changes') change
           WHERE NOT EXISTS (
             SELECT 1 FROM jsonb_array_elements(NEW.correction_of->'targets') target
             WHERE target->>'assignment_id' = change->>'assignment_id' AND
               target->>'assignment_revision' = change->>'assignment_revision'
           )
         ) OR
         NEW.profile IS DISTINCT FROM parent.profile OR
         to_jsonb(NEW.inventory) IS DISTINCT FROM to_jsonb(parent.inventory) OR
         NEW.inventory_digest IS DISTINCT FROM parent.inventory_digest OR
         NEW.plan IS DISTINCT FROM effective_plan OR
         NEW.plan_digest IS DISTINCT FROM effective_plan_digest OR
         NEW.experiment_contract IS DISTINCT FROM parent.experiment_contract OR
         NEW.scale_contract IS DISTINCT FROM parent.scale_contract OR
         (NEW.correction_of->'before_counts'->>'shipped')::integer +
           (NEW.correction_of->'before_counts'->>'stalled')::integer +
           (NEW.correction_of->'before_counts'->>'excluded')::integer IS DISTINCT FROM
             jsonb_array_length(to_jsonb(parent.inventory)) OR
         (NEW.correction_of->'after_counts'->>'shipped')::integer +
           (NEW.correction_of->'after_counts'->>'stalled')::integer +
           (NEW.correction_of->'after_counts'->>'excluded')::integer IS DISTINCT FROM
             jsonb_array_length(to_jsonb(parent.inventory)) OR
         (NEW.correction_of->'delta'->>'shipped')::integer +
           (NEW.correction_of->'delta'->>'stalled')::integer +
           (NEW.correction_of->'delta'->>'excluded')::integer IS DISTINCT FROM 0 OR
         (NEW.correction_of->'after_counts'->>'shipped')::integer IS DISTINCT FROM
           (NEW.correction_of->'before_counts'->>'shipped')::integer +
             (NEW.correction_of->'delta'->>'shipped')::integer OR
         (NEW.correction_of->'after_counts'->>'stalled')::integer IS DISTINCT FROM
           (NEW.correction_of->'before_counts'->>'stalled')::integer +
             (NEW.correction_of->'delta'->>'stalled')::integer OR
         (NEW.correction_of->'after_counts'->>'excluded')::integer IS DISTINCT FROM
           (NEW.correction_of->'before_counts'->>'excluded')::integer +
             (NEW.correction_of->'delta'->>'excluded')::integer THEN
        RAISE EXCEPTION 'correction parent pins are stale or foreign'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER aaa_cycle_waves_seal_correction_parent
    BEFORE INSERT ON cycle_waves
    FOR EACH ROW EXECUTE FUNCTION barkpark_seal_cycle_correction_parent();
    """

    execute """
    CREATE FUNCTION barkpark_reject_sealed_cycle_append() RETURNS trigger AS $$
    DECLARE target_wave_id uuid;
    BEGIN
      IF TG_TABLE_NAME = 'cycle_build_plans' THEN
        target_wave_id := NEW.wave_id;
      ELSIF TG_TABLE_NAME = 'epic_assignments' THEN
        target_wave_id := NEW.cycle_wave_id;
      ELSIF TG_TABLE_NAME = 'epic_assignment_results' THEN
        SELECT cycle_wave_id INTO target_wave_id FROM epic_assignments WHERE id = NEW.assignment_id;
      ELSE
        SELECT assignment.cycle_wave_id INTO target_wave_id
        FROM epic_assignments assignment WHERE assignment.id = NEW.assignment_id;
      END IF;

      IF target_wave_id IS NULL THEN RETURN NEW; END IF;
      PERFORM 1 FROM cycle_waves WHERE id = target_wave_id FOR UPDATE;

      IF EXISTS (
        SELECT 1 FROM cycle_waves
        WHERE id = target_wave_id AND correction_of_wave_id IS NOT NULL
      ) OR EXISTS (
        SELECT 1 FROM cycle_waves WHERE correction_of_wave_id = target_wave_id
      ) THEN
        RAISE EXCEPTION 'cycle wave is sealed by an immutable correction successor'
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    for {table, trigger} <- [
          {:cycle_build_plans, :cycle_build_plans_reject_sealed_append},
          {:epic_assignments, :epic_assignments_reject_sealed_append},
          {:epic_assignment_results, :epic_assignment_results_reject_sealed_append},
          {:epic_assignment_tasks, :epic_assignment_tasks_reject_sealed_append}
        ] do
      execute """
      CREATE TRIGGER #{trigger}
      BEFORE INSERT ON #{table}
      FOR EACH ROW EXECUTE FUNCTION barkpark_reject_sealed_cycle_append();
      """
    end
  end

  def down do
    for {table, trigger} <- [
          {:cycle_build_plans, :cycle_build_plans_reject_sealed_append},
          {:epic_assignments, :epic_assignments_reject_sealed_append},
          {:epic_assignment_results, :epic_assignment_results_reject_sealed_append},
          {:epic_assignment_tasks, :epic_assignment_tasks_reject_sealed_append}
        ] do
      execute "DROP TRIGGER IF EXISTS #{trigger} ON #{table};"
    end

    execute "DROP FUNCTION IF EXISTS barkpark_reject_sealed_cycle_append();"
    execute "DROP TRIGGER IF EXISTS aaa_cycle_waves_seal_correction_parent ON cycle_waves;"
    execute "DROP FUNCTION IF EXISTS barkpark_seal_cycle_correction_parent();"
    drop constraint(:cycle_waves, :cycle_waves_correction_not_self)
    drop constraint(:cycle_waves, :cycle_waves_correction_version)
    drop constraint(:cycle_waves, :cycle_waves_correction_digest)
    drop constraint(:cycle_waves, :cycle_waves_correction_all_or_none)

    drop index(:cycle_waves, [:correction_of_wave_id],
           name: :cycle_waves_correction_of_wave_index
         )

    alter table(:cycle_waves) do
      remove :correction_of_digest
      remove :correction_of
      remove :correction_of_wave_id
    end
  end
end
