defmodule Barkpark.Repo.Migrations.CreateLoginTickets do
  use Ecto.Migration

  # Single-use, short-TTL login handoff tickets (dwb-7 "Studio one-click entry").
  # A ticket is minted from a valid api_token and consumed once by
  # `GET /login/ticket/:ticket`, which drops the bound raw api_token into the
  # browser session (exactly like POST /login). We store only the SHA-256 hash
  # of the opaque ticket (same hygiene as api_tokens), and the raw api_token
  # encrypted-at-rest via Cloak (`Barkpark.EncryptedBinary`) for its 60s life.
  def change do
    create table(:login_tickets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # SHA-256 of the opaque ticket string — never the raw ticket.
      add :ticket_hash, :string, null: false
      # The bound raw api_token, Cloak-encrypted (ciphertext) at rest. Decrypted
      # only on a winning single-use consume, then the row is spent (used_at set).
      add :api_token, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      # nil until consumed. The atomic `UPDATE ... WHERE used_at IS NULL` is the
      # single-use race guard: exactly one concurrent consume can flip it.
      add :used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:login_tickets, [:ticket_hash])
    # Sweep support: prune expired/spent rows on a schedule (best-effort GC).
    create index(:login_tickets, [:expires_at])
  end
end
