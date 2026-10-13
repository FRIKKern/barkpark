defmodule Barkpark.Auth.TokenSession do
  @moduledoc """
  A revocable browser session bound to an `ApiToken` (ruling #16 rework half,
  task-57f23825b18ab55d). A token sign-in (`POST /login`, or a consumed login
  ticket) mints one of these and the cookie carries only its opaque session
  id — never the raw api_token. Hash-at-rest for the session id itself
  (`session_hash`, SHA-256, mirrors `ApiToken.hash_token/1` /
  `Accounts.UserSession.hash_token/1`); the raw bearer the client still needs
  for a Web Component `data-token=` attribute is held Cloak-encrypted at rest
  (`Barkpark.EncryptedBinary`), the same scheme `Barkpark.Auth.LoginTicket`
  uses for the same reason.

  Logout DELETES the row (see the creating migration's note) rather than only
  flagging `revoked_at` — a live row is a live, decryptable credential. The
  flag is kept as a second, idempotent kill switch for revocation paths that
  don't want a hard delete (e.g. a future cascade off `Auth.revoke_token/1`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "token_sessions" do
    field :session_hash, :string
    field :raw_token, Barkpark.EncryptedBinary
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec

    belongs_to :api_token, Barkpark.Auth.ApiToken

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :session_hash,
      :raw_token,
      :expires_at,
      :revoked_at,
      :last_used_at,
      :api_token_id
    ])
    |> validate_required([:session_hash, :raw_token, :api_token_id])
    |> assoc_constraint(:api_token)
    |> unique_constraint(:session_hash)
  end

  @doc "Hash an opaque session id for storage / lookup (SHA-256, lowercase hex)."
  @spec hash_token(binary()) :: String.t()
  def hash_token(raw) when is_binary(raw) do
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end
end
