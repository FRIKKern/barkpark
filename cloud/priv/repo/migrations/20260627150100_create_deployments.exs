defmodule BarkparkCloud.Repo.Migrations.CreateDeployments do
  use Ecto.Migration

  # One build-and-release of a Site. The Deployment row IS the build job — the
  # off-box builder (P2) atomically claims rows where status='queued' and walks
  # them through queued → building → pushing → live (or failed). status indexed
  # because the builder's queue read is the hot path; (site_id, inserted_at)
  # indexed for the deployment-history view. claim_worker / claimed_at /
  # claim_epoch are the fencing fields — same shape as the bp task substrate
  # (CAS on epoch in close, sweep on expired claims).
  def change do
    create table(:deployments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :site_id, references(:sites, type: :binary_id, on_delete: :delete_all), null: false

      add :status, :string, null: false, default: "queued"
      add :git_ref, :string
      add :artifact_url, :string
      add :image_tag, :string
      add :build_log_url, :string
      add :failure_reason, :text

      add :claim_worker, :string
      add :claimed_at, :utc_datetime_usec
      add :claim_epoch, :integer, null: false, default: 0

      add :became_live_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:deployments, [:site_id, :inserted_at])
    # Builder queue read — small, hot, index-driven.
    create index(:deployments, [:status, :inserted_at])
  end
end
