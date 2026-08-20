defmodule BarkparkCloud.Repo.Migrations.AddTriggerToDeploymentsAndContentSecret do
  use Ecto.Migration

  # site-spawner W5 (charter D47/D49): publish-to-live auto-update.
  #
  # deployments gains:
  #   * trigger — provenance of WHY this build ran. "manual" (a human ran
  #     `bp cloud site deploy`, the pre-W5 default — so every existing row
  #     backfills to it) or "content-auto" (a content publish on the bound
  #     dataset fired the per-site webhook receiver). NOT NULL + default "manual"
  #     mirrors the `environment` enum: the wish's "observable — content-triggered,
  #     not manual" bar reads straight off this column, threaded through
  #     deployment_json/1.
  #
  # sites gains:
  #   * content_webhook_secret_encrypted — the per-site HMAC secret the CP mints at
  #     create, registers on the box's dataset webhook, and verifies inbound
  #     content-publish deliveries against. Vault-encrypted at rest exactly like
  #     github_webhook_secret_encrypted (a :binary, mirroring env_encrypted); the
  #     plaintext is never persisted. Per-site because the receiver is per-site
  #     (POST /v1/sites/webhooks/content-publish/:site_id).
  def change do
    alter table(:deployments) do
      add :trigger, :string, null: false, default: "manual"
    end

    alter table(:sites) do
      add :content_webhook_secret_encrypted, :binary
    end
  end
end
