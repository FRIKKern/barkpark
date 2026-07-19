defmodule Barkpark.Repo.Migrations.FixLegendaryPromotionEffort do
  use Ecto.Migration

  @moduledoc """
  Make promotion admission honor the effort frozen in the authoritative Paper.

  The original guard encoded Epic's `build = high` rule directly. Legendary
  deliberately freezes builders at `medium`, so a complete Legendary fleet was
  rejected even when every live assignment matched its Paper. Patch the
  installed trigger function in place; fresh databases receive the same fix in
  the original migration.
  """

  def up do
    execute("""
    DO $migration$
    DECLARE
      original_definition text;
      patched_definition text;
    BEGIN
      SELECT pg_get_functiondef('barkpark_validate_cycle_correction()'::regprocedure)
      INTO original_definition;

      IF strpos(original_definition, 'expected.expected_effort') > 0 THEN
        RETURN;
      END IF;

      patched_definition := replace(
        original_definition,
        'fleet_phase.key AS phase, assignment.value AS fleet_assignment',
        'fleet_phase.key AS phase, fleet_phase.value->>''effort'' AS expected_effort, assignment.value AS fleet_assignment'
      );

      patched_definition := regexp_replace(
        patched_definition,
        'actual\\.effort IS DISTINCT FROM\\s+CASE WHEN expected\\.phase IN \\(''build'', ''review''\\) THEN ''high'' ELSE ''medium'' END',
        'actual.effort IS DISTINCT FROM expected.expected_effort'
      );

      IF patched_definition = original_definition OR
         strpos(patched_definition, 'expected.expected_effort') = 0 THEN
        RAISE EXCEPTION 'promotion effort guard patch did not match the installed function';
      END IF;

      EXECUTE patched_definition;
    END
    $migration$;
    """)
  end

  def down do
    execute("""
    DO $migration$
    DECLARE
      original_definition text;
      patched_definition text;
    BEGIN
      SELECT pg_get_functiondef('barkpark_validate_cycle_correction()'::regprocedure)
      INTO original_definition;

      patched_definition := replace(
        original_definition,
        'actual.effort IS DISTINCT FROM expected.expected_effort',
        'actual.effort IS DISTINCT FROM
          CASE WHEN expected.phase IN (''build'', ''review'') THEN ''high'' ELSE ''medium'' END'
      );

      patched_definition := replace(
        patched_definition,
        'fleet_phase.key AS phase, fleet_phase.value->>''effort'' AS expected_effort, assignment.value AS fleet_assignment',
        'fleet_phase.key AS phase, assignment.value AS fleet_assignment'
      );

      IF patched_definition = original_definition OR
         strpos(patched_definition, 'expected.expected_effort') > 0 THEN
        RAISE EXCEPTION 'promotion effort guard rollback did not match the installed function';
      END IF;

      EXECUTE patched_definition;
    END
    $migration$;
    """)
  end
end
