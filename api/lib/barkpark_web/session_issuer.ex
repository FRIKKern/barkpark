defmodule BarkparkWeb.SessionIssuer do
  @moduledoc """
  The single place a user login turns into a session response. Mints a session
  token, sets the signed `user_session` cookie (browser) alongside the bearer in
  the body (API/JS), and 201s. Shared by password login (`AuthController`) and
  passkey login (`WebauthnController`) so both mint identically — including the
  `mfa_verified: true` freshness stamp when a strong factor was presented.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Barkpark.Accounts

  @doc """
  Issue a session for `user` and render the standard login response. `opts` are
  forwarded to `Accounts.create_user_session_token/2` (e.g. `mfa_verified: true`).
  """
  @spec issue(Plug.Conn.t(), Accounts.User.t(), keyword()) :: Plug.Conn.t()
  def issue(conn, user, opts \\ []) do
    {:ok, token} =
      Accounts.create_user_session_token(user, actor_opts(conn) ++ opts)

    audit_session_mint(user, opts)

    conn
    |> configure_session(renew: true)
    |> put_session("user_session", token)
    |> put_status(:created)
    |> json(login_body(token, user))
  end

  # era-w2-org-require-mfa: when a governing org requires MFA and the user has
  # no factor, login still SUCCEEDS (the session is how they enrol) but the
  # body carries `mfa_enrolment_required: true` so clients route straight to
  # enrolment. The key is ADDITIVE and only present when true — with no org
  # requiring MFA the response is byte-identical to before.
  defp login_body(token, user) do
    if org_mfa_enrolment_blocked?(user) do
      %{token: token, user: %{id: user.id, email: user.email}, mfa_enrolment_required: true}
    else
      %{token: token, user: %{id: user.id, email: user.email}}
    end
  end

  @doc """
  Is `user` held to org-MFA enrolment — governed by a `require_mfa` org
  (`Barkpark.Tenancy.org_requires_mfa_for_user?/1`, ANY-org-requires →
  enforce) with NO factor enrolled? The ONE predicate every session-mint
  chokepoint shares (era-w8-sso-mfa-binding): password/magic login flags the
  session, the SSO callbacks refuse to mint, and the LiveView `on_mount`
  hook refuses to mount.
  """
  @spec org_mfa_enrolment_blocked?(Accounts.User.t()) :: boolean()
  def org_mfa_enrolment_blocked?(%Accounts.User{} = user) do
    not Accounts.mfa_enrolled?(user) and
      Barkpark.Tenancy.org_requires_mfa_for_user?(user.id)
  end

  @doc """
  Refuse an SSO session-mint for a governed factor-less user
  (era-w8-sso-mfa-binding). Audits the block, then forks on the caller: a
  browser (Accept: text/html) is redirected to `/login` with enrolment
  guidance — never landed in Studio; an API caller gets the SAME
  `403 mfa_enrolment_required` envelope `RequireOrgMfaEnrolment` emits, so
  clients handle one shape. No session token is created on this path —
  unlike `POST /v1/auth/login`, an IdP redirect has no enrolment story that
  needs the session, so the SSO door fails closed.
  """
  @spec deny_org_mfa_enrolment(Plug.Conn.t(), Accounts.User.t(), String.t(), binary() | nil) ::
          Plug.Conn.t()
  def deny_org_mfa_enrolment(conn, %Accounts.User{} = user, provider, org_id \\ nil) do
    Barkpark.Audit.emit(%{
      category: "auth",
      action: "mfa_enrolment_required",
      subject: user.id,
      actor_type: "user",
      actor_id: user.id,
      metadata: %{
        "reason" => "org_require_mfa",
        "provider" => provider,
        "organization_id" => org_id,
        "path" => conn.request_path
      }
    })

    if browser?(conn) do
      conn
      |> Phoenix.Controller.fetch_flash()
      |> Phoenix.Controller.put_flash(:error, org_mfa_enrolment_message())
      |> Phoenix.Controller.redirect(to: "/login")
    else
      conn
      |> put_status(403)
      |> json(%{
        error: %{
          code: "mfa_enrolment_required",
          message: "an organization you belong to requires MFA — enrol a factor to continue",
          hint:
            "enrol TOTP via POST /v1/auth/mfa/enroll + /verify, or a passkey via " <>
              "POST /v1/auth/webauthn/register/challenge + /register, then retry"
        }
      })
    end
  end

  @doc """
  Is `user` refused THIS authentication method by org policy
  (era-bl-allowed-auth-methods)? The twin of `org_mfa_enrolment_blocked?/1`
  and, like it, the ONE predicate every session-mint chokepoint shares:
  password + magic-link login (API and browser) and passkey login consult it
  before a token is ever created.

  `false` — the zero-tax answer — whenever no governing org set an
  allow-list, so an ordinary org's login path is unchanged.
  """
  @spec auth_method_blocked?(Accounts.User.t(), String.t()) :: boolean()
  def auth_method_blocked?(%Accounts.User{} = user, method) when is_binary(method) do
    not Barkpark.Tenancy.auth_method_allowed_for_user?(user.id, method)
  end

  @doc """
  Refuse a session-mint whose METHOD the user's org policy disallows
  (era-bl-allowed-auth-methods). Audits the block, then forks on the caller
  exactly like `deny_org_mfa_enrolment/4`: a browser (Accept: text/html) is
  redirected to `/login` with guidance, an API caller gets a
  `403 auth_method_not_allowed` envelope.

  403, not 401, and NOT the generic `invalid_credentials` 401: the credentials
  were CORRECT and the refusal is a policy decision the user must be told
  about, or they retype a working password forever. The check runs only AFTER
  the credential verified, so the refusal reveals nothing about an address
  that has no account.

  `provider` is the PRECISE door for the audit trail when it is finer-grained
  than the policy term — `"social:google"` gates on the coarse `"social"`
  method but is recorded exactly, so a reader of the trail can tell which
  provider was refused. Defaults to `method`.

  No session token exists on this path — the door fails closed.
  """
  @spec deny_auth_method(Plug.Conn.t(), Accounts.User.t(), String.t(), String.t() | nil) ::
          Plug.Conn.t()
  def deny_auth_method(conn, %Accounts.User{} = user, method, provider \\ nil)
      when is_binary(method) do
    allowed = Barkpark.Tenancy.org_allowed_auth_methods_for_user(user.id)

    Barkpark.Audit.emit(%{
      category: "auth",
      action: "auth_method_not_allowed",
      subject: user.id,
      actor_type: "user",
      actor_id: user.id,
      metadata: %{
        "reason" => "org_allowed_auth_methods",
        "method" => method,
        "provider" => provider || method,
        "allowed" => allowed,
        "path" => conn.request_path
      }
    })

    if browser?(conn) do
      conn
      |> Phoenix.Controller.fetch_flash()
      |> Phoenix.Controller.put_flash(:error, auth_method_message(method))
      |> Phoenix.Controller.redirect(to: "/login")
    else
      conn
      |> put_status(403)
      |> json(%{
        error: %{
          code: "auth_method_not_allowed",
          message: auth_method_message(method),
          hint: auth_method_hint(allowed)
        }
      })
    end
  end

  @doc "The human-facing refusal shared by the API and browser doors."
  @spec auth_method_message(String.t()) :: String.t()
  def auth_method_message(method) do
    "#{method_label(method)} is disabled for your organization."
  end

  # The hint names what IS open rather than assuming SSO is the answer — an
  # org can equally have disabled SSO and left password on, and a hint that
  # said "use single sign-on" there would send the member to a closed door.
  # The user is past their credential check at this point, so naming their own
  # org's allowed methods reveals nothing they could not already probe.
  defp auth_method_hint([]),
    do: "no sign-in method is currently permitted — contact your organization's administrator"

  defp auth_method_hint(allowed) when is_list(allowed) do
    "permitted sign-in method(s) for your organization: " <> Enum.join(allowed, ", ")
  end

  defp auth_method_hint(_), do: "contact your organization's administrator"

  defp method_label("password"), do: "Password sign-in"
  defp method_label("magic_link"), do: "Magic-link sign-in"
  defp method_label("passkey"), do: "Passkey sign-in"
  defp method_label("sso"), do: "Single sign-on"
  defp method_label("social"), do: "Social sign-in"
  defp method_label(other), do: "#{other} sign-in"

  @doc "The human-facing org-MFA enrolment guidance shared by the browser doors."
  @spec org_mfa_enrolment_message() :: String.t()
  def org_mfa_enrolment_message do
    "Your organization requires MFA. Enrol a factor first " <>
      "(POST /v1/auth/mfa/enroll or `bp auth mfa enroll`), then sign in again."
  end

  # A browser's form POST / redirect chain advertises text/html; API clients
  # (interop suite, SDKs) don't — they keep the JSON contract.
  defp browser?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/html"))
  end

  # Record the successful session mint on the tamper-evident audit trail. This
  # is the shared choke point for the interactive login paths (password + magic
  # link via AuthController, passkey via WebauthnController), so every one of
  # them lands a `session_minted` event identically. `mfa_verified` marks the
  # session as born strong-factor-fresh. Best-effort + fully isolated: an audit
  # hiccup must never fail the login that already succeeded.
  defp audit_session_mint(user, opts) do
    Barkpark.Audit.emit(%{
      category: "auth",
      action: "session_minted",
      subject: user.id,
      actor_type: "user",
      actor_id: user.id,
      metadata: %{"mfa_verified" => Keyword.get(opts, :mfa_verified, false)}
    })

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  The actor-identity opts EVERY session mint stamps on its row.

  One definition for all six mint sites (this module, both arms of
  `SessionController`, and the OIDC / SAML / social callbacks). Each of them
  used to carry its own byte-identical `user_agent/1` next to its own
  `client_ip/1` — and the `client_ip/1` copies all read `conn.remote_ip`
  directly, which behind the co-located Caddy is ALWAYS the loopback hop. Every
  `user_sessions.ip_address` therefore recorded the proxy, identical for every
  user on the box, while looking entirely valid.

  The address now comes from `Barkpark.RateLimiter.client_ip_with_source/1` —
  the canonical `rate-limit-client-ip` resolver — which walks
  `x-forwarded-for` RIGHT-to-left past trusted hops and falls back to the
  verified peer. Crucially it does NOT read the header's leftmost value: that
  would replace a useless-but-honest address with a FORGEABLE one, and a
  forgeable audit trail is worse than a uniform one, because it gets believed.

  `ip_source` records which of the two the row holds, so a reader can tell a
  derived client address from a raw peer.
  """
  @spec actor_opts(Plug.Conn.t()) :: keyword()
  def actor_opts(conn) do
    {ip, source} = Barkpark.RateLimiter.client_ip_with_source(conn)

    [ip_address: ip, ip_source: Atom.to_string(source), user_agent: user_agent(conn)]
  end

  defp user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      _ -> nil
    end
  end
end
