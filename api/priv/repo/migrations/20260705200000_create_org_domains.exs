defmodule Barkpark.Repo.Migrations.CreateOrgDomains do
  @moduledoc """
  era-w3-jit-domain — a verified email domain claimed by an Organization. Once a
  domain's DNS TXT record proves ownership (`verified_at` set), logins on that
  domain auto-route to the org's SSO. Domain is globally unique (one org owns it).
  """
  use Ecto.Migration

  def change do
    create table(:org_domains, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :domain, :string, null: false
      add :dns_token, :string, null: false
      add :verified_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:org_domains, [:domain])
    create index(:org_domains, [:organization_id])
  end
end
