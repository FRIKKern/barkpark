defmodule Barkpark.Repo.Migrations.AddIdpMfaToOidcAndSessions do
  use Ecto.Migration

  # An OIDC connection may trust the IdP's own MFA (`amr` contains "mfa", or
  # `acr` equals `mfa_acr`). Off by default. A session minted that way carries
  # `idp_mfa`, which the org require-MFA gates accept in place of a Barkpark
  # factor.
  def change do
    alter table(:oidc_connections) do
      add :trust_idp_mfa, :boolean, null: false, default: false
      add :mfa_acr, :string
    end

    alter table(:user_sessions) do
      add :idp_mfa, :boolean, null: false, default: false
    end
  end
end
