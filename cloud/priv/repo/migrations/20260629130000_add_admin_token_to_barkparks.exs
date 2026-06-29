defmodule BarkparkCloud.Repo.Migrations.AddAdminTokenToBarkparks do
  use Ecto.Migration

  # instance-admin-token — store the per-instance admin bearer the warm-pool
  # provisioner mints on the box so the OWNER can retrieve it from the product
  # (API + bp) instead of SSH/rescue-rebooting just to get content access.
  #
  # ENCRYPTED AT REST: the column holds the Base64 of Registry.Vault's AES-256-GCM
  # output (the SAME at-rest encryption connect_provider/providers.encrypted_token
  # uses) — NEVER the plaintext bp_admin_ token. Nullable: the ip-only succeed path
  # (a worker that did not report a token, or a pre-feature row) leaves it nil and
  # keeps working.
  def change do
    alter table(:barkparks) do
      add :admin_token_encrypted, :text
    end
  end
end
