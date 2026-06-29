defmodule Barkpark.Accounts.UserSession do
  @moduledoc """
  A login session bearer for a `User`. Hash-at-rest: only `token_hash`
  (SHA-256, lowercase hex) is stored; the plaintext is returned once at mint and
  is unrecoverable. `revoked_at` is the kill switch (logout / sign-out-everywhere);
  `expires_at` bounds lifetime. Mirrors `cloud/`'s `Accounts.UserToken` session
  context and the core `Barkpark.Auth.ApiToken` hashing scheme.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @default_validity_days 30

  # Idle-timeout window (seconds). `nil` ⇒ idle-logout DISABLED — the default.
  # Enabling it is intentionally NOT enough to log anyone out: the predicates
  # below are PURE and are NOT wired into `Accounts.verify_user_session_token/1`,
  # whose absolute-only check stays intact (wiring idle-logout in would evict
  # currently-valid sessions — a behaviour regression). See
  # docs/auth-user-sessions.md.
  @idle_timeout_seconds nil

  schema "user_sessions" do
    field :token_hash, :string
    field :context, :string, default: "session"
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :ip_address, :string
    field :user_agent, :string

    belongs_to :user, Barkpark.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Default session validity, in days."
  def default_validity_days, do: @default_validity_days

  @doc """
  Idle-timeout window in seconds, or `nil` when idle-logout is disabled
  (the default). Read through this accessor — never the attribute — so
  callers branch on a runtime value.
  """
  @spec idle_timeout_seconds() :: pos_integer() | nil
  def idle_timeout_seconds, do: @idle_timeout_seconds

  @doc """
  True when the session's absolute `expires_at` has passed. A `nil`
  `expires_at` (unbounded session) is never expired.
  """
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(session, now \\ DateTime.utc_now())
  def expired?(%__MODULE__{expires_at: nil}, _now), do: false
  def expired?(%__MODULE__{expires_at: exp}, now), do: DateTime.compare(now, exp) != :lt

  @doc """
  True when idle-logout is enabled (`idle_timeout_seconds/0` non-nil) AND the
  session has been idle past that window (measured from `last_used_at`).
  Always `false` while the window is disabled. PURE predicate — not enforced on
  the verify path; see the module note.
  """
  @spec idle_expired?(t(), DateTime.t()) :: boolean()
  def idle_expired?(session, now \\ DateTime.utc_now())

  def idle_expired?(%__MODULE__{last_used_at: last}, now) do
    case idle_timeout_seconds() do
      nil ->
        false

      window ->
        base = last || now
        DateTime.compare(now, DateTime.add(base, window, :second)) != :lt
    end
  end

  @doc """
  True when the session is usable: not revoked, not absolutely expired, and
  not idle-expired. The single predicate a future hardened verify path would
  call; today's verify path enforces only `revoked_at` + absolute `expires_at`.
  """
  @spec active?(t(), DateTime.t()) :: boolean()
  def active?(session, now \\ DateTime.utc_now())

  def active?(%__MODULE__{revoked_at: r} = s, now) do
    is_nil(r) and not expired?(s, now) and not idle_expired?(s, now)
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :token_hash,
      :context,
      :expires_at,
      :revoked_at,
      :last_used_at,
      :ip_address,
      :user_agent,
      :user_id
    ])
    |> validate_required([:token_hash, :user_id])
    |> assoc_constraint(:user)
    |> unique_constraint(:token_hash)
  end

  @doc "Hash a raw token for storage / lookup (SHA-256, lowercase hex)."
  @spec hash_token(binary()) :: String.t()
  def hash_token(raw) when is_binary(raw) do
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end
end
