defmodule BarkparkCloud.Repo.Migrations.CreateProviders do
  use Ecto.Migration

  # A connected cloud account a Team links so the control plane can provision
  # Barkparks into it (e.g. a Hetzner API token). Belongs to a Team. The
  # `encrypted_token` column holds CIPHERTEXT only — the Base64 of an
  # AES-256-GCM encryption (BarkparkCloud.Registry.Vault); the plaintext token
  # never touches the DB. Real key management is a later/human concern; this
  # migration just gives the ciphertext a home (text, since the Base64 payload
  # is unbounded by token length).
  def change do
    create table(:providers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false

      add :kind, :string, null: false
      add :label, :string
      add :encrypted_token, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:providers, [:team_id])
  end
end
