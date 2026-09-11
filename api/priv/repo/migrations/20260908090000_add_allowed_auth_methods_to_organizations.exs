defmodule Barkpark.Repo.Migrations.AddAllowedAuthMethodsToOrganizations do
  use Ecto.Migration

  # era-bl-allowed-auth-methods: the org-wide "which login doors are open"
  # policy, on top of era-w2-org-require-mfa's shape. NULLABLE and NULL by
  # default — a NULL column imposes no restriction, so with the policy unset
  # everywhere the auth surface is byte-identical to before the feature
  # existed (zero tax). A non-NULL value is the EXHAUSTIVE allow-list of
  # methods this org's members may authenticate with; anything absent from it
  # is refused at the session-mint chokepoint.
  def change do
    alter table(:organizations) do
      add :allowed_auth_methods, {:array, :text}, default: nil, null: true
    end
  end
end
