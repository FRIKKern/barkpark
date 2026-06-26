defmodule BarkparkCloud.Repo.Migrations.CreateTeamMemberships do
  use Ecto.Migration

  # Binds a User to a Team with a role (owner/admin/member) — the control-plane
  # mirror of api/'s Tenancy.Membership. Unlike api/ (whose principal is an API
  # TOKEN, hence the principal_type/principal_id pair), the Cloud principal is
  # always a real User, so the binding is a plain user_id FK. The composite
  # UNIQUE (user_id, team_id) enforces "a user is in a team at most once".
  def change do
    create table(:team_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false

      add :role, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:team_memberships, [:team_id])

    create unique_index(:team_memberships, [:user_id, :team_id],
             name: :team_memberships_user_team_unique_idx
           )
  end
end
