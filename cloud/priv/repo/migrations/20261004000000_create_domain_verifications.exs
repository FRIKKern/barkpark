defmodule BarkparkCloud.Repo.Migrations.CreateDomainVerifications do
  @moduledoc """
  Owner ruling #29 (2026-10-03, "DNS TXT check"): a team proves it controls a
  domain before a site may claim it, by publishing
  `_barkpark-verify.<domain> TXT "barkpark-verify=<token>"`.

  ADDITIVE ONLY: one new table. Existing site domains are not touched — they
  keep serving, and re-adding a domain a site already holds stays idempotent.
  """
  use Ecto.Migration

  def change do
    create table(:domain_verifications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false
      add :domain, :string, null: false
      add :token, :string, null: false
      add :verified_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:domain_verifications, [:team_id, :domain])
  end
end
