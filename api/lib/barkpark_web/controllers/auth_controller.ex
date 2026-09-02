defmodule BarkparkWeb.AuthController do
  @moduledoc """
  Core user-auth JSON API (`/v1/auth/*`).

  Public: register, login (with TOTP second factor), verify-email, request-reset,
  reset. Session-gated (`RequireUserSession`): me, logout, mfa/enroll, mfa/verify,
  mfa/disable, erase, change_password. The mfa/* routes, erase, and
  change_password all additionally require the current password (re-auth) so a
  hijacked-but-unlocked session cannot silently alter MFA, erase the account, or
  change the password.

  Login returns the session token as a bearer in the body AND sets a signed
  `user_session` cookie, so both API clients and browsers are served. Anti-
  enumeration: request-reset AND register always return a generic success;
  login failures are a single generic `invalid_credentials` regardless of
  whether the email exists OR whether the password was correct-but-MFA-needed.
  """
  use BarkparkWeb, :controller

  # Step-up MFA: disabling MFA is a sensitive action, so an enrolled user must
  # have presented a fresh factor on this session (not just the password) —
  # a hijacked live session can't silently strip MFA. Recovery is preserved: a
  # one-time recovery code satisfies the step-up, and the token-based password
  # reset still wipes MFA outright.
  plug(BarkparkWeb.Plugs.RequireRecentMfa when action in [:mfa_disable])

  alias Barkpark.Accounts
  alias Barkpark.Accounts.{NotificationWithhold, UserNotifier, UserSession}
  alias Barkpark.Audit
  alias Barkpark.Auth
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  # ── Registration ───────────────────────────────────────────────────────────

  # MEDIUM-7: anti-enumeration. A duplicate email must be INDISTINGUISHABLE from
  # a fresh signup — same status, same body shape — so a caller can't probe which
  # addresses are registered. We notify the existing owner out-of-band instead of
  # leaking "has already been taken". Real validation errors (weak password) stay
  # 422. The response omits the user id precisely so the two paths can't diverge.
  #
  # The email-taken signal must NEVER reach the caller, even when it co-occurs with
  # another error (the weak-password probe: validate_email's unsafe_validate_unique
  # still runs when only :password is invalid, so a duplicate+short password
  # produces BOTH errors). We therefore always strip the :email signal from any
  # 422 body, so existing-email+weak-password and new-email+weak-password are
  # byte-identical (password error only).
  def register(conn, %{"email" => email, "password" => password}) do
    case Accounts.register_user(%{email: email, password: password}) do
      {:ok, user} ->
        send_confirmation(user)
        registration_accepted(conn, email)

      {:error, changeset} ->
        if email_taken?(changeset) do
          # An existing account is implicated — notify it out-of-band, never leak.
          notify_existing_account(email)
        end

        case errors_without_email_signal(changeset) do
          # Email collision was the ONLY problem → indistinguishable from a fresh
          # signup (generic 201). Otherwise surface the real errors with the email
          # existence signal already stripped.
          map when map_size(map) == 0 -> registration_accepted(conn, email)
          errors -> error(conn, 422, "invalid_registration", errors)
        end
    end
  end

  def register(conn, _), do: error(conn, 400, "bad_request", "email and password are required")

  # ── Login (+ TOTP second factor) ────────────────────────────────────────────

  def login(conn, %{"email" => email, "password" => password} = params) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        # ONE generic failed-login event, emitted HERE (not in Accounts) on
        # purpose: `get_user_by_email_and_password/2` returns nil identically for
        # an unknown email, a wrong password, AND a locked account, so this site
        # sees every failure with a CONSTANT shape — no `subject`, no user id, no
        # email — and therefore the presence of the event never reveals whether
        # the address is registered. Emitting the failure inside Accounts (where
        # the User struct only exists for real accounts) would reintroduce that
        # enumeration oracle on the audit log itself.
        audit(%{
          category: "auth",
          action: "login_failed",
          actor_type: "anonymous",
          metadata: %{"reason" => "invalid_credentials"}
        })

        error(
          conn,
          401,
          "invalid_credentials",
          "email or password is incorrect",
          "double-check the email and password; if forgotten, start a reset with request-reset"
        )

      user ->
        if user.totp_enabled do
          login_with_mfa(conn, user, params["totp_code"], params["recovery_code"])
        else
          issue_session(conn, user)
        end
    end
  end

  def login(conn, _), do: error(conn, 400, "bad_request", "email and password are required")

  # Standard two-step 2FA UX: the PASSWORD is already correct here (a wrong
  # password never reaches this fn — `login/2` returns `invalid_credentials`
  # first), so a missing OR invalid second factor returns `mfa_required` —
  # the "now enter your code" signal a two-step login client needs.
  #
  # DELIBERATE, industry-accepted tradeoff (restores LOW-13's removal): replying
  # `mfa_required` only after a correct password confirms password validity to a
  # caller who already supplied it — a minor oracle that standard 2FA flows
  # accept as the price of a usable two-step login. The generic-on-everything
  # alternative breaks the UX (the client can't tell "wrong password" from
  # "needs a code").
  #
  # MEDIUM-6: the TOTP is consumed via verify_totp so the code is one-time.
  defp login_with_mfa(conn, user, code, recovery) do
    cond do
      is_binary(code) and match?({:ok, _}, Accounts.verify_totp(user, code)) ->
        issue_session(conn, user, mfa_verified: true)

      is_binary(recovery) and match?({:ok, _}, Accounts.consume_recovery_code(user, recovery)) ->
        issue_session(conn, user, mfa_verified: true)

      true ->
        # A correct password with a missing OR invalid second factor is a failed
        # login second factor — audit it, mirroring the step-up failure branch
        # (mfa_step_up emits the same auth/mfa_failed). Without this the LOGIN
        # second-factor failure was silent while step-up's was not. The `context`
        # metadata distinguishes the two failure sites ("login" vs "step_up").
        Audit.emit(%{
          category: "auth",
          action: "mfa_failed",
          subject: user.id,
          actor_type: "user",
          actor_id: user.id,
          metadata: %{"context" => "login"}
        })

        error(
          conn,
          401,
          "mfa_required",
          "a valid TOTP or recovery code is required",
          "enter the 6-digit code from your authenticator app (or a one-time recovery code) and retry"
        )
    end
  end

  # ── Session lifecycle ───────────────────────────────────────────────────────

  @doc """
  GDPR right of access — export the current subject's complete data bundle as
  machine-readable JSON. Session-gated: a subject can only export their own data.
  """
  def export(conn, _params) do
    user = conn.assigns.current_user
    json(conn, Barkpark.Accounts.Privacy.export_subject(user))
  end

  @doc """
  GDPR right to erasure — pseudonymise the current subject and revoke all access.
  Sensitive: requires the current password (reauth). The now-erased session is
  dropped from the response.
  """
  def erase(conn, %{"password" => password}) do
    user = conn.assigns.current_user

    if reauthed?(user, password) do
      {:ok, summary} = Barkpark.Accounts.Privacy.erase_subject(user)

      conn
      |> configure_session(drop: true)
      |> json(%{ok: true, erased: summary})
    else
      error(
        conn,
        403,
        "invalid_password",
        "the current password is required to erase your account"
      )
    end
  end

  def erase(conn, _), do: error(conn, 400, "bad_request", "password is required")

  @doc """
  Self-service password change. Sensitive: requires the CURRENT password
  (reauth), same shape as `erase/2` above. Delegates to
  `Accounts.update_user_password/3`, which already exists and is tested —
  this action is its first HTTP door. That function revokes every session
  for the user on success (including this one), same contract as a
  token-based `reset/2`; unlike `reset/2` it reports no sessions-revoked
  count (see the function's own doc for why), so the response is a plain
  `{"ok": true}` and the caller signs in again afterwards.
  """
  def change_password(conn, %{"current_password" => current_password, "password" => password}) do
    user = conn.assigns.current_user

    case Accounts.update_user_password(user, current_password, %{password: password}) do
      {:ok, _user} ->
        audit(%{
          category: "auth",
          action: "password_changed",
          subject: user.id,
          actor_type: "user",
          actor_id: user.id,
          metadata: %{"via" => "self_service"}
        })

        conn
        |> configure_session(drop: true)
        |> json(%{ok: true})

      {:error, :invalid_current} ->
        error(
          conn,
          403,
          "invalid_password",
          "the current password is required to change your password"
        )

      {:error, %Ecto.Changeset{} = cs} ->
        error(conn, 422, "invalid_password", changeset_errors(cs))
    end
  end

  def change_password(conn, _),
    do: error(conn, 400, "bad_request", "current_password and password are required")

  def me(conn, _params) do
    user = conn.assigns.current_user

    json(conn, %{
      user: %{
        id: user.id,
        email: user.email,
        confirmed: not is_nil(user.confirmed_at),
        mfa: user.totp_enabled
      }
    })
  end

  @doc """
  Session-gated self-mint of a Personal Access Token that carries the caller's
  USER identity (`owner_user_id`).

  ## No-escalation invariant (SECURITY)

  `owner_user_id` is ALWAYS `current_user.id`, taken from the authenticated
  session — NEVER from the request body. Any caller-supplied `owner_user_id` /
  `user_id` in `params` is IGNORED: a user can only mint a token owned by
  THEMSELVES.

  The raw token is returned ONCE and never recoverable. Field hygiene: only the
  token's non-secret fields are echoed — never the `token_hash`.

  ## Workspace + permission tier are DERIVED, never a literal (SECURITY)

  Both used to be hardcoded (`role: "member"`, permissions `["read"]`) with no
  `:workspace_id`, which meant `Auth.create_personal_access_token/3` fell back
  to the seeded Default Workspace for EVERY caller and granted it a
  `Tenancy.Membership` with zero relationship check — any session-authenticated
  user, including one with no membership anywhere, self-minted a token that
  could read Default-Workspace content. Fixed on both axes at once (a
  permission-only fix WORSENS this: a higher-tier token minted into a
  workspace the caller does not belong to):

    * `:workspace_id` + the minting role are resolved from the caller's OWN
      `Tenancy.Membership` (`resolve_caller_workspace/1`) — never a
      client-supplied value, never the Default Workspace. A caller who holds
      no membership anywhere resolves to `{nil, nil}`, and
      `create_personal_access_token/3` then mints the token WORKSPACE-LESS
      (no membership row at all) rather than falling back to any default.
    * Permissions are `Auth.max_pat_permissions_for_role/1` of that SAME
      resolved role (Option A, lead-ratified 2026-08-24): an owner/admin
      self-mints up to `["read", "write"]`, a member still gets `["read"]`
      only — `authorize_pat_permissions/2` is the same gate it was written
      for, never bypassed.

  ### PAT admin mint closed 2026-09-02

  Orchestrator ruling, delegated; owner informed 2026-09-01: owner/admin
  self-mint tops out at `["read", "write"]`; the flat admin bit is
  instance-wide and is not a workspace-role artefact.

  Option A as ratified on 2026-08-24 let this arm return
  `["read", "write", "admin"]`. `BarkparkWeb.Plugs.RequireAdmin` is an
  UNSCOPED `Auth.has_permission?(token, "admin")` with no workspace in the
  check, so that PAT cleared every `[:api, :require_admin]` route on the
  instance — `GET /v1/secrets/:name` returned run secrets in cleartext to any
  owner of any workspace, including one they had just created. The ceiling now
  lives in `Auth`'s `@pat_allowed_elevated_permissions`; this action is
  unchanged and still derives, never literalises. `RequireAdmin` is untouched
  (it is the flat instance tier by design) and workspace-scoped admin
  authority stays on the MEMBERSHIP role, read by
  `Tenancy.Auth.workspace_admin?/2`.

  `owner_user_id` stays hard-bound regardless of any of the above.

  ## MFA posture (deliberate, not accidental)

  An owned token is a NON-INTERACTIVE credential. Org-MFA-enrolment is a
  SESSION/ISSUANCE gate, enforced HERE at mint (this action rides
  `[:user_auth, :require_user]`, and `:require_user` includes
  `RequireOrgMfaEnrolment`), NOT re-checked per token-CLAIM. So an unenrolled
  user governed by a `require_mfa` org is 403'd BEFORE they can obtain an owned
  token — the token path is safe because the upstream issuance gate holds. The
  subsequent `bp access claim`/`mine` is then gated by token auth + the grant's
  account-binding + the no-escalation caps baked at grant mint. (The SESSION
  claim path re-applies `RequireOrgMfaEnrolment` on the `:access_principal`
  pipeline; the token path relies on this issuance gate.)
  """
  def create_token(conn, params) do
    user = conn.assigns.current_user
    name = token_name(params)
    {workspace_id, role} = resolve_caller_workspace(user)
    permissions = Auth.max_pat_permissions_for_role(role)

    # owner_user_id is HARD-BOUND to the session user. A body `owner_user_id` /
    # `user_id` is never read — this is the mint's no-escalation guarantee.
    case Auth.create_personal_access_token(name, permissions,
           role: role,
           created_by: user.email,
           owner_user_id: user.id,
           workspace_id: workspace_id
         ) do
      {:ok, {raw, token}} ->
        # Minting a standing credential is an audit-worthy lifecycle event.
        Audit.emit(%{
          category: "token",
          action: "personal_access_token_minted",
          subject: token.id,
          actor_type: "user",
          actor_id: user.id,
          metadata: %{"name" => token.name, "permissions" => token.permissions}
        })

        conn
        |> put_status(:created)
        |> json(%{
          token: raw,
          personal_access_token: %{
            id: token.id,
            name: token.name,
            owner_user_id: token.owner_user_id,
            permissions: token.permissions,
            expires_at: token.expires_at,
            inserted_at: token.inserted_at
          }
        })

      {:error, :forbidden} ->
        error(conn, 403, "forbidden", "you may not mint a token with those permissions")

      {:error, %Ecto.Changeset{} = cs} ->
        error(conn, 422, "unprocessable", changeset_errors(cs))
    end
  end

  # A user-facing token name. Whitelisted from the body (never an owner field);
  # falls back to a stable default so the mint never depends on client input.
  defp token_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp token_name(_), do: "personal access token"

  # Resolve the CALLER'S OWN workspace + membership role for the self-mint —
  # never a client-supplied value, never the seeded Default Workspace.
  # `Tenancy.list_workspaces_for/1` is membership-scoped (INNER JOIN on
  # `workspace_memberships`), so a workspace the caller has no membership row
  # in can never come back; a user with no membership anywhere resolves to
  # `{nil, nil}`, which `Auth.create_personal_access_token/3` reads as "mint
  # workspace-less" (no Tenancy.Membership grant). Ordered by slug, so a user
  # in more than one workspace resolves deterministically to the same one on
  # every call.
  defp resolve_caller_workspace(user) do
    case Tenancy.list_workspaces_for(user) do
      [workspace | _rest] -> {workspace.id, TenancyAuth.membership_role(user, workspace.id)}
      [] -> {nil, nil}
    end
  end

  @doc """
  Session management (era-w7): the caller's active sessions — the "your
  devices" list. Marks which one is CURRENT and whether each is step-up-fresh.
  """
  def sessions(conn, _params) do
    user = conn.assigns.current_user
    current = conn.assigns.current_user_session

    sessions =
      user
      |> Accounts.list_user_sessions()
      |> Enum.map(fn s ->
        %{
          id: s.id,
          current: s.id == current.id,
          user_agent: s.user_agent,
          ip_address: s.ip_address,
          created_at: s.inserted_at,
          last_used_at: s.last_used_at,
          mfa_fresh: UserSession.mfa_fresh?(s),
          sso: if(s.saml_org_slug, do: "saml")
        }
      end)

    json(conn, %{sessions: sessions})
  end

  @doc """
  Revoke ONE session by id (self-scoped — another user's session id is 404).
  Revoking the CURRENT session behaves as logout; the revoked bearer stops
  working immediately either way. Audited.
  """
  def revoke_session(conn, %{"id" => id}) do
    user = conn.assigns.current_user
    current = conn.assigns.current_user_session

    case Accounts.revoke_user_session_by_id(user, id) do
      :ok ->
        Audit.emit(%{
          category: "auth",
          action: "session_revoked",
          subject: user.id,
          actor_type: "user",
          actor_id: user.id,
          metadata: %{"session" => id, "current" => id == current.id}
        })

        conn = if id == current.id, do: clear_session(conn), else: conn
        json(conn, %{ok: true, current: id == current.id})

      :not_found ->
        error(conn, 404, "not_found", "no such session")
    end
  end

  def logout(conn, _params) do
    slo_url =
      case bearer_or_cookie(conn) do
        nil ->
          nil

        token ->
          # Capture the session's SAML birth context BEFORE revoking, so a
          # SAML-born logout can hand back the IdP LogoutRequest URL (SLO).
          slo = saml_slo_url(token)
          audit_logout(token)
          Accounts.revoke_user_session_token(token)
          slo
      end

    body = if slo_url, do: %{ok: true, slo_url: slo_url}, else: %{ok: true}

    conn
    |> clear_session()
    |> json(body)
  end

  # SP-initiated Single Logout: when the session was born from a SAML login and
  # the org's IdP has an SLO endpoint, the redirect URL that carries our
  # LogoutRequest to the IdP. The client completes the front channel by sending
  # the browser there. nil for non-SAML sessions or SLO-less connections.
  defp saml_slo_url(token) do
    with {_user, session} <- Accounts.verify_user_session(token),
         %{saml_org_slug: slug, saml_name_id: name_id}
         when is_binary(slug) and is_binary(name_id) <- session,
         c <- Barkpark.Sso.Saml.connection_for_org_slug(slug),
         true <- Barkpark.Sso.Saml.slo_available?(c) do
      Barkpark.Sso.Saml.sp_logout_redirect_url(c, slug, name_id, session.saml_session_index)
    else
      _ -> nil
    end
  end

  # ── Email verification + password reset ─────────────────────────────────────

  def verify_email(conn, %{"token" => token}) do
    case Accounts.confirm_user(token) do
      {:ok, _user} ->
        json(conn, %{ok: true})

      :error ->
        error(
          conn,
          422,
          "invalid_token",
          "the confirmation link is invalid or expired",
          "request a fresh confirmation email — verification links are single-use and time-limited"
        )
    end
  end

  def request_reset(conn, %{"email" => email}) do
    # Always 200 — never reveal whether the email is registered.
    if user = Accounts.get_user_by_email(email) do
      {:ok, token} = Accounts.build_email_token(user, "reset")
      UserNotifier.deliver_reset(user.email, build_url("/auth/reset/", token))
    else
      # CONSENTED: no account behind this address, so there is nobody the reset
      # was withheld FROM. Named rather than silent so the branch is greppable
      # with every other withhold; records nothing, so a probe cannot amplify
      # into writes and a probed address is never persisted.
      NotificationWithhold.record("reset", :no_recipient_by_construction)
    end

    json(conn, %{ok: true})
  end

  @doc """
  Passwordless sign-in — request a magic link. Emails a single-use login link
  if the address maps to a user; ALWAYS returns a generic `{ok: true}` so the
  response never reveals whether the email is registered (anti-enumeration,
  identical to request-reset).
  """
  def request_magic_link(conn, %{"email" => email}) do
    # `build_login_token/1` deliberately returns THREE shapes; a catch-all here
    # used to collapse the last two into one silence, discarding the distinction
    # the context module had just made. A stranger probing an address and a real
    # user whose token mint failed are NOT the same event.
    case Accounts.build_login_token(email) do
      {:ok, token, user} ->
        UserNotifier.deliver_magic_link(user.email, build_url("/auth/magic/", token))

      :no_user ->
        NotificationWithhold.record("magic_link", :no_recipient_by_construction)

      {:error, changeset} ->
        NotificationWithhold.record("magic_link", :dispatch_crashed,
          user_id: Ecto.Changeset.get_field(changeset, :user_id),
          detail: "token_mint_failed"
        )
    end

    json(conn, %{ok: true})
  end

  def request_magic_link(conn, _), do: error(conn, 400, "bad_request", "email is required")

  @doc """
  Passwordless sign-in — complete it. Consumes the single-use magic-link token
  and issues a session. Unknown, already-used, and expired tokens all return
  the same generic `invalid_token` error (no oracle).
  """
  def magic_login(conn, %{"token" => token}) do
    case Accounts.consume_login_token(token) do
      {:ok, user} ->
        issue_session(conn, user)

      :error ->
        error(
          conn,
          401,
          "invalid_token",
          "this sign-in link is invalid or has expired",
          "request a fresh sign-in link and use it promptly"
        )
    end
  end

  def magic_login(conn, _), do: error(conn, 400, "bad_request", "token is required")

  def reset(conn, %{"token" => token, "password" => password}) do
    case Accounts.reset_user_password_counting(token, %{password: password}) do
      {:ok, user, sessions_revoked} ->
        # A token-based reset revokes every session ("sign out everywhere") and,
        # on the recovery path, wipes MFA — a high-value account-recovery event
        # worth recording on the tamper-evident trail. `sessions_revoked` is the
        # COUNT the revoke actually stamped, carried from
        # Accounts.revoke_all_user_sessions/1 — the receipt reports the number
        # rather than re-asserting the claim (PDS-D503).
        audit(%{
          category: "auth",
          action: "password_reset",
          subject: user.id,
          actor_type: "user",
          actor_id: user.id,
          metadata: %{"via" => "reset_token", "sessions_revoked" => sessions_revoked}
        })

        json(conn, %{ok: true, sessionsRevoked: sessions_revoked})

      {:error, cs} ->
        error(conn, 422, "invalid_password", changeset_errors(cs))

      :error ->
        error(
          conn,
          422,
          "invalid_token",
          "the reset link is invalid or expired",
          "request a new reset link with request-reset — reset links are single-use and time-limited"
        )
    end
  end

  # ── TOTP MFA enrolment ───────────────────────────────────────────────────────

  # MEDIUM-8: re-auth on enrol. Even behind a live session, minting a new MFA
  # secret requires the current password — a stolen/forgotten-unlocked session
  # cannot silently bootstrap attacker-controlled MFA.
  def mfa_enroll(conn, %{"password" => password}) do
    user = conn.assigns.current_user

    if reauthed?(user, password) do
      secret = Accounts.totp_secret()
      uri = Accounts.totp_uri(user, secret)

      json(conn, %{
        secret: Base.encode32(secret, padding: false),
        otpauth_uri: uri,
        qr_svg: uri |> EQRCode.encode() |> EQRCode.svg()
      })
    else
      error(conn, 403, "reauth_required", "the current password is required")
    end
  end

  def mfa_enroll(conn, _),
    do: error(conn, 403, "reauth_required", "the current password is required")

  # MEDIUM-8: re-auth on verify too — the step that actually persists the secret.
  def mfa_verify(conn, %{"secret" => secret_b32, "code" => code, "password" => password}) do
    user = conn.assigns.current_user

    cond do
      not reauthed?(user, password) ->
        error(conn, 403, "reauth_required", "the current password is required")

      true ->
        with {:ok, secret} <- decode_secret(secret_b32),
             {:ok, _user, recovery_codes} <- Accounts.enable_totp(user, secret, code) do
          # The user just proved a live TOTP — mark THIS session fresh so a
          # sensitive action right after enrolling isn't immediately challenged.
          maybe_stamp_step_up(conn)

          Audit.emit(%{
            category: "auth",
            action: "mfa_enrolled",
            subject: user.id,
            actor_type: "user",
            actor_id: user.id,
            metadata: %{"factor" => "totp"}
          })

          json(conn, %{ok: true, recovery_codes: recovery_codes})
        else
          _ ->
            error(
              conn,
              422,
              "invalid_code",
              "the TOTP code did not match the secret",
              "codes rotate every 30s — re-read the current code from your authenticator and retry"
            )
        end
    end
  end

  # Secret + code present but no password → the re-auth gate, not a code problem.
  def mfa_verify(conn, %{"secret" => _, "code" => _}),
    do: error(conn, 403, "reauth_required", "the current password is required")

  def mfa_verify(conn, _),
    do: error(conn, 422, "invalid_code", "secret, code and password are required")

  # MEDIUM-8: an MFA-disable route, session-gated AND password-gated. Without
  # this, a user (or admin recovering a hijacked account) had no way to drop MFA
  # short of a full password reset.
  def mfa_disable(conn, %{"password" => password}) do
    user = conn.assigns.current_user

    if reauthed?(user, password) do
      {:ok, _user} = Accounts.disable_totp(user)

      Audit.emit(%{
        category: "auth",
        action: "mfa_disabled",
        subject: user.id,
        actor_type: "user",
        actor_id: user.id,
        metadata: %{}
      })

      json(conn, %{ok: true})
    else
      error(conn, 403, "reauth_required", "the current password is required")
    end
  end

  def mfa_disable(conn, _),
    do: error(conn, 403, "reauth_required", "the current password is required")

  @doc """
  Step-up MFA — present a current TOTP or one-time recovery code to mark THIS
  session fresh for sensitive actions (the step-up window). This is how a client
  clears a `mfa_required` (401) challenge before retrying the guarded action.
  Emits an `auth/mfa_passed` or `auth/mfa_failed` audit event either way.
  """
  def mfa_step_up(conn, %{"code" => code}) when is_binary(code) do
    user = conn.assigns.current_user
    session = conn.assigns.current_user_session

    case Accounts.verify_step_up(user, code) do
      {:ok, _user, factor} ->
        {:ok, session} = Accounts.stamp_session_mfa(session)

        Audit.emit(%{
          category: "auth",
          action: "mfa_passed",
          subject: user.id,
          actor_type: "user",
          actor_id: user.id,
          metadata: %{"factor" => to_string(factor)}
        })

        json(conn, %{
          ok: true,
          factor: factor,
          fresh_until:
            DateTime.add(session.mfa_verified_at, UserSession.default_step_up_window(), :second)
        })

      :error ->
        Audit.emit(%{
          category: "auth",
          action: "mfa_failed",
          subject: user.id,
          actor_type: "user",
          actor_id: user.id,
          metadata: %{"context" => "step_up"}
        })

        error(
          conn,
          422,
          "invalid_code",
          "the MFA code did not match",
          "use a current TOTP code or an unused recovery code, then retry"
        )
    end
  end

  def mfa_step_up(conn, _), do: error(conn, 422, "invalid_code", "a code is required")

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp issue_session(conn, user, opts \\ []),
    do: BarkparkWeb.SessionIssuer.issue(conn, user, opts)

  # Verify the current password for a session-authenticated, sensitive action.
  defp reauthed?(user, password) when is_binary(password),
    do: Barkpark.Accounts.User.valid_password?(user, password)

  defp reauthed?(_user, _), do: false

  # Mark the current session MFA-fresh after a live factor was proven inline
  # (enrolment verify). No-op if the session isn't on the conn (bearer flows
  # without a resolved session record).
  defp maybe_stamp_step_up(conn) do
    case conn.assigns[:current_user_session] do
      %UserSession{} = session -> Accounts.stamp_session_mfa(session)
      _ -> :noop
    end
  end

  # MEDIUM-7: the single registration-accepted shape, reused by the fresh-signup
  # and duplicate-email paths so they're byte-identical to the caller.
  defp registration_accepted(conn, email) do
    conn
    |> put_status(:created)
    |> json(%{user: %{email: email, confirmed: false}})
  end

  # True iff the changeset carries the "email already registered" signal (a unique
  # collision). This is the existence oracle that MEDIUM-7 must never surface to a
  # caller — regardless of whether it co-occurs with a genuine error (the weak-
  # password probe: unsafe_validate_unique still runs when only :password is bad).
  defp email_taken?(%Ecto.Changeset{errors: errors}),
    do: Enum.any?(errors, &email_taken_error?/1)

  defp email_taken_error?({:email, {_msg, opts}}),
    do: opts[:validation] == :unsafe_unique or opts[:constraint] == :unique

  defp email_taken_error?(_), do: false

  # Serialize the changeset's errors WITH the email-uniqueness signal removed, so
  # the 422 body can never reveal account existence. A legitimate :email *format*
  # error is preserved (it carries no existence information).
  defp errors_without_email_signal(changeset) do
    filtered = Enum.reject(changeset.errors, &email_taken_error?/1)
    %{changeset | errors: filtered} |> changeset_errors()
  end

  defp notify_existing_account(email) do
    if user = Accounts.get_user_by_email(email) do
      UserNotifier.deliver_already_registered(user.email)
    else
      # Defensive: this helper only runs when the changeset said the address IS
      # taken, so the account should exist. If it does not, there is nobody to
      # notify — consented, and named rather than silent.
      NotificationWithhold.record("already_registered", :no_recipient_by_construction)
    end

    :ok
  end

  defp send_confirmation(user) do
    case Accounts.build_email_token(user, "confirm") do
      {:ok, token} ->
        UserNotifier.deliver_confirmation(user.email, build_url("/auth/confirm/", token))

      {:error, _changeset} ->
        # The account was just created and the caller is about to return a
        # generic 201. Without this the registration succeeds, no confirmation
        # email is ever sent, and nothing anywhere records it — the account is
        # unconfirmable and the user was told it worked. Narrow (the reachable
        # cause is assoc_constraint(:user), i.e. the row vanished mid-flight)
        # but silent, which is the part that made it unfixable.
        NotificationWithhold.record("confirmation", :dispatch_crashed,
          user_id: user.id,
          detail: "token_mint_failed"
        )
    end
  end

  defp decode_secret(b32) do
    case Base.decode32(b32, padding: false) do
      {:ok, secret} -> {:ok, secret}
      :error -> :error
    end
  end

  defp bearer_or_cookie(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw] -> String.trim(raw)
      _ -> get_session(conn, "user_session")
    end
  end

  # Self-service logout. Resolve the owning user (best-effort — a stale/invalid
  # bearer yields a nil subject rather than failing the logout) so the event is
  # attributed, then record it. Emitted BEFORE the token is revoked so the
  # session still resolves; the revoke itself is what actually signs the user out.
  defp audit_logout(token) do
    subject =
      case Accounts.verify_user_session(token) do
        {%{id: id}, _session} -> id
        _ -> nil
      end

    audit(%{
      category: "auth",
      action: "logout",
      subject: subject,
      actor_type: "user",
      actor_id: subject,
      metadata: %{}
    })
  end

  # Best-effort audit emit: an audit-bus hiccup must never break the auth flow
  # it accompanies (the state change has already committed). Result discarded,
  # infra raise/throw swallowed — mirrors the isolation of other emit producers.
  defp audit(attrs) do
    Audit.emit(attrs)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp build_url(path, token), do: BarkparkWeb.Endpoint.url() <> path <> token

  defp error(conn, status, code, message, hint \\ nil) do
    error_map = %{code: code, message: message}
    error_map = if hint, do: Map.put(error_map, :hint, hint), else: error_map

    conn
    |> put_status(status)
    |> json(%{error: error_map})
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
  end
end
