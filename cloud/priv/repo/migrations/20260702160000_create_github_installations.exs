defmodule BarkparkCloud.Repo.Migrations.CreateGithubInstallations do
  use Ecto.Migration

  # A team's connected GitHub App installation (gh-2). ONE per team for v1 — the
  # unique index on team_id enforces it. `installation_id_encrypted` holds
  # CIPHERTEXT ONLY (Base64 of AES-256-GCM via BarkparkCloud.Registry.Vault); the
  # plaintext installation handle never touches the DB (text, since the Base64
  # payload is unbounded by the handle's length). `account_login` is a non-secret
  # display value kept plaintext. The FK cascades on team delete (drop a team,
  # its GitHub link goes with it).
  def change do
    create table(:github_installations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false

      add :installation_id_encrypted, :text, null: false
      add :account_login, :string

      timestamps(type: :utc_datetime_usec)
    end

    # One installation per team (v1). Also the lookup index for the team-scoped
    # read path.
    create unique_index(:github_installations, [:team_id])
  end
end
