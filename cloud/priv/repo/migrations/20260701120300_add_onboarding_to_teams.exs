defmodule BarkparkCloud.Repo.Migrations.AddOnboardingToTeams do
  use Ecto.Migration

  # Coolify tracks first-run with a single `teams.show_boarding` boolean
  # (database/migrations/2023_08_22_071048_add_boarding_to_teams.php). We mirror
  # the per-team minimalism but make it resumable AND analytics-bearing:
  #
  #   * onboarding_state        — small jsonb blob {version, last_step, acked:[...]}
  #                               so a half-finished checklist survives a reload.
  #   * onboarding_completed_at — null = still onboarding; a timestamp the instant
  #                               the team finishes OR dismisses. Doubles as the
  #                               time-to-first-instance activation metric (compare
  #                               to teams.inserted_at) a beta-exiting product wants.
  #
  # The column defaults make a fresh team "onboarding" for free — the analog of
  # Coolify force-setting `show_boarding = true` on team birth (app/Models/User.php
  # :96) — so the transactional register/3 signup path stays untouched. No new
  # table, FK, or index: onboarding is strictly 1:1 with a team and read only via
  # the already-loaded current_team (point lookup by PK).
  def change do
    alter table(:teams) do
      add :onboarding_state, :map, null: false, default: %{}
      add :onboarding_completed_at, :utc_datetime_usec
    end
  end
end
