defmodule BarkparkCloud.Repo.Migrations.CreateOauthStates do
  use Ecto.Migration

  # OAuth/SSO (oauth-sso) CSRF-state SINGLE-USE ledger. The signed HMAC state
  # (BarkparkCloud.OAuth) is tamper-proof and TTL-bound on its own, but a signed
  # token is REPLAYABLE within its TTL — an intercepted callback URL could be
  # driven a second time. This table makes the state single-use: mint_state/1
  # inserts one row per issued state (its random nonce), and verify_state/2
  # CONSUMES it (a single DELETE); a second callback with the same state deletes
  # zero rows and is rejected. expires_at is a hard TTL backstop so a nonce that
  # is never redeemed (the browser abandons the flow) is reaped, not leaked.
  def change do
    create table(:oauth_states, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :nonce, :string, null: false
      add :provider, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # One row per nonce — the insert is the mint, the delete is the single-use
    # consume. The unique index also backstops a (vanishingly unlikely) nonce
    # collision from the 16-byte CSPRNG.
    create unique_index(:oauth_states, [:nonce])

    # Sweep index: reap expired, never-redeemed states.
    create index(:oauth_states, [:expires_at])
  end
end
