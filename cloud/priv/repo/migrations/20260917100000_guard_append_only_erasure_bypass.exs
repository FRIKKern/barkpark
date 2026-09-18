defmodule BarkparkCloud.Repo.Migrations.GuardAppendOnlyErasureBypass do
  use Ecto.Migration

  # THE ERASURE BYPASS, NARROWED TO ONE VERB UNDER ONE SESSION FLAG.
  #
  # `audit_events_no_mutate` and `user_security_events_no_mutate` are BEFORE
  # UPDATE OR DELETE row triggers that raise unconditionally. Both migrations
  # (20260701120600, 20260911170000) wrote the same caveat in their own comments:
  # a row-level BEFORE DELETE trigger ALSO fires on an FK ON DELETE CASCADE, so
  # a hard team-delete or user-delete would ABORT, and whoever lands one "must
  # run inside a maintenance txn that drops/replaces this trigger (or deletes the
  # team's audit rows through a guarded bypass) before the cascade."
  #
  # This is that guarded bypass, and it is deliberately the NARROW one:
  #
  #   * ALTER TABLE ... DISABLE TRIGGER would have worked and was rejected: it
  #     takes an ACCESS EXCLUSIVE lock on a hot append-only table for the whole
  #     erasure transaction, and it disables the guard for EVERY session, not
  #     just the erasing one.
  #   * The flag is `barkpark.erasure`, a SESSION GUC set with `SET LOCAL` inside
  #     the erasure transaction, so it reverts at COMMIT/ROLLBACK and is visible
  #     to no other connection. `current_setting(..., true)` is the missing-ok
  #     form: an ordinary connection that never heard of the GUC reads NULL and
  #     falls straight through to the RAISE.
  #   * UPDATE STAYS FATAL, with ONE surgically-shaped exception that the FK
  #     graph forces and that the first test run found. `audit_events` is the
  #     table where an erased USER is ANONYMISED rather than deleted:
  #     `actor_user_id` is `ON DELETE SET NULL`, so a user delete cascades as an
  #     UPDATE, and an unconditional UPDATE raise aborts the account erasure just
  #     as surely as the DELETE raise aborted the team one. The exception is
  #     therefore not "UPDATE is allowed under the flag" — it is exactly the
  #     nilify the FK itself performs:
  #
  #         the flag is on, AND
  #         NEW.actor_user_id IS NULL, AND
  #         OLD.actor_user_id IS NOT NULL, AND
  #         every other column is byte-identical
  #           (`to_jsonb(NEW) - 'actor_user_id' = to_jsonb(OLD) - 'actor_user_id'`)
  #
  #     Rewriting an `action`, a `metadata`, a `target_id` or a `team_id` still
  #     raises, flag or no flag. `user_security_events` has no nilify FK, so its
  #     UPDATE arm keeps the unconditional raise with no exception at all.
  #
  # Down-migration restores the unconditional raise verbatim.

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION audit_events_append_only()
    RETURNS trigger AS $$
    BEGIN
      IF current_setting('barkpark.erasure', true) = 'on' THEN
        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;

        -- The actor nilify the ON DELETE SET NULL FK performs, and nothing else.
        IF TG_OP = 'UPDATE'
           AND NEW.actor_user_id IS NULL
           AND OLD.actor_user_id IS NOT NULL
           AND (to_jsonb(NEW) - 'actor_user_id') = (to_jsonb(OLD) - 'actor_user_id') THEN
          RETURN NEW;
        END IF;
      END IF;

      RAISE EXCEPTION 'audit_events is append-only: % is not permitted', TG_OP;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION user_security_events_append_only()
    RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' AND current_setting('barkpark.erasure', true) = 'on' THEN
        RETURN OLD;
      END IF;
      RAISE EXCEPTION 'user_security_events is append-only: % is not permitted', TG_OP;
    END;
    $$ LANGUAGE plpgsql;
    """)
  end

  def down do
    execute("""
    CREATE OR REPLACE FUNCTION audit_events_append_only()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'audit_events is append-only: % is not permitted', TG_OP;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION user_security_events_append_only()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'user_security_events is append-only: % is not permitted', TG_OP;
    END;
    $$ LANGUAGE plpgsql;
    """)
  end
end
