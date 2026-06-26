defmodule BarkparkCloud.Repo.Migrations.CreateBarkparks do
  use Ecto.Migration

  # The registry row: one per registered Barkpark instance a Team owns — the
  # metadata behind "one dashboard of all your Barkparks", and the row the
  # warm-pool (cloud-6) writes when it hands a fresh server to a Team. Belongs
  # to a Team (the control-plane boundary). slug is unique PER TEAM (not global,
  # unlike the teams.slug index) — two Teams may both have a Barkpark named
  # "prod" — so the unique index is composite over (team_id, slug).
  def change do
    create table(:barkparks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false

      add :name, :string, null: false
      add :slug, :string, null: false
      add :url, :string
      add :host, :string
      add :mode, :string, null: false, default: "managed"
      add :health_status, :string, null: false, default: "unknown"
      add :version, :string
      add :git_commit, :string
      add :agent_status, :string, null: false, default: "offline"
      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:barkparks, [:team_id])

    create unique_index(:barkparks, [:team_id, :slug],
             name: :barkparks_team_slug_unique_idx
           )
  end
end
