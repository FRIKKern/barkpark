defmodule BarkparkCloud.Repo.Migrations.AddProviderToBarkparks do
  use Ecto.Migration

  # Provider-neutral hosting (charter Decision 9): a managed instance now records
  # WHICH cloud it lives on and the region/size it was launched with, so the
  # provision-job claim can thread {kind, region, server_type} to the Go worker
  # instead of hard-coding Hetzner's nbg1/cax11.
  #
  #   * `provider` is NOT NULL, default "hetzner" — every existing row is Hetzner
  #     by construction (the only provider before this migration), and a new row
  #     without an explicit provider is Hetzner too, so the claim payload for a
  #     legacy/default row stays byte-identical.
  #   * `region` / `server_type` are NULLABLE: the control plane still falls back
  #     to the warm-pool defaults (Registry.default_region/0, default_server_type/0)
  #     when a row didn't pin them, so a NULL is not a broken claim.
  def change do
    alter table(:barkparks) do
      add :provider, :string, null: false, default: "hetzner"
      add :region, :string
      add :server_type, :string
    end
  end
end
