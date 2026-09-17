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
  #   * UPDATE STAYS FATAL UNCONDITIONALLY. The flag is checked only on
  #     TG_OP = 'DELETE'. Erasure removes a fact; it never rewrites one. An
  #     append-only table whose rows could be EDITED under a flag would not be
  #     append-only in any sense worth the name — a row that can be erased is
  #     still honest about what it said while it existed.
  #
  # Down-migration restores the unconditional raise verbatim.

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION audit_events_append_only()
    RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' AND current_setting('barkpark.erasure', true) = 'on' THEN
        RETURN OLD;
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
