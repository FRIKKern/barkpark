defmodule BarkparkCloud.Repo.Migrations.CreateSites do
  use Ecto.Migration

  # A hosted Next.js (or any nixpacks-buildable) website running co-located with
  # a Barkpark instance. Belongs to a Barkpark (the box it runs on) and through
  # it to a Team. (team_id, slug) is unique per team — two teams may both have a
  # site called "shop". `domains` is an array because one site can answer on the
  # apex + www + a custom domain. `env_encrypted` is Vault-encrypted JSON; the
  # plaintext is never persisted. `current_deployment_id` is the live image
  # pointer — null until the first deployment goes live.
  def change do
    create table(:sites, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :barkpark_id, references(:barkparks, type: :binary_id, on_delete: :delete_all),
        null: false

      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false

      add :name, :string, null: false
      add :slug, :string, null: false
      add :framework, :string, null: false, default: "nextjs"
      add :domains, {:array, :string}, null: false, default: []
      add :env_encrypted, :binary
      add :scale_mode, :string, null: false, default: "always_on"
      add :port, :integer
      add :current_deployment_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sites, [:barkpark_id])
    create index(:sites, [:team_id])
    create unique_index(:sites, [:team_id, :slug], name: :sites_team_slug_unique_idx)
    # Cheap O(1) "is this domain registered?" for the on-demand TLS ask-gate.
    create index(:sites, [:domains], using: :gin)
  end
end
