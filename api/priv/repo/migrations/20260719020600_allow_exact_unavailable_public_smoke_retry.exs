defmodule Barkpark.Repo.Migrations.AllowExactUnavailablePublicSmokeRetry do
  use Ecto.Migration

  @old_guard """
  IF EXISTS (SELECT 1 FROM cycle_correction_quarantines q WHERE q.correction_wave_id = NEW.target_wave_id) THEN
        RAISE EXCEPTION 'quarantined correction cannot be promoted';
      END IF;
  """

  @new_guard """
  IF EXISTS (SELECT 1 FROM cycle_correction_quarantines q WHERE q.correction_wave_id = NEW.target_wave_id) AND
         NOT barkpark_unavailable_smoke_retry_allowed(NEW.target_wave_id, current_head) THEN
        RAISE EXCEPTION 'quarantined correction cannot be promoted';
      END IF;
  """

  def up do
    execute retry_authority_function()
    replace_guard!(@old_guard, @new_guard)
  end

  def down do
    replace_guard!(@new_guard, @old_guard)
    execute "DROP FUNCTION IF EXISTS barkpark_unavailable_smoke_retry_allowed(uuid, uuid);"
  end

  defp replace_guard!(from, to) do
    execute """
    DO $migration$
    DECLARE
      definition text;
      old_guard text := #{dollar_quote(from)};
      new_guard text := #{dollar_quote(to)};
    BEGIN
      SELECT pg_get_functiondef('barkpark_validate_cycle_correction()'::regprocedure)
      INTO definition;

      IF position(old_guard IN definition) = 0 THEN
        RAISE EXCEPTION 'cycle correction quarantine guard does not match expected definition';
      END IF;

      definition := replace(definition, old_guard, new_guard);

      IF position(old_guard IN definition) > 0 OR position(new_guard IN definition) = 0 THEN
        RAISE EXCEPTION 'cycle correction quarantine guard replacement was not exact';
      END IF;

      EXECUTE definition;
    END;
    $migration$;
    """
  end

  defp dollar_quote(value), do: "$guard$#{value}$guard$"

  defp retry_authority_function do
    """
    CREATE OR REPLACE FUNCTION barkpark_unavailable_smoke_retry_allowed(
      target_revision uuid,
      current_head uuid
    ) RETURNS boolean AS $$
      SELECT
        EXISTS (
          SELECT 1
          FROM cycle_correction_promotion_events rollback
          JOIN cycle_release_public_smokes smoke
            ON smoke.compensation_event_id = rollback.id
          WHERE rollback.id = current_head
            AND rollback.action = 'rollback'
            AND smoke.target_wave_id = target_revision
            AND smoke.state = 'compensated'
            AND smoke.promotion_event_id = rollback.previous_event_id
            AND smoke.failure->>'reason' = ':public_release_smoke_unavailable'
        )
        AND NOT EXISTS (
          SELECT 1
          FROM cycle_correction_quarantines quarantine
          WHERE quarantine.correction_wave_id = target_revision
            AND NOT EXISTS (
              SELECT 1
              FROM cycle_release_public_smokes smoke
              JOIN cycle_correction_promotion_events promoted
                ON promoted.id = smoke.promotion_event_id
              JOIN cycle_correction_promotion_events compensation
                ON compensation.id = smoke.compensation_event_id
              WHERE promoted.target_wave_id = target_revision
                AND promoted.root_wave_id = quarantine.root_wave_id
                AND compensation.action = 'rollback'
                AND compensation.previous_event_id = promoted.id
                AND smoke.state = 'compensated'
                AND smoke.failure->>'reason' = ':public_release_smoke_unavailable'
                AND quarantine.idempotency_key =
                  promoted.idempotency_key || ':public-smoke-quarantine'
                AND quarantine.evidence =
                  'public-reader-smoke://' || promoted.id::text || '/failed'
                AND quarantine.evidence_revision =
                  barkpark_jsonb_canonical_digest(smoke.failure)
                AND quarantine.reason =
                  'post-promotion anonymous public Paper smoke failed: :public_release_smoke_unavailable'
            )
        );
    $$ LANGUAGE sql STABLE;
    """
  end
end
