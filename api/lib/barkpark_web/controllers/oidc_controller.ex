defmodule BarkparkWeb.OidcController do
  @moduledoc """
  OIDC relying-party endpoints (era-w3-oidc-rp).

  - `GET /v1/auth/oidc/:org_slug/start` — redirect the browser to the org's IdP
    (auth-code + PKCE). `state`/`nonce`/`code_verifier` are stashed in the
    session for the callback.
  - `GET /v1/auth/oidc/:org_slug/callback` — verify `state`, complete the flow
    (`Barkpark.Sso.Oidc.handle_callback/3`), and mint a user session.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Accounts
  alias Barkpark.Sso
  alias Barkpark.Sso.Oidc
  alias BarkparkWeb.ErrorResponse
  alias BarkparkWeb.SessionIssuer

  def start(conn, %{"org_slug" => slug}) do
    case Oidc.connection_for_org_slug(slug) do
      nil ->
        ErrorResponse.emit_custom(
          conn,
          404,
          "not_found",
          "no OIDC connection for this organization"
        )

      c ->
        p = Oidc.new_auth_params()
        url = Oidc.authorize_url(c, Map.put(p, :redirect_uri, callback_uri(slug)))

        conn
        |> put_session(:oidc_state, p.state)
        |> put_session(:oidc_nonce, p.nonce)
        |> put_session(:oidc_verifier, p.code_verifier)
        |> redirect(external: url)
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

    cond do
      is_nil(c) ->
        Sso.record_login_failure("oidc", slug, :no_connection)

        ErrorResponse.emit_custom(
          conn,
          404,
          "not_found",
          "no OIDC connection for this organization"
        )

      state != get_session(conn, :oidc_state) ->
        Sso.record_login_failure("oidc", slug, :state_mismatch)
        ErrorResponse.emit_custom(conn, 400, "malformed", "state mismatch")

      true ->
        opts = [
          redirect_uri: callback_uri(slug),
          code_verifier: get_session(conn, :oidc_verifier),
          nonce: get_session(conn, :oidc_nonce)
        ]

        case Oidc.handle_callback(c, code, opts) do
          {:ok, user, _claims} ->
            # era-w8-sso-mfa-binding: org-require-MFA binds at session-mint
            # time — a governed factor-less user is refused HERE (audited),
            # never landed in Studio. Checked AFTER handle_callback's JIT so
            # a first-ever login into a require_mfa org is governed too.
            if SessionIssuer.org_mfa_enrolment_blocked?(user) do
              SessionIssuer.deny_org_mfa_enrolment(conn, user, "oidc", c.organization_id)
            else
              Sso.record_login(user, "oidc", c.organization_id)

              {:ok, token} =
                Accounts.create_user_session_token(user, SessionIssuer.actor_opts(conn))

              conn =
                conn |> configure_session(renew: true) |> put_session("user_session", token)

              # studio-user-login: a browser completing the code flow
              # (Accept: text/html) lands IN Studio on its new session cookie;
              # non-HTML callers keep the JSON contract byte-identical.
              if browser?(conn) do
                redirect(conn, to: "/studio")
              else
                conn
                |> put_status(:created)
                |> json(%{ok: true, token: token, user: %{id: user.id, email: user.email}})
              end
            end

          {:error, reason} ->
            # Failed token exchange / claim validation lands on the audit
            # trail (era-w8) — only successes audited before.
            Sso.record_login_failure("oidc", slug, reason)

            ErrorResponse.emit_custom(conn, 401, "unauthorized", "OIDC callback rejected", %{
              reason: to_string(reason)
            })
        end
    end
  end

  def callback(conn, %{"org_slug" => _} = params) do
    case params do
      %{"error" => err} ->
        ErrorResponse.emit_custom(conn, 401, "unauthorized", "the IdP returned an error", %{
          reason: to_string(err)
        })

      _ ->
        ErrorResponse.emit_custom(conn, 400, "malformed", "code and state are required")
    end
  end

  defp callback_uri(slug), do: BarkparkWeb.Endpoint.url() <> "/v1/auth/oidc/#{slug}/callback"

  # A browser's redirect chain advertises text/html; API clients don't.
  defp browser?(conn) do
    conn
    |> Plug.Conn.get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/html"))
  end
end
