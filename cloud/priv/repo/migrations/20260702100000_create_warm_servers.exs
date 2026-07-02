defmodule BarkparkCloud.Repo.Migrations.CreateWarmServers do
  use Ecto.Migration

  # The warm pool (dwb-10): pre-baked Barkpark-ready boxes the Go worker creates
  # ahead of time so a go-live ASSIGNS an already-booted host (≤15s to live)
  # instead of waiting on a cold `hcloud server create`. This table is the
  # ATOMIC CLAIM STORE — a claim is a FOR UPDATE SKIP LOCKED row flip, the same
  # race-safe primitive provision_jobs uses, because Hetzner label updates are
  # not CAS and two workers must never both win the same box (the old fixed-name
  # `warm-1` collision). NO Oban, no attempts budget (a warm box is fungible):
  # a plain table + a SKIP LOCKED claim.
  #
  # Reversible: `change` drops the table (and its indexes) on rollback.
  def change do
    create table(:warm_servers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The Hetzner box name: a unique warm-<rand>. Unique so re-registering the
      # same box is idempotent instead of inserting a duplicate pool row.
      add :name, :string, null: false
      add :ip, :string

      # ready → claimed (assign) | retiring (reconcile shrink). Default ready; a
      # claim CAS-es one ready row to claimed/retiring via SKIP LOCKED.
      add :status, :string, null: false, default: "ready"

      # The claimer's per-claim token + when it was claimed, stamped on claim so a
      # stale (crashed-mid-consume) row can be reaped past a threshold.
      add :claim_token, :string
      add :claimed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # A re-register of the same box must not duplicate the pool row.
    create unique_index(:warm_servers, [:name])
    # The claim query selects the oldest ready row — index status so that scan
    # (status = 'ready' ORDER BY inserted_at) stays cheap.
    create index(:warm_servers, [:status])
  end
end
