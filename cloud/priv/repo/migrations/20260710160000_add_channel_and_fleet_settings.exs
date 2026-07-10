defmodule BarkparkCloud.Repo.Migrations.AddChannelAndFleetSettings do
  use Ecto.Migration

  # isu-w5.2 — canary-gated fleet rollout.
  #
  # (1) `barkparks.channel` — the rollout CHANNEL each managed instance rides.
  #     "prod" (the fleet default) or "staging" (the canary boxes the rollout
  #     worker advances FIRST, then health-gates prod behind). NOT NULL default
  #     "prod" so every existing row is a prod box — the fleet is unchanged until
  #     an operator deliberately marks a canary. Written through the narrow
  #     `autoupdate_changeset/2` (the same team-facing policy setter), validated
  #     to exactly prod|staging.
  #
  # (2) `fleet_settings` — a single-row table holding fleet-WIDE operator state.
  #     Today: `autoupdate_halted`, the kill switch a platform operator flips to
  #     stop the rollout worker from ADVANCING (settle bookkeeping continues so
  #     in-flight boxes still resolve). Single-row by convention — the registry
  #     reads-or-defaults and upserts the one row.
  def change do
    alter table(:barkparks) do
      add :channel, :string, null: false, default: "prod"
    end

    # The staging gate scans staging-channel rows every tick; keep that cheap as
    # the fleet grows.
    create index(:barkparks, [:channel], name: :barkparks_channel_idx)

    create table(:fleet_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :autoupdate_halted, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end
