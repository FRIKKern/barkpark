defmodule Barkpark.Repo.Migrations.RepairEpicFleetReplacementBoundaries do
  use Ecto.Migration

  def up do
    execute """
    CREATE OR REPLACE FUNCTION barkpark_epic_replacement_ordinal_valid()
    RETURNS trigger AS $$
    DECLARE
      previous_ordinal integer;
    BEGIN
      IF NEW.replaces_attempt_id IS NULL THEN
        RETURN NEW;
      END IF;

      SELECT ordinal INTO previous_ordinal
      FROM epic_benchmark_attempts
      WHERE experiment_id = NEW.experiment_id
        AND attempt_id = NEW.replaces_attempt_id;

      IF previous_ordinal IS NULL OR NEW.ordinal <= previous_ordinal THEN
        RAISE EXCEPTION 'replacement attempt must have a greater ordinal'
          USING ERRCODE = 'check_violation',
                CONSTRAINT = 'epic_benchmark_attempts_replacement_ordinal';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    DROP TRIGGER IF EXISTS epic_benchmark_attempts_replacement_ordinal
      ON epic_benchmark_attempts
    """

    execute """
    CREATE TRIGGER epic_benchmark_attempts_replacement_ordinal
    BEFORE INSERT ON epic_benchmark_attempts
    FOR EACH ROW EXECUTE FUNCTION barkpark_epic_replacement_ordinal_valid()
    """

    create unique_index(:epic_benchmark_attempts, [:experiment_id, :replaces_attempt_id],
             name: :epic_benchmark_attempts_replaces_once_index,
             where: "replaces_attempt_id IS NOT NULL"
           )
  end

  def down do
    drop_if_exists index(:epic_benchmark_attempts, [:experiment_id, :replaces_attempt_id],
                     name: :epic_benchmark_attempts_replaces_once_index
                   )

    # Migration 20260715000400 owns the ordinal function and trigger on fresh
    # databases, so rolling this repair back must leave that declared boundary.
  end
end
