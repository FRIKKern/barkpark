defmodule Barkpark.Repo.Migrations.RejectPaddedCycleUnitIds do
  use Ecto.Migration

  def up do
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM cycle_waves wave
        WHERE CASE
          WHEN jsonb_typeof(to_jsonb(wave.inventory)) IS DISTINCT FROM 'array' THEN true
          ELSE
            EXISTS (
              SELECT 1
              FROM jsonb_array_elements(to_jsonb(wave.inventory)) inventory_unit
              WHERE jsonb_typeof(inventory_unit) <> 'object' OR
                    jsonb_typeof(inventory_unit->'unit_id') IS DISTINCT FROM 'string' OR
                    btrim(inventory_unit->>'unit_id') = '' OR
                    btrim(inventory_unit->>'unit_id') <> inventory_unit->>'unit_id'
            ) OR
            (
              SELECT count(*)
              FROM jsonb_array_elements(to_jsonb(wave.inventory))
            ) <> (
              SELECT count(DISTINCT inventory_unit->>'unit_id')
              FROM jsonb_array_elements(to_jsonb(wave.inventory)) inventory_unit
            ) OR
            (wave.profile = 'legendary' AND
             jsonb_array_length(to_jsonb(wave.inventory)) < 15)
        END
      ) THEN
        RAISE EXCEPTION 'cannot install cycle wave inventory retrofit: existing inventory is malformed, padded, duplicate, or below the legendary floor'
          USING ERRCODE = 'check_violation';
      END IF;
    END;
    $$;
    """

    execute """
    CREATE FUNCTION barkpark_validate_cycle_wave_inventory_00600() RETURNS trigger AS $$
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
    CREATE TRIGGER aa_cycle_waves_validate_inventory_00600
    BEFORE INSERT OR UPDATE ON cycle_waves
    FOR EACH ROW EXECUTE FUNCTION barkpark_validate_cycle_wave_inventory_00600();
    """

    execute """
    CREATE FUNCTION barkpark_reject_padded_cycle_assignment_unit_ids() RETURNS trigger AS $$
    BEGIN
      IF NEW.phase = 'build' AND NEW.cycle_wave_id IS NOT NULL AND
         jsonb_typeof(NEW.snapshot->'unit_ids') = 'array' AND
         EXISTS (
           SELECT 1 FROM jsonb_array_elements(NEW.snapshot->'unit_ids') unit
           WHERE jsonb_typeof(unit) = 'string' AND
                 btrim(unit #>> '{}') <> (unit #>> '{}')
         ) THEN
        RAISE EXCEPTION 'build assignment unit_ids must contain only unpadded non-empty strings'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER aa_epic_assignments_reject_padded_cycle_unit_ids
    BEFORE INSERT OR UPDATE ON epic_assignments
    FOR EACH ROW EXECUTE FUNCTION barkpark_reject_padded_cycle_assignment_unit_ids();
    """

    execute """
    CREATE FUNCTION barkpark_reject_padded_cycle_result_unit_ids() RETURNS trigger AS $$
    DECLARE
      assignment_phase text;
      assignment_cycle_wave uuid;
      outcome_units jsonb;
    BEGIN
      SELECT phase, cycle_wave_id INTO assignment_phase, assignment_cycle_wave
      FROM epic_assignments WHERE id = NEW.assignment_id;

      IF NEW.status = 'completed' AND assignment_phase = 'build' AND
         assignment_cycle_wave IS NOT NULL AND
         jsonb_typeof(NEW.payload->'completed_unit_ids') = 'array' AND
         jsonb_typeof(NEW.payload->'stalled_unit_ids') = 'array' AND
         jsonb_typeof(NEW.payload->'excluded_unit_ids') = 'array' THEN
        outcome_units := (NEW.payload->'completed_unit_ids') ||
                         (NEW.payload->'stalled_unit_ids') ||
                         (NEW.payload->'excluded_unit_ids');

        IF EXISTS (
          SELECT 1 FROM jsonb_array_elements(outcome_units) unit
          WHERE jsonb_typeof(unit) = 'string' AND
                btrim(unit #>> '{}') <> (unit #>> '{}')
        ) THEN
          RAISE EXCEPTION 'completed build result outcomes must contain only unpadded non-empty strings'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER aa_epic_assignment_results_reject_padded_cycle_unit_ids
    BEFORE INSERT OR UPDATE ON epic_assignment_results
    FOR EACH ROW EXECUTE FUNCTION barkpark_reject_padded_cycle_result_unit_ids();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS aa_cycle_waves_validate_inventory_00600 ON cycle_waves;"
    execute "DROP FUNCTION IF EXISTS barkpark_validate_cycle_wave_inventory_00600();"

    execute """
    DROP TRIGGER IF EXISTS aa_epic_assignment_results_reject_padded_cycle_unit_ids
    ON epic_assignment_results;
    """

    execute "DROP FUNCTION IF EXISTS barkpark_reject_padded_cycle_result_unit_ids();"

    execute """
    DROP TRIGGER IF EXISTS aa_epic_assignments_reject_padded_cycle_unit_ids
    ON epic_assignments;
    """

    execute "DROP FUNCTION IF EXISTS barkpark_reject_padded_cycle_assignment_unit_ids();"
  end
end
