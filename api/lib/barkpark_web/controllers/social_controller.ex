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

  def start(conn, %{"provider" => name}) do
    case Social.provider(name) do
      nil ->
        ErrorResponse.emit_custom(conn, 404, "not_found", "provider not enabled")

      p ->
        state = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        url = Social.authorize_url(p, state, callback_uri(name))

        conn
        |> put_session(:social_state, state)
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

    cond do
      is_nil(p) ->
        Sso.record_login_failure("social:#{name}", nil, :provider_not_enabled)
        ErrorResponse.emit_custom(conn, 404, "not_found", "provider not enabled")

      state != get_session(conn, :social_state) ->
        Sso.record_login_failure("social:#{name}", nil, :state_mismatch)
        ErrorResponse.emit_custom(conn, 400, "malformed", "state mismatch")

      true ->
        case Social.handle_callback(p, code, callback_uri(name)) do
          {:ok, user} ->
            # era-w8-sso-mfa-binding: org-require-MFA binds at session-mint
            # time — a governed factor-less user (via existing workspace
            # memberships; social login is app-level, no org of its own) is
            # refused HERE (audited), never landed in Studio.
            if SessionIssuer.org_mfa_enrolment_blocked?(user) do
              SessionIssuer.deny_org_mfa_enrolment(conn, user, "social:#{name}")
            else
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

            ErrorResponse.emit_custom(conn, 401, "unauthorized", "social callback rejected", %{
              reason: to_string(reason)
            })
        end
    end
  end

  def callback(conn, %{"provider" => _} = params) do
    case params do
      %{"error" => err} ->
        ErrorResponse.emit_custom(conn, 401, "unauthorized", "the provider returned an error", %{
          reason: to_string(err)
        })

      _ ->
        ErrorResponse.emit_custom(conn, 400, "malformed", "code and state are required")
    end
  end

  defp callback_uri(name), do: BarkparkWeb.Endpoint.url() <> "/v1/auth/social/#{name}/callback"
end
