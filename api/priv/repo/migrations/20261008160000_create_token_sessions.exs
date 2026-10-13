defmodule Barkpark.Repo.Migrations.CreateTokenSessions do
  use Ecto.Migration

  # Ruling #16 rework half (task-57f23825b18ab55d): a browser token sign-in
  # (POST /login, or a consumed login ticket) now mints a revocable session
  # row instead of dropping the raw api_token straight into the cookie. The
  # cookie carries only this row's opaque session id (hashed here, same
  # hygiene as api_tokens/user_sessions); the raw bearer that row needs to
  # hand back to the client (`data-token=` on Web Components) is held
  # Cloak-encrypted at rest (`Barkpark.EncryptedBinary`), mirroring
  # `login_tickets.api_token`. Unlike a login ticket, this row is MULTI-USE
  # (it backs the whole session, not a single 60s handoff) — so logout DELETES
  # the row outright rather than merely flagging `revoked_at`: per the
  # Barkpark.Auth.LoginTicketSweeper retention lesson, a live row is a live,
  # decryptable credential regardless of a flag, so deleting it at logout is
  # what actually stops a copied cookie from working. `revoked_at` is kept
  # anyway as a second, idempotent kill switch (used by a future cascade off
  # `Auth.revoke_token/1`, mirroring `broadcast_socket_teardown/1`'s intent).
  def change do
    create table(:token_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :api_token_id, references(:api_tokens, type: :binary_id, on_delete: :delete_all),
        null: false

      # SHA-256 of the opaque session id the cookie carries — never the
      # plaintext session id, same hygiene as api_tokens.token_hash.
      add :session_hash, :string, null: false
      # The bound raw api_token, Cloak-encrypted (ciphertext) at rest.
      add :raw_token, :binary, null: false
      add :expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:token_sessions, [:session_hash])
    create index(:token_sessions, [:api_token_id])
  end
end
