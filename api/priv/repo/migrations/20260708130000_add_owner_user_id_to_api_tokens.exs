defmodule Barkpark.Repo.Migrations.AddOwnerUserIdToApiTokens do
  use Ecto.Migration

  # Give an api_token an optional USER identity: a nullable FK to the owner
  # user. This is PURELY ADDITIVE — existing rows stay NULL and continue to
  # authenticate byte-identically (Auth.verify_token's WHERE clause is
  # untouched; the column is not read on the token-lookup path). Only the
  # grantee CLAIM/MINE surface resolves an owned token → its %User{}
  # (ResolveTokenOwner). NO backfill: an un-owned token remains un-owned.
  #
  # on_delete: :nilify_all — deleting a user severs the identity link but
  # leaves the token (it simply reverts to un-owned), never cascading a
  # token deletion off a user removal.
  def change do
    alter table(:api_tokens) do
      add :owner_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:api_tokens, [:owner_user_id])
  end
end
