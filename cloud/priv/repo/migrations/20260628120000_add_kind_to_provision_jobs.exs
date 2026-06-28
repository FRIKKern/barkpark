defmodule BarkparkCloud.Repo.Migrations.AddKindToProvisionJobs do
  use Ecto.Migration

  # User-initiated DEPROVISION reuses the existing provision_jobs queue rather than
  # a parallel table — same claim/stale-recovery/attempts machinery, one worker
  # transport. `kind` discriminates the two:
  #
  #   * "provision"   — the go-live path: stand a box up, report its IP.
  #   * "deprovision" — the Remove path: tear the box + DNS down, then the control
  #     plane deletes the barkpark row.
  #
  # Default "provision" + NOT NULL so every existing row (all provisions) is
  # correctly classified with no backfill, and the claim filters split the two
  # kinds so the provision worker never grabs a deprovision job (and vice versa).
  #
  # Reversible: the down side drops the column.
  def change do
    alter table(:provision_jobs) do
      add :kind, :string, null: false, default: "provision"
    end

    # The deprovision claim queries `WHERE kind = 'deprovision' AND status =
    # 'pending'` (mirroring the provision claim's status filter); index the
    # discriminator so each kind's claim scans only its own rows.
    create index(:provision_jobs, [:kind])
  end
end
