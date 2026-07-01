defmodule BarkparkCloud.Repo.Migrations.AddTrialToTeams do
  use Ecto.Migration

  # dwb-13 — the DURABLE trial ledger on the team row.
  #
  # The `trial` Subscription row (Billing.grant_trial/1) is the ENTITLEMENT
  # mechanism the gates read; these team columns are the "one trial per team
  # EVER" LEDGER. They survive a teardown of the subscription row, so a torn-down
  # or expired trial can never be re-granted — `Billing.start_trial/1` claims the
  # window with an atomic `UPDATE … WHERE trial_started_at IS NULL`, which is both
  # the one-ever gate and the race guard (two concurrent first-launches stamp
  # exactly once).
  #
  #   * trial_started_at        — set ONCE, when the team's one free trial begins.
  #                               NULL = this team has never started a trial.
  #   * trial_ends_at           — trial_started_at + TRIAL_DAYS. The window the
  #                               expiry worker reads for advance notices + teardown.
  #   * trial_notice_3d_sent_at — the T-3-day advance-notice idempotency stamp.
  #   * trial_notice_1d_sent_at — the T-1-day advance-notice idempotency stamp.
  #     (Both claimed atomically by the worker so an hourly cron never re-sends.)
  #
  # Backfill: existing trial teams (a live `trial` subscription) get their ledger
  # seeded from that row, so a team that already consumed its trial before this
  # migration is correctly marked "used" (its expired trial can't restart).
  def change do
    alter table(:teams) do
      add :trial_started_at, :utc_datetime_usec
      add :trial_ends_at, :utc_datetime_usec
      add :trial_notice_3d_sent_at, :utc_datetime_usec
      add :trial_notice_1d_sent_at, :utc_datetime_usec
    end

    # Seed the ledger from any existing trial subscription. Guarded by a NULL
    # check so it is idempotent; the `down` (column drop, via `alter` reversal)
    # removes the data, so the execute has an empty inverse.
    execute(
      """
      UPDATE teams t
         SET trial_started_at = s.inserted_at,
             trial_ends_at    = s.current_period_end
        FROM subscriptions s
       WHERE s.team_id = t.id
         AND s.plan = 'trial'
         AND s.status = 'active'
         AND t.trial_started_at IS NULL
      """,
      ""
    )
  end
end
