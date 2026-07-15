defmodule Barkpark.Repo.Migrations.ExtendEpicFleetBenchmarkLedger do
  use Ecto.Migration

  def up do
    execute """
    CREATE FUNCTION barkpark_epic_costs_valid(costs jsonb)
    RETURNS boolean AS $$
    DECLARE
      metric record;
      state text;
    BEGIN
      IF jsonb_typeof(costs) <> 'object' OR costs = '{}'::jsonb THEN
        RETURN false;
      END IF;

      FOR metric IN SELECT key, value FROM jsonb_each(costs)
      LOOP
        IF length(metric.key) = 0 OR jsonb_typeof(metric.value) <> 'object' THEN
          RETURN false;
        END IF;

        state := metric.value->>'state';

        IF state = 'observed' THEN
          IF jsonb_typeof(metric.value->'value') <> 'number' THEN
            RETURN false;
          END IF;
        ELSIF state IN ('unsupported', 'missing', 'invalid') THEN
          IF jsonb_typeof(metric.value->'reason') <> 'string' OR
             length(trim(metric.value->>'reason')) = 0 THEN
            RETURN false;
          END IF;
        ELSE
          RETURN false;
        END IF;
      END LOOP;

      RETURN true;
    END;
    $$ LANGUAGE plpgsql IMMUTABLE STRICT;
    """

    create table(:epic_benchmark_experiments, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :delete_all), null: false
      add :epic_id, :text, null: false
      add :wave_id, :text, null: false
      add :experiment_id, :text, null: false
      add :phase, :text, null: false
      add :protocol_version, :integer, null: false
      add :manifest, :map, null: false, default: %{}
      add :manifest_digest, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(
             :epic_benchmark_experiments,
             [:workspace_id, :epic_id, :wave_id, :experiment_id],
             name: :epic_benchmark_experiments_scope_id_index
           )

    create constraint(:epic_benchmark_experiments, :epic_benchmark_experiments_phase,
             check: "phase IN ('epic', 'legendary')"
           )

    create constraint(
             :epic_benchmark_experiments,
             :epic_benchmark_experiments_protocol_version,
             check: "protocol_version > 0"
           )

    create constraint(:epic_benchmark_experiments, :epic_benchmark_experiments_manifest_digest,
             check: "manifest_digest ~ '^[0-9a-f]{64}$'"
           )

    create table(:epic_benchmark_attempts, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :experiment_id,
          references(:epic_benchmark_experiments, type: :uuid, on_delete: :delete_all),
          null: false

      add :attempt_id, :text, null: false
      add :replaces_attempt_id, :text
      add :ordinal, :integer, null: false
      add :treatment, :text, null: false
      add :status, :text, null: false
      add :costs, :map, null: false, default: %{}
      add :provenance, :map, null: false, default: %{}
      add :payload, :map, null: false, default: %{}
      add :attempt_digest, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:epic_benchmark_attempts, [:experiment_id, :attempt_id],
             name: :epic_benchmark_attempts_experiment_id_index
           )

    create index(:epic_benchmark_attempts, [:experiment_id, :ordinal])

    execute """
    ALTER TABLE epic_benchmark_attempts
      ADD CONSTRAINT epic_benchmark_attempts_replacement_fkey
      FOREIGN KEY (experiment_id, replaces_attempt_id)
      REFERENCES epic_benchmark_attempts(experiment_id, attempt_id)
      ON DELETE CASCADE
      DEFERRABLE INITIALLY DEFERRED;
    """

    create constraint(:epic_benchmark_attempts, :epic_benchmark_attempts_not_self_replacement,
             check: "replaces_attempt_id IS NULL OR replaces_attempt_id <> attempt_id"
           )

    create constraint(:epic_benchmark_attempts, :epic_benchmark_attempts_ordinal,
             check: "ordinal > 0"
           )

    create constraint(:epic_benchmark_attempts, :epic_benchmark_attempts_status,
             check: "status IN ('completed', 'failed', 'timeout', 'contaminated', 'cancelled')"
           )

    create constraint(:epic_benchmark_attempts, :epic_benchmark_attempts_costs,
             check: "barkpark_epic_costs_valid(costs)"
           )

    create constraint(:epic_benchmark_attempts, :epic_benchmark_attempts_digest,
             check: "attempt_digest ~ '^[0-9a-f]{64}$'"
           )

    execute """
    CREATE FUNCTION barkpark_epic_replacement_ordinal_valid()
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
    CREATE TRIGGER epic_benchmark_attempts_replacement_ordinal
    BEFORE INSERT ON epic_benchmark_attempts
    FOR EACH ROW EXECUTE FUNCTION barkpark_epic_replacement_ordinal_valid();
    """

    execute """
    CREATE TRIGGER epic_benchmark_experiments_no_update_delete
    BEFORE UPDATE OR DELETE ON epic_benchmark_experiments
    FOR EACH ROW EXECUTE FUNCTION barkpark_epic_ledger_immutable();
    """

    execute """
    CREATE TRIGGER epic_benchmark_attempts_no_update_delete
    BEFORE UPDATE OR DELETE ON epic_benchmark_attempts
    FOR EACH ROW EXECUTE FUNCTION barkpark_epic_ledger_immutable();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS epic_benchmark_attempts_replacement_ordinal ON epic_benchmark_attempts;"
    execute "DROP FUNCTION IF EXISTS barkpark_epic_replacement_ordinal_valid();"

    execute "DROP TRIGGER IF EXISTS epic_benchmark_attempts_no_update_delete ON epic_benchmark_attempts;"

    execute "DROP TRIGGER IF EXISTS epic_benchmark_experiments_no_update_delete ON epic_benchmark_experiments;"

    drop table(:epic_benchmark_attempts)
    drop table(:epic_benchmark_experiments)
    execute "DROP FUNCTION IF EXISTS barkpark_epic_costs_valid(jsonb);"
  end
end
