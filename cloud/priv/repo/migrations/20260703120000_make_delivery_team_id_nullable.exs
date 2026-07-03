defmodule BarkparkCloud.Repo.Migrations.MakeDeliveryTeamIdNullable do
  use Ecto.Migration

  # transactional-delivery-observability: the identity/transactional emails
  # (invite / password-reset / verify / email-change-code) now each write a
  # Delivery row so a must-arrive email is observable + gets the same retry seam
  # `alert`/`test` sends already have. But password-reset / verify / change-code
  # are USER-scoped, not team-scoped — the recipient may belong to no team, or the
  # send happens on a path that has no team in hand. So `team_id` must be allowed
  # to be null for those rows (the invite row still carries its real team_id).
  #
  # Purely additive + reversible: relax the NOT NULL constraint, no data touched.
  # `list_deliveries/2` already filters `team_id == ^tid`, so null-team identity
  # rows simply never surface in a team's delivery log (correct — they aren't
  # team-scoped). The FK (on_delete: :delete_all) stays; a null team_id just skips
  # the reference. NO backfill: existing rows are all team-scoped and unchanged.
  def up do
    alter table(:notification_deliveries) do
      modify :team_id, :binary_id, null: true
    end
  end

  def down do
    alter table(:notification_deliveries) do
      modify :team_id, :binary_id, null: false
    end
  end
end
