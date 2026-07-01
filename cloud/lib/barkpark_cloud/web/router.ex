defmodule BarkparkCloud.Web.Router do
  @moduledoc """
  The control-plane HTTP API (cloud-12a) — a minimal JSON `Plug.Router` over the
  Accounts / Registry / Billing contexts. Deliberately NOT Phoenix/LiveView: this
  is the callable JSON surface the agent (cloud-10) POSTs to, the Go CLI client
  (cloud-12b) calls, and the live dashboard (served by this app, SSE-pushed via
  `GET /v1/events`) consumes.

  ## Route table

      METHOD  PATH                 AUTH      PURPOSE
      GET     /up                  —         control-plane liveness (200 db up | 503 db down)
      GET     /health              —         alias of /up
      POST    /v1/auth/login       —         email+password → {token, team_id} | {two_factor_required, challenge_token}
      POST    /v1/auth/two-factor-challenge — challenge_token + code/recovery_code → {token, team_id}
      GET     /v1/auth/oauth/providers           —  enabled OAuth providers (SPA buttons)
      GET     /v1/auth/oauth/:provider           —  302 → IdP authorize URL (signed, single-use state)
      GET     /v1/auth/oauth/:provider/callback  —  exchange → session → 302 /#oauth=<token>&team=<id>
      DELETE  /v1/auth/logout      user      revoke the calling session token
      POST    /v1/account/two-factor/enroll user   start TOTP enroll → {otpauth_uri, secret}
      POST    /v1/account/two-factor/confirm user  {code} → {recovery_codes} (2FA on)
      GET     /v1/account/two-factor user   {enabled: bool}
      DELETE  /v1/account/two-factor user   disable 2FA → {ok: true}
      POST    /v1/account/two-factor/recovery-codes user  regenerate → {recovery_codes}
      POST    /v1/auth/verify-email        —     {token} → confirm the account (single-use)
      POST    /v1/auth/resend-verification user  re-send the confirm mail (always 200)
      POST    /v1/account/email/change     user  {new_email} → stage + email a 6-digit code
      POST    /v1/account/email/confirm    user  {code} → swap email + Stripe sync
      GET     /v1/me               user      {user{id,email,confirmed,two_factor_enabled}, team{id,name,slug}}
      GET     /v1/account/sessions         user  list live sessions (current flagged)
      DELETE  /v1/account/sessions/:id     user  revoke one session by id (own only)
      DELETE  /v1/account/sessions         user  sign out everywhere except this tab
      PUT     /v1/account/password         user  change password ⇒ sign out everywhere
      GET     /v1/subscription     user      {subscription | nil} — current plan
      GET     /v1/events           user*     Server-Sent-Events live stream (*token= or Bearer)
      POST    /v1/agent/report     agent     land a health report (health + events)
      GET     /v1/agent/commands   agent     approved-command queue (empty for now)
      POST    /v1/agent/results    agent     ack command results
      GET     /v1/barkparks        user      the team's registered Barkparks (+provision_status)
      GET     /v1/audit            admin     the team's append-only audit trail (keyset-paginated)
      DELETE  /v1/barkparks/:id    user      remove an instance (deregister; live box → 409)
      GET     /v1/barkparks/:id/events user  the instance's agent-event history (team-scoped)
      POST    /v1/barkparks/:id/retry user   re-enqueue a FAILED provision
      GET     /v1/barkparks/:id/credentials admin  reveal the per-instance admin token (team-admin only)
      GET     /v1/providers        user      the team's connected cloud providers
      POST    /v1/providers        user      connect a cloud provider
      GET     /v1/env-vars         user      the team's env vars (masked, values NEVER returned)
      POST    /v1/env-vars         user      create/update an env var (owner/admin)
      DELETE  /v1/env-vars/:id     user      delete an env var (owner/admin)
      GET     /v1/notifications/settings  user the team's email-notification settings (secrets masked)
      PUT     /v1/notifications/settings  user update transport / per-event toggles / SMTP secrets
      POST    /v1/notifications/test      user send a rate-limited test email
      GET     /v1/tokens           user(s)   list the caller's Personal Access Tokens
      POST    /v1/tokens           user(s)   mint a PAT → {token: <plaintext ONCE>, pat}
      DELETE  /v1/tokens/:id       user(s)   revoke a PAT (own only) → {ok:true} | 404
      POST    /v1/billing/checkout user      open a hosted Checkout Session → {checkout_url}
      POST    /v1/billing/webhook  —*        Stripe events (signature-verified, raw body)
      POST    /v1/launch           user      go-live (alias of /v1/go-live)
      POST    /v1/go-live          user      gate on active subscription + create a provisioning Barkpark
      POST    /v1/internal/provision-jobs/claim       worker  claim oldest pending job
      POST    /v1/internal/provision-jobs/:id/succeed worker  flip barkpark up at {ip} (+ optional encrypted admin_token)
      POST    /v1/internal/provision-jobs/:id/fail    worker  mark job failed {error}
      POST    /v1/sites            user      create a hosted Site under a Barkpark
      GET     /v1/sites            user      list the team's sites (across all boxes)
      GET     /v1/sites/:id        user      one site
      POST    /v1/sites/:id/deploy user      enqueue a Deployment (the build job)
      GET     /v1/sites/:id/deployments user list a site's deployments, newest first
      POST    /v1/sites/:id/artifact user    upload tarball (octet-stream) → file:// URL
      POST    /v1/sites/:id/env    user      replace the encrypted env blob
      POST    /v1/sites/:id/domains user     add a domain to a site
      POST    /v1/sites/:id/github  user     link a GitHub repo + branch + webhook secret
      POST    /v1/webhooks/github/:site_id —  GitHub push → enqueue Deployment (HMAC)
      GET     /v1/tls/ask          —         on-demand-TLS gate (200/404 by domain)
      POST    /v1/builder/claim    user      atomic next-queued deployment claim
      POST    /v1/builder/deployments/:id/transition user fenced status update
      GET     /v1/agent/pending    agent     deployments in pushing for this box
      POST    /v1/agent/deployments/claim agent atomic pickup of the next pushing
      POST    /v1/agent/deployments/:id/transition agent fenced live transition
      *       (anything else)      —         404 JSON

  Every response is JSON. Errors are `{"error": "<reason>"}`. The agent routes
  authenticate with an AGENT token (`Registry.verify_agent_token`); the user
  routes with a USER session token (`Accounts.verify_user_session_token`); the
  internal `/v1/internal/*` routes with the shared WORKER token (`require_worker`
  — Bearer WORKER_TOKEN, never a user/agent token) — all via
  `BarkparkCloud.Web.Auth`.
  """
  use Plug.Router
  require Logger

  alias BarkparkCloud.{Accounts, Billing, Events, Notifications, OAuth, Registry, Repo}
  alias BarkparkCloud.Accounts.{Team, TwoFactorRateLimiter, UserToken}
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Web.Auth

  # The dashboard SPA (plain HTML+CSS+JS, no build step) is served straight from
  # priv/static. This runs BEFORE :match so a real asset short-circuits the
  # router; `only:` is an explicit allowlist that DELIBERATELY excludes "v1" so
  # the JSON API can never be shadowed by a same-named file — every /v1/* request
  # falls through to the matchers below. A missing asset (e.g. no favicon.ico)
  # just falls through too. priv/ ships in the OTP release by default, so
  # `from: :barkpark_cloud` resolves the same in dev and prod.
  plug(Plug.Static,
    at: "/",
    from: :barkpark_cloud,
    only: ~w(index.html app.css app.js favicon.ico)
  )

  plug(:match)

  # `application/octet-stream` is passed through unparsed: the artifact upload
  # route reads the raw binary body itself with Plug.Conn.read_body so a 100 MB
  # tarball never gets JSON-decoded (or memory-buffered by the parser).
  #
  # `body_reader: {__MODULE__, :cache_raw_body, []}` stashes the unmodified
  # bytes on `conn.assigns[:raw_body]` for the HMAC-verifying webhook paths
  # (Stripe billing + GitHub push) so signature checks see the EXACT bytes the
  # sender signed — the parsed JSON map is not stable enough (key order,
  # whitespace, anything would break the HMAC). Non-webhook paths skip the
  # cache (no needless buffering). The same function handles both webhooks.
  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json", "application/octet-stream"],
    body_reader: {__MODULE__, :cache_raw_body, []},
    json_decoder: Jason
  )

  plug(:dispatch)

  @raw_body_paths ["/v1/billing/webhook"]
  @raw_body_path_prefixes ["/v1/webhooks/github/"]

  @doc """
  A `Plug.Parsers` `:body_reader` that caches the RAW request body on
  `conn.assigns[:raw_body]` for HMAC-verifying webhook paths (Stripe billing +
  GitHub push), then returns those same bytes so the JSON parser still runs.
  Every other path falls through to the default reader with no buffering.
  """
  def cache_raw_body(conn, opts) do
    if needs_raw_body?(conn.request_path) do
      {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
      {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
    else
      Plug.Conn.read_body(conn, opts)
    end
  end

  defp needs_raw_body?(path) do
    path in @raw_body_paths or
      Enum.any?(@raw_body_path_prefixes, &String.starts_with?(path, &1))
  end

  ## Dashboard SPA — GET / and GET /dashboard serve the single-page app.
  ##
  ## Plug.Static (above) handles the named assets (/index.html, /app.css,
  ## /app.js); these two routes serve the SPA shell at the bare root and at
  ## /dashboard so a deep-link or a refresh on either lands the HTML (the SPA
  ## then routes client-side on the hash). The JSON API lives entirely under
  ## /v1/*, so this never collides with it.

  get("/", do: send_dashboard(conn))
  get("/dashboard", do: send_dashboard(conn))

  ## Stripe Checkout returns the customer to the SPA root with a ?checkout=
  ## success|cancel flag (see Billing.StripeGateway / #282) — no dedicated route
  ## is needed since "/" already serves the SPA and it's hash-routed. app.js
  ## reads the query flag, shows the right state, and refetches the now-active
  ## subscription (the webhook activates it server-side; SSE also pushes a
  ## "subscription" event the moment it lands).

  defp send_dashboard(conn) do
    path = Application.app_dir(:barkpark_cloud, "priv/static/index.html")

    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, path)
  end

  ## Auth — POST /v1/auth/login {email, password}
  ##   → 200 {token, team_id}                          — non-2FA user, logged in
  ##   → 200 {two_factor_required: true, challenge_token} — 2FA user, step two
  ##   → 401 {error: "invalid_credentials"}
  ##
  ## two-factor-auth: the non-2FA response shape is UNCHANGED ({token, team_id}),
  ## so existing clients/tests keep working. A user with confirmed 2FA gets a
  ## short-lived challenge_token instead of a session — they must clear
  ## POST /v1/auth/two-factor-challenge to upgrade it into a real session.

  post "/v1/auth/login" do
    email = conn.body_params["email"]
    password = conn.body_params["password"]

    with true <- is_binary(email) and is_binary(password),
         %{} = user <- Accounts.get_user_by_email_and_password(email, password) do
      if Accounts.two_factor_enabled?(user) do
        {:ok, pending} = Accounts.create_two_factor_pending_token(user)
        json(conn, 200, %{two_factor_required: true, challenge_token: pending})
      else
        {:ok, token} = Accounts.create_user_session_token(user, session_opts(conn))
        team = Accounts.primary_team(user)
        json(conn, 200, %{token: token, team_id: team && team.id})
      end
    else
      _ -> json(conn, 401, %{error: "invalid_credentials"})
    end
  end

  ## two-factor-auth — POST /v1/auth/two-factor-challenge
  ##   body {challenge_token, code} OR {challenge_token, recovery_code}
  ##   → 200 {token, team_id}        — OTP/recovery accepted; full session minted
  ##   → 401 {error: "invalid_code"} — bad token, bad OTP, or unknown recovery code
  ##   → 429 {error: "rate_limited"} — >5 attempts/min for this pending user
  ##
  ## Step two of the two-phase login. The challenge_token is the 2fa-pending
  ## token from /v1/auth/login; a correct OTP or an unused recovery code swaps it
  ## for a real session token (same {token, team_id} shape login returns for a
  ## non-2FA user). The minted session records device metadata via
  ## session_opts(conn), exactly like the non-2FA path. The rate limiter mirrors
  ## Coolify's 5/min on this challenge.

  post "/v1/auth/two-factor-challenge" do
    pending = conn.body_params["challenge_token"]
    code = conn.body_params["code"]
    recovery = conn.body_params["recovery_code"]

    case is_binary(pending) and Accounts.verify_two_factor_pending_token(pending) do
      %{} = user ->
        case TwoFactorRateLimiter.check(user.id) do
          {:error, :rate_limited} ->
            json(conn, 429, %{error: "rate_limited"})

          :ok ->
            ok? =
              cond do
                is_binary(code) and code != "" ->
                  Accounts.verify_two_factor_otp(user, code)

                is_binary(recovery) and recovery != "" ->
                  match?({:ok, _}, Accounts.consume_recovery_code(user, recovery))

                true ->
                  false
              end

            if ok? do
              Accounts.delete_two_factor_pending_tokens(user)
              {:ok, token} = Accounts.create_user_session_token(user, session_opts(conn))
              team = Accounts.primary_team(user)
              json(conn, 200, %{token: token, team_id: team && team.id})
            else
              json(conn, 401, %{error: "invalid_code"})
            end
        end

      _ ->
        json(conn, 401, %{error: "invalid_code"})
    end
  end

  ## Auth — POST /v1/auth/register {email, password, team_name?}
  ##   → 201 {token, team_id} (user created + a team + an owner membership + a
  ##     session token; the caller is logged in immediately, exactly like login)
  ##   → 409 {error: "email_taken"}              (email already registered)
  ##   → 422 {error: "<field>_invalid"|..., details?}  (changeset rejection)
  ##
  ## The whole user→team→membership→token chain runs inside ONE Repo.transaction
  ## (`register/3` below), so a half-way failure rolls back — no orphan user or
  ## team is ever left behind. The duplicate-email check runs BEFORE the insert,
  ## and the citext unique index is the race backstop (a unique-violation on the
  ## email maps to 409, never a 500). YAGNI: no email verification, no captcha,
  ## no rate-limiter — rate-limiting this unauthenticated endpoint is a deploy
  ## concern (a fronting proxy / WAF rule), not application logic.
  post "/v1/auth/register" do
    email = conn.body_params["email"]
    password = conn.body_params["password"]
    team_name = conn.body_params["team_name"]

    with true <- is_binary(email) and is_binary(password),
         nil <- Accounts.get_user_by_email(email) do
      case register(email, password, team_name, session_opts(conn)) do
        {:ok, %{token: token, team: team}} ->
          json(conn, 201, %{token: token, team_id: team.id})

        {:error, :email_taken} ->
          json(conn, 409, %{error: "email_taken"})

        {:error, %Ecto.Changeset{} = changeset} ->
          json(conn, 422, register_error(changeset))
      end
    else
      false -> json(conn, 422, %{error: "validation_failed"})
      %{} -> json(conn, 409, %{error: "email_taken"})
    end
  end

  ## Auth — POST /v1/auth/request-reset {email} → 200 {ok: true} (ALWAYS)
  ##
  ## Forgot-password step 1. ENUMERATION-SAFE: answers 200 whether or not the
  ## email is registered, so a probe can't learn which addresses have accounts.
  ## When a user matches, a single-use reset token is minted and the reset LINK is
  ## EMAILED — never returned in the response. (Contrast the invite flow, which
  ## hands the accept token back in `accept_url` for copy-paste: a reset link in
  ## the HTTP body would let anyone reset anyone's password by calling this.)
  ## YAGNI: rate-limiting is a fronting-proxy/WAF concern, as for login/register.
  post "/v1/auth/request-reset" do
    email = conn.body_params["email"]

    # Best-effort: a mailer/DB hiccup must not change the response (still 200) or
    # leak via timing of a 500 — the user is told "check your email" regardless.
    if is_binary(email) do
      case Accounts.request_password_reset(email) do
        {:ok, {user, raw_token}} ->
          _ = Notifications.deliver_password_reset(user.email, reset_url(conn, raw_token))
          :ok

        _ ->
          :ok
      end
    end

    json(conn, 200, %{ok: true})
  end

  ## Auth — POST /v1/auth/reset {token, password} → 200 {ok: true}
  ##   → 401 {error: "invalid_token"}            (no live/single-use token; also replay/expiry)
  ##   → 422 {error: "password_invalid", ...}    (new password too short/weak)
  ##
  ## Forgot-password step 2. Proving control of the emailed token IS the auth, so
  ## no current password is required. On success the user is signed out everywhere
  ## (sessions + agent tokens revoked in `reset_password_by_token/2`); the client
  ## then sends them to log in fresh with the new password.
  post "/v1/auth/reset" do
    token = conn.body_params["token"]
    password = conn.body_params["password"]

    with true <- is_binary(token) and is_binary(password),
         {:ok, _user} <- Accounts.reset_password_by_token(token, password) do
      json(conn, 200, %{ok: true})
    else
      false -> json(conn, 422, %{error: "validation_failed"})
      {:error, :invalid_token} -> json(conn, 401, %{error: "invalid_token"})
      {:error, %Ecto.Changeset{} = changeset} -> json(conn, 422, register_error(changeset))
    end
  end

  ## OAuth / SSO (oauth-sso) — "Continue with GitHub / Google".
  ##
  ## Three UNAUTHENTICATED routes (they PRECEDE a session, exactly like
  ## /v1/auth/login). The flow is cookieless: a stateless HMAC-signed, SINGLE-USE
  ## `state` guards CSRF + replay, and the final session token rides back on the
  ## URL FRAGMENT (never the query — a fragment stays out of access logs /
  ## Referer), where app.js's bootstrap reads it into setSession. See
  ## BarkparkCloud.OAuth.
  ##
  ##   GET /v1/auth/oauth/providers          200 {providers:[…]}  (enabled only)
  ##   GET /v1/auth/oauth/:provider          302 → IdP authorize URL (404 if off)
  ##   GET /v1/auth/oauth/:provider/callback 302 → /#oauth=<token>&team=<id>
  ##                                         (302 → /#oauth_error=oauth_failed on any failure)

  # The SPA reads this to decide which "Continue with …" buttons to render —
  # only fully-configured providers (client_id+secret set) appear. No auth: a
  # logged-out visitor needs it to render the sign-in screen.
  get "/v1/auth/oauth/providers" do
    json(conn, 200, %{providers: OAuth.enabled_providers()})
  end

  # Kick off the flow: 302 the browser to the IdP's authorization URL (carrying
  # client_id, the derived redirect_uri, scope, and a freshly-minted single-use
  # signed state). An unknown or disabled :provider is a 404 — same gate Coolify
  # puts on the route via the provider's `enabled` flag.
  get "/v1/auth/oauth/:provider" do
    provider = conn.path_params["provider"]

    case OAuth.authorize_url(provider) do
      {:ok, url, _state} -> redirect_to(conn, url)
      {:error, :provider_not_enabled} -> json(conn, 404, %{error: "provider_not_enabled"})
    end
  end

  # The IdP redirects back here with ?code&state (or ?error= when the user
  # declined / the IdP refused). An IdP error is handled FIRST — a clean generic
  # redirect, never a crash and never an exchange attempt. Otherwise: verify the
  # single-use state (CSRF + replay), trade the code for the user's VERIFIED
  # identity, resolve-or-birth the Cloud user (safe (provider, provider_uid)
  # linking — never email), mint a session token CARRYING the caller's IP +
  # User-Agent (so the OAuth session is covered by the sessions list and
  # sign-out-everywhere), and 302 to the SPA with the token on the fragment.
  #
  # Every failure collapses to ONE generic /#oauth_error=oauth_failed redirect
  # (like Coolify's single translated `auth.failed`) — no provider/internal
  # detail leaks, and a bad/expired/forged/replayed state creates NO user and NO
  # token.
  get "/v1/auth/oauth/:provider/callback" do
    provider = conn.path_params["provider"]

    if is_binary(conn.query_params["error"]) do
      # The IdP declined (e.g. ?error=access_denied) — the user cancelled or the
      # provider refused. No code to exchange; render the clean auth error.
      redirect_to(conn, "/#oauth_error=oauth_failed")
    else
      code = conn.query_params["code"]
      state = conn.query_params["state"]

      with true <- OAuth.enabled?(provider),
           true <- is_binary(code) and is_binary(state),
           :ok <- OAuth.verify_state(state, provider),
           {:ok, identity} <- OAuth.fetch_identity(provider, code),
           {:ok, user} <- Accounts.get_or_create_user_from_oauth(identity),
           {:ok, token} <- Accounts.create_user_session_token(user, session_opts(conn)) do
        team = Accounts.primary_team(user)
        redirect_to(conn, "/#oauth=#{token}&team=#{team && team.id}")
      else
        _ -> redirect_to(conn, "/#oauth_error=oauth_failed")
      end
    end
  end

  ## Auth — POST /v1/auth/verify-email {token} → 200 {ok: true} | 422 {error:
  ## "invalid_token"}. The emailed `?confirm=` link reaches the hash-routed SPA,
  ## which POSTs the token here (no cookie session, so CSRF-trivial). Confirming
  ## twice / after a revoke fails closed as invalid_token (single-use).
  post "/v1/auth/verify-email" do
    token = conn.body_params["token"]

    with true <- is_binary(token),
         {:ok, _user} <- Accounts.confirm_user(token) do
      json(conn, 200, %{ok: true})
    else
      _ -> json(conn, 422, %{error: "invalid_token"})
    end
  end

  ## Agent routes (agent-token auth)

  # POST /v1/agent/report — body is the cloud-10 agent Report (see
  # internal/agent/report.go). Lands the health columns via upsert_health and the
  # health-gate signals via record_event. → 200 {ok: true}.
  post "/v1/agent/report" do
    conn = Auth.require_agent(conn, [])

    if conn.halted do
      conn
    else
      barkpark = conn.assigns.current_barkpark
      report = conn.body_params

      # The health BEFORE this report — so we can detect an up↔down FLIP and
      # email only on the transition (Coolify alerts on the flip, not every
      # cycle), never on a steady-state report.
      prior_health = barkpark.health_status
      new_health = normalize_health(report["health_status"])

      # health-status: land the report AND re-arm the staleness latch in one
      # call. record_agent_report/2 lands the health columns (upsert_health) and
      # then zeroes unreachable_count + clears unreachable_notification_sent, so a
      # box the StalenessWorker had latched offline can alert again on a LATER
      # outage. The recovery EMAIL itself is emitted below by
      # maybe_dispatch_health_flip (unknown→up ⇒ :agent_reachable) — no parallel
      # dispatch here.
      _ =
        Registry.record_agent_report(barkpark, %{
          health_status: new_health,
          agent_status: normalize_agent(report["agent_status"]),
          version: report["version"],
          git_commit: report["git_commit"],
          last_seen_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
        })

      # The agent's per-cycle signals become one append-only event. The full
      # report rides in the payload so the dashboard/event stream can show disk,
      # PG size, backup, dirty-tree, and the granular health checks.
      _ = Registry.record_event(barkpark, "health", report)

      # Push "fleet" so a live health change (up/down, version, agent online)
      # reflects on the dashboard without a manual refresh.
      push_event(barkpark.team_id, "fleet")

      # notifications-email: alert on a health FLIP only (down→up reachable,
      # up→down unreachable). Additive to the SSE push above.
      maybe_dispatch_health_flip(barkpark, prior_health, new_health)

      json(conn, 200, %{ok: true})
    end
  end

  # GET /v1/agent/commands — the approved-command queue. Empty for now: the
  # command-queue source is a later concern (cloud-13). Returns [] so the Go
  # agent's `len(cmds) == 0` fast-path is exercised. Shape: a JSON array of
  # {id, name} — the agent decodes straight into []Command.
  get "/v1/agent/commands" do
    conn = Auth.require_agent(conn, [])

    if conn.halted do
      conn
    else
      json(conn, 200, command_queue())
    end
  end

  # POST /v1/agent/results — body is a JSON array of CommandResult. With an empty
  # queue the agent never POSTs here, but the route exists and acks so a future
  # queue source has its landing spot. → 200 {ok: true}.
  post "/v1/agent/results" do
    conn = Auth.require_agent(conn, [])

    if conn.halted do
      conn
    else
      json(conn, 200, %{ok: true})
    end
  end

  ## User routes (session-token auth)

  # GET /v1/me → 200 {user: {id, email}, team: {id, name, slug}} — who am I.
  # The dashboard topbar uses this for the real team NAME + the account email
  # instead of a raw, opaque "Team a1b2c3d4" id slice.
  get "/v1/me" do
    conn = conn |> Auth.require_user_or_pat([]) |> Auth.require_ability("read")

    if conn.halted do
      conn
    else
      user = conn.assigns.current_user
      team = conn.assigns.current_team

      json(conn, 200, %{
        # two-factor-auth: the SPA reads two_factor_enabled to render the right
        # Security-panel state on load. The secret/codes columns are NEVER
        # serialized — only the boolean on/off switch. email-verification adds
        # `confirmed` so the SPA can nudge an unverified account.
        user: %{
          id: user.id,
          email: user.email,
          confirmed: not is_nil(user.confirmed_at),
          two_factor_enabled: Accounts.two_factor_enabled?(user)
        },
        team: team && %{id: team.id, name: team.name, slug: team.slug},
        # The caller's role in their current team — the SPA hides/shows the
        # invite + member-management controls on this. nil when teamless.
        role: team && Accounts.team_role(user, team),
        # Fold the onboarding summary into the boot read so the SPA renders the
        # "Finish setup" checklist without a second round-trip. Non-secret shape
        # (no gateway/customer ids) — safe for a PAT caller too.
        onboarding: team && onboarding_json(Accounts.onboarding_status(team))
      })
    end
  end

  ## two-factor-auth — account routes (require_user). Enroll / confirm / disable
  ## / regenerate / status. The secret + recovery codes are never echoed except
  ## the one-time recovery-code list and the enroll provisioning material.

  # POST /v1/account/two-factor/enroll → 200 {otpauth_uri, secret}
  # Generate + persist a pending (unconfirmed) TOTP secret and return the
  # provisioning material; the SPA renders the QR client-side from otpauth_uri.
  post "/v1/account/two-factor/enroll" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      {:ok, %{otpauth_uri: uri, secret_base32: secret}} =
        Accounts.start_two_factor_enrollment(conn.assigns.current_user)

      json(conn, 200, %{otpauth_uri: uri, secret: secret})
    end
  end

  # POST /v1/account/two-factor/confirm {code}
  #   → 200 {recovery_codes: [...]} — 2FA now ON; codes shown EXACTLY once
  #   → 422 {error: "invalid_otp" | "not_enrolled"}
  post "/v1/account/two-factor/confirm" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      case Accounts.confirm_two_factor(conn.assigns.current_user, conn.body_params["code"] || "") do
        {:ok, codes} -> json(conn, 200, %{recovery_codes: codes})
        {:error, :invalid_otp} -> json(conn, 422, %{error: "invalid_otp"})
        {:error, :not_enrolled} -> json(conn, 422, %{error: "not_enrolled"})
      end
    end
  end

  # GET /v1/account/two-factor → 200 {enabled: bool} — status for the panel.
  get "/v1/account/two-factor" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      json(conn, 200, %{enabled: Accounts.two_factor_enabled?(conn.assigns.current_user)})
    end
  end

  # DELETE /v1/account/two-factor → 200 {ok: true} — disable (nulls all columns).
  delete "/v1/account/two-factor" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      {:ok, _} = Accounts.disable_two_factor(conn.assigns.current_user)
      json(conn, 200, %{ok: true})
    end
  end

  # POST /v1/account/two-factor/recovery-codes
  #   → 200 {recovery_codes: [...]} — fresh set; old codes invalidated; once
  #   → 422 {error: "not_enabled"}  — 2FA is not on
  post "/v1/account/two-factor/recovery-codes" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      case Accounts.regenerate_recovery_codes(conn.assigns.current_user) do
        {:ok, codes} -> json(conn, 200, %{recovery_codes: codes})
        {:error, :not_enabled} -> json(conn, 422, %{error: "not_enabled"})
      end
    end
  end

  # GET /v1/onboarding → 200 {onboarding: {completed, completed_at, last_step,
  # all_done, steps:[{key,done}]} | nil}. The SPA reads this (on boot via /v1/me,
  # and again on a subscription/fleet live event) to render the persistent
  # "Finish setup" checklist. Steps are SERVER-computed, so they reflect state
  # the user changed outside the checklist (subscribed via Billing, launched via
  # the Launch view) with zero client logic. Readable by ANY team member. A
  # teamless user gets nil.
  get "/v1/onboarding" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 200, %{onboarding: nil})

      true ->
        status = Accounts.onboarding_status(conn.assigns.current_team)
        json(conn, 200, %{onboarding: onboarding_json(status)})
    end
  end

  # POST /v1/onboarding {action: "advance"|"ack"|"complete"|"skip", step?}
  #   advance  — persist the resume pointer (step required, must be a known step)
  #   ack      — manually tick a server-unverifiable step (published_doc)
  #   complete — finish (only honored when all steps done; else 422 steps_incomplete)
  #   skip     — dismiss early (Coolify's skipBoarding) — stamps completed_at
  # RBAC: the mutations change TEAM state (they finish/dismiss the whole team's
  # onboarding + set the activation metric), so they are gated at owner/admin via
  # `Auth.require_primary_team_admin/1` — a plain `member` gets 403. GET stays
  # readable to any member. (401 unauth, 422 no_team, 403 non-admin all handled
  # inside the gate.) Deliberate Coolify divergence: NO force-redirect middleware
  # — the checklist is a soft, dismissable SPA surface; the real launch gate stays
  # the existing 402 on /v1/go-live. On any state change we push an "onboarding"
  # invalidation so other tabs refetch.
  post "/v1/onboarding" do
    conn = Auth.require_primary_team_admin(conn)

    if conn.halted do
      conn
    else
      handle_onboarding_action(conn, conn.body_params, conn.assigns.current_team)
    end
  end

  # POST /v1/auth/resend-verification (user) → ALWAYS 200 {ok: true}. Re-sends the
  # confirm mail for the current user. An already-confirmed user, an unknown
  # state, or a throttled resend is STILL 200 — no information is leaked and no
  # error is surfaced (the deliver context is fail-soft).
  post "/v1/auth/resend-verification" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      _ = Accounts.deliver_user_confirmation_instructions(conn.assigns.current_user)
      json(conn, 200, %{ok: true})
    end
  end

  # POST /v1/account/email/change (user) {new_email} → 202 {ok: true} (stages the
  # pending address + emails a 6-digit code to it) | 422 {error: "email_invalid"}.
  # ENUMERATION-SAFE: an already-registered target, a throttled request, and a
  # down mailer ALL answer the same 202 — only a malformed address (a syntax
  # fact) is 422. So a prober can't learn which addresses have accounts.
  post "/v1/account/email/change" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      not is_binary(conn.body_params["new_email"]) ->
        json(conn, 422, %{error: "email_invalid"})

      true ->
        case Accounts.deliver_user_update_email_instructions(
               conn.assigns.current_user,
               conn.body_params["new_email"]
             ) do
          {:error, %Ecto.Changeset{}} -> json(conn, 422, %{error: "email_invalid"})
          _ -> json(conn, 202, %{ok: true})
        end
    end
  end

  # POST /v1/account/email/confirm (user) {code} → 200 {user:{id,email,confirmed}}
  # (swaps the email + syncs the Stripe customer) | 422 {error: "invalid_code"} |
  # 422 {error: "locked"} (too many wrong codes — restart the change) | 422
  # {error: "no_pending_email"}.
  post "/v1/account/email/confirm" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      not is_binary(conn.body_params["code"]) ->
        json(conn, 422, %{error: "invalid_code"})

      true ->
        case Accounts.update_user_email(conn.assigns.current_user, conn.body_params["code"]) do
          {:ok, user} ->
            json(conn, 200, %{
              user: %{id: user.id, email: user.email, confirmed: not is_nil(user.confirmed_at)}
            })

          {:error, :no_pending_email} ->
            json(conn, 422, %{error: "no_pending_email"})

          {:error, :locked} ->
            json(conn, 422, %{error: "locked"})

          _ ->
            json(conn, 422, %{error: "invalid_code"})
        end
    end
  end

  ## Account & sessions (session-token auth)

  # DELETE /v1/auth/logout → 200 {ok: true}. Revokes THE CALLING token (the
  # leaked-session kill switch for a single device). Idempotent — a second
  # logout on an already-revoked token is still 200. The current token plaintext
  # is re-extracted via Auth.bearer_token/1 (the same value require_user already
  # resolved) so the exact row presented gets revoked.
  delete "/v1/auth/logout" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      _ = Accounts.revoke_user_session_token(Auth.bearer_token(conn))
      json(conn, 200, %{ok: true})
    end
  end

  # GET /v1/account/sessions → 200 {sessions: [{id, ip_address, user_agent,
  # last_used_at, inserted_at, current}]}. `current` flags the row matching the
  # calling token so the UI can label "This device". The token_hash is NEVER
  # echoed.
  get "/v1/account/sessions" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      current_hash = Accounts.UserToken.hash_token(Auth.bearer_token(conn) || "")
      rows = Accounts.list_user_sessions(conn.assigns.current_user)
      json(conn, 200, %{sessions: Enum.map(rows, &session_json(&1, current_hash))})
    end
  end

  # DELETE /v1/account/sessions/:id → 200 {ok: true} | 404. Revoke one of the
  # caller's sessions by row id. Ownership-scoped: another user's token id is a
  # 404, never an existence leak.
  delete "/v1/account/sessions/:id" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      case Accounts.revoke_user_session(conn.assigns.current_user, conn.path_params["id"]) do
        {:ok, _} -> json(conn, 200, %{ok: true})
        {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
      end
    end
  end

  # DELETE /v1/account/sessions → 200 {revoked: N}. "Sign out everywhere" EXCEPT
  # the acting browser, kept alive via :except so the caller stays logged in
  # here. N is the number of OTHER sessions just revoked.
  delete "/v1/account/sessions" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      {:ok, n} =
        Accounts.revoke_all_user_sessions(conn.assigns.current_user,
          except: Auth.bearer_token(conn)
        )

      json(conn, 200, %{revoked: n})
    end
  end

  # PUT /v1/account/password {current_password, new_password} → 200 {ok: true,
  # token: <fresh>} | 401 wrong current | 422 weak new. On success EVERY other
  # session + all reachable agent tokens are revoked; the response carries a
  # freshly-minted session for THIS browser so the caller stays logged in. The
  # old token they presented is revoked among the rest, so the SPA MUST swap to
  # the returned token (mirrors Coolify's dispatch('reloadWindow')).
  put "/v1/account/password" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      cur = to_string(conn.body_params["current_password"])
      new = to_string(conn.body_params["new_password"])
      user = conn.assigns.current_user
      old_token = Auth.bearer_token(conn)

      case Accounts.update_user_password(user, cur, new, keep: old_token) do
        {:ok, _u} ->
          # The old token was kept alive THROUGH the bulk revoke (via :keep) so
          # the in-flight request never lost its own auth mid-call. Revoke it now
          # and hand back a fresh one so the SPA swaps and stays authenticated.
          _ = Accounts.revoke_user_session_token(old_token)
          {:ok, fresh} = Accounts.create_user_session_token(user, session_opts(conn))
          json(conn, 200, %{ok: true, token: fresh})

        {:error, :invalid_current_password} ->
          json(conn, 401, %{error: "invalid_current_password"})

        {:error, %Ecto.Changeset{} = cs} ->
          json(conn, 422, %{error: "invalid", details: errors(cs)})
      end
    end
  end

  # GET /v1/subscription → 200 {subscription: {plan, status, started_at} | nil}.
  # The Billing view reads this to show the REAL current plan (and gate the
  # already-subscribed state) instead of hardcoding "Free = current plan". A
  # team with no active subscription gets {subscription: nil}.
  get "/v1/subscription" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 200, %{subscription: nil})

      true ->
        # The LIVE subscription (active OR past_due) so the Billing view shows a
        # paying-but-in-dunning customer their real plan + status, not "no plan".
        case Billing.live_subscription(conn.assigns.current_team) do
          nil -> json(conn, 200, %{subscription: nil})
          sub -> json(conn, 200, %{subscription: subscription_json(sub)})
        end
    end
  end

  # GET /v1/providers → 200 {providers: [...]} for the user's team. Backs the
  # Providers view so connected providers SURVIVE a reload (the connect flow was
  # previously optimistic-only — a connected provider vanished on refresh).
  get "/v1/providers" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 200, %{providers: []})

      true ->
        providers = Registry.list_providers(conn.assigns.current_team)
        json(conn, 200, %{providers: Enum.map(providers, &provider_json/1)})
    end
  end

  # GET /v1/events — the live dashboard's Server-Sent-Events stream. Auth is by
  # `?token=<session-token>` (a query param, because the browser EventSource API
  # CANNOT set an Authorization header) OR a normal Bearer header for non-browser
  # clients. On success the request process subscribes to its team's :pg group
  # and parks in a receive loop, chunking each broadcast as an SSE `data:` frame
  # plus a periodic heartbeat comment to keep proxies from idling it out. The
  # browser refetches the relevant GET on each event — the event is an
  # invalidation signal, not authoritative state.
  get "/v1/events" do
    conn = require_user_sse(conn)

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns[:current_team]) ->
        json(conn, 422, %{error: "no_team"})

      true ->
        stream_events(conn, conn.assigns.current_team.id)
    end
  end

  # GET /v1/barkparks → 200 {barkparks: [...]} for the user's team. Each row
  # carries the LATEST provision job's status/error (merged from a single batch
  # query) so the dashboard can show a FAILED launch distinctly from one still
  # provisioning — a failed job leaves the barkpark health "unknown"/host nil,
  # otherwise indistinguishable from in-progress.
  get "/v1/barkparks" do
    conn = conn |> Auth.require_user_or_pat([]) |> Auth.require_ability("read")

    if conn.halted do
      conn
    else
      barkparks =
        case conn.assigns.current_team do
          nil -> []
          team -> Registry.list_barkparks(team)
        end

      ids = Enum.map(barkparks, & &1.id)
      pmap = Registry.latest_provision_status_map(ids)
      dmap = Registry.latest_deprovision_status_map(ids)

      json(conn, 200, %{
        barkparks: Enum.map(barkparks, &barkpark_json(&1, pmap[&1.id], dmap[&1.id]))
      })
    end
  end

  # GET /v1/audit?limit=&before=&target_type=&target_id= → 200 {events: [...]}.
  # The authenticated admin's team audit trail, newest first, keyset-paginated
  # (`?before=<oldest inserted_at>` walks the next page). Strictly team-scoped via
  # conn.assigns.current_team — an admin only ever sees their OWN team's events.
  #
  # RBAC: ADMIN-gated (rbac-roles). Reading the audit log is owner/admin-only —
  # require_primary_team_admin halts 401 (no session) / 422 no_team / 403 (a plain
  # member). This is the docstring-promised tightening the swarm candidate could
  # only hint at: main now ships the team-role gate, so a plain member can no
  # longer read the trail.
  get "/v1/audit" do
    conn = Auth.require_primary_team_admin(conn)

    if conn.halted do
      conn
    else
      opts = [
        limit: parse_int(conn.query_params["limit"], 50),
        before: parse_dt(conn.query_params["before"]),
        target_type: conn.query_params["target_type"],
        target_id: conn.query_params["target_id"]
      ]

      events = Accounts.list_audit_events(conn.assigns.current_team, opts)
      json(conn, 200, %{events: Enum.map(events, &audit_json/1)})
    end
  end

  # DELETE /v1/barkparks/:id → 200 {ok: true} — remove an instance from the
  # dashboard. Team-scoped: a wrong-team / nonexistent id is the same 404 (no
  # existence leak). Guard: a LIVE managed box (host set) is NOT removable here —
  # deleting only the registry row would strand a billed server (deprovisioning
  # the actual box is a Go-worker follow-up). Failed / never-provisioned rows are
  # safe to remove (a failed provision already tore its box down). 409 with a
  # clear reason for the blocked live case.
  # DELETE /v1/barkparks/:id — remove an instance. Team-scoped (wrong-team /
  # nonexistent → 404, no existence leak). LIVE box (host set) → enqueue a
  # DEPROVISION job, 202 {status: "deprovisioning"} (the worker tears the real box
  # + DNS down, then the row is deleted; a duplicate concurrent remove is deduped
  # → still 202). NON-live box (host nil) → delete the row now, 200 {status:
  # "removed"} (no live server to tear down).
  # ADMIN-gated: removing an instance (and tearing down a billed box) is
  # privileged. require_primary_team_admin halts 401 / 422 no_team / 403 for a
  # member; a non-admin can no longer deprovision the team's infrastructure.
  delete "/v1/barkparks/:id" do
    # Infra-destructive → team admin (owner/admin) only. require_primary_team_admin
    # gates the user's PRIMARY team (401 / 422 no_team / 403), matching the doc above.
    conn = Auth.require_primary_team_admin(conn)

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        team = conn.assigns.current_team

        case Registry.get_barkpark(conn.path_params["id"]) do
          %Barkpark{team_id: tid} = bp when tid == team.id ->
            cond do
              # Live box → tear the real server + DNS down (deprovision job).
              is_binary(bp.host) and bp.host != "" ->
                deprovision_live_barkpark(conn, team, bp)

              # Not live YET, but a provision is in flight: deleting the row now
              # would let the worker bring a box up the control plane can't see
              # (succeed_job no-ops on the missing row) — a stranded billed box.
              # Refuse until the provision lands (then it's a live-box deprovision)
              # or fails (then it's a clean non-live remove).
              Registry.active_provision_job?(bp) ->
                json(conn, 409, %{
                  error: "provisioning_in_progress",
                  detail:
                    "This instance is still provisioning. Try removing it once it's up or has failed."
                })

              # Non-live, nothing in flight (never provisioned, or a failed
              # provision that already tore its own box down) → delete the row
              # now, ATOMIC with a `barkpark.deleted` audit event (the row delete
              # and the audit insert share one transaction — never one without
              # the other).
              true ->
                audit_attrs = %{
                  team_id: team.id,
                  actor_user_id: conn.assigns.current_user.id,
                  action: "barkpark.deleted",
                  target_type: "barkpark",
                  target_id: bp.id,
                  metadata: %{name: bp.name}
                }

                case Accounts.audit(audit_attrs, fn -> Registry.delete_barkpark(bp) end) do
                  {:ok, _} ->
                    push_event(team.id, "fleet")
                    push_event(team.id, "audit")
                    json(conn, 200, %{ok: true, status: "removed"})

                  {:error, %Ecto.Changeset{} = cs} ->
                    json(conn, 422, %{error: "invalid", details: errors(cs)})
                end
            end

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # POST /v1/barkparks/:id/retry → 201 {job} — re-enqueue provisioning for an
  # instance whose LAST provision attempt FAILED. Gated on a failed latest job so
  # a retry can never open a second concurrent provision (and a second billed
  # box) while one is pending/claimed/succeeded → 409 conflict in that case.
  post "/v1/barkparks/:id/retry" do
    # RBAC (rbac-roles): re-provisions a billed box → team admin only.
    conn = Auth.require_team_admin(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        team = conn.assigns.current_team

        case Registry.get_barkpark(conn.path_params["id"]) do
          %Barkpark{team_id: tid} = bp when tid == team.id ->
            case Registry.latest_provision_job(bp) do
              %{status: "failed"} ->
                case Registry.enqueue_provision_job(bp) do
                  {:ok, _job} ->
                    push_event(team.id, "fleet")
                    json(conn, 201, %{ok: true})

                  {:error, cs} ->
                    json(conn, 422, %{error: "invalid", details: errors(cs)})
                end

              _ ->
                json(conn, 409, %{error: "not_retryable"})
            end

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # GET /v1/barkparks/:id/credentials → 200 {admin_token, url, host} — the
  # OWNER-facing retrieval of the per-instance admin bearer the warm-pool minted on
  # the box (instance-admin-token). Eliminates the SSH/rescue-reboot dance: the
  # token was reported on /succeed and stored ENCRYPTED, and this decrypts it for
  # the owner. Show-to-owner — treat the response as a secret.
  #
  # ADMIN-gated + team-scoped, fail-closed: require_team_admin 401s an
  # unauthenticated caller and 403s a member who is not owner/admin; a barkpark in
  # ANOTHER team (or no such id) is the SAME 404 — NO existence leak for a
  # non-member. 404 "no_admin_token" when the row never got one (ip-only succeed /
  # pre-feature instance); 500 if the stored ciphertext fails to decrypt.
  get "/v1/barkparks/:id/credentials" do
    # RBAC (rbac-roles): reveals a live admin credential → team admin (owner/admin) only.
    conn = Auth.require_team_admin(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        team = conn.assigns.current_team

        case Registry.get_barkpark(conn.path_params["id"]) do
          %Barkpark{team_id: tid} = bp when tid == team.id ->
            case Registry.reveal_admin_token(bp) do
              {:ok, nil} ->
                json(conn, 404, %{
                  error: "no_admin_token",
                  detail:
                    "No admin token is stored for this instance yet. It is captured at " <>
                      "provision time — a pre-existing instance may need a re-provision."
                })

              {:ok, token} ->
                json(conn, 200, %{admin_token: token, url: bp.url, host: bp.host})

              :error ->
                json(conn, 500, %{error: "decrypt_failed"})
            end

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # POST /v1/providers {kind, token, label?} → 201 {provider: ...}. The plaintext
  # token is encrypted at rest by connect_provider — it is NEVER echoed back.
  post "/v1/providers" do
    # RBAC (rbac-roles): stores a cloud credential at rest → team admin only.
    conn = Auth.require_team_admin(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      true ->
        kind = conn.body_params["kind"]
        token = conn.body_params["token"]
        label = conn.body_params["label"]

        case Registry.connect_provider(conn.assigns.current_team, kind, token || "", label: label) do
          {:ok, provider} -> json(conn, 201, %{provider: provider_json(provider)})
          {:error, changeset} -> json(conn, 422, %{error: "invalid", details: errors(changeset)})
        end
    end
  end

  # GET /v1/env-vars → 200 {env_vars: [...]} for the user's team. Values are NEVER
  # in the payload — only key + scope + flags + comment (the masking discipline).
  # A secret is set-and-forget, surfaced by key, not value.
  get "/v1/env-vars" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      true ->
        vars = Registry.list_env_vars(conn.assigns.current_team)
        json(conn, 200, %{env_vars: Enum.map(vars, &env_var_json/1)})
    end
  end

  # POST /v1/env-vars {key, value, scope?, barkpark_id?, is_secret?, is_shown_once?,
  # comment?} → 201 {env_var}. Write-gated to owner/admin (Accounts.team_admin?/2).
  # The plaintext `value` is encrypted at rest and NEVER echoed. A write to a
  # write-once var → 409. A barkpark_id NOT owned by the team → 403 (the FK checks
  # existence, not ownership — the context fails the cross-tenant write closed).
  post "/v1/env-vars" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      not Accounts.team_admin?(conn.assigns.current_user, conn.assigns.current_team) ->
        json(conn, 403, %{error: "forbidden"})

      not is_binary(conn.body_params["key"]) or conn.body_params["key"] == "" ->
        json(conn, 422, %{error: "key_required"})

      true ->
        attrs =
          Map.take(
            conn.body_params,
            ~w(key value scope barkpark_id is_secret is_shown_once comment)
          )

        case Registry.put_env_var(conn.assigns.current_team, attrs) do
          {:ok, ev} -> json(conn, 201, %{env_var: env_var_json(ev)})
          {:error, :write_once} -> json(conn, 409, %{error: "write_once"})
          {:error, :barkpark_not_in_team} -> json(conn, 403, %{error: "forbidden"})
          {:error, changeset} -> json(conn, 422, %{error: "invalid", details: errors(changeset)})
        end
    end
  end

  # DELETE /v1/env-vars/:id → 200 {ok: true} (owner/admin), 404 if not in the
  # team (existence-leak protection — a wrong-team id is indistinguishable from
  # a non-existent one).
  delete "/v1/env-vars/:id" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      not Accounts.team_admin?(conn.assigns.current_user, conn.assigns.current_team) ->
        json(conn, 403, %{error: "forbidden"})

      true ->
        case Registry.delete_env_var(conn.assigns.current_team, conn.path_params["id"]) do
          {:ok, _} -> json(conn, 200, %{ok: true})
          {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # GET /v1/notifications/settings → 200 {settings: <masked>} for the user's team.
  # Secrets are MASKED ("********" when set, nil when unset) — the ciphertext is
  # never serialized. Auto-creates the row on first read (lazy backstop).
  get "/v1/notifications/settings" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      true ->
        settings = Notifications.get_or_create_settings(conn.assigns.current_team)
        json(conn, 200, %{settings: Notifications.settings_view(settings)})
    end
  end

  # PUT /v1/notifications/settings {transport?, alerts_enabled?, smtp_*?, api_key?,
  # from_*?, <event toggles>?} → 200 {settings: <masked>} | 422 {error, details}.
  # Plaintext secrets are encrypted at rest by update_settings (Registry.Vault);
  # they are NEVER echoed back. A PUT that omits a secret keeps the stored one.
  #
  # ADMIN-gated (matches the sibling credential route POST /v1/providers and
  # `@action_min connect_provider: [admin]`): these settings store SMTP creds at
  # rest and toggle alert delivery — a plain member must not repoint team alert
  # mail to an attacker relay or silence past_due alerts. 403 for a non-admin.
  put "/v1/notifications/settings" do
    conn = Auth.require_team_admin(conn, [])

    if conn.halted do
      conn
    else
      case Notifications.update_settings(conn.assigns.current_team, conn.body_params) do
        {:ok, settings} ->
          json(conn, 200, %{settings: Notifications.settings_view(settings)})

        {:error, changeset} ->
          json(conn, 422, %{error: "invalid", details: errors(changeset)})
      end
    end
  end

  # notifications-chat: PUT /v1/notifications/channels {type, enabled, credentials?}
  # → 200 {settings: <masked>} | 422. Upsert one chat channel. `credentials` is a
  # plaintext map the context seals via Vault before it hits the DB; omit it to
  # toggle enable/disable without re-supplying the secret. A `webhook` URL that
  # resolves to a private/metadata address is REJECTED at save time (SSRF guard).
  # ADMIN-gated like the sibling settings route — a member must not repoint a
  # team's alert egress to an attacker-controlled endpoint.
  put "/v1/notifications/channels" do
    conn = Auth.require_team_admin(conn, [])

    if conn.halted do
      conn
    else
      params = conn.body_params
      type = params["type"]
      enabled = params["enabled"] == true
      creds = if is_map(params["credentials"]), do: params["credentials"], else: nil

      case Notifications.put_channel(conn.assigns.current_team, type, enabled, creds) do
        {:ok, settings} ->
          push_event(conn.assigns.current_team.id, "notifications")
          json(conn, 200, %{settings: Notifications.settings_view(settings)})

        {:error, changeset} ->
          json(conn, 422, %{error: "invalid", details: errors(changeset)})
      end
    end
  end

  # notifications-chat: PUT /v1/notifications/events {event, channels:[...]} → 200
  # {settings: <masked>} | 422. Set which chat channel types receive `event` (the
  # event×channel matrix toggle). ADMIN-gated for parity with the settings route.
  put "/v1/notifications/events" do
    conn = Auth.require_team_admin(conn, [])

    if conn.halted do
      conn
    else
      params = conn.body_params
      event = params["event"]
      channels = if is_list(params["channels"]), do: params["channels"], else: []

      case Notifications.set_event_route(conn.assigns.current_team, event, channels) do
        {:ok, settings} ->
          push_event(conn.assigns.current_team.id, "notifications")
          json(conn, 200, %{settings: Notifications.settings_view(settings)})

        {:error, changeset} ->
          json(conn, 422, %{error: "invalid", details: errors(changeset)})
      end
    end
  end

  # POST /v1/notifications/test {to?} → 200 {ok: true} | 429 {error: "rate_limited",
  # retry_after} | 422 {error: "no_team"|"no_recipient"}. Sends a test email over
  # the platform transport. Rate-limited to one per 10s per team (Coolify parity),
  # enforced in the context via last_test_sent_at. `to` defaults to the first
  # team member's email and MUST be a team member (the platform mailer is not an
  # open relay) — a non-member recipient is 403. ADMIN-gated for parity with the
  # settings route.
  #
  # notifications-chat: when the body carries `{"channel": "<type>"|null}` (or
  # `{"target": "chat"}`), this instead fires the always-send `test` CHAT event to
  # the enabled chat channels (all, or just `channel`), enqueuing one Oban job each
  # → 202. `channel: null` with `target: "chat"` fans to every enabled channel.
  post "/v1/notifications/test" do
    conn = Auth.require_team_admin(conn, [])

    cond do
      conn.halted ->
        conn

      chat_test?(conn.body_params) ->
        :ok =
          Notifications.send_test_chat(conn.assigns.current_team, conn.body_params["channel"])

        json(conn, 202, %{ok: true})

      true ->
        test_email(conn)
    end
  end

  # True when the caller wants a CHAT test rather than the default email test.
  defp chat_test?(params) do
    Map.has_key?(params, "channel") or params["target"] == "chat"
  end

  defp test_email(conn) do
    if conn.halted do
      conn
    else
      to = conn.body_params["to"]

      case Notifications.deliver_test(conn.assigns.current_team, to) do
        {:ok, _} ->
          json(conn, 200, %{ok: true})

        {:error, {:rate_limited, retry_after}} ->
          json(conn, 429, %{error: "rate_limited", retry_after: retry_after})

        {:error, :no_recipient} ->
          json(conn, 422, %{error: "no_recipient"})

        {:error, :recipient_not_member} ->
          json(conn, 403, %{error: "recipient_not_member"})

        {:error, _reason} ->
          json(conn, 502, %{error: "send_failed"})
      end
    end
  end

  ## Teams — members & invitations (cloud adaptation of Coolify's Team Livewire).
  ##
  ## Every per-team route resolves + role-gates the team from the path `:id` via
  ## `with_team_role/3` (NOT the user's primary team), so the feature is correct
  ## even before a team-switcher exists. A non-member of the path team gets the
  ## same 404 as a nonexistent team — no existence leak.

  # GET /v1/teams/:id/members → 200 {members: [{user_id, email, role, joined_at}]}.
  get "/v1/teams/:id/members" do
    with_team_role(conn, "member", fn conn, team ->
      json(conn, 200, %{members: Enum.map(Accounts.list_team_members(team), &member_json/1)})
    end)
  end

  # POST /v1/teams/:id/invitations {email, role?} → 201 {invitation, accept_url}.
  # The raw accept token appears ONCE here, in accept_url, and is never persisted
  # in plaintext. No mailer — the inviter copy-pastes the url out-of-band.
  post "/v1/teams/:id/invitations" do
    with_team_role(conn, "admin", fn conn, team ->
      email = conn.body_params["email"]
      role = conn.body_params["role"] || "member"

      cond do
        not (is_binary(email) and email != "") ->
          json(conn, 422, %{error: "email_required"})

        true ->
          # activity-audit-log: the invite + a `member.invited` audit row commit
          # in one transaction (target_id resolved from the created invitation).
          audit_invite =
            Accounts.audit(
              %{
                team_id: team.id,
                actor_user_id: conn.assigns.current_user.id,
                action: "member.invited",
                target_type: "invitation",
                metadata: %{email: email, role: role}
              },
              fn -> Accounts.invite_member(team, email, role, conn.assigns.current_user) end,
              fn %{invitation: inv} -> %{target_id: inv.id} end
            )

          case audit_invite do
            {:ok, %{invitation: inv, token: raw}} ->
              push_event(team.id, "members")
              push_event(team.id, "audit")

              json(conn, 201, %{
                invitation: invitation_json(inv),
                accept_url: accept_url(conn, raw)
              })

            {:error, :already_member} ->
              json(conn, 409, %{error: "already_member"})

            {:error, :role_too_high} ->
              json(conn, 422, %{error: "role_too_high"})

            {:error, :invalid_role} ->
              json(conn, 422, %{error: "invalid_role"})

            {:error, %Ecto.Changeset{} = cs} ->
              # Partial-unique violation → one live invite per email per team.
              json(conn, 409, %{error: "already_invited", details: errors(cs)})
          end
      end
    end)
  end

  # GET /v1/teams/:id/invitations → 200 {invitations: [...]} — pending only.
  get "/v1/teams/:id/invitations" do
    with_team_role(conn, "admin", fn conn, team ->
      json(conn, 200, %{
        invitations: Enum.map(Accounts.list_invitations(team), &invitation_json/1)
      })
    end)
  end

  # DELETE /v1/teams/:id/invitations/:inv_id → 200 {ok: true} | 404.
  delete "/v1/teams/:id/invitations/:inv_id" do
    with_team_role(conn, "admin", fn conn, team ->
      inv_id = conn.path_params["inv_id"]

      # activity-audit-log: the revoke + an `invitation.revoked` audit row commit
      # in one transaction. target_id is the path invitation id (known up front).
      audit_revoke =
        Accounts.audit(
          %{
            team_id: team.id,
            actor_user_id: conn.assigns.current_user.id,
            action: "invitation.revoked",
            target_type: "invitation",
            target_id: inv_id
          },
          fn -> Accounts.revoke_invitation(team, inv_id) end
        )

      case audit_revoke do
        {:ok, _} -> json(conn, 200, %{ok: true})
        {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
      end
    end)
  end

  # PATCH /v1/teams/:id/members/:user_id {role} → 200 {member} — change a role.
  # ANTI-ESCALATION: the acting admin must out-rank the target's current role and
  # may not grant a role above their own (an admin cannot self-promote to owner,
  # mint an owner, or demote an owner/peer admin) → 403 forbidden. 409 last_owner
  # when demoting the sole owner; 422 invalid_role; 404 not a member.
  patch "/v1/teams/:id/members/:user_id" do
    with_team_role(conn, "admin", fn conn, team ->
      role = conn.body_params["role"]

      with %{} = target <- Accounts.get_user(conn.path_params["user_id"]),
           # activity-audit-log: the role change + a `member.role_changed` audit
           # row commit in one transaction (the update itself opens a txn for the
           # last-owner lock; audit nests it as a savepoint).
           {:ok, membership} <-
             Accounts.audit(
               %{
                 team_id: team.id,
                 actor_user_id: conn.assigns.current_user.id,
                 action: "member.role_changed",
                 target_type: "user",
                 target_id: target.id,
                 metadata: %{new_role: to_string(role)}
               },
               fn ->
                 Accounts.update_member_role_as(
                   conn.assigns.current_user,
                   team,
                   target,
                   to_string(role)
                 )
               end
             ) do
        push_event(team.id, "members")
        push_event(team.id, "audit")

        json(conn, 200, %{
          member:
            member_json(%{user: target, role: membership.role, joined_at: membership.inserted_at})
        })
      else
        nil -> json(conn, 404, %{error: "not_found"})
        {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
        {:error, :invalid_role} -> json(conn, 422, %{error: "invalid_role"})
        {:error, :forbidden} -> json(conn, 403, %{error: "forbidden"})
        {:error, :last_owner} -> json(conn, 409, %{error: "last_owner"})
      end
    end)
  end

  # DELETE /v1/teams/:id/members/:user_id → 200 {ok: true}. Evicts the removed
  # user's sessions. ANTI-ESCALATION: an admin may remove only members they
  # out-rank; an owner may remove any peer (while owner_count > 1) → 403 forbidden
  # otherwise. 409 last_owner; 404 not a member.
  delete "/v1/teams/:id/members/:user_id" do
    with_team_role(conn, "admin", fn conn, team ->
      with %{} = target <- Accounts.get_user(conn.path_params["user_id"]),
           # activity-audit-log: the removal (+ its session eviction) and a
           # `member.removed` audit row commit in one transaction.
           {:ok, :removed} <-
             Accounts.audit(
               %{
                 team_id: team.id,
                 actor_user_id: conn.assigns.current_user.id,
                 action: "member.removed",
                 target_type: "user",
                 target_id: target.id,
                 metadata: %{email: target.email}
               },
               fn -> Accounts.remove_member_as(conn.assigns.current_team_role, team, target) end
             ) do
        push_event(team.id, "members")
        push_event(team.id, "audit")
        json(conn, 200, %{ok: true})
      else
        nil -> json(conn, 404, %{error: "not_found"})
        {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
        {:error, :forbidden} -> json(conn, 403, %{error: "forbidden"})
        {:error, :last_owner} -> json(conn, 409, %{error: "last_owner"})
      end
    end)
  end

  # GET /v1/invitations/:token → 200 {team, email, role, expires_at} | 404.
  # UNAUTHENTICATED on purpose: the accept page shows "you've been invited to
  # <team>" before the invitee logs in / registers. A garbage / expired / already
  # accepted token is the same 404 (no enumeration signal).
  get "/v1/invitations/:token" do
    case Accounts.get_live_invitation(conn.path_params["token"]) do
      nil ->
        json(conn, 404, %{error: "invalid_or_expired"})

      inv ->
        json(conn, 200, %{
          team: %{name: inv.team.name, slug: inv.team.slug},
          email: inv.email,
          role: inv.role,
          expires_at: inv.expires_at
        })
    end
  end

  # POST /v1/invitations/accept {token} → 200 {team_id}. Authed but NOT
  # team-scoped (the user is not yet a member). The email-match guard ensures the
  # logged-in user's email equals the invited email.
  post "/v1/invitations/accept" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      # activity-audit-log: accepting lands a membership; the audit row's team_id
      # + target_id are resolved FROM that membership (this route is not team-
      # scoped up front — the user is not yet a member), so the whole unit commits
      # atomically under the accepted team.
      audit_accept =
        Accounts.audit(
          %{
            actor_user_id: conn.assigns.current_user.id,
            action: "invitation.accepted",
            target_type: "user"
          },
          fn ->
            Accounts.accept_invitation(conn.body_params["token"] || "", conn.assigns.current_user)
          end,
          fn membership ->
            %{team_id: membership.team_id, target_id: conn.assigns.current_user.id}
          end
        )

      case audit_accept do
        {:ok, membership} ->
          push_event(membership.team_id, "members")
          push_event(membership.team_id, "audit")
          json(conn, 200, %{team_id: membership.team_id})

        {:error, :invalid_token} ->
          json(conn, 404, %{error: "invalid_or_expired"})

        {:error, :email_mismatch} ->
          json(conn, 403, %{error: "email_mismatch"})

        {:error, _} ->
          json(conn, 422, %{error: "accept_failed"})
      end
    end
  end

  ## Personal access tokens (session-authed management)
  ##
  ## Managing PATs is SESSION-ONLY — you mint / list / revoke tokens from the
  ## logged-in dashboard, never WITH a PAT. This is the privilege-escalation
  ## firewall: a leaked `read` token can never mint itself a `root` one (the
  ## mint route 401s a PAT bearer because it requires a session). Adapted from
  ## Coolify's Security/ApiTokens Livewire component.

  # GET /v1/tokens → 200 {tokens: [...]} — the caller's PATs, newest first.
  # NEVER emits the token_hash or any plaintext (a PAT is shown once, at mint).
  get "/v1/tokens" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      tokens = Accounts.list_personal_access_tokens(conn.assigns.current_user)
      json(conn, 200, %{tokens: Enum.map(tokens, &pat_json/1)})
    end
  end

  # POST /v1/tokens {name, abilities[], expires_in_days?} → 201
  # {token: <plaintext ONCE>, pat: {...}}. The plaintext is the ONLY moment the
  # credential leaves the server; pat carries no hash/no plaintext.
  #   422 {error: "no_team"}            — the user has no team to mint under.
  #   422 {error: "invalid", details}   — changeset rejection (bad name/ability).
  post "/v1/tokens" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      true ->
        user = conn.assigns.current_user

        attrs = %{
          name: conn.body_params["name"],
          abilities: conn.body_params["abilities"] || ["read"],
          expires_in_days: parse_expiry(conn.body_params["expires_in_days"])
        }

        # activity-audit-log: the mint + a `token.minted` audit row commit in one
        # transaction. create_personal_access_token returns a 3-tuple
        # {:ok, plaintext, pat}; normalize it to {:ok, {plaintext, pat}} so it
        # threads through audit/3 (which matches a 2-tuple {:ok, result}), then
        # unwrap on the far side. The plaintext is NEVER written to the audit row.
        audit_mint =
          Accounts.audit(
            %{
              team_id: conn.assigns.current_team.id,
              actor_user_id: user.id,
              action: "token.minted",
              target_type: "token",
              metadata: %{name: attrs.name, abilities: attrs.abilities}
            },
            fn ->
              case Accounts.create_personal_access_token(user, conn.assigns.current_team, attrs) do
                {:ok, plaintext, pat} -> {:ok, {plaintext, pat}}
                other -> other
              end
            end,
            fn {_plaintext, pat} -> %{target_id: pat.id} end
          )

        case audit_mint do
          {:ok, {plaintext, pat}} ->
            json(conn, 201, %{token: plaintext, pat: pat_json(pat)})

          # A plain member may mint only a `read` PAT — minting deploy/root/write
          # is owner/admin-only (anti-escalation, see create_personal_access_token).
          {:error, :forbidden} ->
            json(conn, 403, %{error: "forbidden"})

          {:error, cs} ->
            json(conn, 422, %{error: "invalid", details: errors(cs)})
        end
    end
  end

  # DELETE /v1/tokens/:id → 200 {ok: true} — revoke the caller's own PAT
  # (idempotent). A wrong-user / nonexistent id is the same 404 (no existence
  # leak across users).
  delete "/v1/tokens/:id" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      # activity-audit-log: the revoke + a `token.revoked` audit row commit in one
      # transaction. team_id + target_id are resolved from the revoked PAT (which
      # carries the team it was minted under), so the row is correctly team-scoped
      # even though this route resolves no team up front.
      audit_revoke_token =
        Accounts.audit(
          %{
            actor_user_id: conn.assigns.current_user.id,
            action: "token.revoked",
            target_type: "token"
          },
          fn ->
            Accounts.revoke_personal_access_token(
              conn.assigns.current_user,
              conn.path_params["id"]
            )
          end,
          fn token -> %{team_id: token.team_id, target_id: token.id} end
        )

      case audit_revoke_token do
        {:ok, _token} -> json(conn, 200, %{ok: true})
        {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
        {:error, cs} -> json(conn, 422, %{error: "invalid", details: errors(cs)})
      end
    end
  end

  # POST /v1/billing/checkout {plan} → 200 {checkout_url} — open a hosted
  # Checkout Session for the AUTHED user's team on `plan` (the customer opens the
  # url in a browser to pay). team_id is the authed team, NEVER client-supplied.
  # 422 {error: "plan_invalid"} for an unknown plan or "free" (free needs no
  # checkout). 422 {error: "no_team"} when the user has no team to bill.
  # OWNER-gated: billing is owner-only (`@action_min billing: [owner]`) — spending
  # money / changing the plan is the team owner's call, not any member or admin.
  # require_primary_team_owner halts with 401 (no auth), 422 no_team, or 403
  # (not-owner) before we reach here.
  post "/v1/billing/checkout" do
    # Spends money / changes plan → owner-only. Gated to the user's PRIMARY team
    # owner (401 / 422 no_team / 403), matching `@action_min billing: [owner]`.
    conn = Auth.require_primary_team_owner(conn)

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      true ->
        plan = conn.body_params["plan"]

        case Billing.checkout(conn.assigns.current_team, to_string(plan)) do
          {:ok, checkout_url} ->
            json(conn, 200, %{checkout_url: checkout_url})

          {:error, :plan_invalid} ->
            # BILL-2: distinguish a genuinely bad plan from a deploy where billing
            # was never wired (StripeGateway with no prices / webhook secret) — in
            # the latter EVERY paid plan resolves to no price, so :plan_invalid is
            # misleading. Surface an operator-actionable error `bp subscribe` can
            # report instead of telling the user their plan choice was wrong.
            if Billing.configured?() do
              json(conn, 422, %{error: "plan_invalid"})
            else
              json(conn, 422, %{error: "billing_not_configured"})
            end

          {:error, reason} ->
            json(conn, 422, %{error: "checkout_failed", reason: inspect(reason)})
        end
    end
  end

  # POST /v1/billing/portal → 200 {portal_url} — open a Stripe Customer Portal
  # session for the AUTHED user's team so they self-manage their subscription
  # (update card, view invoices, cancel) in a browser. 422 {no_team} when the
  # user has no team; 422 {no_subscription} when the team has no live sub.
  # Coolify-anchor: getStripeCustomerPortalSession.
  # OWNER-gated: the portal exposes card/PII/cancel — owner-only, like checkout.
  post "/v1/billing/portal" do
    conn = Auth.require_primary_team_owner(conn)

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      true ->
        case Billing.billing_portal_url(conn.assigns.current_team) do
          {:ok, url} ->
            json(conn, 200, %{portal_url: url})

          {:error, :no_subscription} ->
            json(conn, 422, %{error: "no_subscription"})

          {:error, reason} ->
            json(conn, 422, %{error: "portal_failed", reason: inspect(reason)})
        end
    end
  end

  # POST /v1/billing/cancel {password, at_period_end?} → 200 {status,
  # cancel_at_period_end}. DESTRUCTIVE → password re-confirmation (Coolify-anchor:
  # the Subscription Livewire cancel re-checks Hash::check before acting).
  # at_period_end defaults true (reversible grace — stays entitled until the
  # period end); false cancels immediately (status canceled + the team's managed
  # boxes suspended). 401 {password_invalid} on a wrong password; 422 {no_team} /
  # {no_subscription}.
  post "/v1/billing/cancel" do
    # OWNER-gated, and the gate is placed BEFORE the password re-confirm: the
    # `confirm_password` check verifies the CALLER's own password (not authority),
    # so it must never be the sole gate on a destructive cancel. The owner gate
    # halts 401 / 422 no_team / 403 first.
    conn = Auth.require_primary_team_owner(conn)

    cond do
      conn.halted ->
        conn

      not confirm_password(conn) ->
        json(conn, 401, %{error: "password_invalid"})

      true ->
        # Default to grace; only an explicit `false` cancels immediately.
        at_end = conn.body_params["at_period_end"] != false

        # activity-audit-log: the cancel + a `subscription.canceled` audit row
        # commit in one transaction (target_id + metadata resolved from the
        # updated subscription). A grace cancel (at_period_end) and an immediate
        # cancel both record here; the metadata distinguishes them.
        audit_cancel =
          Accounts.audit(
            %{
              team_id: conn.assigns.current_team.id,
              actor_user_id: conn.assigns.current_user.id,
              action: "subscription.canceled",
              target_type: "subscription",
              metadata: %{at_period_end: at_end}
            },
            fn -> Billing.request_cancel(conn.assigns.current_team, at_end) end,
            fn sub -> %{target_id: sub.id} end
          )

        case audit_cancel do
          {:ok, sub} ->
            # The plan state changed and (on immediate cancel) the fleet was
            # suspended — push both so an open dashboard reflects it live.
            push_event(conn.assigns.current_team.id, "subscription")
            push_event(conn.assigns.current_team.id, "fleet")
            push_event(conn.assigns.current_team.id, "audit")
            json(conn, 200, %{status: sub.status, cancel_at_period_end: sub.cancel_at_period_end})

          {:error, :no_subscription} ->
            json(conn, 422, %{error: "no_subscription"})

          {:error, reason} ->
            json(conn, 422, %{error: "cancel_failed", reason: inspect(reason)})
        end
    end
  end

  # POST /v1/billing/webhook — UNAUTHENTICATED but SIGNATURE-VERIFIED. Stripe
  # posts subscription events here. We read the RAW body (cached by
  # cache_raw_body/2 — the signature is over the raw bytes) + the Stripe-Signature
  # header and hand both to Billing.handle_webhook/2, which verifies the
  # signature and, on a valid activating event, marks the team's subscription
  # active from the SIGNED metadata. 200 {ok: true} on a handled/ignored valid
  # event; 400 {error: "invalid_signature"} on a bad/missing signature — a forged
  # webhook MUST NOT grant a subscription. Idempotent (a repeat is a no-op).
  post "/v1/billing/webhook" do
    raw_body = conn.assigns[:raw_body] || ""
    signature = stripe_signature(conn)

    case Billing.handle_webhook(raw_body, signature) do
      {:ok, result} ->
        # A newly-activated subscription pushes "subscription" so the customer's
        # post-checkout dashboard (the ?checkout=success return) flips to active
        # live — and "fleet" since launching is now unblocked.
        case result do
          %BarkparkCloud.Billing.Subscription{team_id: tid} = sub ->
            push_event(tid, "subscription")
            push_event(tid, "fleet")

            # notifications-email: a past_due subscription emails the team (on by
            # default — a billing failure is exactly the kind of alert a hosted
            # customer must not miss). Additive; the SSE push above still fires.
            if sub.status == "past_due" do
              Notifications.dispatch_event(tid, :subscription_past_due, %{})
            end

            # activity-audit-log: a genuinely-landed ACTIVE subscription records a
            # SYSTEM-actor `subscription.activated` event (a Stripe-fired change
            # has NO human actor, so actor_user_id is nil — the schema allows it).
            # Best-effort + post-commit ON PURPOSE: handle_webhook already
            # persisted the subscription and must stay free of an Accounts
            # dependency, so the audit is recorded here at the router seam; a
            # failed insert is LOGGED, never 500s the webhook (and never rolls the
            # subscription back — a forged event never reaches this branch, it
            # failed signature verification above). Gated on "active" so a
            # past_due / recovery result is not mislabeled an activation.
            if sub.status == "active" do
              case Accounts.record_audit(%{
                     team_id: tid,
                     actor_user_id: nil,
                     action: "subscription.activated",
                     target_type: "subscription",
                     target_id: sub.id,
                     metadata: %{plan: sub.plan, source: "stripe_webhook"}
                   }) do
                {:ok, _event} ->
                  push_event(tid, "audit")

                {:error, cs} ->
                  Logger.error("audit subscription.activated failed: #{inspect(cs)}")
              end
            end

          _ ->
            :ok
        end

        json(conn, 200, %{ok: true})

      {:error, :invalid_signature} ->
        json(conn, 400, %{error: "invalid_signature"})

      {:error, reason} ->
        json(conn, 400, %{error: "invalid_webhook", reason: inspect(reason)})
    end
  end

  # POST /v1/launch {provider, name} and POST /v1/go-live {name, plan} — the
  # control-plane half of go-live: auth + an ACTIVE-SUBSCRIPTION gate (the
  # subscription replaces the old per-go-live charge) + create the registry row
  # in a provisioning state. No active subscription → 402 {no_active_subscription,
  # checkout_path} and NOTHING is provisioned. The actual Go warm-pool
  # provisioning + reporting-back is cloud-12b/cloud-13. → 201 {barkpark} honestly
  # carrying health_status:"unknown", agent_status:"offline".
  post("/v1/launch", do: go_live(conn))
  post("/v1/go-live", do: go_live(conn))

  ## Internal routes (worker-token auth) — the Go warm-pool provisioner's queue.
  ## NEVER user/agent-reachable: require_worker matches the shared WORKER_TOKEN
  ## only, 401 otherwise.

  # POST /v1/internal/provision-jobs/claim → claim the oldest pending job (FOR UPDATE SKIP LOCKED) for this
  # worker. 200 {job_id, name, slug, region, server_type} for a claimed job, or
  # 204 (no body) when none is pending (the worker sleeps + retries). The
  # claim_token is generated here — one per claim, traceable on the job row.
  post "/v1/internal/provision-jobs/claim" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      case Registry.claim_next_job(generate_claim_token()) do
        nil ->
          send_resp(conn, 204, "")

        {job, barkpark} ->
          json(conn, 200, claim_json(job, barkpark))
      end
    end
  end

  # POST /v1/internal/provision-jobs/:id/succeed {ip} → mark the job succeeded
  # and flip its Barkpark to up at {ip}. IDEMPOTENT + status-guarded:
  #   200 {ok: true} — a fresh "claimed"→"succeeded" OR a retried succeed for an
  #     already-"succeeded" job (a dropped response self-heals; the worker KEEPS
  #     its box).
  #   409 {error: "conflict"} — the job is in a terminal NON-succeeded state
  #     ("failed"). The control plane already gave up; the worker treats the 4xx
  #     as "tear down the orphan box".
  #   422 when ip is missing (or a changeset rejection); 404 when no job has that id.
  post "/v1/internal/provision-jobs/:id/succeed" do
    conn = Auth.require_worker(conn, [])

    cond do
      conn.halted ->
        conn

      not (is_binary(conn.body_params["ip"]) and conn.body_params["ip"] != "") ->
        json(conn, 422, %{error: "ip_required"})

      true ->
        # instance-admin-token: the worker MAY report the per-instance admin token
        # it minted on the box alongside {ip}. When present it is stored encrypted
        # (Vault) on the barkpark row so the owner can retrieve it from the product;
        # absent is fine (back-compat — the ip-only succeed path is unchanged).
        opts = succeed_opts(conn.body_params["admin_token"])

        case Registry.succeed_job(conn.path_params["id"], conn.body_params["ip"], opts) do
          {:ok, job} ->
            # The box just went live — push "fleet" so the dashboard flips it
            # from "provisioning" to up without a manual refresh.
            broadcast_barkpark_team(job.barkpark_id, "fleet")
            # notifications-email: additive alert (the SSE signal still fires).
            dispatch_barkpark_event(job.barkpark_id, :provision_succeeded)
            json(conn, 200, %{ok: true})

          {:error, :not_found} ->
            json(conn, 404, %{error: "not_found"})

          {:error, :conflict} ->
            json(conn, 409, %{error: "conflict"})

          {:error, _} ->
            json(conn, 422, %{error: "invalid"})
        end
    end
  end

  ## Internal deprovision queue (worker-token auth) — the Remove path's drain.

  post "/v1/internal/deprovision-jobs/claim" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      case Registry.claim_next_deprovision_job(generate_claim_token()) do
        nil ->
          send_resp(conn, 204, "")

        {job, barkpark} ->
          json(conn, 200, deprovision_claim_json(job, barkpark))
      end
    end
  end

  post "/v1/internal/deprovision-jobs/:id/succeed" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      team_id = team_id_for_barkpark_of_job(conn.path_params["id"])

      case Registry.succeed_deprovision_job(conn.path_params["id"]) do
        {:ok, _} ->
          push_event(team_id, "fleet")
          json(conn, 200, %{ok: true})

        {:error, :conflict} ->
          json(conn, 409, %{error: "conflict"})

        {:error, _} ->
          json(conn, 422, %{error: "invalid"})
      end
    end
  end

  post "/v1/internal/deprovision-jobs/:id/fail" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      reason = conn.body_params["error"]

      case Registry.fail_job(
             conn.path_params["id"],
             if(is_binary(reason), do: reason, else: "unspecified")
           ) do
        {:ok, job} ->
          broadcast_barkpark_team(job.barkpark_id, "fleet")
          json(conn, 200, %{ok: true})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, :conflict} ->
          json(conn, 409, %{error: "conflict"})

        {:error, _} ->
          json(conn, 422, %{error: "invalid"})
      end
    end
  end

  ## Sites — hosted websites running co-located with a Barkpark.

  # POST /v1/sites {barkpark_id, name, framework?, domains?, scale_mode?} → 201
  # {site}. The site inherits its team_id from the Barkpark — the caller doesn't
  # (and can't) pick a different team.
  post "/v1/sites" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      true ->
        team = conn.assigns.current_team
        bp_id = conn.body_params["barkpark_id"]
        name = conn.body_params["name"]

        with true <- is_binary(bp_id),
             %Registry.Barkpark{team_id: tid} = bp when tid == team.id <-
               Registry.get_barkpark(bp_id),
             true <- is_binary(name) and name != "",
             slug <- conn.body_params["slug"] || slugify(name),
             attrs <- %{
               name: name,
               slug: slug,
               framework: conn.body_params["framework"] || "nextjs",
               domains: conn.body_params["domains"] || [],
               scale_mode: conn.body_params["scale_mode"] || "always_on"
             },
             # activity-audit-log: the create + a `site.created` audit event share
             # ONE transaction (the target_id is resolved from the created site).
             # target_fun supplies the id only knowable after the insert.
             {:ok, site} <-
               Accounts.audit(
                 %{
                   team_id: team.id,
                   actor_user_id: conn.assigns.current_user.id,
                   action: "site.created",
                   target_type: "site",
                   metadata: %{name: name, framework: attrs.framework, barkpark_id: bp.id}
                 },
                 fn -> Registry.create_site(bp, attrs) end,
                 fn s -> %{target_id: s.id} end
               ) do
          # Push "sites" so an open sites list / instance detail (including other
          # browser tabs) picks up the new site without a manual refresh.
          push_event(site.team_id, "sites")
          push_event(site.team_id, "audit")
          json(conn, 201, %{site: site_json(site)})
        else
          nil ->
            json(conn, 404, %{error: "barkpark_not_found"})

          %Registry.Barkpark{} ->
            # Existed but wrong team — same 404 as "not found" to avoid an
            # existence leak across team boundaries.
            json(conn, 404, %{error: "barkpark_not_found"})

          false ->
            json(conn, 422, %{error: "name_required"})

          {:error, %Ecto.Changeset{} = cs} ->
            json(conn, 422, %{error: "invalid", details: errors(cs)})
        end
    end
  end

  # GET /v1/sites → 200 {sites: [...]} for the user's team.
  get "/v1/sites" do
    conn = conn |> Auth.require_user_or_pat([]) |> Auth.require_ability("read")

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 200, %{sites: []})

      true ->
        sites = Registry.list_sites_for_team(conn.assigns.current_team)
        json(conn, 200, %{sites: Enum.map(sites, &site_json/1)})
    end
  end

  # GET /v1/sites/:id → 200 {site} | 404. Team-scoped — a wrong-team caller
  # gets the same 404 as a nonexistent id.
  get "/v1/sites/:id" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        case Registry.get_team_site(conn.assigns.current_team, conn.path_params["id"]) do
          %Registry.Site{} = site -> json(conn, 200, %{site: site_json(site)})
          nil -> json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # POST /v1/sites/:id/deploy {git_ref?, artifact_url?} → 201 {deployment}.
  # Enqueues a Deployment with status:"queued"; the off-box builder (P2) polls
  # for queued rows and walks them through building → pushing → live.
  post "/v1/sites/:id/deploy" do
    with_team_site(conn, {:ability, "write"}, fn site ->
      attrs = %{
        git_ref: conn.body_params["git_ref"],
        artifact_url: conn.body_params["artifact_url"]
      }

      case Registry.create_deployment(site, attrs) do
        {:ok, deployment} ->
          push_event(site.team_id, "deployments")
          json(conn, 201, %{deployment: deployment_json(deployment)})

        {:error, cs} ->
          json(conn, 422, %{error: "invalid", details: errors(cs)})
      end
    end)
  end

  # GET /v1/sites/:id/deployments → 200 {deployments: [...]} newest first.
  get "/v1/sites/:id/deployments" do
    with_team_site(conn, fn site ->
      deployments = Registry.list_deployments(site)
      json(conn, 200, %{deployments: Enum.map(deployments, &deployment_json/1)})
    end)
  end

  # POST /v1/sites/:id/artifact (application/octet-stream body) → 201
  # {artifact_url}. The CLI's `bp deploy` streams a tar.gz of the project dir
  # here; the control plane writes it to a configured artifact dir and returns
  # a `file://` URL the builder can read. This is the MVP of off-box artifact
  # storage — no S3, no signed URLs, just a host-local path the builder
  # process shares with the control plane.
  #
  # Size cap: 100 MB by default (configurable via :max_artifact_bytes). A
  # larger payload is refused with 413 and the partial file is removed.
  #
  # Ownership: a site in another team returns 404 (existence-leak protection),
  # same shape as a nonexistent id — never 403.
  post "/v1/sites/:id/artifact" do
    with_team_site(conn, fn site ->
      cfg = artifact_config()
      max = cfg[:max_artifact_bytes]
      dir = cfg[:artifact_dir]
      :ok = File.mkdir_p!(dir)

      filename = artifact_filename(site.slug)
      path = Path.join(dir, filename)

      case stream_body_to_file(conn, path, max) do
        {:ok, conn, bytes} ->
          url = "file://" <> path

          json(conn, 201, %{
            artifact_url: url,
            bytes: bytes,
            filename: filename
          })

        {:error, :too_large, conn} ->
          _ = File.rm(path)
          json(conn, 413, %{error: "artifact_too_large", max_bytes: max})

        {:error, reason, conn} ->
          _ = File.rm(path)
          json(conn, 500, %{error: "upload_failed", reason: inspect(reason)})
      end
    end)
  end

  # POST /v1/sites/:id/env {env: {...}} → 200 {ok: true}. Replaces the whole
  # encrypted env blob (Vault.encrypt-stored, never echoed back).
  post "/v1/sites/:id/env" do
    with_team_site(conn, fn site ->
      env = conn.body_params["env"]

      cond do
        not is_map(env) ->
          json(conn, 422, %{error: "env_required"})

        true ->
          case Registry.set_site_env(site, env) do
            {:ok, _} -> json(conn, 200, %{ok: true})
            {:error, cs} -> json(conn, 422, %{error: "invalid", details: errors(cs)})
          end
      end
    end)
  end

  # POST /v1/sites/:id/domains {domain} → 200 {site}. Adds the domain to the
  # site's array; the domain becomes acceptable to the on-demand-TLS ask-gate.
  post "/v1/sites/:id/domains" do
    with_team_site(conn, fn site ->
      domain = conn.body_params["domain"]

      cond do
        not is_binary(domain) or domain == "" ->
          json(conn, 422, %{error: "domain_required"})

        true ->
          case Registry.add_site_domain(site, domain) do
            {:ok, site} -> json(conn, 200, %{site: site_json(site)})
            {:error, cs} -> json(conn, 422, %{error: "invalid", details: errors(cs)})
          end
      end
    end)
  end

  # POST /v1/sites/:id/github {repo, branch?, webhook_secret?} → 200
  # {webhook_url, webhook_secret, site}.
  #
  # Link a GitHub repo + branch to this Site so pushes to <branch> of <repo>
  # auto-create a Deployment (verified via HMAC-SHA256 against the stored
  # secret). `repo` is the "owner/repo" form GitHub uses. `branch` defaults to
  # "main" on the server. `webhook_secret` is the value the user will paste
  # into GitHub's webhook "Secret" field — when omitted, the server generates a
  # cryptographically random one and returns it ONCE in this response (it is
  # Vault-encrypted at rest and never returned again).
  post "/v1/sites/:id/github" do
    with_team_site(conn, fn site ->
      repo = conn.body_params["repo"]
      branch = conn.body_params["branch"]
      provided = conn.body_params["webhook_secret"]

      cond do
        not (is_binary(repo) and repo != "") ->
          json(conn, 422, %{error: "repo_required"})

        true ->
          # Generate a secret when the user didn't pass one. Always echo BACK
          # the plaintext secret in the success response (this is the ONLY
          # moment plaintext leaves the server) so the user can paste it into
          # GitHub's webhook form.
          plaintext_secret =
            cond do
              is_binary(provided) and provided != "" -> provided
              true -> generate_webhook_secret()
            end

          case Registry.set_site_github(site, repo, branch, plaintext_secret) do
            {:ok, updated} ->
              json(conn, 200, %{
                site: site_json(updated),
                webhook_url: webhook_url_for(conn, updated.id),
                webhook_secret: plaintext_secret
              })

            {:error, cs} ->
              json(conn, 422, %{error: "invalid", details: errors(cs)})
          end
      end
    end)
  end

  # POST /v1/webhooks/github/:site_id  — NO bearer auth (verified via HMAC).
  #
  # GitHub POSTs a push event here; the route:
  #   1. Looks up the Site by id (404 silently when missing or not configured).
  #   2. Verifies X-Hub-Signature-256 (HMAC-SHA256 over the raw body) against
  #      the Vault-decrypted webhook secret — CONSTANT-TIME compare. 401 on bad
  #      sig (no detail; do not help an attacker tune their guesses).
  #   3. Only ACTS on `X-GitHub-Event: push`. Other events (ping, pull_request,
  #      …) are acknowledged 200 with `ignored:true` so GitHub stops retrying.
  #   4. Compares the pushed ref (`refs/heads/<branch>`) to the Site's
  #      configured branch — a push to a different branch is a no-op 200
  #      `{ignored: true, reason: "branch_mismatch"}`.
  #   5. Creates a Deployment with `git_ref = <pushed sha>`. Returns 201
  #      `{deployment_id, sha, branch}`.
  #
  # This route is OUTSIDE the team-auth path on purpose: a webhook fires before
  # any user is logged in. The HMAC + the opaque site UUID are the only gates.
  post "/v1/webhooks/github/:site_id" do
    site_id = conn.path_params["site_id"]
    site = Registry.get_site(site_id)

    cond do
      is_nil(site) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        case Registry.reveal_site_github_secret(site) do
          {:ok, nil} ->
            # No webhook configured — same shape as "not found" so a probe
            # cannot distinguish unconfigured from nonexistent.
            json(conn, 404, %{error: "not_found"})

          :error ->
            json(conn, 500, %{error: "secret_unreadable"})

          {:ok, secret} when is_binary(secret) ->
            raw = raw_request_body(conn)
            sig = get_first_header(conn, "x-hub-signature-256")

            if verify_github_signature(raw, secret, sig) do
              handle_verified_github_push(conn, site)
            else
              json(conn, 401, %{error: "bad_signature"})
            end
        end
    end
  end

  # GET /v1/tls/ask?domain=... → 200 (registered) | 404 (not). NO AUTH on
  # purpose: this is the Caddy `on_demand_tls.ask` gate. Caddy calls this
  # BEFORE attempting a cert issuance for a hostname; a 200 says "we own this,
  # go ahead", a 404 says "stop". The 404 is what prevents the box from being
  # a cert-issuance DoS target. Bodies are empty — Caddy only reads the status.
  get "/v1/tls/ask" do
    domain = conn.query_params["domain"] || ""

    cond do
      domain == "" -> send_resp(conn, 404, "")
      Registry.domain_registered?(domain) -> send_resp(conn, 200, "")
      true -> send_resp(conn, 404, "")
    end
  end

  ## Builder routes — the off-box build plane (P2 / Move A).
  ##
  ## Builders authenticate with a user session token for now (a dedicated
  ## builder-token type is a hardening follow-up). Auth scope: a builder may
  ## claim any queued deployment regardless of team — the build plane is
  ## fleet-wide. The user-token check is a coarse "is this a real user of
  ## Barkpark Cloud" gate. Sites the builder touches still belong to whichever
  ## team owns them; the builder never re-team a deployment.

  # POST /v1/internal/provision-jobs/:id/fail {error} → mark the job failed; the
  # Barkpark stays provisioning. IDEMPOTENT + status-guarded:
  #   200 {ok: true} — a fresh fail OR a retried fail for an already-"failed" job.
  #   409 {error: "conflict"} — the job already "succeeded"; a straggler fail must
  #     not un-succeed a live box.
  #   404 when no job has that id.
  post "/v1/internal/provision-jobs/:id/fail" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      reason = conn.body_params["error"]

      case Registry.fail_job(
             conn.path_params["id"],
             if(is_binary(reason), do: reason, else: "unspecified")
           ) do
        {:ok, job} ->
          # Push "fleet" so the dashboard surfaces the failed launch (with its
          # error + a retry affordance) instead of a stuck "provisioning".
          broadcast_barkpark_team(job.barkpark_id, "fleet")
          # notifications-email: failure alert (on by default — alert hygiene).
          dispatch_barkpark_event(job.barkpark_id, :provision_failed, %{detail: job.error})
          json(conn, 200, %{ok: true})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, :conflict} ->
          json(conn, 409, %{error: "conflict"})

        {:error, _} ->
          json(conn, 422, %{error: "invalid"})
      end
    end
  end

  # POST /v1/builder/claim {worker_id} → 200 {deployment, observed_epoch} |
  # 404 {error: "no_queued"} | 422 missing worker_id.
  # Atomic via Registry.claim_next_deployment/1 (FOR UPDATE SKIP LOCKED +
  # epoch bump in one transaction).
  post "/v1/builder/claim" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      worker_id = conn.body_params["worker_id"]

      cond do
        not (is_binary(worker_id) and worker_id != "") ->
          json(conn, 422, %{error: "worker_id_required"})

        true ->
          case Registry.claim_next_deployment(worker_id) do
            {:ok, deployment} ->
              json(conn, 200, %{
                deployment: deployment_json(deployment),
                observed_epoch: deployment.claim_epoch
              })

            {:error, :no_queued} ->
              json(conn, 404, %{error: "no_queued"})
          end
      end
    end
  end

  # POST /v1/builder/deployments/:id/transition
  # {worker_id, observed_epoch, status, image_tag?, build_log_url?,
  #  failure_reason?, became_live_at?} → 200 {deployment} | 409 stale_epoch |
  # 404 not_found | 422 invalid.
  #
  # CASes on (claim_worker, claim_epoch) — the only protection against a stale
  # lease-swept worker writing after another worker re-claimed the row.
  post "/v1/builder/deployments/:id/transition" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      params = conn.body_params
      worker_id = params["worker_id"]
      epoch = parse_epoch(params["observed_epoch"])

      cond do
        not (is_binary(worker_id) and worker_id != "") ->
          json(conn, 422, %{error: "worker_id_required"})

        is_nil(epoch) ->
          json(conn, 422, %{error: "observed_epoch_required"})

        true ->
          attrs =
            %{}
            |> maybe_put(:status, params["status"])
            |> maybe_put(:image_tag, params["image_tag"])
            |> maybe_put(:build_log_url, params["build_log_url"])
            |> maybe_put(:failure_reason, params["failure_reason"])
            |> maybe_put_datetime(:became_live_at, params["became_live_at"])
            # Explicit null-clearing handoff between stages. The builder, when
            # transitioning a row to `pushing`, explicitly sends `claim_worker:
            # null` + `claim_epoch: 0` so the row appears unclaimed to the
            # agent's claim query. Only null/zero values pass — never a
            # different worker id, never a positive epoch. This is the only
            # path that mutates claim_* outside the claim/sweep paths.
            |> put_handoff_claim_worker(params)
            |> put_handoff_claim_epoch(params)

          case Registry.transition_deployment_fenced(
                 conn.path_params["id"],
                 worker_id,
                 epoch,
                 attrs
               ) do
            {:ok, deployment} ->
              # Push "deployments" so an open site view advances the row
              # (queued → building → pushing → live) without a manual refresh.
              broadcast_site_team(deployment.site_id, "deployments")
              json(conn, 200, %{deployment: deployment_json(deployment)})

            {:error, :stale_epoch} ->
              json(conn, 409, %{error: "stale_epoch"})

            {:error, :not_found} ->
              json(conn, 404, %{error: "not_found"})

            {:error, %Ecto.Changeset{} = cs} ->
              json(conn, 422, %{error: "invalid", details: errors(cs)})
          end
      end
    end
  end

  ## Agent runtime routes (P3 / Move A finish) — agent-authed via require_agent.
  ## The on-box runtime executor calls these to walk a Deployment from `pushing`
  ## (set by the builder) → `live` (running container behind Caddy) or `failed`
  ## (health-check failure). Scope is strictly the agent's current_barkpark.

  # GET /v1/agent/pending → 200 {deployments: [{... site: {slug, domains}}]}.
  # The agent runtime needs the site's slug + domains to render its Caddyfile
  # block on a first-time deploy; bundling the site shape with each deployment
  # avoids a second round trip for the common case.
  get "/v1/agent/pending" do
    conn = Auth.require_agent(conn, [])

    if conn.halted do
      conn
    else
      bp = conn.assigns.current_barkpark
      ds = Registry.list_pending_deployments_for_barkpark(bp)
      json(conn, 200, %{deployments: Enum.map(ds, &deployment_with_site_json/1)})
    end
  end

  # POST /v1/agent/deployments/claim {worker_id} → 200 {deployment,
  # observed_epoch} | 404 no_pending | 422 missing.
  #
  # Atomic — picks the oldest pushing row whose site is on current_barkpark,
  # bumps the epoch, stamps the worker. Same fencing semantics as the builder
  # claim, narrower filter. Status STAYS `pushing` (the agent transitions to
  # `live` via /transition once the container is up).
  post "/v1/agent/deployments/claim" do
    conn = Auth.require_agent(conn, [])

    if conn.halted do
      conn
    else
      worker_id = conn.body_params["worker_id"]

      cond do
        not (is_binary(worker_id) and worker_id != "") ->
          json(conn, 422, %{error: "worker_id_required"})

        true ->
          bp = conn.assigns.current_barkpark

          case Registry.claim_pending_deployment_for_barkpark(bp, worker_id) do
            {:ok, deployment} ->
              json(conn, 200, %{
                deployment: deployment_with_site_json(deployment),
                observed_epoch: deployment.claim_epoch
              })

            {:error, :no_pending} ->
              json(conn, 404, %{error: "no_pending"})
          end
      end
    end
  end

  # POST /v1/agent/deployments/:id/transition
  # {worker_id, observed_epoch, status, image_tag?, became_live_at?,
  #  failure_reason?, site_port?, make_current?}
  #
  # The agent's fenced transition. When `make_current=true` AND `status=live`,
  # the Site's `current_deployment_id` is set to this deployment AND `port` is
  # set to `site_port` — in the SAME transaction as the deployment status flip.
  # No window where the deployment is `live` but the site's pointer is stale.
  #
  # Scope: the deployment's site must belong to current_barkpark — otherwise
  # 404 (no cross-box transition leak).
  post "/v1/agent/deployments/:id/transition" do
    conn = Auth.require_agent(conn, [])

    if conn.halted do
      conn
    else
      params = conn.body_params
      worker_id = params["worker_id"]
      epoch = parse_epoch(params["observed_epoch"])

      cond do
        not (is_binary(worker_id) and worker_id != "") ->
          json(conn, 422, %{error: "worker_id_required"})

        is_nil(epoch) ->
          json(conn, 422, %{error: "observed_epoch_required"})

        true ->
          deployment_id = conn.path_params["id"]
          bp = conn.assigns.current_barkpark

          # Cross-box check: the deployment's site must belong to current_barkpark.
          # 404 (same as nonexistent) — never an existence leak.
          case agent_owns_deployment?(bp, deployment_id) do
            false ->
              json(conn, 404, %{error: "not_found"})

            true ->
              attrs =
                %{}
                |> maybe_put(:status, params["status"])
                |> maybe_put(:image_tag, params["image_tag"])
                |> maybe_put(:failure_reason, params["failure_reason"])
                |> maybe_put(:build_log_url, params["build_log_url"])
                |> maybe_put_datetime(:became_live_at, params["became_live_at"])

              site_attrs =
                cond do
                  params["make_current"] == true and params["status"] == "live" ->
                    %{}
                    |> maybe_put(:current_deployment_id, deployment_id)
                    |> maybe_put(:port, params["site_port"])

                  true ->
                    nil
                end

              result =
                if site_attrs do
                  Registry.transition_deployment_with_site_update(
                    deployment_id,
                    worker_id,
                    epoch,
                    attrs,
                    site_attrs
                  )
                else
                  Registry.transition_deployment_fenced(
                    deployment_id,
                    worker_id,
                    epoch,
                    attrs
                  )
                end

              case result do
                {:ok, deployment} ->
                  # Push "deployments" so an open site view advances the row to its
                  # FINAL state (pushing → live / failed) without a manual refresh —
                  # the agent owns this last transition (mirrors the builder route).
                  broadcast_site_team(deployment.site_id, "deployments")
                  json(conn, 200, %{deployment: deployment_json(deployment)})

                {:error, :stale_epoch} ->
                  json(conn, 409, %{error: "stale_epoch"})

                {:error, :not_found} ->
                  json(conn, 404, %{error: "not_found"})

                {:error, %Ecto.Changeset{} = cs} ->
                  json(conn, 422, %{error: "invalid", details: errors(cs)})
              end
          end
      end
    end
  end

  ## Health / status surfaces (health-status)

  # GET /up, GET /health — control-plane liveness. 200 {db: "up"} | 503 {db: "down"}.
  # UNAUTHENTICATED: this is the load-balancer / uptime-monitor probe. The check
  # is a single `SELECT 1` round-trip to the control plane's own Postgres (its
  # only hard dependency) via BarkparkCloud.Health.health/0. Sits OUTSIDE /v1 (so
  # it never collides with the JSON API) and is NOT in the Plug.Static allowlist
  # (so nothing shadows it). `/up` mirrors Phoenix's conventional liveness path;
  # `/health` is the common alias.
  get("/up", do: send_health(conn))
  get("/health", do: send_health(conn))

  # GET /v1/barkparks/:id/events → 200 {events: [...]} newest first | 404.
  # User-authed + TEAM-SCOPED: a wrong-team / nonexistent id is the SAME 404 (no
  # existence leak), matching DELETE /v1/barkparks/:id. Surfaces the granular
  # history the agent already writes (disk%, PG size, backup, dirty-tree, the
  # health-gate array) plus the new "status" transition rows — a pure read over
  # Registry.recent_events_for_team/3, no new model. `?limit=` caps the window
  # (default 50, max 200).
  get "/v1/barkparks/:id/events" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        conn = fetch_query_params(conn)
        limit = parse_limit(conn.query_params["limit"], 50, 200)

        case Registry.recent_events_for_team(
               conn.assigns.current_team,
               conn.path_params["id"],
               limit
             ) do
          nil -> json(conn, 404, %{error: "not_found"})
          events -> json(conn, 200, %{events: Enum.map(events, &event_json/1)})
        end
    end
  end

  ## Catch-all → 404 JSON

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  ## Health surface helpers (health-status)

  # Routes BarkparkCloud.Health.health/0 to an HTTP status: 200 when the Repo
  # answers SELECT 1, 503 when it doesn't. Never raises (health/0 rescues).
  defp send_health(conn) do
    case BarkparkCloud.Health.health() do
      {:ok, body} -> json(conn, 200, body)
      {:error, body} -> json(conn, 503, body)
    end
  end

  # One agent-event row, JSON-shaped for GET /v1/barkparks/:id/events. The
  # append-only stream has no updated_at — only inserted_at.
  defp event_json(e) do
    %{id: e.id, type: e.type, payload: e.payload, inserted_at: e.inserted_at}
  end

  # Clamp the ?limit= window: a positive integer capped at `max`, else `default`.
  defp parse_limit(nil, default, _max), do: default

  defp parse_limit(s, default, max) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> min(n, max)
      _ -> default
    end
  end

  defp parse_limit(_, default, _max), do: default

  ## go-live handler (shared by /launch and /go-live)

  defp go_live(conn) do
    # go-live is the launch action — accept a session OR a PAT, but gate each
    # principal correctly (CREDENTIAL-AWARE):
    #   * a PAT must carry the `deploy` ability (Coolify's exclusive deploy-token).
    #   * a SESSION carries ["root"], so `require_ability` is a no-op for it — gate
    #     the session branch on TEAM-ADMIN inline here. NOT
    #     `require_primary_team_admin/1`, which re-runs `require_user` and discards
    #     the resolved PAT/session assigns.
    # The ROLE check precedes the entitlement (402) check, so a plain member gets
    # 403 (not 402) and the deploy-PAT path still works.
    conn = Auth.require_user_or_pat(conn, [])

    conn =
      cond do
        conn.halted ->
          conn

        # PAT bearer → must carry the `deploy` ability.
        conn.assigns[:current_token] ->
          Auth.require_ability(conn, "deploy")

        # Session with no team → fall through to the 422 no_team branch below.
        is_nil(conn.assigns[:current_team]) ->
          conn

        # Session → must be owner/admin of the resolved team.
        Accounts.team_admin?(conn.assigns.current_user, conn.assigns.current_team) ->
          conn

        true ->
          conn |> json(403, %{error: "forbidden"}) |> halt()
      end

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      # The launch gate: ENTITLEMENT is REQUIRED — an active subscription, or a
      # past_due one still inside its grace window (a transient dunning state
      # must not lock out a paying customer; Coolify-anchor: isSubscriptionActive
      # stays true through stripe_past_due). Not entitled → 402 and provision
      # NOTHING. The check runs before any name validation so an unentitled caller
      # always learns to subscribe (the actionable next step), not "name_required".
      not Billing.entitled?(conn.assigns.current_team) ->
        json(conn, 402, %{
          error: "no_active_subscription",
          checkout_path: "/v1/billing/checkout"
        })

      # usage-limits-quotas: the QUOTA gate — the plan's managed-instance ceiling.
      # 403 (authenticated AND entitled, but the plan forbids one more) with the
      # actionable upgrade path, surfaced BEFORE the caller fills in a name. It
      # runs AFTER the 402 so an unsubscribed caller still learns "subscribe"
      # first. The Registry.register_barkpark/2 guard below is the un-bypassable
      # backstop for any path that skips this handler (the agent/internal register).
      Billing.barkpark_limit_reached?(conn.assigns.current_team) ->
        json(conn, 403, %{
          error: "limit_reached",
          limit: Billing.barkpark_limit(conn.assigns.current_team),
          upgrade_path: "/v1/billing/checkout"
        })

      true ->
        team = conn.assigns.current_team
        name = conn.body_params["name"]
        slug = if(is_binary(name), do: slugify(name), else: nil)

        with true <- is_binary(name) and name != "",
             # Clean-first FQDN: `<slug>.barkpark.cloud` when the slug is free
             # and not reserved, else the globally-unique
             # `<slug>-<team_short_id>` form. The `:url` global unique index is
             # both the reservation mechanism and the cross-tenant backstop;
             # claim_json reads the DNS label back off the stored `url` so the
             # provisioned FQDN == the customer-facing FQDN (clean or suffixed).
             {:ok, barkpark} <-
               Registry.register_managed_barkpark(team, name, slug) do
          # activity-audit-log: record `barkpark.go_live` POST-COMMIT, best-effort.
          # register_managed_barkpark is clean-first-then-suffix: its FIRST insert
          # may hit the url unique index and RECOVER by retrying with the suffixed
          # FQDN. That recovery is incompatible with an enclosing transaction (the
          # failed insert would poison it), so this seam CANNOT use the atomic
          # audit/3 wrapper. Recording after the row commits mirrors the
          # already-best-effort provision-job enqueue below; a failed audit insert
          # is logged, never 500s a successful launch.
          case Accounts.record_audit(%{
                 team_id: team.id,
                 actor_user_id: conn.assigns.current_user.id,
                 action: "barkpark.go_live",
                 target_type: "barkpark",
                 target_id: barkpark.id,
                 metadata: %{name: name, plan: conn.body_params["plan"]}
               }) do
            {:ok, _} -> :ok
            {:error, cs} -> Logger.error("audit barkpark.go_live failed: #{inspect(cs)}")
          end

          # Async half: hand the provisioning work to the Go warm-pool worker
          # via a pending job. The subscription gate ALREADY passed and the
          # barkpark row ALREADY exists in a provisioning state by this point, so
          # an enqueue hiccup (a DB blip) must NOT 500 the request — that would
          # strand a launched-but-unprovisioned go-live. A missed job is
          # recoverable (the row carries the provisioning state; re-enqueue is a
          # separate concern), so on error we LOG and still return the normal 201.
          case Registry.enqueue_provision_job(barkpark) do
            {:ok, _job} ->
              :ok

            {:error, reason} ->
              Logger.error(
                "go_live: failed to enqueue provision job for barkpark #{barkpark.id}: " <>
                  inspect(reason)
              )
          end

          # Live-push the new provisioning row to any open dashboard tab.
          push_event(team.id, "fleet")
          push_event(team.id, "audit")
          json(conn, 201, %{barkpark: barkpark_json(barkpark)})
        else
          false ->
            json(conn, 422, %{error: "name_required"})

          # usage-limits-quotas: a race that slipped past the cond's quota check
          # (a concurrent create that filled the last slot between the check and
          # the insert) still returns 403, never a 500. The context guard is the
          # backstop; this maps it to the same friendly response.
          {:error, :limit_reached} ->
            json(conn, 403, %{
              error: "limit_reached",
              limit: Billing.barkpark_limit(team),
              upgrade_path: "/v1/billing/checkout"
            })

          {:error, %Ecto.Changeset{} = changeset} ->
            json(conn, 422, %{error: "invalid", details: errors(changeset)})
        end
    end
  end

  ## register handler (POST /v1/auth/register)

  # The transactional signup: register the user, create a team (the given
  # team_name, or one derived from the email local-part, deduped against the
  # slug unique), grant the user "owner" on it, and mint a session token. All
  # four steps share ONE transaction — any failure rolls the whole thing back,
  # so a rejected membership/token never strands a half-created user+team.
  #
  # The citext unique index on users.email is the race backstop: two concurrent
  # registers that both pass the pre-insert get_user_by_email check collide here
  # on insert; the loser's changeset carries the unique-constraint error, which
  # register_error/1 maps to 409 (never a 500).
  defp register(email, password, team_name, session_opts) do
    result =
      Repo.transaction(fn ->
        with {:ok, user} <- Accounts.register_user(%{email: email, password: password}),
             {:ok, team} <- create_signup_team(user, team_name),
             {:ok, _membership} <- Accounts.add_member(team, user, "owner"),
             # BILL-1: grant the new team a self-serve FREE TRIAL in the SAME tx,
             # right after the team+membership land — so a brand-new user is
             # ENTITLED immediately and can go live with no operator/SSH and no
             # card. No gateway/charge; the trial lapses after 14 days (entitlement
             # enforced against current_period_end), after which they subscribe.
             # Inside the transaction so a trial-grant failure rolls the whole
             # signup back rather than stranding an un-entitled team.
             {:ok, _trial} <- Billing.grant_trial(team),
             # notifications-email: auto-create the team's email-notification
             # settings row in the SAME tx (mirrors Coolify's Team.php:59
             # auto-create). A lazy get_or_create_settings/1 backstops any team
             # that predates this.
             {:ok, _settings} <- Notifications.ensure_settings(team),
             {:ok, token} <- Accounts.create_user_session_token(user, session_opts) do
          %{user: user, team: team, token: token}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, payload} -> {:ok, payload}
      {:error, %Ecto.Changeset{} = changeset} -> classify_register_error(changeset)
      {:error, other} -> {:error, other}
    end
  end

  # Create the signup team. With an explicit team_name we slugify it directly;
  # otherwise we derive a slug from the email local-part. Either way the slug is
  # deduped against the teams.slug unique by appending -2, -3, … on collision.
  #
  # Dedup is a PRE-INSERT lookup (get_team_by_slug), NOT a try-insert-on-error
  # loop: this whole call runs inside the signup transaction, and a unique
  # violation there aborts the entire Postgres transaction (25P02) — every later
  # statement then fails. So we pick a free slug first, then insert once. The
  # teams.slug unique index is still the race backstop; a genuine concurrent
  # collision surfaces as a changeset error → 422 (rare, user-retriable).
  defp create_signup_team(user, team_name) do
    {name, base_slug} =
      if is_binary(team_name) and String.trim(team_name) != "" do
        {team_name, slugify(team_name)}
      else
        local = user.email |> String.split("@") |> List.first()
        {local, slugify(local)}
      end

    Accounts.create_team(%{name: name, slug: dedupe_slug(base_slug, 0)})
  end

  # Find a free slug by pre-checking the teams.slug unique: base, then base-2,
  # base-3, … Bounded so a pathological run can't loop forever (falls through to
  # the base slug, letting the insert + unique index reject it as a 422).
  defp dedupe_slug(base_slug, attempt) when attempt < 50 do
    candidate = if attempt == 0, do: base_slug, else: "#{base_slug}-#{attempt + 1}"

    if Accounts.get_team_by_slug(candidate),
      do: dedupe_slug(base_slug, attempt + 1),
      else: candidate
  end

  defp dedupe_slug(base_slug, _attempt), do: base_slug

  # A changeset bubbling out of the transaction is either a duplicate-email
  # unique-violation (→ :email_taken, the citext race backstop) or a genuine
  # validation failure (→ the changeset, mapped to 422 by the caller).
  defp classify_register_error(%Ecto.Changeset{errors: errors} = changeset) do
    email_unique? =
      Enum.any?(errors, fn
        {:email, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
        _ -> false
      end)

    if email_unique?, do: {:error, :email_taken}, else: {:error, changeset}
  end

  # Map a validation changeset to the 422 body. A single offending field becomes
  # `{error: "<field>_invalid"}`; multiple fields fall back to
  # `{error: "validation_failed", details: {...}}`. Either way `details` carries
  # the per-field messages for an honest client surface.
  defp register_error(%Ecto.Changeset{} = changeset) do
    details = errors(changeset)

    case Map.keys(details) do
      [field] -> %{error: "#{field}_invalid", details: details}
      _ -> %{error: "validation_failed", details: details}
    end
  end

  ## Serializers — the precise JSON shapes cloud-12b's Go client must match.

  # instance-admin-token: build the succeed_job opts from the (optional) reported
  # admin token. A non-empty binary becomes `[admin_token: t]`; anything else
  # (missing/blank/non-string) yields `[]`, preserving the ip-only succeed path.
  defp succeed_opts(token) when is_binary(token) and token != "", do: [admin_token: token]
  defp succeed_opts(_), do: []

  defp barkpark_json(bp, provision \\ nil, deprovision \\ nil) do
    base = %{
      id: bp.id,
      name: bp.name,
      slug: bp.slug,
      url: bp.url,
      host: bp.host,
      mode: bp.mode,
      health_status: bp.health_status,
      agent_status: bp.agent_status,
      version: bp.version,
      git_commit: bp.git_commit,
      last_seen_at: bp.last_seen_at,
      team_id: bp.team_id,
      # Billing-suspension axis (subscription-billing) — the dashboard renders a
      # "suspended (billing)" state distinct from a health-down box.
      suspended: bp.suspended,
      suspended_reason: bp.suspended_reason,
      inserted_at: bp.inserted_at
    }

    base
    |> merge_job_status(:provision_status, :provision_error, provision)
    |> merge_job_status(:deprovision_status, :deprovision_error, deprovision)
  end

  defp merge_job_status(map, status_key, error_key, %{status: status, error: error}),
    do: Map.merge(map, %{status_key => status, error_key => error})

  defp merge_job_status(map, _status_key, _error_key, _), do: map

  ## Onboarding action dispatch + serializer

  defp handle_onboarding_action(conn, %{"action" => "advance", "step" => step}, team) do
    if step in Team.onboarding_steps() do
      {:ok, team} = Accounts.advance_onboarding(team, step)
      onboarding_ok(conn, team)
    else
      json(conn, 422, %{error: "unknown_step"})
    end
  end

  defp handle_onboarding_action(conn, %{"action" => "ack", "step" => step}, team) do
    if step in Team.onboarding_steps() do
      {:ok, team} = Accounts.ack_onboarding_step(team, step)
      onboarding_ok(conn, team)
    else
      json(conn, 422, %{error: "unknown_step"})
    end
  end

  defp handle_onboarding_action(conn, %{"action" => "skip"}, team) do
    {:ok, team} = Accounts.skip_onboarding(team)
    onboarding_ok(conn, team)
  end

  defp handle_onboarding_action(conn, %{"action" => "complete"}, team) do
    if Accounts.onboarding_status(team).all_done? do
      {:ok, team} = Accounts.complete_onboarding(team)
      onboarding_ok(conn, team)
    else
      json(conn, 422, %{error: "steps_incomplete"})
    end
  end

  defp handle_onboarding_action(conn, _bad, _team), do: json(conn, 422, %{error: "bad_action"})

  defp onboarding_ok(conn, team) do
    push_event(team.id, "onboarding")
    json(conn, 200, %{onboarding: onboarding_json(Accounts.onboarding_status(team))})
  end

  # The non-secret onboarding shape for the dashboard's "Finish setup" checklist.
  defp onboarding_json(status) do
    %{
      completed: status.completed?,
      completed_at: status.completed_at,
      last_step: status.last_step,
      all_done: status.all_done?,
      steps: Enum.map(status.steps, &%{key: &1.key, done: &1.done})
    }
  end

  # The non-secret subscription shape for the dashboard's Billing view. Gateway
  # customer / subscription ids are NEVER serialized.
  defp subscription_json(sub) do
    %{
      plan: sub.plan,
      status: sub.status,
      # Lifecycle / dunning state (subscription-billing) so the Billing view can
      # show "past due" / "cancels at period end" without a second call.
      past_due: sub.past_due,
      cancel_at_period_end: sub.cancel_at_period_end,
      current_period_end: sub.current_period_end,
      canceled_at: sub.canceled_at,
      started_at: sub.inserted_at
    }
  end

  # A team member row for the dashboard's Members view. No secrets — just the
  # identity + the grant.
  defp member_json(%{user: user, role: role, joined_at: joined_at}) do
    %{user_id: user.id, email: user.email, role: role, joined_at: joined_at}
  end

  # A pending invitation. token_hash is NEVER serialized — the plaintext appears
  # exactly once, in the POST response's accept_url.
  defp invitation_json(inv) do
    %{
      id: inv.id,
      email: inv.email,
      role: inv.role,
      expires_at: inv.expires_at,
      inserted_at: inv.inserted_at
    }
  end

  # Build the copy-paste accept URL the inviter shares out-of-band. The scheme +
  # host come from the request (so dev http:// and prod https://api.barkpark.cloud
  # both work without threading config) — mirrors webhook_url_for/2. The SPA is
  # hash-routed, so the token rides a `#/invitations/accept?token=` fragment.
  defp accept_url(conn, raw_token) do
    scheme = conn.scheme |> to_string()
    host = conn.host

    port_part =
      cond do
        scheme == "https" and conn.port == 443 -> ""
        scheme == "http" and conn.port == 80 -> ""
        true -> ":" <> Integer.to_string(conn.port)
      end

    "#{scheme}://#{host}#{port_part}/#/invitations/accept?token=#{raw_token}"
  end

  # The emailed password-reset link. Same request-derived scheme/host/port as
  # accept_url/2 (dev http:// and prod https://api.barkpark.cloud both work with
  # no threaded config); the SPA is hash-routed, so the token rides a
  # `#/auth/reset?token=` fragment the reset view reads.
  defp reset_url(conn, raw_token) do
    scheme = conn.scheme |> to_string()
    host = conn.host

    port_part =
      cond do
        scheme == "https" and conn.port == 443 -> ""
        scheme == "http" and conn.port == 80 -> ""
        true -> ":" <> Integer.to_string(conn.port)
      end

    "#{scheme}://#{host}#{port_part}/#/auth/reset?token=#{raw_token}"
  end

  # One audit-trail row for GET /v1/audit. `actor` is the actor User flattened to
  # {id, email} (preloaded by list_audit_events) or nil for a system/webhook
  # action. metadata is the free jsonb context map, echoed as-is.
  defp audit_json(e) do
    %{
      id: e.id,
      action: e.action,
      actor: e.actor_user && %{id: e.actor_user.id, email: e.actor_user.email},
      target_type: e.target_type,
      target_id: e.target_id,
      metadata: e.metadata,
      inserted_at: e.inserted_at
    }
  end

  defp provider_json(p) do
    # encrypted_token is NEVER serialized — the connected token stays at rest.
    %{
      id: p.id,
      kind: p.kind,
      label: p.label,
      team_id: p.team_id,
      inserted_at: p.inserted_at
    }
  end

  # The non-secret PAT shape for the dashboard's API-tokens view. NEVER emits
  # token_hash and NEVER the plaintext (the plaintext is returned once, only in
  # the POST /v1/tokens mint response). `revoked_at` non-nil renders as a
  # "revoked" tombstone client-side.
  defp pat_json(t) do
    %{
      id: t.id,
      name: t.name,
      abilities: t.abilities,
      last_used_at: t.last_used_at,
      expires_at: t.expires_at,
      revoked_at: t.revoked_at,
      inserted_at: t.inserted_at
    }
  end

  # Map the requested expiry to a bounded day-count (or nil = never). The set
  # `7/30/60/90/365` mirrors Coolify's ApiTokens expiry select
  # (app/Livewire/Security/ApiTokens.php) so every token has a finite horizon
  # unless "never" is explicitly chosen. `0` / "never" → nil; anything outside
  # the set falls back to the PAT default (30 days) — the server is the
  # authority, the client cannot smuggle an arbitrary lifetime.
  defp parse_expiry(nil), do: UserToken.pat_default_validity_days()
  defp parse_expiry(0), do: nil
  defp parse_expiry("never"), do: nil
  defp parse_expiry(n) when is_integer(n) and n in [7, 30, 60, 90, 365], do: n

  defp parse_expiry(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> parse_expiry(n)
      _ -> UserToken.pat_default_validity_days()
    end
  end

  defp parse_expiry(_), do: UserToken.pat_default_validity_days()

  # The claim payload the Go warm-pool provisioner decodes into a go-live spec:
  # the job id to report back against, the Barkpark's name + subdomain label, and
  # the region / server_type (warm-pool defaults — nbg1/cax11 — since the Barkpark
  # row doesn't pin them yet). Keys are EXACTLY what the Go worker expects.
  #
  # `slug` carries the GLOBALLY-unique provisioning subdomain (`<slug>-<team_short_id>`),
  # NOT the bare per-team slug — the worker turns this label into the DNS record
  # (`<label>.barkpark.cloud`) and the Hetzner box name, both of which MUST be
  # globally unique or two tenants collide. This is the SAME value stored in the
  # Barkpark's `:url`, so the provisioned FQDN == the customer-facing FQDN.
  defp claim_json(job, barkpark) do
    %{
      job_id: job.id,
      name: barkpark.name,
      slug: Barkpark.subdomain_from_url(barkpark),
      region: Registry.default_region(),
      server_type: Registry.default_server_type(),
      # The decrypted team + instance env, merged most-specific-wins. The worker
      # bakes these into the box's runtime env at provision time. Resolved at
      # CLAIM time so a retry / stale-claim re-pick carries rotated values. Sent
      # ONLY over the worker-token-authed internal channel (TLS in prod) — the
      # one place the plaintext must exist so the values can reach the instance.
      # Additive: an OLD worker simply ignores the key.
      env: Registry.resolved_env_for_barkpark(barkpark)
    }
  end

  defp env_var_json(%Registry.EnvVar{} = e) do
    # value_encrypted is NEVER serialized — the value stays at rest. The list
    # view is metadata-only: a secret is set-and-forget, surfaced by key, not
    # value (the masking discipline of provider_json/1 + site_json/1).
    %{
      id: e.id,
      key: e.key,
      scope: e.scope,
      barkpark_id: e.barkpark_id,
      is_secret: e.is_secret,
      is_shown_once: e.is_shown_once,
      comment: e.comment,
      inserted_at: e.inserted_at,
      updated_at: e.updated_at
    }
  end

  defp deprovision_claim_json(job, barkpark) do
    %{
      job_id: job.id,
      ip: barkpark.host,
      dns_label: Barkpark.subdomain_from_url(barkpark),
      dns_zone: Barkpark.base_domain()
    }
  end

  defp site_json(s) do
    # env_encrypted is NEVER serialized — the env blob stays at rest.
    # github_webhook_secret_encrypted is NEVER serialized either; the plaintext
    # is shown ONCE in the POST /v1/sites/:id/github response body and that's it.
    %{
      id: s.id,
      barkpark_id: s.barkpark_id,
      team_id: s.team_id,
      name: s.name,
      slug: s.slug,
      framework: s.framework,
      domains: s.domains,
      scale_mode: s.scale_mode,
      port: s.port,
      current_deployment_id: s.current_deployment_id,
      github_repo: s.github_repo,
      github_branch: s.github_branch,
      github_webhook_configured: not is_nil(s.github_webhook_secret_encrypted),
      inserted_at: s.inserted_at,
      updated_at: s.updated_at
    }
  end

  defp deployment_json(d) do
    %{
      id: d.id,
      site_id: d.site_id,
      status: d.status,
      git_ref: d.git_ref,
      artifact_url: d.artifact_url,
      image_tag: d.image_tag,
      build_log_url: d.build_log_url,
      failure_reason: d.failure_reason,
      became_live_at: d.became_live_at,
      inserted_at: d.inserted_at,
      updated_at: d.updated_at
    }
  end

  # Agent-route serialization that bundles the Site shape (slug + domains) the
  # runtime executor needs to render its Caddyfile. Encoded once so claim +
  # pending responses are identical.
  defp deployment_with_site_json(d) do
    base = deployment_json(d)
    site = if Ecto.assoc_loaded?(d.site), do: d.site, else: Registry.get_site(d.site_id)

    Map.put(base, :site, %{
      slug: site && site.slug,
      domains: (site && site.domains) || []
    })
  end

  # Scope check: does deployment_id's site belong to barkpark? Used by the
  # agent transition route to return 404 (not 422 / 403) when a malicious or
  # confused agent points at a deployment on another box — same shape as
  # nonexistent, never an existence leak.
  defp agent_owns_deployment?(barkpark, deployment_id) when is_binary(deployment_id) do
    case Registry.get_deployment(deployment_id) do
      nil ->
        false

      %Registry.Deployment{site_id: site_id} ->
        case Registry.get_site(site_id) do
          %Registry.Site{barkpark_id: bp_id} -> bp_id == barkpark.id
          _ -> false
        end
    end
  end

  defp agent_owns_deployment?(_, _), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Handoff helpers: only the null-clear is accepted. The wire MUST include the
  # key explicitly (with value null) — a body that omits the key leaves the
  # field alone. A non-null value silently no-ops (defence in depth).
  defp put_handoff_claim_worker(map, params) do
    if Map.has_key?(params, "claim_worker") and is_nil(params["claim_worker"]) do
      Map.put(map, :claim_worker, nil)
    else
      map
    end
  end

  defp put_handoff_claim_epoch(map, params) do
    if Map.has_key?(params, "claim_epoch") and params["claim_epoch"] == 0 do
      Map.put(map, :claim_epoch, 0)
    else
      map
    end
  end

  defp maybe_put_datetime(map, _key, nil), do: map

  defp maybe_put_datetime(map, key, iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Map.put(map, key, DateTime.truncate(dt, :microsecond))
      _ -> map
    end
  end

  defp maybe_put_datetime(map, _key, _), do: map

  defp parse_epoch(n) when is_integer(n) and n >= 0, do: n

  defp parse_epoch(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp parse_epoch(_), do: nil

  # GET /v1/audit query parsing. parse_int/2 reads ?limit= (a bad/absent value
  # falls back to the default; list_audit_events hard-caps it at 200 anyway).
  defp parse_int(nil, default), do: default

  defp parse_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(_, default), do: default

  # parse_dt/1 reads the ?before= keyset cursor as an ISO-8601 timestamp; a
  # malformed/absent value yields nil (no cursor → first page).
  defp parse_dt(nil), do: nil

  defp parse_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_dt(_), do: nil

  # Resolve + role-gate the path team, then run `fun.(conn, team)`. 401/403/404
  # are handled inside Auth.require_team_role (halts the conn); we only invoke
  # `fun` on a passing gate.
  defp with_team_role(conn, min_role, fun) do
    conn = Auth.require_team_role(conn, conn.path_params["id"], min_role)
    if conn.halted, do: conn, else: fun.(conn, conn.assigns.current_team_scoped)
  end

  # Walk: auth → team check → fetch site (team-scoped) → run fn(site).
  #
  # `auth` selects the credential mode:
  #   * `:session` (the default) — session-token ONLY (the dashboard / browser
  #     management routes). A PAT cannot reach these.
  #   * `{:ability, ab}` — accept a session OR a PAT, then gate on ability `ab`
  #     (a session implies `root`, so the browser always passes). Used by the
  #     programmatic routes external integrations call (e.g. deploy → "write").
  defp with_team_site(conn, fun), do: with_team_site(conn, :session, fun)

  defp with_team_site(conn, auth, fun) do
    conn =
      case auth do
        :session -> Auth.require_user(conn, [])
        {:ability, ab} -> conn |> Auth.require_user_or_pat([]) |> Auth.require_ability(ab)
      end

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        case Registry.get_team_site(conn.assigns.current_team, conn.path_params["id"]) do
          %Registry.Site{} = site -> fun.(site)
          nil -> json(conn, 404, %{error: "not_found"})
        end
    end
  end

  ## Helpers

  # The approved-command queue source. Empty by default; a configurable stub lets
  # a test (or cloud-13) inject commands without a queue backend.
  defp command_queue do
    Application.get_env(:barkpark_cloud, __MODULE__, [])
    |> Keyword.get(:command_queue, [])
  end

  # Pull the Stripe-Signature header off the inbound webhook request. Absent →
  # "" so verify_webhook fails closed (an unsigned event grants nothing) instead
  # of crashing on a nil signature.
  defp stripe_signature(conn) do
    case Plug.Conn.get_req_header(conn, "stripe-signature") do
      [sig | _] -> sig
      _ -> ""
    end
  end

  # Re-confirm the authed user's password for a destructive billing action
  # (cancel). Delegates to Accounts.get_user_by_email_and_password/2, which runs
  # Bcrypt.verify_pass with a timing-safe no_user_verify fallback. A non-binary
  # / absent password fails closed (false) without touching the hash.
  defp confirm_password(conn) do
    user = conn.assigns[:current_user]
    password = conn.body_params["password"]

    is_binary(password) and not is_nil(user) and
      match?(%{}, Accounts.get_user_by_email_and_password(user.email, password))
  end

  # A per-claim opaque token stamped onto the claimed job — traces a job to the
  # worker run that holds it. Not a credential (the worker auths with the shared
  # WORKER_TOKEN); just a claim marker.
  defp generate_claim_token,
    do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  # The agent reports health_status ∈ up/down/unknown; default unknown if absent
  # or out-of-enum so a malformed field never crashes the health changeset.
  defp normalize_health(s) when s in ["up", "down", "unknown"], do: s
  defp normalize_health(_), do: "unknown"

  # A report means the agent is online; honour an explicit offline, else online.
  defp normalize_agent("offline"), do: "offline"
  defp normalize_agent(_), do: "online"

  # name → slug: lowercase, non-alnum → hyphen, trim hyphens. Falls back to a
  # short random suffix so a name like "!!!" still yields a valid slug.
  defp slugify(name) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if base == "" do
      "bp-" <>
        (:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false) |> String.downcase())
    else
      base
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  # A bare 302 to `location` with an empty body — the OAuth routes' only response
  # shape (kick-off → IdP, callback → SPA fragment). The browser follows the
  # Location header; nothing is rendered.
  defp redirect_to(conn, location) do
    conn
    |> put_resp_header("location", location)
    |> send_resp(302, "")
  end

  ## Live events (SSE) helpers

  # Broadcast a coarse invalidation `type` to a team's connected dashboards.
  # Thin wrapper over BarkparkCloud.Events so the mutation sites read cleanly.
  defp push_event(team_id, type), do: Events.broadcast(team_id, type)

  # Resolve a barkpark's owning team and push `type` to it. Used by the WORKER
  # routes (succeed/fail job), which authenticate as a faceless principal and so
  # have no current_team — the team is derived from the affected barkpark. A
  # since-deleted barkpark is a silent no-op.
  defp broadcast_barkpark_team(barkpark_id, type) do
    case Registry.get_barkpark(barkpark_id) do
      %Barkpark{team_id: tid} -> push_event(tid, type)
      _ -> :ok
    end
  end

  # notifications-email: resolve a barkpark's owning team + name and fire an
  # email alert for `event`. Used by the WORKER routes (succeed/fail job), which
  # have no current_team — the team is derived from the affected barkpark. A
  # since-deleted barkpark is a silent no-op. dispatch_event itself never raises.
  defp dispatch_barkpark_event(barkpark_id, event, payload \\ %{}) do
    case Registry.get_barkpark(barkpark_id) do
      %Barkpark{team_id: tid, name: name} ->
        Notifications.dispatch_event(tid, event, Map.put_new(payload, :name, name))

      _ ->
        :ok
    end
  end

  # notifications-email: email only on a health up↔down FLIP. down/unknown → up
  # is "reachable again"; up → down is "unreachable". A steady-state report (no
  # change) or a flip to/from "unknown" mid-provision sends nothing.
  defp maybe_dispatch_health_flip(%Barkpark{} = bp, prior, new) when prior != new do
    case {prior, new} do
      {"down", "up"} -> dispatch_barkpark_event(bp.id, :agent_reachable)
      {"unknown", "up"} -> dispatch_barkpark_event(bp.id, :agent_reachable)
      {"up", "down"} -> dispatch_barkpark_event(bp.id, :agent_unreachable)
      _ -> :ok
    end
  end

  defp maybe_dispatch_health_flip(_bp, _prior, _new), do: :ok

  # Resolve a site's owning team and push `type` to it. Used by the deployment
  # transition routes (builder/agent principals have no current_team).
  defp broadcast_site_team(site_id, type) do
    case Registry.get_site(site_id) do
      %Registry.Site{team_id: tid} -> push_event(tid, type)
      _ -> :ok
    end
  end

  defp team_id_for_barkpark_of_job(job_id) do
    with id when is_binary(id) <- job_id,
         %BarkparkCloud.Registry.ProvisionJob{barkpark_id: bp_id} <- safe_get_job(id),
         %Barkpark{team_id: tid} <- Registry.get_barkpark(bp_id) do
      tid
    else
      _ -> nil
    end
  end

  defp safe_get_job(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(BarkparkCloud.Registry.ProvisionJob, uuid)
      :error -> nil
    end
  end

  defp deprovision_live_barkpark(conn, team, bp) do
    case Registry.enqueue_deprovision_job(bp) do
      {:ok, _job} ->
        push_event(team.id, "fleet")
        json(conn, 202, %{ok: true, status: "deprovisioning"})

      {:error, :already_deprovisioning} ->
        json(conn, 202, %{ok: true, status: "deprovisioning"})

      {:error, cs} ->
        json(conn, 422, %{error: "invalid", details: errors(cs)})
    end
  end

  # Auth for GET /v1/events. The browser EventSource API can't set headers, so a
  # `?token=` query param is accepted in addition to the normal Bearer header.
  # Assigns :current_user + :current_team on success; halts 401 otherwise.
  defp require_user_sse(conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    token = Auth.bearer_token(conn) || conn.query_params["token"]

    case is_binary(token) && token != "" && Accounts.verify_user_session_token(token) do
      %{} = user ->
        conn
        |> assign(:current_user, user)
        |> assign(:current_team, Accounts.primary_team(user))

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end

  # Subscribe the request process to the team's event group, then hold the
  # connection open as an SSE stream: an opening comment, then one `data:` frame
  # per broadcast, with a heartbeat comment every 25s so an idle stream isn't
  # reaped by a fronting proxy. A failed chunk (client gone) ends the loop; :pg
  # auto-unsubscribes the dying process.
  defp stream_events(conn, team_id) do
    :ok = Events.subscribe(team_id)

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    case Plug.Conn.chunk(conn, ": connected\n\n") do
      {:ok, conn} -> sse_loop(conn)
      {:error, _} -> conn
    end
  end

  defp sse_loop(conn) do
    receive do
      {:bpcloud_event, event} ->
        case encode_sse_frame(event) do
          {:ok, frame} ->
            case Plug.Conn.chunk(conn, frame) do
              {:ok, conn} -> sse_loop(conn)
              {:error, _} -> conn
            end

          :error ->
            # An unencodable event must NOT crash (and so close) the whole SSE
            # stream — the event is only an invalidation hint, safely dropped.
            # Log and keep parking for the next (good) event / heartbeat.
            Logger.error("sse_loop: dropping unencodable event #{inspect(event)}")
            sse_loop(conn)
        end
    after
      25_000 ->
        case Plug.Conn.chunk(conn, ": ping\n\n") do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end
    end
  end

  # Encode one event as an SSE `data:` frame. A Jason failure (an unencodable
  # payload) returns :error so the loop can SKIP this frame instead of raising
  # and tearing down the connection — uses Jason.encode/1, never the `!` variant.
  defp encode_sse_frame(event) do
    case Jason.encode(event) do
      {:ok, json} -> {:ok, "data: " <> json <> "\n\n"}
      {:error, _} -> :error
    end
  end

  ## GitHub webhook helpers (P7 stream B)

  # Recover the EXACT request bytes Plug.Parsers consumed. `cache_raw_body/2`
  # stashes the body as a single binary on `conn.assigns[:raw_body]` for the
  # webhook paths; we hand it back as-is. Returns "" when nothing was stashed
  # (e.g. a request with no body) so HMAC verification sees a stable empty
  # string rather than nil.
  defp raw_request_body(conn), do: conn.assigns[:raw_body] || ""

  defp get_first_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [v | _] -> v
      _ -> nil
    end
  end

  ## Account & sessions helpers

  # The non-secret session shape for the active-sessions list. NEVER echoes the
  # token_hash; `current` is computed against the caller's hash so the UI can
  # badge "This device" and disable its own Revoke button.
  defp session_json(%Accounts.UserToken{} = t, current_hash) do
    %{
      id: t.id,
      ip_address: t.ip_address,
      user_agent: t.user_agent,
      last_used_at: t.last_used_at,
      inserted_at: t.inserted_at,
      current: t.token_hash == current_hash
    }
  end

  # Device metadata for a freshly-minted session token: the caller's peer IP and
  # User-Agent. Captured at login / register / password-change re-mint so the
  # sessions list has something to show. Both nil-tolerant — a missing header or
  # peer just stores nil.
  defp session_opts(conn) do
    [ip_address: peer_ip(conn), user_agent: get_first_header(conn, "user-agent")]
  end

  # Render conn.remote_ip (an :inet address tuple) as a printable string, or nil
  # when absent. :inet.ntoa returns a charlist; to_string makes it a binary.
  defp peer_ip(conn) do
    case conn.remote_ip do
      nil -> nil
      ip -> ip |> :inet.ntoa() |> to_string()
    end
  end

  # Verify a GitHub X-Hub-Signature-256 header against `raw_body` using `secret`.
  # GitHub format: "sha256=<lowercase-hex of HMAC-SHA256(secret, raw_body)>".
  # Compare with Plug.Crypto.secure_compare/2 so the check is CONSTANT TIME —
  # a byte-by-byte mismatch must not leak timing info.
  defp verify_github_signature(_raw, _secret, nil), do: false
  defp verify_github_signature(_raw, _secret, ""), do: false

  defp verify_github_signature(raw_body, secret, "sha256=" <> hex) do
    computed_hex =
      :crypto.mac(:hmac, :sha256, secret, raw_body)
      |> Base.encode16(case: :lower)

    # Both strings must be the same length for secure_compare; if GitHub sent a
    # malformed header (wrong length) treat it as a mismatch up front.
    if byte_size(hex) == byte_size(computed_hex) do
      Plug.Crypto.secure_compare(String.downcase(hex), computed_hex)
    else
      false
    end
  end

  defp verify_github_signature(_raw, _secret, _other), do: false

  # The verified-push branch of POST /v1/webhooks/github/:site_id. By this point
  # the HMAC has passed; we still 200 (not 4xx) on non-push events and
  # mismatched-branch pushes so GitHub stops retrying. Only an actual push to
  # the configured branch creates a Deployment.
  defp handle_verified_github_push(conn, site) do
    event = get_first_header(conn, "x-github-event")
    body = conn.body_params

    cond do
      event == nil ->
        json(conn, 200, %{ok: true, ignored: true, reason: "missing_event_header"})

      event == "ping" ->
        # The "set up" hit GitHub fires when you save a webhook config. Always
        # 200 so the webhook config UI shows "Last delivery was successful".
        json(conn, 200, %{ok: true, pong: true})

      event != "push" ->
        json(conn, 200, %{ok: true, ignored: true, reason: "unsupported_event"})

      true ->
        ref = body["ref"]
        sha = body["after"] || (is_map(body["head_commit"]) and body["head_commit"]["id"]) || nil
        configured_branch = site.github_branch || "main"
        expected_ref = "refs/heads/" <> configured_branch

        cond do
          not is_binary(ref) ->
            json(conn, 200, %{ok: true, ignored: true, reason: "missing_ref"})

          ref != expected_ref ->
            json(conn, 200, %{
              ok: true,
              ignored: true,
              reason: "branch_mismatch",
              pushed_ref: ref,
              expected_ref: expected_ref
            })

          not is_binary(sha) or sha == "" ->
            json(conn, 200, %{ok: true, ignored: true, reason: "missing_sha"})

          true ->
            # The artifact_url is left empty — the MVP only records that a
            # push happened at this sha. A future builder enhancement (P7+)
            # can git-clone github_repo at this sha and build from source.
            case Registry.create_deployment(site, %{git_ref: sha, artifact_url: nil}) do
              {:ok, deployment} ->
                push_event(site.team_id, "deployments")

                json(conn, 201, %{
                  ok: true,
                  deployment_id: deployment.id,
                  sha: sha,
                  branch: configured_branch
                })

              {:error, cs} ->
                json(conn, 422, %{error: "invalid", details: errors(cs)})
            end
        end
    end
  end

  # Build the user-facing webhook URL the user pastes into GitHub's "Payload
  # URL" field. The scheme + host come from the request so dev (http://...)
  # and prod (https://api.barkpark.cloud) both land on a working URL without
  # threading config through.
  defp webhook_url_for(conn, site_id) do
    scheme = conn.scheme |> to_string()
    host = conn.host

    port_part =
      cond do
        scheme == "https" and conn.port == 443 -> ""
        scheme == "http" and conn.port == 80 -> ""
        true -> ":" <> Integer.to_string(conn.port)
      end

    "#{scheme}://#{host}#{port_part}/v1/webhooks/github/#{site_id}"
  end

  # Generate a fresh webhook secret — 32 cryptographic random bytes,
  # url-safe-Base64 encoded (no padding) so it pastes cleanly into GitHub's
  # secret field.
  defp generate_webhook_secret do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  ## Artifact upload helpers

  # Reads the runtime artifact-upload config: the on-disk dir and the max
  # body size. The dir falls through Application env → BARKPARK_CLOUD_ARTIFACT_DIR
  # env var → /tmp/barkpark-cloud-artifacts dev default. Size cap default: 100 MB.
  defp artifact_config do
    cfg = Application.get_env(:barkpark_cloud, __MODULE__, [])

    dir =
      Keyword.get(cfg, :artifact_dir) ||
        System.get_env("BARKPARK_CLOUD_ARTIFACT_DIR") ||
        "/tmp/barkpark-cloud-artifacts"

    max = Keyword.get(cfg, :max_artifact_bytes, 100 * 1024 * 1024)

    [artifact_dir: dir, max_artifact_bytes: max]
  end

  # Filename: <slug>-<8-byte-random>.tar.gz. The random suffix lets repeated
  # uploads for the same site coexist; the builder reads via file:// URL so
  # the path is the contract — no DB row for the artifact itself.
  defp artifact_filename(slug) do
    rand =
      :crypto.strong_rand_bytes(8)
      |> Base.url_encode64(padding: false)
      |> String.downcase()

    safe_slug = if is_binary(slug) and slug != "", do: slug, else: "site"
    "#{safe_slug}-#{rand}.tar.gz"
  end

  # Streams the request body to `path`, abandoning early when `max_bytes` is
  # exceeded. Returns `{:ok, conn, bytes}` on success, `{:error, :too_large,
  # conn}` when the body crosses the cap, `{:error, reason, conn}` on any I/O
  # failure. The file is opened once, written incrementally, and closed by
  # this function — partial files are caller's responsibility to remove on
  # error (since the path is known there).
  defp stream_body_to_file(conn, path, max_bytes) do
    case File.open(path, [:write, :binary]) do
      {:ok, file} ->
        try do
          do_stream(conn, file, 0, max_bytes)
        after
          File.close(file)
        end

      {:error, reason} ->
        {:error, {:open, reason}, conn}
    end
  end

  defp do_stream(conn, file, written, max_bytes) do
    # 8 MiB chunk window — large enough that the per-call overhead is amortized
    # against the 100 MB cap; small enough that a refused upload stops early.
    case Plug.Conn.read_body(conn, length: 8 * 1024 * 1024, read_length: 1024 * 1024) do
      {:ok, chunk, conn} ->
        new_written = written + byte_size(chunk)

        cond do
          new_written > max_bytes ->
            {:error, :too_large, conn}

          true ->
            case IO.binwrite(file, chunk) do
              :ok -> {:ok, conn, new_written}
              {:error, reason} -> {:error, {:write, reason}, conn}
            end
        end

      {:more, chunk, conn} ->
        new_written = written + byte_size(chunk)

        cond do
          new_written > max_bytes ->
            {:error, :too_large, conn}

          true ->
            case IO.binwrite(file, chunk) do
              :ok -> do_stream(conn, file, new_written, max_bytes)
              {:error, reason} -> {:error, {:write, reason}, conn}
            end
        end

      {:error, reason} ->
        {:error, {:read, reason}, conn}
    end
  end
end
