defmodule Barkpark.Repo.Migrations.AddRequireGroupMatchToOidcConnections do
  use Ecto.Migration

  # With `require_group_match` on, a sign-in whose groups match no mapping is
  # refused, and the user's seats the connection gave are removed. Off by
  # default.
  def change do
    alter table(:oidc_connections) do
      add :require_group_match, :boolean, null: false, default: false
    end
  end
end
