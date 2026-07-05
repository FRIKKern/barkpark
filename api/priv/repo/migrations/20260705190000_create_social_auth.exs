defmodule Barkpark.Repo.Migrations.CreateSocialAuth do
  @moduledoc """
  era-w2-social-oauth — social login (Google / GitHub / Microsoft).

  `social_providers` holds the app-level OAuth client credentials per provider
  (`client_secret` encrypted at rest). `social_identities` links a Barkpark User
  to a `(provider, external_id)` so re-login matches the same account and a
  social login never silently creates a duplicate of an existing email account.
  """
  use Ecto.Migration

  def change do
    create table(:social_providers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :client_id, :string, null: false
      add :client_secret, :binary
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:social_providers, [:provider])

    create table(:social_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :external_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:social_identities, [:provider, :external_id],
             name: :social_identities_provider_external_idx
           )

    create index(:social_identities, [:user_id])
  end
end
