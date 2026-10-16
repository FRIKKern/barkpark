defmodule Barkpark.Repo.Migrations.PortableSearchRefreshUpsert do
  use Ecto.Migration

  @moduledoc """
  `bp_search_refresh_request` upserts without an ON CONFLICT target.

  Migration 20261016130000 recorded a pending scope with
  `INSERT ... ON CONFLICT (type, scope_dataset, scope_dataset_id, wide)`.
  That target names the plain columns, so it only matches the Postgres 15
  index built with NULLS NOT DISTINCT. Before Postgres 15 the same migration
  now builds the index on `COALESCE(scope_dataset_id, <zero uuid>)`, which the
  target does not match, and the insert would fail with "there is no unique or
  exclusion constraint matching the ON CONFLICT specification".

  The function now updates the scope's row first, matching
  `scope_dataset_id IS NOT DISTINCT FROM p_dataset_id`. When no row matches it
  inserts with `ON CONFLICT DO NOTHING`, which any unique index arbitrates.
  When a concurrent write inserted the row first, it loops and updates that
  row. When the worker deleted the row in between, the next pass inserts it
  again. The written values are the same as before: slots, public and gate
  are OR'd, gen goes up by one, requested_at and updated_at are set to now.
  """

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_refresh_request(
      p_type text, p_dataset text, p_dataset_id uuid, p_wide boolean,
      p_slots boolean, p_public boolean, p_gate boolean
    ) RETURNS void LANGUAGE plpgsql AS $$
    DECLARE
      inline_max int := coalesce(
        nullif(current_setting('barkpark.search_refresh_inline_max', true), '')::int, 1000);
      n int;
    BEGIN
      IF NOT p_slots AND NOT p_public THEN
        RETURN;
      END IF;

      SELECT count(*) INTO n FROM (
        SELECT 1 FROM documents d
        WHERE d.type = p_type
          AND ((p_dataset_id IS NOT NULL AND d.dataset_id = p_dataset_id)
               OR (p_wide AND d.dataset = p_dataset))
        LIMIT inline_max + 1
      ) s;

      IF n <= inline_max THEN
        PERFORM bp_search_refresh_batch(p_type, p_dataset, p_dataset_id, p_wide,
                                        p_slots, p_public, NULL, NULL);
        RETURN;
      END IF;

      LOOP
        UPDATE search_refresh_pending p
        SET slots = p.slots OR p_slots,
            public = p.public OR p_public,
            gate = p.gate OR p_gate,
            gen = p.gen + 1,
            requested_at = now() AT TIME ZONE 'utc',
            updated_at = now()
        WHERE p.type = p_type
          AND p.scope_dataset = p_dataset
          AND p.scope_dataset_id IS NOT DISTINCT FROM p_dataset_id
          AND p.wide = p_wide;

        IF FOUND THEN
          RETURN;
        END IF;

        INSERT INTO search_refresh_pending
          (type, scope_dataset, scope_dataset_id, wide, slots, public, gate)
        VALUES (p_type, p_dataset, p_dataset_id, p_wide, p_slots, p_public, p_gate)
        ON CONFLICT DO NOTHING;

        IF FOUND THEN
          RETURN;
        END IF;
      END LOOP;
    END
    $$
    """)
  end

  # Migration 20261016130000's version, which needs the Postgres 15 index.
  def down do
    execute("""
    CREATE OR REPLACE FUNCTION bp_search_refresh_request(
      p_type text, p_dataset text, p_dataset_id uuid, p_wide boolean,
      p_slots boolean, p_public boolean, p_gate boolean
    ) RETURNS void LANGUAGE plpgsql AS $$
    DECLARE
      inline_max int := coalesce(
        nullif(current_setting('barkpark.search_refresh_inline_max', true), '')::int, 1000);
      n int;
    BEGIN
      IF NOT p_slots AND NOT p_public THEN
        RETURN;
      END IF;

      SELECT count(*) INTO n FROM (
        SELECT 1 FROM documents d
        WHERE d.type = p_type
          AND ((p_dataset_id IS NOT NULL AND d.dataset_id = p_dataset_id)
               OR (p_wide AND d.dataset = p_dataset))
        LIMIT inline_max + 1
      ) s;

      IF n <= inline_max THEN
        PERFORM bp_search_refresh_batch(p_type, p_dataset, p_dataset_id, p_wide,
                                        p_slots, p_public, NULL, NULL);
        RETURN;
      END IF;

      INSERT INTO search_refresh_pending AS p
        (type, scope_dataset, scope_dataset_id, wide, slots, public, gate)
      VALUES (p_type, p_dataset, p_dataset_id, p_wide, p_slots, p_public, p_gate)
      ON CONFLICT (type, scope_dataset, scope_dataset_id, wide) DO UPDATE
      SET slots = p.slots OR EXCLUDED.slots,
          public = p.public OR EXCLUDED.public,
          gate = p.gate OR EXCLUDED.gate,
          gen = p.gen + 1,
          requested_at = now() AT TIME ZONE 'utc',
          updated_at = now();
    END
    $$
    """)
  end
end
