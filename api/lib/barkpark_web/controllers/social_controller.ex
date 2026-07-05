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
  alias Barkpark.Sso.Social

  def start(conn, %{"provider" => name}) do
    case Social.provider(name) do
      nil ->
        conn |> put_status(404) |> json(%{error: "provider not enabled"})

      p ->
        state = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        url = Social.authorize_url(p, state, callback_uri(name))

        conn
        |> put_session(:social_state, state)
        |> redirect(external: url)
    end
  end

  def callback(conn, %{"provider" => name, "code" => code, "state" => state}) do
    p = Social.provider(name)

    cond do
      is_nil(p) ->
        conn |> put_status(404) |> json(%{error: "provider not enabled"})

      state != get_session(conn, :social_state) ->
        conn |> put_status(400) |> json(%{error: "state mismatch"})

      true ->
        case Social.handle_callback(p, code, callback_uri(name)) do
          {:ok, user} ->
            {:ok, token} =
              Accounts.create_user_session_token(user,
                ip_address: client_ip(conn),
                user_agent: user_agent(conn)
              )

            conn
            |> configure_session(renew: true)
            |> put_session("user_session", token)
            |> put_status(:created)
            |> json(%{ok: true, token: token, user: %{id: user.id, email: user.email}})

          {:error, reason} ->
            conn |> put_status(401) |> json(%{error: "social_failed", detail: to_string(reason)})
        end
    end
  end

  def callback(conn, %{"provider" => _} = params) do
    case params do
      %{"error" => err} -> conn |> put_status(401) |> json(%{error: "social_error", detail: err})
      _ -> conn |> put_status(400) |> json(%{error: "code and state are required"})
    end
  end

  defp callback_uri(name), do: BarkparkWeb.Endpoint.url() <> "/v1/auth/social/#{name}/callback"
  defp client_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      _ -> nil
    end
  end
end
