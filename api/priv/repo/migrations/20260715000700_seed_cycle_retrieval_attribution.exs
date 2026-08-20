defmodule Barkpark.Repo.Migrations.SeedCycleRetrievalAttribution do
  use Ecto.Migration

  def up do
    alter table(:epic_assignments) do
      add :unit_ids, {:array, :text}
      add :inventory_digest, :text
    end

    execute "ALTER TABLE epic_assignments DISABLE TRIGGER epic_assignments_no_update_delete;"

    execute """
    UPDATE epic_assignments assignment
    SET inventory_digest = wave.inventory_digest,
        unit_ids = CASE
          WHEN assignment.phase = 'build' AND
               jsonb_typeof(assignment.snapshot->'unit_ids') = 'array'
          THEN ARRAY(
            SELECT unit #>> '{}'
            FROM jsonb_array_elements(assignment.snapshot->'unit_ids')
                 WITH ORDINALITY AS owned(unit, ordinal)
            ORDER BY ordinal
          )
          ELSE ARRAY[]::text[]
        END
    FROM cycle_waves wave
    WHERE assignment.cycle_wave_id = wave.id;
    """

    execute "ALTER TABLE epic_assignments ENABLE TRIGGER epic_assignments_no_update_delete;"

    create constraint(:epic_assignments, :epic_assignments_cycle_retrieval_attribution,
             check: """
             (cycle_wave_id IS NULL AND unit_ids IS NULL AND inventory_digest IS NULL) OR
             (cycle_wave_id IS NOT NULL AND unit_ids IS NOT NULL AND
              inventory_digest ~ '^[0-9a-f]{64}$')
             """
           )

    execute """
    CREATE FUNCTION barkpark_seed_cycle_retrieval_attribution() RETURNS trigger AS $$
    BEGIN
      IF NEW.cycle_wave_id IS NULL THEN
        NEW.unit_ids := NULL;
        NEW.inventory_digest := NULL;
        RETURN NEW;
      END IF;

      SELECT wave.inventory_digest INTO NEW.inventory_digest
      FROM cycle_waves wave
      WHERE wave.id = NEW.cycle_wave_id;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'cycle assignment retrieval attribution requires an immutable wave'
          USING ERRCODE = 'foreign_key_violation';
      END IF;

      IF NEW.phase = 'build' AND jsonb_typeof(NEW.snapshot->'unit_ids') = 'array' THEN
        SELECT COALESCE(array_agg(unit #>> '{}' ORDER BY ordinal), ARRAY[]::text[])
        INTO NEW.unit_ids
        FROM jsonb_array_elements(NEW.snapshot->'unit_ids')
             WITH ORDINALITY AS owned(unit, ordinal);
      ELSE
        NEW.unit_ids := ARRAY[]::text[];
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER aa_epic_assignments_seed_cycle_retrieval_attribution
    BEFORE INSERT ON epic_assignments
    FOR EACH ROW EXECUTE FUNCTION barkpark_seed_cycle_retrieval_attribution();
    """
  end

  def down do
    execute """
    DROP TRIGGER IF EXISTS aa_epic_assignments_seed_cycle_retrieval_attribution
    ON epic_assignments;
    """

    execute "DROP FUNCTION IF EXISTS barkpark_seed_cycle_retrieval_attribution();"

    drop constraint(:epic_assignments, :epic_assignments_cycle_retrieval_attribution)

    alter table(:epic_assignments) do
      remove :inventory_digest
      remove :unit_ids
    end
  end
end
