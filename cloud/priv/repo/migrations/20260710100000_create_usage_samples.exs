defmodule BarkparkCloud.Repo.Migrations.CreateUsageSamples do
  use Ecto.Migration

  # cloud-console wave 3 — cached fleet usage snapshots. The usage-sampler worker
  # writes ONE row per checkable instance every ~15 min (crontab 7,22,37,52), and
  # `GET /v1/usage/summary` answers the Overview fleet meter strip from the LATEST
  # row per instance — a pure DB read, so the ~15s live `/usage` fan-out never
  # blocks the fleet view. `envelope` is the full `Usage.compose/1` output
  # (`{meters: {…}}`) stored verbatim as jsonb; it never carries an admin token.
  # `measured_at` is the real wall-clock sample time (always set, even for a box
  # whose instance-sourced meters degraded to "unmetered"), so the console can
  # honestly stamp "as of Xs ago".
  def change do
    create table(:usage_samples, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Removing an instance drops its samples in the same statement.
      add :barkpark_id,
          references(:barkparks, type: :binary_id, on_delete: :delete_all),
          null: false

      add :envelope, :map, null: false
      add :measured_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Backs BOTH the latest-per-instance summary read (ORDER BY measured_at DESC
    # LIMIT 1 within a barkpark_id) and the retention prune (measured_at < cutoff).
    create index(:usage_samples, [:barkpark_id, :measured_at])
  end
end
