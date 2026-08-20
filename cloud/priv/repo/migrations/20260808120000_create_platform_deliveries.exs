defmodule BarkparkCloud.Repo.Migrations.CreatePlatformDeliveries do
  use Ecto.Migration

  # deploy-reliability W23 (charter D385) — THE PLATFORM'S OWN PAST.
  #
  # Twenty-two waves taught this control plane to answer what is true NOW; every
  # one of those answers is recomputed from a live query and forgotten. Nothing
  # here has ever remembered a single delivery: which sha reached the fleet, on
  # whose run, how long it waited, when it started serving. This table is that
  # memory — one row per (sha, delivering run, first sighting).
  #
  # ## Why it is NOT a row in `deployments`
  #
  # `deployments.site_id` is NOT NULL with an FK to `sites`, and Barkpark's own
  # platform deploys have no site row at all — there is no `sites` record for the
  # control plane itself. That is the decisive argument, stronger than the
  # missing columns: a platform delivery cannot be represented in that table
  # without either inventing a fake site or dropping the FK that keeps site
  # deployments honest.
  #
  # ## Why the key is (sha, delivering_run_id, first_seen_at) and not (sha, first_seen_at)
  #
  # Measured this wave: 179 of 180 non-success deploy runs carry ZERO jobs, so
  # ~36% of merged shas have no run of their own — they are CARRIED by a later
  # sha's run. Those commits are exactly the population a `(sha, first_seen_at)`
  # key collapses: two different runs delivering the same carried sha at the same
  # first sighting would fold into one row, and the record would under-count the
  # very deliveries that are hardest to see. The run id is part of the identity.
  #
  # ## Expand-safe only
  #
  # `deploy/cp-deploy.sh` does NOT run migrations; the Docker CMD does — when the
  # IDLE slot boots WHILE THE OLD SLOT STILL SERVES (cloud/Dockerfile:82). So a
  # migration in this repo runs against a schema the currently-serving release is
  # still reading. A brand-new additive table is legal precisely because the old
  # slot never touches it. Never add a NOT NULL column without a default to an
  # existing table here.
  def change do
    create table(:platform_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # WHAT was delivered.
      add :sha, :string, null: false

      # WHOSE run delivered it. Text, not an integer: a GitHub run id is numeric
      # today, and a future deliverer (a manual cp-deploy, a rerun harness) must
      # be able to name itself without a schema change.
      add :delivering_run_id, :string, null: false

      # WHEN the recorder first saw this sha on this run. Part of the identity,
      # so it is never rewritten — a later sighting is a later row.
      add :first_seen_at, :utc_datetime_usec, null: false

      # The merge instant, when the recorder knows it. NULL is honest: a sha
      # delivered outside a merge (a manual deploy) has no merge to point at.
      add :merged_at, :utc_datetime_usec

      # Latency, in whole seconds, as measured by the recorder. Both NULLABLE —
      # a run that never reported a duration must read as unknown, never as 0.
      add :queued_seconds, :integer
      add :build_seconds, :integer

      # When this sha started SERVING (the slot flip). NULL until proven.
      add :serving_since, :utc_datetime_usec

      # Which leg delivered it: "cp" (the control plane) or "instance".
      add :target, :string, null: false, default: "cp"

      # True when this sha rode another sha's run rather than having one of its
      # own — the ~36% population that has been invisible for 22 waves.
      add :carried, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # THE KEY. The writer upserts on exactly this triple with ON CONFLICT DO
    # NOTHING, so a re-run of a deploy job re-posts its batch and writes nothing.
    create unique_index(:platform_deliveries, [:sha, :delivering_run_id, :first_seen_at],
             name: :platform_deliveries_sha_run_seen_index
           )

    # The read: "what happened to THIS sha", newest sighting first.
    create index(:platform_deliveries, [:sha, :first_seen_at])

    # The bare list (a pinned window) and the retention prune both walk time.
    create index(:platform_deliveries, [:inserted_at])
  end
end
