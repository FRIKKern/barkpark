defmodule Barkpark.Repo.Migrations.AddShareScopeToApiTokens do
  @moduledoc """
  P5 — scoped-share EDIT tokens.

  A share-edit token is a normal `api_tokens` row with an OPAQUE permission
  (`share-edit-docs` / `share-edit-media`) and NO membership row, bound to one
  exact `"workspace/project/dataset"` scope recorded here. `RequireShareEditToken`
  grants a write ONLY when the presented token's `share_scope` byte-matches the
  request scope AND the registry still has that scope `:edit`-shared.

  NULL for every existing/normal token — fully backward-compatible. The btree
  index backs `Auth.revoke_share_tokens/3` (batch revoke on unshare) and the
  admin token-list endpoint.
  """
  use Ecto.Migration

  def change do
    alter table(:api_tokens) do
      add :share_scope, :string
    end

    create index(:api_tokens, [:share_scope])
  end
end
