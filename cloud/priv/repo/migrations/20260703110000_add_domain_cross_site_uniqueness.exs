defmodule BarkparkCloud.Repo.Migrations.AddDomainCrossSiteUniqueness do
  use Ecto.Migration

  # Cross-team domain collision / takeover guard (DB-level backstop for the
  # app-level check in Registry.add_site_domain/2).
  #
  # `sites.domains` is a text[] array, so a plain UNIQUE index cannot enforce
  # per-element uniqueness across rows. A BEFORE INSERT/UPDATE trigger does: it
  # rejects any write that would place a domain already present in ANOTHER site's
  # array onto this one, raising a `unique_violation` (translated to a friendly
  # {:error, :domain_taken} / 409 in the app).
  #
  # PROD-SAFETY / ORDERING — this migration is intentionally safe to apply even if
  # prod currently holds a duplicate:
  #   * CREATE OR REPLACE FUNCTION and CREATE TRIGGER never scan existing rows, so
  #     (unlike CREATE UNIQUE INDEX) this CANNOT fail on a pre-existing collision.
  #   * The trigger only checks domains NEWLY added by a write (NEW.domains minus
  #     OLD.domains on UPDATE; all of NEW.domains on INSERT). An unrelated update
  #     to a row that happens to share a legacy duplicate does NOT re-trip it.
  # Existing duplicates therefore remain (frozen, cannot grow) until the separate
  # prod-duplicate audit resolves them. The trigger does NOT auto-heal them — it
  # only prevents NEW collisions. Do not treat this migration as the dedup.
  def up do
    execute("""
    CREATE OR REPLACE FUNCTION enforce_site_domain_uniqueness()
    RETURNS trigger AS $$
    DECLARE
      added text[];
      d text;
    BEGIN
      IF (TG_OP = 'UPDATE') THEN
        added := ARRAY(
          SELECT unnest(NEW.domains)
          EXCEPT
          SELECT unnest(OLD.domains)
        );
      ELSE
        added := NEW.domains;
      END IF;

      IF added IS NULL THEN
        RETURN NEW;
      END IF;

      FOREACH d IN ARRAY added LOOP
        IF EXISTS (
          SELECT 1 FROM sites s
          WHERE s.id <> NEW.id AND d = ANY(s.domains)
        ) THEN
          RAISE EXCEPTION 'domain % is already registered to another site', d
            USING ERRCODE = 'unique_violation';
        END IF;
      END LOOP;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER sites_domain_cross_site_uniqueness
    BEFORE INSERT OR UPDATE ON sites
    FOR EACH ROW EXECUTE FUNCTION enforce_site_domain_uniqueness();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS sites_domain_cross_site_uniqueness ON sites;")
    execute("DROP FUNCTION IF EXISTS enforce_site_domain_uniqueness();")
  end
end
