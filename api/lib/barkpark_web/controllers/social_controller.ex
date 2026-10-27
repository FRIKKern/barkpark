defmodule BarkparkWeb.SocialController do
  @moduledoc """
  Social login (era-w2-social-oauth): Google / GitHub / Microsoft.

  - `GET /v1/auth/social/:provider/start` — redirect to the provider (state in
    the session).
  - `GET /v1/auth/social/:provider/callback` — verify state, exchange, and mint
    a user session (find-or-link by social identity / email).
  """
  use BarkparkWeb, :controller

  alias Barkpark.Accounts
  alias Barkpark.Sso
  alias Barkpark.Sso.Social
  alias BarkparkWeb.ErrorResponse
  alias BarkparkWeb.SessionIssuer
  alias BarkparkWeb.SignInFailure
  alias BarkparkWeb.SsoFlows

  require Logger

  @expired "This sign-in expired, or it was started in another browser or tab. Start it again."

  def start(conn, %{"provider" => name}) do
    case Social.provider(name) do
      nil ->
        ErrorResponse.emit_custom(conn, 404, "not_found", "provider not enabled")

      p ->
        state = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        url = Social.authorize_url(p, state, callback_uri(name))

        conn
        |> SsoFlows.start("social:" <> name, state)
        |> redirect(external: url)
    end
  end

  # `when is_binary(code)` on the ACTION HEAD — Social.handle_callback/3 already
  # guards `is_binary(code)`, but a callee guard raises BELOW the action frame,
  # where Phoenix's ActionClauseError→400 conversion no longer applies (500).
  # Guarded here, `?code[]=` falls through to the fallback clause for a 400.
  def callback(conn, %{"provider" => name, "code" => code, "state" => state})
      when is_binary(code) do
    p = Social.provider(name)
    flow = p && SsoFlows.take(conn, "social:" <> name, state, &legacy_flow/1)

    cond do
      is_nil(p) ->
        Sso.record_login_failure("social:#{name}", nil, :provider_not_enabled)
        ErrorResponse.emit_custom(conn, 404, "not_found", "provider not enabled")

      match?({:error, _}, flow) ->
        {:error, reason} = flow
        Sso.record_login_failure("social:#{name}", nil, reason)
        Logger.warning("[Social] #{name}: state rejected: #{reason}")

        SignInFailure.respond(conn, %{
          status: 400,
          code: "malformed",
          message: "state mismatch",
          details: %{reason: Atom.to_string(reason)},
          hint: "Start the sign-in again in the same browser.",
          page_message: @expired,
          start_path: start_path(name)
        })

      true ->
        {:ok, conn, _flow} = flow

        case Social.handle_callback(p, code, callback_uri(name)) do
          {:ok, user} ->
            # era-w8-sso-mfa-binding: org-require-MFA binds at session-mint
            # time — a governed factor-less user (via existing workspace
            # memberships; social login is app-level, no org of its own) is
            # refused HERE (audited), never landed in Studio.
            # era-bl-allowed-auth-methods: consumer OAuth answers to the
            # "social" term, NOT "sso". `handle_callback/3` find-or-LINKS by
            # email against a consumer provider with no org binding, so
            # counting it as enterprise SSO would let a personal Google
            # account satisfy an `["sso"]` policy — the exact bypass this
            # feature closes. The precise provider rides the audit trail.
            cond do
              SessionIssuer.org_mfa_enrolment_blocked?(user) ->
                SessionIssuer.deny_org_mfa_enrolment(conn, user, "social:#{name}")

              SessionIssuer.auth_method_blocked?(user, "social") ->
                SessionIssuer.deny_auth_method(conn, user, "social", "social:#{name}")

              # Owner ruling #14: a social sign-in carries no second factor, so
              # in a require-MFA org it is refused for every member who has one
              # (TOTP or passkey) and pointed at a door that presents it.
              SessionIssuer.org_factor_required?(user, :no_code_door) ->
                SessionIssuer.deny_org_factor_required(conn, user, "social:#{name}")

              true ->
                Sso.record_login(user, "social:#{name}", nil)

                {:ok, token} =
                  Accounts.create_user_session_token(user, SessionIssuer.actor_opts(conn))

                conn
                |> configure_session(renew: true)
                |> put_session("user_session", token)
                |> put_status(:created)
                |> json(%{ok: true, token: token, user: %{id: user.id, email: user.email}})
            end

          {:error, reason} ->
            # Failed exchange lands on the audit trail (era-w8).
            Sso.record_login_failure("social:#{name}", nil, reason)
            text = SignInFailure.reason_text(reason)
            Logger.warning("[Social] #{name}: callback rejected: #{text}")

            SignInFailure.respond(conn, %{
              status: 401,
              code: "unauthorized",
              message: "social callback rejected",
              details: %{reason: text},
              page_message: "The provider did not accept this sign-in. Try again.",
              start_path: start_path(name)
            })
        end
    end
  end

  def callback(conn, %{"provider" => name} = params) do
    case params do
      %{"error" => err} ->
        text = SignInFailure.reason_text(err)
        Logger.warning("[Social] #{name}: the provider returned #{text}")

        SignInFailure.respond(conn, %{
          status: 401,
          code: "unauthorized",
          message: "the provider returned an error",
          details: %{reason: text},
          page_message: "The provider refused this sign-in. Try again.",
          start_path: start_path(name)
        })

      _ ->
        SignInFailure.respond(conn, %{
          status: 400,
          code: "malformed",
          message: "code and state are required",
          page_message: @expired,
          start_path: start_path(name)
        })
    end
  end

  # A start before sign-in state moved to the server kept it in one slot.
  defp legacy_flow(conn) do
    case get_session(conn, :social_state) do
      state when is_binary(state) -> %{state: state}
      _ -> nil
    end
  end

  defp start_path(name), do: "/v1/auth/social/#{URI.encode_www_form(name)}/start"

  defp callback_uri(name), do: BarkparkWeb.Endpoint.url() <> "/v1/auth/social/#{name}/callback"
end
