defmodule BarkparkCloud.Repo.Migrations.AddDeploymentAbandonedToEmailNotificationSettings do
  @moduledoc """
  dr-w13-bl-abandonment-splits-off-the-flood — the per-team toggle for the
  ABANDONED-CHAIN alert, landing in the same change as its producer.

  ## Why the column exists at all

  `Registry.dispatch_deployment_failed/1` is the one funnel both synchronous
  terminals reach, and until now it dispatched `:deployment_failed` for a chain
  the fleet GAVE UP ON exactly as it did for a single attempt that failed — one
  event name over ~870 routine failures a day and seven abandonments all-time
  (charter D193). `AbandonmentPolicy.abandonment?/1` splits the branch;
  `:deployment_abandoned` is the name the split needs, and
  `EmailSettings.@events` is the schema-side vocabulary every rail derives from
  (`Notifications.@chat_events`, the console matrix, both renderers). An atom in
  `@events` without a column makes `event_enabled?/2`'s `Map.fetch!/2` raise, so
  the column is not optional decoration — it is the toggle.

  ## DEFAULT TRUE, and the default is the argument

  `EmailSettings`'s moduledoc states the rule this table has followed since it
  was created: **failures default ON, successes default OFF**. A publish that was
  given up on is the most severe failure the fleet produces. `deployment_failed`
  — the event this one splits OFF — is `default: true`, so an abandonment that
  reached a team before this migration still reaches them after it, under a name
  that says what happened. A `default: false` here would silently REMOVE an alert
  those teams already receive, which is the opposite of what the split is for.

  ## No back-fill beyond the column default

  `default: true` + `null: false` is applied by Postgres to existing rows as part
  of the ADD (PG 11+ stores it in the catalog rather than rewriting the table),
  so every existing team gets the same answer a new team gets and there is no
  separate UPDATE pass to reason about. Nothing else is touched.
  """

  use Ecto.Migration

  def change do
    alter table(:email_notification_settings) do
      add :deployment_abandoned, :boolean, null: false, default: true
    end
  end
end
