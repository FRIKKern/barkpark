defmodule BarkparkCloud.Repo.Migrations.AddRefreshedAtToWarmServers do
  use Ecto.Migration

  # snapshot-management: the self-refresh loop tracks when each pool box's
  # checkout was last brought to origin/main, so it can refresh the STALEST box
  # first and skip a box refreshed within the min-interval. Null = never
  # refreshed since it entered the pool (the stalest). Indexed for the
  # "stalest ready box" claim ordering (nulls first).
  def change do
    alter table(:warm_servers) do
      add :refreshed_at, :utc_datetime_usec
    end

    create index(:warm_servers, [:status, :refreshed_at])
  end
end
