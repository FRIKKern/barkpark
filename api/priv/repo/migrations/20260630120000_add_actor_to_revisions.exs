defmodule Barkpark.Repo.Migrations.AddActorToRevisions do
  use Ecto.Migration

  # Upgrade the existing version-history table into a who-did-what content trail.
  # `actor_user_id` is a plain STRING (the api/ side keys actors by a string id /
  # api-token id, matching plugin_settings_audit.user_id — there is no single FK
  # target on this side). NULLABLE: backfilled history and system writes have no
  # actor, and existing callers that don't thread :user_id still write a revision
  # with a nil actor (back-compat). Indexed (actor_user_id) so "everything alice
  # edited" is a cheap scan. No new table — version history already writes inside
  # the mutation transaction, so the actor stamp is atomic-with-mutation for free.
  #
  # Version renumbered above main's api latest (20260629170000) so this
  # never-run migration lands AFTER the migrated ones rather than triggering
  # Ecto's out-of-order "migrations already run" error.
  def change do
    alter table(:revisions) do
      add :actor_user_id, :string
    end

    create index(:revisions, [:actor_user_id])
  end
end
