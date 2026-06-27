defmodule BarkparkCloud.Repo.Migrations.CreateProvisionJobs do
  use Ecto.Migration

  # The queue that bridges the Elixir control plane and the Go warm-pool
  # provisioner. Go-live pays + registers a Barkpark row in a provisioning
  # state, then enqueues a pending job here. The off-box Go worker
  # (cmd/barkpark-provisioner) claims the oldest pending job, runs
  # WarmPool.Provision, and reports success (→ the Barkpark flips to up with its
  # IP) or failure (→ the Barkpark stays provisioning). NO Oban (YAGNI): a plain
  # table + a CAS claim query. One job belongs to one Barkpark.
  def change do
    create table(:provision_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :barkpark_id, references(:barkparks, type: :binary_id, on_delete: :delete_all),
        null: false

      # pending → claimed → succeeded | failed. Default pending; a claim CAS-es
      # the oldest pending to claimed, stamping claim_token + claimed_at.
      add :status, :string, null: false, default: "pending"

      # The worker's per-claim token, stamped on claim so a job can be traced to
      # the worker that holds it. Null until claimed.
      add :claim_token, :string
      add :claimed_at, :utc_datetime_usec

      # The provisioned host IP, stamped on success (and mirrored to the
      # Barkpark's host via upsert_health). Null until succeeded.
      add :result_ip, :string

      # The failure reason, stamped on fail. Null unless failed.
      add :error, :string

      timestamps(type: :utc_datetime_usec)
    end

    # The claim query selects the oldest pending job — index status so that scan
    # (status = 'pending' ORDER BY inserted_at) stays cheap.
    create index(:provision_jobs, [:status])
    create index(:provision_jobs, [:barkpark_id])
  end
end
