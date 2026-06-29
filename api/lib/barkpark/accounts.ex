defmodule Barkpark.Accounts do
  @moduledoc """
  Core user accounts: registration, password login, login sessions, email
  verification + password reset, and TOTP MFA with recovery codes.

  The security invariants live here so HTTP controllers stay thin:

    * passwords are argon2id (`User`); login is constant-time and does a dummy
      verify for unknown emails (no account-existence leak);
    * session + email tokens are random 32-byte secrets stored only as SHA-256
      hashes — the plaintext is returned once and never persisted;
    * a password reset revokes every existing session ("sign out everywhere");
    * TOTP secrets are encrypted at rest; recovery codes are one-time and stored
      only as hashes.

  @canonical capability:user-auth aka:login,register,session,password,mfa,totp,accounts
  """
  import Ecto.Query, warn: false
  alias Barkpark.Repo
  alias Barkpark.Accounts.{User, UserSession, UserEmailToken}

  @rand_bytes 32
  @recovery_code_count 10

  # ── Registration & lookup ──────────────────────────────────────────────────

  @doc "Register a new user. `{:ok, user}` or `{:error, changeset}`."
  @spec register_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc "Changeset for live registration form validation."
  def change_user_registration(attrs \\ %{}),
    do: User.registration_changeset(%User{}, attrs)

  @spec get_user(binary()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email),
    do: Repo.get_by(User, email: String.downcase(email))

  @doc """
  Return the user iff `email` + `password` match. Constant-time: an unknown
  email still runs a dummy argon2 verify so timing cannot distinguish
  "no such user" from "wrong password".
  """
  @spec get_user_by_email_and_password(String.t(), String.t()) :: User.t() | nil
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_email(email)
    if User.valid_password?(user, password), do: user, else: nil
  end

  @doc "Change an existing user's password (verify current first), revoking all sessions."
  @spec update_user_password(User.t(), String.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()} | {:error, :invalid_current}
  def update_user_password(%User{} = user, current_password, attrs) do
    if User.valid_password?(user, current_password) do
      do_reset_password(user, attrs)
    else
      {:error, :invalid_current}
    end
  end

  # ── Sessions ───────────────────────────────────────────────────────────────

  @doc "Mint a session token for `user`. Returns the one-time plaintext bearer."
  @spec create_user_session_token(User.t(), keyword()) ::
          {:ok, binary()} | {:error, Ecto.Changeset.t()}
  def create_user_session_token(%User{} = user, opts \\ []) do
    plaintext = generate_token()
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    expires = DateTime.add(now, UserSession.default_validity_days() * 24 * 3600, :second)

    %UserSession{}
    |> UserSession.changeset(%{
      user_id: user.id,
      token_hash: UserSession.hash_token(plaintext),
      expires_at: expires,
      last_used_at: now,
      ip_address: Keyword.get(opts, :ip_address),
      user_agent: Keyword.get(opts, :user_agent)
    })
    |> Repo.insert()
    |> case do
      {:ok, _} -> {:ok, plaintext}
      {:error, cs} -> {:error, cs}
    end
  end

  @doc "Resolve a session-token plaintext to its `%User{}` or nil (refreshes last_used_at)."
  @spec verify_user_session_token(binary()) :: User.t() | nil
  def verify_user_session_token(plaintext) when is_binary(plaintext) do
    hash = UserSession.hash_token(plaintext)
    now = DateTime.utc_now()

    query =
      from t in UserSession,
        where: t.token_hash == ^hash and is_nil(t.revoked_at),
        where: is_nil(t.expires_at) or t.expires_at > ^now

    case Repo.one(query) do
      %UserSession{user_id: uid} ->
        from(t in UserSession, where: t.token_hash == ^hash)
        |> Repo.update_all(set: [last_used_at: DateTime.truncate(now, :microsecond)])

        Repo.get(User, uid)

      nil ->
        nil
    end
  end

  def verify_user_session_token(_), do: nil

  @doc "Revoke a single session by plaintext (idempotent)."
  @spec revoke_user_session_token(binary()) :: :ok
  def revoke_user_session_token(plaintext) when is_binary(plaintext) do
    hash = UserSession.hash_token(plaintext)
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    from(t in UserSession, where: t.token_hash == ^hash and is_nil(t.revoked_at))
    |> Repo.update_all(set: [revoked_at: now])

    :ok
  end

  @doc "Revoke all of a user's sessions (\"sign out everywhere\")."
  @spec revoke_all_user_sessions(User.t()) :: :ok
  def revoke_all_user_sessions(%User{id: uid}) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    from(t in UserSession, where: t.user_id == ^uid and is_nil(t.revoked_at))
    |> Repo.update_all(set: [revoked_at: now])

    :ok
  end

  # ── Email tokens: verify-email + password-reset ────────────────────────────

  @doc """
  Build a single-use email token for `context` (`"confirm"` / `"reset"`).
  Returns `{plaintext, token}` — the plaintext goes in the emailed link; only
  its hash is stored. Caller hands the plaintext to the mailer.
  """
  @spec build_email_token(User.t(), String.t()) ::
          {:ok, binary()} | {:error, Ecto.Changeset.t()}
  def build_email_token(%User{} = user, context) do
    plaintext = generate_token()
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    expires = DateTime.add(now, UserEmailToken.validity_seconds(context), :second)

    %UserEmailToken{}
    |> UserEmailToken.changeset(%{
      user_id: user.id,
      token_hash: UserEmailToken.hash_token(plaintext),
      context: context,
      sent_to: user.email,
      expires_at: expires
    })
    |> Repo.insert()
    |> case do
      {:ok, _} -> {:ok, plaintext}
      {:error, cs} -> {:error, cs}
    end
  end

  @doc "Confirm a user's email from a `\"confirm\"` token plaintext. Consumes the token."
  @spec confirm_user(binary()) :: {:ok, User.t()} | :error
  def confirm_user(plaintext) when is_binary(plaintext) do
    with %UserEmailToken{user_id: uid} = tok <- fetch_email_token(plaintext, "confirm"),
         %User{} = user <- Repo.get(User, uid) do
      {:ok, user} =
        Repo.transaction(fn ->
          Repo.delete!(tok)
          Repo.update!(User.confirm_changeset(user))
        end)

      {:ok, user}
    else
      _ -> :error
    end
  end

  @doc "Reset a password from a `\"reset\"` token plaintext, then revoke all sessions."
  @spec reset_user_password(binary(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()} | :error
  def reset_user_password(plaintext, attrs) when is_binary(plaintext) do
    with %UserEmailToken{user_id: uid} = tok <- fetch_email_token(plaintext, "reset"),
         %User{} = user <- Repo.get(User, uid) do
      Repo.delete(tok)
      do_reset_password(user, attrs)
    else
      _ -> :error
    end
  end

  defp do_reset_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, user} ->
        revoke_all_user_sessions(user)
        {:ok, user}

      err ->
        err
    end
  end

  defp fetch_email_token(plaintext, context) do
    hash = UserEmailToken.hash_token(plaintext)
    now = DateTime.utc_now()

    Repo.one(
      from t in UserEmailToken,
        where: t.token_hash == ^hash and t.context == ^context and t.expires_at > ^now
    )
  end

  # ── TOTP MFA ───────────────────────────────────────────────────────────────

  @doc "Generate a fresh TOTP secret (not yet stored) for enrolment."
  @spec totp_secret() :: binary()
  def totp_secret, do: NimbleTOTP.secret()

  @doc "Build the otpauth:// URI for an enrolment QR, given the user + secret."
  @spec totp_uri(User.t(), binary()) :: String.t()
  def totp_uri(%User{email: email}, secret) do
    NimbleTOTP.otpauth_uri("Barkpark:#{email}", secret, issuer: "Barkpark")
  end

  @doc """
  Confirm enrolment: verify `code` against the candidate `secret`, then persist
  it + enable TOTP and mint recovery codes. Returns `{:ok, user, recovery_codes}`
  with the plaintext one-time codes (shown once) or `:error` on a bad code.
  """
  @spec enable_totp(User.t(), binary(), String.t()) ::
          {:ok, User.t(), [String.t()]} | :error
  def enable_totp(%User{} = user, secret, code) when is_binary(code) do
    if NimbleTOTP.valid?(secret, code) do
      {codes, hashes} = generate_recovery_codes()

      {:ok, user} =
        user
        |> User.totp_changeset(%{
          totp_secret: secret,
          totp_enabled: true,
          recovery_codes_hashed: hashes
        })
        |> Repo.update()

      {:ok, user, codes}
    else
      :error
    end
  end

  @doc "Disable TOTP and clear recovery codes."
  @spec disable_totp(User.t()) :: {:ok, User.t()}
  def disable_totp(%User{} = user) do
    user
    |> User.totp_changeset(%{totp_secret: nil, totp_enabled: false, recovery_codes_hashed: []})
    |> Repo.update()
  end

  @doc "Validate a live TOTP `code` for a user with MFA enabled."
  @spec valid_totp?(User.t(), String.t()) :: boolean()
  def valid_totp?(%User{totp_enabled: true, totp_secret: secret}, code)
      when is_binary(secret) and is_binary(code),
      do: NimbleTOTP.valid?(secret, code)

  def valid_totp?(_, _), do: false

  @doc """
  Consume a one-time recovery `code`: if its hash is in the user's list, remove
  it and return `{:ok, user}`; otherwise `:error`. Used as the MFA fallback.
  """
  @spec consume_recovery_code(User.t(), String.t()) :: {:ok, User.t()} | :error
  def consume_recovery_code(%User{recovery_codes_hashed: hashes} = user, code)
      when is_binary(code) do
    hash = hash_recovery_code(code)

    if hash in hashes do
      user
      |> User.totp_changeset(%{recovery_codes_hashed: List.delete(hashes, hash)})
      |> Repo.update()
    else
      :error
    end
  end

  defp generate_recovery_codes do
    codes =
      for _ <- 1..@recovery_code_count do
        :crypto.strong_rand_bytes(6) |> Base.encode32(case: :lower, padding: false)
      end

    {codes, Enum.map(codes, &hash_recovery_code/1)}
  end

  defp hash_recovery_code(code),
    do: :crypto.hash(:sha256, code) |> Base.encode16(case: :lower)

  defp generate_token,
    do: :crypto.strong_rand_bytes(@rand_bytes) |> Base.url_encode64(padding: false)
end
