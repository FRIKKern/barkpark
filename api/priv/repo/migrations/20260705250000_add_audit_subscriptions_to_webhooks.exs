defmodule Barkpark.Repo.Migrations.AddAuditSubscriptionsToWebhooks do
  use Ecto.Migration

  # Auth-event webhooks (era-w7): a webhook with a non-empty `audit_categories`
  # subscribes to AUDIT events (auth/membership/token/…) instead of content
  # mutations. `audit_actions` optionally narrows within the categories (empty =
  # all). `organization_id` scopes an audit subscription to one org's events
  # (nullable = a global subscription, admin-only). Reuses the whole webhooks
  # delivery machine (HMAC, retries, dead-letter, SSRF guard) — no parallel path.
  def change do
    alter table(:webhooks) do
      add :audit_categories, {:array, :string}, null: false, default: []
      add :audit_actions, {:array, :string}, null: false, default: []
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all)
    end

    create index(:webhooks, [:organization_id])
  end
end
