defmodule BarkparkCloud.Repo.Migrations.AddMemberJoinedToEmailNotificationSettings do
  @moduledoc """
  cch-w30-bl-member-joined-alert — the per-team toggle for the MEMBER-JOINED
  alert, landing in the same change as its producer.

  ## Why the column exists at all

  `Accounts.accept_invitation/2` adds a person to a team and, until now, told
  nobody already on that team: the invitee got a transactional invite letter
  before they accepted and the team got nothing after they did. The new event is
  `:member_joined` — the ACCEPTANCE, not the send. Wave 30's deleted
  `member_invited` column is NOT being restored under a new name: that one
  promised a duplicate of the invitee's own letter and had no producer; this one
  has one, in the same commit, and describes a different moment.

  `EmailSettings.@events` is the schema-side vocabulary every rail derives from
  (`Notifications.@chat_events`, the console matrix, both renderers), and
  `event_enabled?/2`'s `Map.fetch!/2` raises on an atom in `@events` with no
  column — so the column is the toggle, not decoration.

  ## DEFAULT FALSE, and the default is the argument

  `EmailSettings`'s moduledoc states the rule this table has followed since it
  was created: **failures default ON, successes default OFF**. A teammate
  joining is not a failure — nothing is broken, nothing needs a remedy — so it
  is opt-in. Defaulting it ON would mail every existing team about an event they
  never asked for the first time anyone accepted an invitation.

  ## No back-fill beyond the column default

  `default: false` + `null: false` is applied by Postgres to existing rows as
  part of the ADD (PG 11+ stores it in the catalog rather than rewriting the
  table), so every existing team gets the same answer a new team gets and there
  is no separate UPDATE pass to reason about. Nothing else is touched.
  """

  use Ecto.Migration

  def change do
    alter table(:email_notification_settings) do
      add :member_joined, :boolean, null: false, default: false
    end
  end
end
