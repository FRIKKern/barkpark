defmodule BarkparkCloud.Repo.Migrations.CreateContentPublishes do
  use Ecto.Migration

  # deploy-reliability W11 (charter D162) — the PUBLISH INSTANT.
  #
  # Every latency this epic has ever published starts at a deployment row's
  # `inserted_at`, i.e. when the control plane ENQUEUED an attempt — never when a
  # human pressed publish. That clock can never be honest: AutoDeployWorker
  # debounces by 60s (D44), so `inserted_at` is structurally ≥60s late, and
  # Deploy.enqueue/6's conflict recovery mints NO ROW AT ALL for a publish that
  # coalesces onto an in-flight build (measured: 26-35% of paper publishes).
  # Those publishes are absent from the numerator AND the denominator of every
  # instrument this epic has built.
  #
  # This table is the t0 the fleet has never had: one row per HMAC-VERIFIED
  # content-publish delivery, stamped at the instant the receiver verified it.
  # It is APPEND-ONLY — rows are never deleted and `received_at` never moves
  # (the receiver stamps `enqueued` onto its own row in the same request, and
  # nothing writes the row again after that).
  #
  # Indexed by (site_id, received_at) — every query this serves is "the publishes
  # for THIS site over THIS window", joined forward to deployments to find the
  # ones that never minted a row.
  def change do
    create table(:content_publishes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :site_id, references(:sites, type: :binary_id, on_delete: :delete_all), null: false

      # The clock. Stamped by the receiver the moment the signature verified —
      # the closest the control plane can get to the human's publish.
      add :received_at, :utc_datetime_usec, null: false

      # Echoed from the delivery payload's `type` when it carries one; NULL when
      # it does not. Never invented — an unknown doc type must read as unknown.
      add :doc_type, :string

      # Which receiver recorded this. One value today; a column so a future
      # publish path (a manual trigger, a backfill) is distinguishable rather
      # than silently folded into the webhook population.
      add :source, :string, null: false, default: "content-webhook"

      # Did AutoDeployWorker.enqueue actually INSERT a job, or did it coalesce
      # onto one already scheduled? False is the interesting value: it is a
      # publish whose rebuild someone else's publish owns.
      add :enqueued, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:content_publishes, [:site_id, :received_at])
  end
end
