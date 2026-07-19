defmodule Barkpark.Repo.Migrations.FixCycleLiveAuthorityDigestAdmission do
  use Ecto.Migration

  @moduledoc """
  Stop reinterpreting the frozen live-authority digest after JSON persistence.

  `live_authority_digest` is produced over the live reconciliation term before
  the Paper is serialized. Promotion already proves the live ownership and
  outcome partition, exact semantic counts, reconciliation digest, fleet
  digest, correction receipt, and Paper revision independently. Re-hashing the
  persisted JSON representation is therefore both redundant and incorrect for
  a valid frozen candidate. Keep the digest's strict wire shape while leaving
  authority to those stronger joins.
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

      IF strpos(
        original_definition,
        'block->''cycle_ledger''->>''live_authority_digest'' ~ ''^[0-9a-f]{64}$'''
      ) > 0 THEN
        RETURN;
      END IF;

      patched_definition := regexp_replace(
        original_definition,
        'block->''cycle_ledger''->>''live_authority_digest'' =[[:space:]]+barkpark_jsonb_canonical_digest[(][[:space:]]+[(]block->''cycle_ledger''[)] - ''reconciliation_digest''::text -[[:space:]]+''live_authority_digest''::text[[:space:]]+[)]',
        'block->''cycle_ledger''->>''live_authority_digest'' ~ ''^[0-9a-f]{64}$'''
      );

      IF patched_definition = original_definition OR
         strpos(
           patched_definition,
           'block->''cycle_ledger''->>''live_authority_digest'' ~ ''^[0-9a-f]{64}$'''
         ) = 0 THEN
        RAISE EXCEPTION 'promotion live-authority digest guard patch did not match the installed function';
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
        'block->''cycle_ledger''->>''live_authority_digest'' ~ ''^[0-9a-f]{64}$''',
        'block->''cycle_ledger''->>''live_authority_digest'' =
              barkpark_jsonb_canonical_digest(
                (block->''cycle_ledger'') - ''reconciliation_digest''::text -
                  ''live_authority_digest''::text
              )'
      );

      IF patched_definition = original_definition OR
         strpos(
           patched_definition,
           'block->''cycle_ledger''->>''live_authority_digest'' ='
         ) = 0 THEN
        RAISE EXCEPTION 'promotion live-authority digest guard rollback did not match the installed function';
      END IF;

      EXECUTE patched_definition;
    END
    $migration$;
    """)
  end
end
