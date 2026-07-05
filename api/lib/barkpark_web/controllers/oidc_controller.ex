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

  def start(conn, %{"org_slug" => slug}) do
    case Oidc.connection_for_org_slug(slug) do
      nil ->
        conn |> put_status(404) |> json(%{error: "no OIDC connection for this organization"})

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

  def callback(conn, %{"org_slug" => slug, "code" => code, "state" => state}) do
    c = Oidc.connection_for_org_slug(slug)

    cond do
      is_nil(c) ->
        conn |> put_status(404) |> json(%{error: "no OIDC connection for this organization"})

      state != get_session(conn, :oidc_state) ->
        conn |> put_status(400) |> json(%{error: "state mismatch"})

      true ->
        opts = [
          redirect_uri: callback_uri(slug),
          code_verifier: get_session(conn, :oidc_verifier),
          nonce: get_session(conn, :oidc_nonce)
        ]

        case Oidc.handle_callback(c, code, opts) do
          {:ok, user, _claims} ->
            Sso.record_login(user, "oidc", c.organization_id)

            {:ok, token} =
              Accounts.create_user_session_token(user,
                ip_address: client_ip(conn),
                user_agent: user_agent(conn)
              )

            conn = conn |> configure_session(renew: true) |> put_session("user_session", token)

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

          {:error, reason} ->
            conn |> put_status(401) |> json(%{error: "oidc_failed", detail: to_string(reason)})
        end
    end
  end

  def callback(conn, %{"org_slug" => _} = params) do
    case params do
      %{"error" => err} -> conn |> put_status(401) |> json(%{error: "oidc_error", detail: err})
      _ -> conn |> put_status(400) |> json(%{error: "code and state are required"})
    end
  end

  defp callback_uri(slug), do: BarkparkWeb.Endpoint.url() <> "/v1/auth/oidc/#{slug}/callback"

  # A browser's redirect chain advertises text/html; API clients don't.
  defp browser?(conn) do
    conn
    |> Plug.Conn.get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/html"))
  end

  defp client_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      _ -> nil
    end
  end
end
