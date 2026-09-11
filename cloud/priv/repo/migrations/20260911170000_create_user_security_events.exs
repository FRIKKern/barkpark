defmodule BarkparkCloud.Repo.Migrations.CreateUserSecurityEvents do
  use Ecto.Migration

  # THE USER-SCOPED SECURITY LOG — a sibling of `audit_events`, deliberately NOT
  # a nullable-team variant of it.
  #
  # `audit_events.team_id` is `null: false`, and that is not an accident: every
  # consumer of that table (GET /v1/audit, the console's team trail, the
  # per-resource history index) is keyed on a team. The auth self-service routes
  # are USER-scoped and mostly pre-team — `Accounts.primary_team/1` is
  # `list_user_teams() |> List.first()` and returns nil for a membership-less
  # user, which is exactly why `Router.audit_account_security/2` has a LOGGED
  # SKIP arm. Relaxing `team_id` to nullable would have made every team-keyed
  # reader silently partial instead; a separate table keeps both trails total.
  #
  # Append-only for the same reason `audit_events` is, enforced the same two
  # ways: `updated_at: false` stops Ecto, and a BEFORE UPDATE OR DELETE trigger
  # stops raw SQL. The user FK is `on_delete: :delete_all` (not `nilify_all`):
  # every row here is ABOUT the user, so a row that outlived its subject would
  # be an unattributable security fact nobody can read.
  #
  # RETENTION: NONE in this migration. The table grows unbounded until a pruner
  # lands. That is a stated decision, not an oversight — a self-service security
  # log whose rows expire silently is worse than one that keeps them, and the
  # pruning window is a product ruling this slice does not own.
  def change do
    create table(:user_security_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :action, :string, null: false
      add :ip, :string
      add :user_agent, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # The one read this table has: "my trail, newest first". The compound index
    # matches the `(user_id)` filter + `(inserted_at DESC, id DESC)` order.
    create index(:user_security_events, [:user_id, :inserted_at])

    execute(
      """
      CREATE OR REPLACE FUNCTION user_security_events_append_only()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'user_security_events is append-only: % is not permitted', TG_OP;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION IF EXISTS user_security_events_append_only() CASCADE;"
    )

    # A row-level BEFORE DELETE trigger also fires on an FK ON DELETE CASCADE, so
    # this trigger would abort a hard user delete. There is no hard user-delete
    # path in cloud/ today (account deletion is not implemented); when one lands
    # it must drop/replace this trigger inside its maintenance transaction. Same
    # caveat, verbatim, as `audit_events_no_mutate`.
    execute(
      """
      CREATE TRIGGER user_security_events_no_mutate
      BEFORE UPDATE OR DELETE ON user_security_events
      FOR EACH ROW EXECUTE FUNCTION user_security_events_append_only();
      """,
      "DROP TRIGGER IF EXISTS user_security_events_no_mutate ON user_security_events;"
    )
  end
end
