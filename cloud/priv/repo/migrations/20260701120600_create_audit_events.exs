defmodule BarkparkCloud.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  # Team-scoped, append-only audit trail: WHO (actor_user_id) did WHAT (action)
  # to WHICH thing (target_type/target_id) in a team, with a free jsonb context
  # map. ONLY inserted_at, no updated_at — an audit event is written once and
  # never mutated (mirrors create_agent_events). `team_id` is a REAL FK column
  # (improving on Coolify's JSON properties->team_id).
  #
  # Version renumbered above main's latest (20260701120500) so it lands AFTER the
  # Oban + PR-#680 foundation rather than colliding with 20260629120000
  # (add_oban_jobs), which the swarm candidate originally reused.
  #
  # Indexed (team_id, inserted_at desc) for the per-team recency feed, and
  # (team_id, target_type, target_id, inserted_at desc) for per-resource history
  # ("everything that happened to THIS site").
  def change do
    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # A deleted team's audit trail has no consumer, so it cascades away with
      # the team (matches agent_events cascading from barkparks). Retention of a
      # LIVE team's trail is the sweeper's job, not this FK's.
      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all),
        null: false

      # NULLABLE + nilify: a system / webhook action has no human actor, and an
      # actor's account deletion must NOT erase the audit fact — only its FK.
      add :actor_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :action, :string, null: false
      add :target_type, :string
      add :target_id, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:audit_events, [:team_id, :inserted_at])
    create index(:audit_events, [:team_id, :target_type, :target_id, :inserted_at])

    # Append-only ENFORCED AT THE DB, not just the schema. The `updated_at: false`
    # timestamps only stop Ecto from writing an update column — a raw
    # `UPDATE`/`DELETE` (a compromised app, a careless psql, a future ORM change)
    # could still rewrite or erase an audit fact. A BEFORE UPDATE OR DELETE
    # trigger raises, so the trail is immutable at the storage layer.
    #
    # CAVEAT (honest): a row-level BEFORE DELETE trigger ALSO fires on an FK
    # ON DELETE CASCADE, so this trigger would abort a hard team deletion that
    # cascades into audit_events. There is NO hard team-delete path in the code
    # today (authz reserves a `:delete_team` capability but nothing implements a
    # `Repo.delete` of a Team), so this is inert now. If a hard team-delete lands,
    # it must run inside a maintenance txn that drops/replaces this trigger (or
    # deletes the team's audit rows through a guarded bypass) before the cascade.
    # The retention sweeper (a follow-up) has the same requirement.
    execute(
      """
      CREATE OR REPLACE FUNCTION audit_events_append_only()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'audit_events is append-only: % is not permitted', TG_OP;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION IF EXISTS audit_events_append_only() CASCADE;"
    )

    execute(
      """
      CREATE TRIGGER audit_events_no_mutate
      BEFORE UPDATE OR DELETE ON audit_events
      FOR EACH ROW EXECUTE FUNCTION audit_events_append_only();
      """,
      "DROP TRIGGER IF EXISTS audit_events_no_mutate ON audit_events;"
    )
  end
end
