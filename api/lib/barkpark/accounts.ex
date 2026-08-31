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
  """
  import Ecto.Query, warn: false
  alias Barkpark.Audit
  alias Barkpark.Repo
  alias Barkpark.Accounts.{User, UserSession, UserEmailToken}
  alias Barkpark.Tenancy.Membership

  @rand_bytes 32
  @recovery_code_count 10

  # ── Registration & lookup ──────────────────────────────────────────────────

  # @canonical capability:user-auth aka:login,register,session,password,mfa,totp,accounts
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
  Workspace-scoped recipient-email typeahead for the Share-access sheet. Returns
  up to `opts[:limit]` (default 8) member emails whose address begins with
  `prefix`, ordered by email. PURE UX — the mint path still validates the
  recipient server-side.

  SCOPING (load-bearing): the searchable population is the CURRENT workspace's
  MEMBERS ONLY — an INNER JOIN to `workspace_memberships` on the `user`
  principal (`m.principal_id == u.id AND m.principal_type == "user" AND
  m.workspace_id == workspace_id`). NEVER the whole users table, NEVER
  cross-tenant. Fails CLOSED: a blank prefix or a nil/blank `workspace_id`
  returns `[]` (no member dump). The prefix's `%`/`_`/`\\` are escaped so a
  typed `%` matches literally and cannot wildcard-dump the roster. Projects
  EMAIL STRINGS ONLY — the User schema has no display name and no other column
  is exposed.
  """
  @spec search_by_email_prefix(String.t(), binary(), keyword()) :: [String.t()]
  def search_by_email_prefix(prefix, workspace_id, opts \\ [])

  def search_by_email_prefix(prefix, workspace_id, opts)
      when is_binary(prefix) and is_binary(workspace_id) and workspace_id != "" do
    case String.trim(prefix) do
      "" ->
        []

      trimmed ->
        pattern = escape_like(String.downcase(trimmed)) <> "%"
        limit = Keyword.get(opts, :limit, 8)

        Repo.all(
          from u in User,
            join: m in Membership,
            on:
              m.principal_id == u.id and m.principal_type == "user" and
                m.workspace_id == ^workspace_id,
            where: ilike(u.email, ^pattern),
            order_by: u.email,
            limit: ^limit,
            select: u.email
        )
    end
  end

  def search_by_email_prefix(_, _, _), do: []

  # Escape LIKE/ILIKE wildcards so a user-typed "%"/"_" matches literally (never
  # a roster dump). Backslash is Postgres' default LIKE escape char, so escape it
  # first, then the metacharacters.
  defp escape_like(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc """
  Return the user iff `email` + `password` match. Constant-time: an unknown
  email still runs a dummy argon2 verify so timing cannot distinguish
  "no such user" from "wrong password".
  """
  @spec get_user_by_email_and_password(String.t(), String.t()) :: User.t() | nil
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_email(email)

    cond do
      # A locked account fails like any bad credential — NO distinct response,
      # so the lockout never widens the anti-enumeration oracle. The password
      # is still verified (constant-time) but the result is discarded.
      locked?(user) ->
        _ = User.valid_password?(user, password)
        nil

      User.valid_password?(user, password) ->
        reset_failed_logins(user)
        user

      true ->
        record_failed_login(user)
        nil
    end
  end

  @doc "Seconds a locked-out account stays locked once the threshold is crossed."
  def lockout_window_seconds, do: Application.get_env(:barkpark, :login_lockout_seconds, 900)

  @doc "Consecutive failed logins that trip the lockout."
  def max_failed_logins, do: Application.get_env(:barkpark, :max_failed_logins, 10)

  # nil user (unknown email) is never "locked" — the dummy verify still runs so
  # timing can't distinguish it.
  defp locked?(%User{locked_until: until}) when not is_nil(until),
    do: DateTime.compare(DateTime.utc_now(), until) == :lt

  defp locked?(_), do: false

  # Count a failure; once the threshold is crossed, stamp `locked_until`. No-op
  # for an unknown email (nothing to protect / would enable user enumeration).
  defp record_failed_login(%User{} = user) do
    n = (user.failed_login_count || 0) + 1
    locked? = n >= max_failed_logins()

    attrs =
      if locked? do
        %{
          failed_login_count: n,
          locked_until: DateTime.add(DateTime.utc_now(), lockout_window_seconds(), :second)
        }
      else
        %{failed_login_count: n}
      end

    user |> Ecto.Changeset.change(attrs) |> Repo.update()

    # The lockout TRIP is a distinct security event — a real account crossed the
    # failed-attempt threshold and is now locked. Only fired on the crossing
    # (a locked account short-circuits in `locked?/1` before ever reaching here),
    # so it is not re-emitted on every subsequent blocked attempt. This DOES
    # imply the account exists, but that is inherent to a lockout (you cannot
    # lock a non-existent account) and unlike the generic failed-login event it
    # takes 10 failures to provoke — no cheap enumeration oracle.
    if locked? do
      emit_audit(%{
        category: "auth",
        action: "account_locked",
        subject: user.id,
        actor_type: "user",
        actor_id: user.id,
        metadata: %{"failed_count" => n}
      })
    end

    :ok
  end

  defp record_failed_login(_), do: :ok

  # A successful login clears the counter + any lock.
  defp reset_failed_logins(%User{failed_login_count: 0, locked_until: nil}), do: :ok

  defp reset_failed_logins(%User{} = user) do
    user
    |> Ecto.Changeset.change(%{failed_login_count: 0, locked_until: nil})
    |> Repo.update()

    :ok
  end

  @doc "Change an existing user's password (verify current first), revoking all sessions."
  @spec update_user_password(User.t(), String.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()} | {:error, :invalid_current}
  def update_user_password(%User{} = user, current_password, attrs) do
    if User.valid_password?(user, current_password) do
      # Drops the revoked-session count deliberately: this arity publishes no
      # claim about sessions, so it has nothing to carry it to.
      case do_reset_password(user, attrs) do
        {:ok, updated, _revoked} -> {:ok, updated}
        err -> err
      end
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

    # A login that presented an MFA factor mints an already-fresh session, so a
    # sensitive action taken right after logging in isn't challenged again.
    mfa_verified_at = if Keyword.get(opts, :mfa_verified, false), do: now

    %UserSession{}
    |> UserSession.changeset(%{
      user_id: user.id,
      token_hash: UserSession.hash_token(plaintext),
      expires_at: expires,
      last_used_at: now,
      mfa_verified_at: mfa_verified_at,
      ip_address: Keyword.get(opts, :ip_address),
      ip_source: Keyword.get(opts, :ip_source),
      user_agent: Keyword.get(opts, :user_agent),
      saml_name_id: Keyword.get(opts, :saml_name_id),
      saml_session_index: Keyword.get(opts, :saml_session_index),
      saml_org_slug: Keyword.get(opts, :saml_org_slug)
    })
    |> Repo.insert()
    |> case do
      {:ok, _} -> {:ok, plaintext}
      {:error, cs} -> {:error, cs}
    end
  end

  @doc "Resolve a session-token plaintext to its `%User{}` or nil (refreshes last_used_at)."
  @spec verify_user_session_token(binary()) :: User.t() | nil
  def verify_user_session_token(plaintext) do
    case verify_user_session(plaintext) do
      {%User{} = user, _session} -> user
      nil -> nil
    end
  end

  @doc """
  Like `verify_user_session_token/1` but returns BOTH the `%User{}` and the
  live `%UserSession{}` (with `last_used_at` freshly stamped), so callers on
  the step-up path can read/write the session's `mfa_verified_at`. Returns
  `nil` for an unknown, revoked, or expired token.
  """
  @spec verify_user_session(binary()) :: {User.t(), UserSession.t()} | nil
  def verify_user_session(plaintext) when is_binary(plaintext) do
    hash = UserSession.hash_token(plaintext)
    now = DateTime.utc_now()

    query =
      from t in UserSession,
        where: t.token_hash == ^hash and is_nil(t.revoked_at),
        where: is_nil(t.expires_at) or t.expires_at > ^now

    case Repo.one(query) do
      %UserSession{user_id: uid, last_used_at: prev} = session ->
        # era-w8-org-session-policy: enforce the strictest idle/absolute-lifetime
        # bound governing this user's orgs. FAIL CLOSED — a governed session that
        # is idle past the window, or older than the absolute lifetime, is treated
        # as no session (logged out). Checked BEFORE touching last_used_at so the
        # idle measurement uses the real prior-activity timestamp, not this
        # request. An all-nil policy (the default: no governing org sets a bound)
        # is always satisfied, so this path is byte-identical to before — zero-tax.
        policy = Barkpark.Tenancy.org_session_policy_for_user(uid)

        if UserSession.within_org_policy?(session, policy, now) do
          effective_last_used = maybe_touch_session_last_used(hash, prev, now)

          case Repo.get(User, uid) do
            %User{} = user -> {user, %{session | last_used_at: effective_last_used}}
            nil -> nil
          end
        else
          nil
        end

      nil ->
        nil
    end
  end

  def verify_user_session(_), do: nil

  # Throttled `last_used_at` stamp: RequireUserSession calls the verify on EVERY
  # request, so an unthrottled write amplifies to one UPDATE per request. Mirror
  # the API-token twin `Auth.touch_last_used/1` (60s window, same idiom) — skip
  # the redundant write when the column was stamped within the window. This is a
  # pure liveness/perf stamp, NOT security-relevant: the auth decision already
  # happened above, so skipping it never changes a login/session outcome.
  @session_last_used_throttle_seconds 60

  defp maybe_touch_session_last_used(hash, prev, now) do
    stale? =
      is_nil(prev) or
        DateTime.diff(now, prev, :second) > @session_last_used_throttle_seconds

    if stale? do
      stamped = DateTime.truncate(now, :microsecond)

      from(t in UserSession, where: t.token_hash == ^hash)
      |> Repo.update_all(set: [last_used_at: stamped])

      stamped
    else
      prev
    end
  end

  @doc """
  Revoke a single session by plaintext (idempotent). Returns `{:ok, revoked}` —
  the NUMBER OF ROWS the revoke actually stamped: 1 for a live session, 0 when
  there was nothing left to revoke (an already-revoked, expired or unknown
  token).

  The count is the post-condition the caller's receipt implies, so it is
  returned rather than swallowed here — a hardcoded `:ok` discarded the outcome
  AT THE SOURCE, leaving every caller's "signed out" claim unreadable in
  principle (PDS-D523, same widening as `revoke_all_user_sessions/1` in
  PDS-D503). Idempotence is preserved: 0 is a normal answer, not an error.
  """
  @spec revoke_user_session_token(binary()) :: {:ok, non_neg_integer()}
  def revoke_user_session_token(plaintext) when is_binary(plaintext) do
    hash = UserSession.hash_token(plaintext)
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    {revoked, _} =
      from(t in UserSession, where: t.token_hash == ^hash and is_nil(t.revoked_at))
      |> Repo.update_all(set: [revoked_at: now])

    {:ok, revoked}
  end

  @doc """
  Revoke all of a user's live sessions ("sign out everywhere"). Returns
  `{:ok, revoked}` — the NUMBER OF ROWS the revoke actually stamped.

  The count is the post-condition every caller's receipt implies: a bare `:ok`
  reads identically whether three sessions died or zero did (PDS-D503). Callers
  that publish a "sessions were killed" claim MUST carry this number, not
  re-assert it from the fact the call returned.
  """
  @spec revoke_all_user_sessions(User.t()) :: {:ok, non_neg_integer()}
  def revoke_all_user_sessions(%User{id: uid}) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    {revoked, _} =
      from(t in UserSession, where: t.user_id == ^uid and is_nil(t.revoked_at))
      |> Repo.update_all(set: [revoked_at: now])

    {:ok, revoked}
  end

  @doc """
  The user's ACTIVE sessions (not revoked, not expired), newest first — the
  "your devices" list. Each row carries device metadata (user_agent, ip,
  created/last-used) for the session-management surface.
  """
  @spec list_user_sessions(User.t()) :: [UserSession.t()]
  def list_user_sessions(%User{id: uid}) do
    now = DateTime.utc_now()

    Repo.all(
      from t in UserSession,
        where: t.user_id == ^uid and is_nil(t.revoked_at),
        where: is_nil(t.expires_at) or t.expires_at > ^now,
        order_by: [desc: t.inserted_at]
    )
  end

  @doc """
  Revoke ONE of `user`'s sessions by its id — self-scoped: a session id
  belonging to another user is `:not_found` (no cross-user probe). Idempotent
  on an already-revoked session.
  """
  @spec revoke_user_session_by_id(User.t(), binary()) :: :ok | :not_found
  def revoke_user_session_by_id(%User{id: uid}, session_id) do
    with {:ok, sid} <- Ecto.UUID.cast(session_id),
         %UserSession{} = session <- Repo.get_by(UserSession, id: sid, user_id: uid) do
      if is_nil(session.revoked_at) do
        now = DateTime.truncate(DateTime.utc_now(), :microsecond)
        {:ok, _} = session |> UserSession.changeset(%{revoked_at: now}) |> Repo.update()
      end

      :ok
    else
      _ -> :not_found
    end
  end

  @doc """
  IdP-initiated Single Logout: revoke the SAML-born sessions an IdP
  `LogoutRequest` names — matched by NameID within the org's connection, and
  narrowed to the specific IdP session when a SessionIndex is supplied (an
  empty/absent index logs out all of that subject's sessions for the org, per
  the SAML profile). Returns the number revoked.
  """
  @spec revoke_saml_sessions(String.t(), String.t(), String.t() | nil) :: non_neg_integer()
  def revoke_saml_sessions(org_slug, name_id, session_index)
      when is_binary(org_slug) and is_binary(name_id) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    query =
      from(t in UserSession,
        where:
          t.saml_org_slug == ^org_slug and t.saml_name_id == ^name_id and
            is_nil(t.revoked_at)
      )

    query =
      case session_index do
        idx when is_binary(idx) and idx != "" -> where(query, [t], t.saml_session_index == ^idx)
        _ -> query
      end

    {count, _} = Repo.update_all(query, set: [revoked_at: now])
    count
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

  @doc """
  Build a single-use magic-link **login** token for the account with `email`.

  Returns `{:ok, plaintext, user}` when the email maps to a user (the caller
  mails the plaintext in the link), or `:no_user` when it does not. The caller
  MUST return an identical generic response either way — never leak whether the
  email exists (anti-enumeration, same discipline as request-reset/register).
  """
  @spec build_login_token(term()) ::
          {:ok, binary(), User.t()} | :no_user | {:error, Ecto.Changeset.t()}
  def build_login_token(email) when is_binary(email) do
    case get_user_by_email(email) do
      %User{} = user ->
        case build_email_token(user, "login") do
          {:ok, plaintext} -> {:ok, plaintext, user}
          {:error, _} = err -> err
        end

      _ ->
        :no_user
    end
  end

  def build_login_token(_), do: :no_user

  @doc """
  Consume a magic-link **login** token plaintext, returning the user. Single-use
  (the row is deleted) and expiry-bounded. Unknown, already-used, and expired
  tokens are all indistinguishable — every failure returns `:error`, so the
  consume path is not an existence oracle.
  """
  @spec consume_login_token(term()) :: {:ok, User.t()} | :error
  def consume_login_token(plaintext) when is_binary(plaintext) do
    with %UserEmailToken{user_id: uid} = tok <- fetch_email_token(plaintext, "login"),
         %User{} = user <- Repo.get(User, uid),
         {:ok, user} <- Repo.transaction(fn -> Repo.delete!(tok) && user end) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  def consume_login_token(_), do: :error

  @doc "Confirm a user's email from a `\"confirm\"` token plaintext. Consumes the token."
  @spec confirm_user(term()) :: {:ok, User.t()} | :error
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

  # Fail soft on a non-binary token (e.g. Phoenix parses `?token[]=x` into a list) —
  # route malformed input onto the existing :error → 422 path, never a 500.
  def confirm_user(_), do: :error

  @doc """
  Reset a password from a `"reset"` token plaintext, then revoke all sessions.

  Drops the revoked-session count — use `reset_user_password_counting/2` on any
  path whose receipt CLAIMS the sessions died (PDS-D503).
  """
  @spec reset_user_password(term(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()} | :error
  def reset_user_password(plaintext, attrs) do
    case reset_user_password_counting(plaintext, attrs) do
      {:ok, user, _revoked} -> {:ok, user}
      other -> other
    end
  end

  @doc """
  `reset_user_password/2` widened by its post-condition: returns
  `{:ok, user, sessions_revoked}`, where `sessions_revoked` is the number of
  live sessions the reset actually stamped `revoked_at` on.

  This is what `POST /v1/auth/reset` reports. Without it the receipt is
  byte-identical whether "sign out everywhere" killed three sessions or none.
  """
  @spec reset_user_password_counting(term(), map()) ::
          {:ok, User.t(), non_neg_integer()} | {:error, Ecto.Changeset.t()} | :error
  def reset_user_password_counting(plaintext, attrs) when is_binary(plaintext) do
    with %UserEmailToken{user_id: uid} = tok <- fetch_email_token(plaintext, "reset"),
         %User{} = user <- Repo.get(User, uid) do
      # Atomic reset + token-consume: reset the password FIRST so a policy-failing
      # password rolls back and the token SURVIVES (the reset link stays usable).
      # A concurrent consume (StaleEntryError on delete) rolls back too → :error,
      # never a 500. Mirrors confirm_user/1 above.
      txn =
        Repo.transaction(fn ->
          case do_reset_password(user, attrs, reset_mfa: true) do
            {:ok, reset_user, revoked} ->
              case Repo.delete(tok, stale_error_field: :id) do
                {:ok, _} -> {reset_user, revoked}
                {:error, _cs} -> Repo.rollback(:stale)
              end

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)

      case txn do
        {:ok, {reset_user, revoked}} -> {:ok, reset_user, revoked}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        {:error, :stale} -> :error
      end
    else
      _ -> :error
    end
  end

  # Fail soft on a non-binary token — mirrors confirm_user/1's catch-all above.
  def reset_user_password_counting(_, _), do: :error

  # `reset_mfa: true` (the forgot-password / account-recovery path) also wipes
  # TOTP + recovery codes — MEDIUM-8: a token-based reset must FULLY recover a
  # hijacked account, including any MFA the attacker enrolled. An authenticated
  # password CHANGE (update_user_password) keeps MFA intact (default false).
  defp do_reset_password(user, attrs, opts \\ []) do
    changeset = User.password_changeset(user, attrs)

    changeset =
      if Keyword.get(opts, :reset_mfa, false) do
        User.totp_changeset(changeset, %{
          totp_secret: nil,
          totp_enabled: false,
          recovery_codes_hashed: [],
          last_totp_at: nil
        })
      else
        changeset
      end

    case Repo.update(changeset) do
      {:ok, user} ->
        {:ok, revoked} = revoke_all_user_sessions(user)
        {:ok, user, revoked}

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

  @doc """
  Disable TOTP and clear recovery codes.

  `last_totp_at` IS PART OF THE WIPE, and this is the whole reason the
  attribute list is spelled out rather than inherited. The stamp is the
  replay guard for ONE secret (`totp_opts/1` feeds it to NimbleTOTP as
  `since:`, and `reused?/3` rejects any code whose 30s step is <= it). Carrying
  it across a disable attaches the OLD secret's consumed step to a BRAND NEW
  one: re-enrol inside the same 30s period as the last successful verify and
  the first `verify_totp/2` against the new secret returns `:error` on a
  perfectly valid code.

  The other two MFA-wipe paths — `do_reset_password/3` with `reset_mfa: true`
  and `Accounts.Privacy` erasure — already clear it. This one drifted, and
  nothing structurally holds the three together, so keep them in sync by hand:
  a field added to the TOTP set belongs in ALL THREE.
  """
  @spec disable_totp(User.t()) :: {:ok, User.t()}
  def disable_totp(%User{} = user) do
    user
    |> User.totp_changeset(%{
      totp_secret: nil,
      totp_enabled: false,
      recovery_codes_hashed: [],
      last_totp_at: nil
    })
    |> Repo.update()
  end

  @doc """
  Validate a live TOTP `code` (non-consuming predicate). Honours the user's
  last-consumed step so a replayed code reads as invalid here too. Prefer
  `verify_totp/2` on the login path — it atomically records consumption.
  """
  @spec valid_totp?(User.t(), String.t()) :: boolean()
  def valid_totp?(%User{totp_enabled: true, totp_secret: secret} = user, code)
      when is_binary(secret) and is_binary(code),
      do: NimbleTOTP.valid?(secret, code, totp_opts(user))

  def valid_totp?(_, _), do: false

  @doc """
  Verify a live TOTP `code` AND consume its time-step so it cannot be replayed
  (MEDIUM-6). Returns `{:ok, user}` on a fresh, valid code; `:error` on an
  invalid code OR one already used in this-or-an-earlier 30s period.

  The consumption write is a COMPARE-AND-SWAP, not a plain update — it closes
  the read-then-write TOCTOU the red-team flagged (LOW): two concurrent verifies
  of the SAME code both pass `NimbleTOTP.valid?` against the same `last_totp_at`,
  then race to stamp it. The CAS advances `last_totp_at` only when the row still
  holds the value this caller read (`is_nil` or `== seen`), so exactly ONE racer
  wins; the loser sees zero rows updated and is rejected as a replay. The stamp
  is therefore also monotonic (a winner always moves it forward).
  """
  # ── CITED SAFE — class A, and the ordering guard is UPSTREAM, not missing
  # (clock-semantics wave, 2026-08-19). Read this before "fixing" the CAS.
  #
  # Provenance: swept as a candidate of the class-C bucket-key defect closed by
  # #12628 (8598c4efe7) and the atomicity defect closed by #12579 (e45f1377bb).
  # This site is neither: `last_totp_at` is an ABSOLUTE STORED INSTANT compared
  # against a persisted column, which is precisely the case where wall clock is
  # CORRECT and `System.monotonic_time` would be meaningless (process-local,
  # gone on restart, incomparable across nodes).
  #
  # (a) STRUCTURAL, before any consequence argument: the CAS below
  #     (`cas_last_totp/2`) is EQUALITY-only — `u.last_totp_at == ^seen` — with
  #     no ordering predicate, and the doc above asserts the stamp is
  #     monotonic. That assertion HOLDS, but not for the reason the code shape
  #     suggests. Ordering is enforced BEFORE the write, by NimbleTOTP's reuse
  #     gate: `reused?/3` (nimble_totp 1.0.0, lib/nimble_totp.ex:250-252) is
  #     `Integer.floor_div(time, period) <= Integer.floor_div(to_unix(since),
  #     period)` => reused => invalid. That is STRICT at step granularity, so
  #     acceptance requires floor(now/30) > floor(since/30), which arithmetically
  #     implies now > since. `totp_opts/1` below is what feeds `since:`.
  #
  # (b) PROVEN, not argued. An exhaustive sweep over a 3-step neighbourhood
  #     (121 x 121 = 14641 (time, since) pairs, each with its own matching code)
  #     found the accepted-with-time-<=-since set EMPTY. End to end: forcing
  #     `last_totp_at` 600 s into the FUTURE — arithmetically identical to a
  #     rewound host clock — makes `verify_totp/2` return `:error` with the
  #     stored value byte-identical; the CAS never runs at all.
  #     CLOCK STEP, both directions: BACKWARD fails CLOSED (the code is rejected
  #     as reuse before any write). FORWARD also fails closed for replay — it
  #     can only advance the consumed step, never rewind it. There is no
  #     direction in which a step admits a replayed code.
  #
  # So the absent `u.last_totp_at < ^now` predicate is REDUNDANT, not
  # absent-and-dangerous, and shipping it would be claiming a defect that does
  # not exist.
  #
  # RESIDUAL — a DEPENDENCY COUPLING, and this is the durable value of the note:
  # the ordering invariant is enforced by a third party's internals, not by
  # anything in this file. A nimble_totp version bump that loosens `reused?/3`
  # to `<`, anyone adding a `time:` option to the `valid?` call, or anyone
  # dropping `since:` from `totp_opts/1`, silently converts this redundant CAS
  # into the real defect — with no test here failing. If you touch any of those
  # three, add the ordering predicate.
  # CONTRAST, deliberately: cloud's twin does NOT rely on the dependency. It
  # stores a step INDEX and guards it in SQL —
  # `u.two_factor_last_step < ^step` in the WHERE at
  # cloud/lib/barkpark_cloud/accounts.ex:2186 — a different mechanism that
  # needs its own guard and has it.
  #
  # WHAT THIS VERDICT DOES NOT REST ON: the MEDIUM-6 / LOW red-team stamps
  # recorded in the doc above. Those graded the read-then-write race between two
  # concurrent verifiers; neither examined what a clock step does to the stamp.
  # The two grounds above are the upstream strict inequality and an exhaustive
  # sweep; neither leans on that history.
  @spec verify_totp(User.t(), String.t()) :: {:ok, User.t()} | :error
  def verify_totp(%User{totp_enabled: true, totp_secret: secret} = user, code)
      when is_binary(secret) and is_binary(code) do
    if NimbleTOTP.valid?(secret, code, totp_opts(user)) do
      now = DateTime.truncate(DateTime.utc_now(), :microsecond)
      consume_totp_step(user, now)
    else
      :error
    end
  end

  def verify_totp(_, _), do: :error

  # Atomic compare-and-swap on `last_totp_at`: advance to `now` ONLY if the row
  # still holds the value this caller read (`seen`). A concurrent verify that
  # already advanced the column leaves this WHERE unmatched → 0 rows → :error
  # (replay). Closes the verify_totp read-then-write race.
  defp consume_totp_step(%User{id: id, last_totp_at: seen} = user, now) do
    {count, _} =
      User
      |> where([u], u.id == ^id)
      |> cas_last_totp(seen)
      |> Repo.update_all(set: [last_totp_at: now])

    if count == 1 do
      {:ok, %{user | last_totp_at: now}}
    else
      :error
    end
  end

  # No ordering predicate here BY VERDICT, not by omission — clock-semantics
  # wave 2026-08-19 classified this class A / CITED SAFE. NimbleTOTP's strict
  # step gate makes `now > seen` a precondition of ever reaching this write; see
  # the block above `verify_totp/2` for the proof and for the dependency
  # coupling that is the residual.
  defp cas_last_totp(query, nil), do: where(query, [u], is_nil(u.last_totp_at))
  defp cas_last_totp(query, seen), do: where(query, [u], u.last_totp_at == ^seen)

  # Feed NimbleTOTP's `:since` so a code from the same/earlier period as the last
  # consumed step is rejected as reuse (one-time-use within the step window).
  defp totp_opts(%User{last_totp_at: nil}), do: []
  defp totp_opts(%User{last_totp_at: since}), do: [since: since]

  @doc """
  Consume a one-time recovery `code`: if its hash is in the user's list, remove
  it and return `{:ok, user}`; otherwise `:error`. Used as the MFA fallback.

  Consumption is a single atomic DB `UPDATE` — `array_remove(...)` gated by a
  `hash = ANY(recovery_codes_hashed)` membership predicate in the WHERE — NOT a
  read-modify-write. This mirrors the `verify_totp` compare-and-swap and closes
  the same TOCTOU: two concurrent logins with the SAME code both used to pass the
  in-memory `hash in hashes` check and race to `Repo.update`, minting two
  sessions; two DIFFERENT codes were a lost-update that could leave an
  already-consumed code back in the array (reusable). Postgres serializes the row
  UPDATE, so exactly ONE racer removes the hash (1 row) and the loser matches 0
  rows → `:error`. One-time-use holds under concurrency; no login outcome changes.
  """
  @spec consume_recovery_code(User.t(), String.t()) :: {:ok, User.t()} | :error
  def consume_recovery_code(%User{id: id, recovery_codes_hashed: hashes} = user, code)
      when is_binary(code) do
    hash = hash_recovery_code(code)

    {count, _} =
      from(u in User,
        where: u.id == ^id,
        where: fragment("? = ANY(?)", ^hash, u.recovery_codes_hashed),
        update: [
          set: [
            recovery_codes_hashed: fragment("array_remove(?, ?)", u.recovery_codes_hashed, ^hash)
          ]
        ]
      )
      |> Repo.update_all([])

    if count == 1 do
      remaining = List.delete(hashes, hash)

      # A one-time recovery code was just burned — a security-relevant fallback
      # authentication. Record it (with how many codes remain) so a run of
      # recovery-code use, or a user running low, is visible on the audit trail.
      emit_audit(%{
        category: "auth",
        action: "recovery_code_used",
        subject: id,
        actor_type: "user",
        actor_id: id,
        metadata: %{"remaining" => length(remaining)}
      })

      {:ok, %{user | recovery_codes_hashed: remaining}}
    else
      :error
    end
  end

  # Best-effort audit emit: an audit-bus hiccup must NEVER break an
  # authentication decision (the change it records has already committed). The
  # emit result is discarded and any infra-level raise/throw is swallowed —
  # mirrors `Barkpark.Access.emit_grant_event/4`.
  defp emit_audit(attrs) do
    Audit.emit(attrs)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # ── Step-up MFA ──────────────────────────────────────────────────────────────

  @doc """
  True when `user` has ANY MFA factor armed (TOTP or a passkey) — i.e. sensitive
  actions on their sessions should require a recent step-up. Opt-in: a user who
  never enrolled a factor is not gated, so there is no added friction for the
  common case. Factor-agnostic so a passkey-only user is protected too.
  """
  @spec mfa_enrolled?(User.t()) :: boolean()
  def mfa_enrolled?(%User{totp_enabled: true}), do: true
  def mfa_enrolled?(%User{} = user), do: Barkpark.Accounts.Webauthn.has_passkey?(user)
  def mfa_enrolled?(_), do: false

  @doc """
  Present an MFA factor for a step-up challenge: a live TOTP `code` (consumed,
  replay-safe) or a one-time recovery code. Returns `{:ok, user, factor}` with
  `factor` in `:totp | :recovery`, or `:error` when neither matches.
  """
  @spec verify_step_up(User.t(), String.t()) ::
          {:ok, User.t(), :totp | :recovery} | :error
  def verify_step_up(%User{} = user, code) when is_binary(code) do
    case verify_totp(user, code) do
      {:ok, user} ->
        {:ok, user, :totp}

      :error ->
        case consume_recovery_code(user, code) do
          {:ok, user} -> {:ok, user, :recovery}
          :error -> :error
        end
    end
  end

  def verify_step_up(_, _), do: :error

  @doc """
  Stamp `mfa_verified_at = now` on a session after a successful step-up, marking
  it fresh for the step-up window. Returns the updated `%UserSession{}`.
  """
  @spec stamp_session_mfa(UserSession.t()) :: {:ok, UserSession.t()} | {:error, term()}
  def stamp_session_mfa(%UserSession{} = session) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    session
    |> UserSession.changeset(%{mfa_verified_at: now})
    |> Repo.update()
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
