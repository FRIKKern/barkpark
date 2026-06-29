defmodule Barkpark.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  # Core user accounts (Phase 1 of core auth). Barkpark core historically had NO
  # user/password concept — only API tokens. This adds first-class human
  # principals so the product (and Cloud-on-Barkpark) can offer real login.
  #
  # ADDITIVE + opt-in: nothing reads this table until a login route is hit; the
  # token-only world is unchanged. Mirrors cloud/'s Accounts.User discipline —
  # password is hashed (argon2id), never stored plaintext; the TOTP secret is
  # encrypted at rest (Cloak); recovery codes are stored only as hashes.
  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :hashed_password, :string, null: false
      add :confirmed_at, :utc_datetime_usec
      # TOTP MFA — secret is Cloak-encrypted at rest (Barkpark.EncryptedBinary).
      add :totp_secret, :binary
      add :totp_enabled, :boolean, null: false, default: false
      # One-time recovery codes, stored ONLY as SHA-256 hashes; consumed on use.
      add :recovery_codes_hashed, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])
  end
end
