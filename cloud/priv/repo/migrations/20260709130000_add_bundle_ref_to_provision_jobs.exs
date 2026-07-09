defmodule BarkparkCloud.Repo.Migrations.AddBundleRefToProvisionJobs do
  use Ecto.Migration

  # azh-w6 (S14c) — portable-archive resurrect rides the provision-job machine.
  # A `resurrect`-kind job restores a torn-down instance from an object-storage
  # bundle; `bundle_ref` names that archive and is threaded into the worker's
  # claim payload. NULLABLE by design: every other kind (provision / deprovision
  # / attach_domain) leaves it NULL, and the changeset requires it only when
  # kind == "resurrect" (no DB-level default stamping — D23 nil-honesty). No new
  # index: the existing partial unique
  # `provision_jobs_one_active_per_barkpark_kind_idx` (on barkpark_id + kind,
  # WHERE status IN ('pending','claimed')) already gives resurrect its own
  # one-active-job slot for free.
  def change do
    alter table(:provision_jobs) do
      add :bundle_ref, :string
    end
  end
end
