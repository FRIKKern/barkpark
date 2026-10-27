defmodule Barkpark.Repo.Migrations.AddClientSecretExpiryToOidcConnections do
  @moduledoc """
  Expiry warnings for OIDC client secrets
  (`Barkpark.Sso.OidcSecretExpiryWarningWorker`).

  ADDITIVE ONLY: two nullable columns. `client_secret_expires_at` is the date
  the identity provider gave for the stored secret, set by the operator. NULL
  means not recorded, which is every existing row. `client_secret_expiry_warned_days`
  holds the last warning step sent for that date (30, 14 or 7 days ahead).
  """
  use Ecto.Migration

  def change do
    alter table(:oidc_connections) do
      add :client_secret_expires_at, :utc_datetime_usec, null: true
      add :client_secret_expiry_warned_days, :integer, null: true
    end
  end
end
