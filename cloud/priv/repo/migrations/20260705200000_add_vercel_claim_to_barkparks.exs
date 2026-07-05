defmodule BarkparkCloud.Repo.Migrations.AddVercelClaimToBarkparks do
  use Ecto.Migration

  # Zero-paste Vercel handoff (task-4e4a53b101a97051): the platform-deployed
  # project the user claims via vercel.com/claim-deployment. The claim code is
  # stored ENCRYPTED (Registry.Vault — it grants project ownership), hence text.
  def change do
    alter table(:barkparks) do
      add :vercel_project_id, :string
      add :vercel_deploy_url, :string
      add :vercel_claim_encrypted, :text
      add :vercel_claim_minted_at, :utc_datetime_usec
    end
  end
end
