defmodule Barkpark.Repo.Migrations.AddSamlSlo do
  use Ecto.Migration

  # Single Logout (SLO) + IdP-initiated SAML support.
  #
  # saml_connections.idp_slo_url — the IdP's logout endpoint (nullable: SLO is
  # optional; without it, Barkpark logout stays local-only).
  #
  # user_sessions.saml_* — the SAML context a session was born from, so logout
  # can send an SP-initiated LogoutRequest and an IdP's LogoutRequest can find
  # (and revoke) exactly the sessions it names. NULL for non-SAML sessions.
  def change do
    alter table(:saml_connections) do
      add :idp_slo_url, :string
    end

    alter table(:user_sessions) do
      add :saml_name_id, :string
      add :saml_session_index, :string
      add :saml_org_slug, :string
    end

    create index(:user_sessions, [:saml_name_id])
  end
end
