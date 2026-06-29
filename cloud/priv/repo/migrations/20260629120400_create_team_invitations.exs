defmodule BarkparkCloud.Repo.Migrations.CreateTeamInvitations do
  use Ecto.Migration

  # Pending invitations for an email to join a Team at a role (the Cloud
  # adaptation of Coolify's team_invitations table). The accept secret is stored
  # ONLY as token_hash (SHA-256 hex) — the plaintext ships once in the accept URL
  # (mirrors user_tokens). Cascade-delete with the team; nilify the inviter FK so
  # removing the inviter does not erase the invite. The partial UNIQUE
  # (team_id, email) WHERE accepted_at IS NULL enforces "one live invite per email
  # per team" while allowing a fresh invite after a prior one accepted.
  def change do
    create table(:team_invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false
      add :invited_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :email, :string, null: false
      add :role, :string, null: false, default: "member"
      add :token_hash, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :accepted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:team_invitations, [:team_id])
    create unique_index(:team_invitations, [:token_hash])

    create unique_index(:team_invitations, [:team_id, :email],
             where: "accepted_at IS NULL",
             name: :team_invitations_team_email_pending_idx
           )
  end
end
