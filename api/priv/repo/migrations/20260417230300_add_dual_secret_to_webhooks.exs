defmodule Barkpark.Repo.Migrations.AddDualSecretToWebhooks do
  use Ecto.Migration

  def change do
    alter table(:webhooks) do
      add :previous_secret, :string
      add :previous_secret_expires_at, :utc_datetime_usec
    end
  end
end
