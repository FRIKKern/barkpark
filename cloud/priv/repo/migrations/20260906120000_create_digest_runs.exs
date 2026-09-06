defmodule BarkparkCloud.Repo.Migrations.CreateDigestRuns do
  use Ecto.Migration

  # dr-w27 — A SINK THE DEPLOY CANNOT DELETE.
  #
  # dr-w18-s3 gave the fleet digest a counted loss so it could not succeed at
  # sending nothing unobserved. It wrote that count to ONE PLACE: a `Logger`
  # line. On 2026-08-09 the digest really did deliver at 06:00Z (four
  # `notification_deliveries` rows) and the grep that was supposed to prove it
  # returned zero lines — over every container on the host — because the control
  # plane is a docker `json-file` container and `deploy/cp-deploy.sh`'s
  # `compose_up_repair` recreated it at 07:31/07:33. Per-container json-file
  # state lives under /var/lib/docker/containers/<id>/ and is deleted with the
  # container. The accounting record for that day is simply gone.
  #
  # ## Why not an existing table
  #
  #   * `notification_deliveries` — `Delivery.changeset/2` requires a
  #     `recipient`, and charter D362 forbids inventing one. The ZERO-RECIPIENT
  #     arm is precisely the loss this record exists to preserve, so the one
  #     table that already holds send outcomes structurally cannot hold it. That
  #     is not an oversight in `Delivery`; it is the rule that keeps a row from
  #     claiming a person was involved who was not.
  #   * `audit_events` — `team_id` is NOT NULL with a cascading FK. A fleet
  #     digest RUN is not team-scoped (the zero-recipient arm has no team at
  #     all), and a record that vanishes when a team is deleted is a second
  #     disappearing sink.
  #   * `platform_deliveries` — its identity is (sha, delivering run); it
  #     remembers deploys, not sends.
  #   * an Oban job row — `deliver_fleet_digest/1` is also called OUTSIDE a job
  #     (its own moduledoc says so), and job rows are pruned.
  #
  # ## Expand-safe only
  #
  # `deploy/cp-deploy.sh` does NOT run migrations; the Docker CMD does, when the
  # IDLE slot boots while the old slot still serves. A brand-new additive table
  # is legal precisely because the old slot never touches it.
  def change do
    create table(:digest_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # WHICH digest. One member today ("fleet_digest"); a second digest gets a
      # word rather than a second table.
      add :event, :string, null: false

      # The accounting phase — `:settled` today, matching the telemetry event
      # and the log line. A future `:started` record is a value, not a column.
      add :phase, :string, null: false

      # THE MEASUREMENTS, one column each, so they are queryable rather than
      # greppable. These are the same four numbers the log line carries.
      add :recipients, :integer, null: false
      add :sent, :integer, null: false
      add :instances, :integer, null: false
      add :covered, :integer, null: false

      # NULLABLE, and the NULL is meaningful: no reason means the run lost
      # nobody. A blank string would be indistinguishable from a reason nobody
      # wrote down.
      add :reason, :string

      # `Withhold.record/4`'s returned count. NULLABLE for the same reason the
      # log line omits the key entirely on branches that never funnel through
      # the withhold vocabulary — absence is not a zero.
      add :withheld, :integer

      # No `updated_at`. That stops Ecto from writing an update column; it is
      # NOT database-enforced immutability (`audit_events` has a trigger for
      # that). The honest statement is narrower: nothing writes one of these
      # rows twice, because the schema below carries an insert changeset and no
      # update path.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:digest_runs, [:event, :inserted_at])
  end
end
