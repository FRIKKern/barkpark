defmodule BarkparkCloud.Repo.Migrations.CreateExternalIdentities do
  use Ecto.Migration

  # OAuth/SSO (oauth-sso): the SAFE alternative to Coolify's email-only linking.
  # The durable key is (provider, provider_uid) — the IdP's stable subject id —
  # so a provider asserting a DIFFERENT user's email can never reach that user's
  # account (Coolify's OauthController.php links by User::whereEmail, the footgun
  # this table exists to avoid). `email` is display/audit only. on_delete:
  # :delete_all so closing a User reaps its linked identities (mirrors
  # user_tokens / team_memberships).
  def change do
    create table(:external_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :provider, :string, null: false
      add :provider_uid, :string, null: false
      add :email, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:external_identities, [:user_id])

    # The integrity guard AND the verify-by-identity lookup index: one IdP
    # identity maps to at most one user. A concurrent double-callback that races
    # to link the same (provider, provider_uid) hits this and is mapped back to
    # the now-linked user rather than a 500.
    create unique_index(:external_identities, [:provider, :provider_uid],
             name: :external_identities_provider_uid_unique_idx
           )
  end
end
