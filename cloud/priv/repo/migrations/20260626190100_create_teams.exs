defmodule BarkparkCloud.Repo.Migrations.CreateTeams do
  use Ecto.Migration

  # A Team is the control-plane analogue of api/'s Workspace — the boundary a
  # set of Barkpark instances + members belong to. Slug is unique across all
  # teams and validated against the same slug_format / reserved-slug rules the
  # api/ Workspace uses (mirrored in BarkparkCloud.Accounts.Team).
  def change do
    create table(:teams, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:teams, [:slug])
  end
end
