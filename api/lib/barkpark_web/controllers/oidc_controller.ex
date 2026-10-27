defmodule BarkparkWeb.OidcController do
  @moduledoc """
  OIDC relying-party endpoints (era-w3-oidc-rp).

  - `GET /v1/auth/oidc/:org_slug/start` — redirect the browser to the org's IdP
    (auth-code + PKCE). `state`/`nonce`/`code_verifier` are stashed in the
    session for the callback.
  - `GET /v1/auth/oidc/:org_slug/callback` — verify `state`, complete the flow
    (`Barkpark.Sso.Oidc.handle_callback/3`), and mint a user session.
  - `POST /v1/auth/sso/exchange` — a Studio's server trades the SSO ticket the
    callback sent it for that session.

  A Studio signs its editors in here (task-8bdf1b15305af840): its start names
  `return_to` (a URL on an origin in `BARKPARK_STUDIO_SSO_ORIGINS`), its own
  `state` and a PKCE S256 `code_challenge`. The callback then sends the browser
  to `return_to?ticket=…&state=…` instead of /studio, with a 60 s ticket
  (`Barkpark.Auth.mint_sso_ticket/4`) bound to the Studio origin and the
  challenge. The org's MFA and allowed-methods rules apply before any ticket.
  With the origin list empty, a start that names `return_to` is refused.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Accounts
  alias Barkpark.Sso
  alias Barkpark.Sso.Oidc
  alias BarkparkWeb.ErrorResponse
  alias BarkparkWeb.SessionIssuer
  alias BarkparkWeb.SignInFailure
  alias BarkparkWeb.SsoFlows

  require Logger

  @expired "This sign-in expired, or it was started in another browser or tab. Start it again."

  def start(conn, %{"org_slug" => slug} = params) do
    case Oidc.connection_for_org_slug(slug) do
      nil ->
        ErrorResponse.emit_custom(
          conn,
          404,
          "not_found",
          "no OIDC connection for this organization"
        )

      c ->
        case studio_return(params) do
          :error ->
            ErrorResponse.emit_custom(
              conn,
              400,
              "malformed",
              "return_to must be on an allowed Studio origin, with state and an S256 code_challenge"
            )

          studio ->
            p = Oidc.new_auth_params()

            case Oidc.authorize_url(c, Map.put(p, :redirect_uri, callback_uri(slug))) do
              {:ok, url} ->
                conn
                |> SsoFlows.start("oidc:" <> slug, p.state, %{
                  nonce: p.nonce,
                  code_verifier: p.code_verifier,
                  studio: studio
                })
                |> redirect(external: url)

              {:error, reason} ->
                Sso.record_login_failure("oidc", slug, reason)

                ErrorResponse.emit_custom(
                  conn,
                  502,
                  "upstream_unavailable",
                  "the identity provider's discovery document could not be read"
                )
            end
        end
    end
  end

  # nil: no Studio named, the callback lands in /studio. A map: where the
  # callback sends the ticket. :error: a Studio named but not allowed.
  defp studio_return(%{"return_to" => to} = params) when is_binary(to) do
    origin = origin(to)

    with true <- origin in Application.get_env(:barkpark, :studio_sso_origins, []),
         state when is_binary(state) and state != "" <- params["state"],
         challenge when is_binary(challenge) <- params["code_challenge"],
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, challenge) do
      %{"to" => to, "origin" => origin, "state" => state, "challenge" => challenge}
    else
      _ -> :error
    end
  end

  defp studio_return(_params), do: nil

  defp origin(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port, userinfo: nil, fragment: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        default = if scheme == "https", do: 443, else: 80
        "#{scheme}://#{host}" <> if(port == default, do: "", else: ":#{port}")

      _ ->
        nil
    end
  end

  # `when is_binary(code)` belongs on the ACTION HEAD, not on the callee: a
  # list-valued `?code[]=` slips past a callee guard and raises below the
  # action frame, where Phoenix's ActionClauseError→400 conversion no longer
  # applies (500). Guarded here, a wrong-typed `code` simply falls through to
  # the fallback clause below and gets the same clean 400 as a missing one.
  def callback(conn, %{"org_slug" => slug, "code" => code, "state" => state})
      when is_binary(code) do
    c = Oidc.connection_for_org_slug(slug)
    flow = c && SsoFlows.take(conn, "oidc:" <> slug, state, &legacy_flow/1)

    cond do
      is_nil(c) ->
        Sso.record_login_failure("oidc", slug, :no_connection)

        ErrorResponse.emit_custom(
          conn,
          404,
          "not_found",
          "no OIDC connection for this organization"
        )

      match?({:error, _}, flow) ->
        state_mismatch(conn, slug, elem(flow, 1))

      true ->
        {:ok, conn, flow} = flow

        opts = [
          redirect_uri: callback_uri(slug),
          code_verifier: flow.code_verifier,
          nonce: flow.nonce
        ]

        case Oidc.handle_callback(c, code, opts) do
          {:ok, user, claims} ->
            # era-w8-sso-mfa-binding: org-require-MFA binds at session-mint
            # time — a governed factor-less user is refused HERE (audited),
            # never landed in Studio. Checked AFTER handle_callback's JIT so
            # a first-ever login into a require_mfa org is governed too.
            # era-bl-allowed-auth-methods: the org allowed-methods policy
            # binds at the SAME seam. OIDC is ENTERPRISE sso (bound to this
            # org's connection), so it answers to the "sso" term. An org that
            # narrowed its list without naming "sso" gets this door closed —
            # without the check the allow-list was inert on exactly the door
            # its own vocabulary invited an admin to disable.
            # An IdP that asserted MFA on a connection trusting it stands in
            # for a Barkpark factor: the session is born MFA-verified.
            idp_mfa? = Oidc.idp_mfa?(c, claims)

            cond do
              not idp_mfa? and SessionIssuer.org_mfa_enrolment_blocked?(user) ->
                SessionIssuer.deny_org_mfa_enrolment(conn, user, "oidc", c.organization_id)

              SessionIssuer.auth_method_blocked?(user, "sso") ->
                SessionIssuer.deny_auth_method(conn, user, "sso", "oidc")

              true ->
                Sso.record_login(user, "oidc", c.organization_id)

                mfa_opts = if idp_mfa?, do: [mfa_verified: true, idp_mfa: true], else: []

                {:ok, token} =
                  Accounts.create_user_session_token(
                    user,
                    SessionIssuer.actor_opts(conn) ++ mfa_opts
                  )

                case flow.studio do
                  %{} = studio -> to_studio(conn, studio, token, user)
                  _ -> signed_in(conn, token, user)
                end
            end

          {:error, reason} ->
            # Failed token exchange / claim validation lands on the audit
            # trail (era-w8) — only successes audited before.
            Sso.record_login_failure("oidc", slug, reason)
            text = SignInFailure.reason_text(reason)
            Logger.warning("[OIDC] #{slug}: callback rejected: #{text}")

            SignInFailure.respond(conn, %{
              status: 401,
              code: "unauthorized",
              message: "OIDC callback rejected",
              details: %{reason: text},
              page_message:
                "The identity provider did not accept this sign-in. Try again, or ask your administrator.",
              start_path: start_path(slug)
            })
        end
    end
  end

  def callback(conn, %{"org_slug" => slug} = params) do
    case params do
      %{"error" => err} ->
        text = SignInFailure.reason_text(err)

        Logger.warning(
          "[OIDC] #{slug}: the IdP returned #{text}: " <>
            SignInFailure.reason_text(params["error_description"] || "")
        )

        SignInFailure.respond(conn, %{
          status: 401,
          code: "unauthorized",
          message: "the IdP returned an error",
          details: %{reason: text},
          page_message:
            "The identity provider refused this sign-in. Try again, or ask your administrator.",
          start_path: start_path(slug)
        })

      _ ->
        SignInFailure.respond(conn, %{
          status: 400,
          code: "malformed",
          message: "code and state are required",
          page_message: @expired,
          start_path: start_path(slug)
        })
    end
  end

  # A flow started before sign-in state moved to the server sits in the
  # session's single slot. Read it so a sign-in in progress at deploy finishes.
  defp legacy_flow(conn) do
    case get_session(conn, :oidc_state) do
      state when is_binary(state) ->
        %{
          state: state,
          nonce: get_session(conn, :oidc_nonce),
          code_verifier: get_session(conn, :oidc_verifier),
          studio: get_session(conn, :oidc_studio)
        }

      _ ->
        nil
    end
  end

  @state_reasons %{
    no_session_state: "no sign-in state in the session cookie",
    state_mismatch: "this browser did not start a sign-in with that state",
    unknown_state: "the state was already used or is unknown",
    state_expired: "the sign-in started more than 10 minutes ago"
  }

  defp state_mismatch(conn, slug, reason) do
    Sso.record_login_failure("oidc", slug, reason)
    Logger.warning("[OIDC] #{slug}: #{reason}: #{@state_reasons[reason]}")

    SignInFailure.respond(conn, %{
      status: 400,
      code: "malformed",
      message: "state mismatch",
      details: %{reason: Atom.to_string(reason)},
      hint: "Start the sign-in again in the same browser.",
      page_message: @expired,
      start_path: start_path(slug)
    })
  end

  defp start_path(slug), do: "/v1/auth/oidc/#{URI.encode_www_form(slug)}/start"

  @doc """
  `POST /v1/auth/sso/exchange` — body `{ticket, audience, code_verifier}`, the
  shape of `POST /v1/auth/login-tickets/exchange`, and the same answer:
  `201 {token, user: {id, email}}`. Every failure is `401 invalid_ticket`.
  """
  def exchange(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with {:ok, {token, _email}} <-
           Barkpark.Auth.consume_sso_ticket(
             params["ticket"],
             params["audience"],
             params["code_verifier"]
           ),
         {%Accounts.User{} = user, _session} <- Accounts.verify_user_session(token) do
      conn
      |> put_status(:created)
      |> json(%{token: token, user: %{id: user.id, email: user.email}})
    else
      _ ->
        ErrorResponse.emit_custom(
          conn,
          401,
          "invalid_ticket",
          "this sign-in ticket is invalid, already used or expired"
        )
    end
  end

  # The Studio that started the flow gets the session as a ticket; Barkpark's
  # own browser session is not signed in.
  defp to_studio(conn, studio, token, user) do
    {:ok, ticket} =
      Barkpark.Auth.mint_sso_ticket(token, user.email, studio["origin"], studio["challenge"])

    query = URI.encode_query(%{"ticket" => ticket, "state" => studio["state"]})
    sep = if String.contains?(studio["to"], "?"), do: "&", else: "?"

    conn
    |> delete_session(:oidc_studio)
    |> redirect(external: studio["to"] <> sep <> query)
  end

  defp signed_in(conn, token, user) do
    conn = conn |> configure_session(renew: true) |> put_session("user_session", token)

    # studio-user-login: a browser completing the code flow
    # (Accept: text/html) lands IN Studio on its new session cookie;
    # non-HTML callers keep the JSON contract byte-identical.
    if SignInFailure.browser?(conn) do
      redirect(conn, to: "/studio")
    else
      conn
      |> put_status(:created)
      |> json(%{ok: true, token: token, user: %{id: user.id, email: user.email}})
    end
  end

  defp callback_uri(slug), do: BarkparkWeb.Endpoint.url() <> "/v1/auth/oidc/#{slug}/callback"
end
