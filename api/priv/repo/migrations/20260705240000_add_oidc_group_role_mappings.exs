defmodule Barkpark.Repo.Migrations.AddOidcGroupRoleMappings do
  use Ecto.Migration

  # OIDC group-claims → role mapping (era-w7): orgs that skip SCIM and ship
  # group membership in the id_token get roles mapped at login time.
  # `groups_claim` names the claim to read; `group_role_mappings` is the
  # admin-configured group→role map — claims can only SELECT among these,
  # never name a role directly.
  def change do
    alter table(:oidc_connections) do
      add :groups_claim, :string, null: false, default: "groups"
      add :group_role_mappings, :map, null: false, default: %{}
    end
  end
end
