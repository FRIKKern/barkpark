defmodule BarkparkCloud.Repo.Migrations.CreateDeviceAuthRequests do
  use Ecto.Migration

  # Device-authorization (bp-login-ux) request ledger — the RFC-8628-shaped
  # handshake behind Claude-Code-style `bp login`. The CLI POSTs
  # /v1/auth/device/start and gets back TWO secrets: a `device_code` it polls
  # with, and a short `user_code` (shown `XXXX-XXXX`) the human approves in the
  # browser. Only the SHA-256 hex HASH of each is stored — never the plaintext —
  # the same hash-at-rest discipline as `user_tokens` / `oauth_states`.
  #
  # Lifecycle: a row is inserted `pending` at start; approve stamps `user_id`
  # and flips it to `approved` (a CAS on `status`, so a second approve no-ops);
  # a successful poll CONSUMES the row (a single DELETE, count==1) and only then
  # mints the real session — so no session plaintext is ever at rest and a
  # replayed poll finds nothing. `expires_at` is enforced in-band by every query
  # (TTL 600s) and swept by the per-minute `DeviceAuthReaper`; the sweep index
  # backs it.
  def change do
    create table(:device_auth_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The two hashed secrets. device_code is the CLI's polling credential;
      # user_code is the short human-typed approval code (hash of its canonical,
      # dash-stripped, upper-cased form).
      add :device_code_hash, :string, null: false
      add :user_code_hash, :string, null: false

      # Captured off the CLI's request at start, so the minted session — and the
      # approve screen — describe the bp machine, not the approving browser.
      add :client_name, :string
      add :ip_address, :string
      add :user_agent, :text

      # pending → approved (approve) → consumed-by-delete (poll). Denied rows are
      # deleted outright.
      add :status, :string, null: false, default: "pending"

      # Stamped by approve; the session-mint target at poll time. delete_all when
      # the user is removed so a stale request can't mint for a dead account.
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)

      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Both secrets are looked up by hash; unique backs the verify-by-hash lookup
    # and backstops a (vanishingly unlikely) CSPRNG collision.
    create unique_index(:device_auth_requests, [:device_code_hash])
    create unique_index(:device_auth_requests, [:user_code_hash])

    # Sweep index: reap expired, never-completed requests.
    create index(:device_auth_requests, [:expires_at])
  end
end
