defmodule BarkparkWeb.Plugs.RequireUserSession do
  @moduledoc """
  Gate a route on a valid USER login session (distinct from API-token auth).

  Accepts the session bearer two ways, mirroring
  `RequireBearerOrSessionToken`:

    * `Authorization: Bearer <session-token>` — API/JS clients holding the token
      returned by `POST /v1/auth/login`;
    * the signed `user_session` cookie — first-party browser.

  On success assigns `:current_user` and a `Barkpark.Content.CallerContext`
  (principal `:user`) for downstream content scoping. The cookie branch is a
  CSRF surface, so on mutating methods it additionally requires an
  `x-requested-with` header (same defense-in-depth as the api-token cookie
  branch); the bearer branch is exempt (APIs don't carry cookies).
  """
  import Plug.Conn
  alias Barkpark.Accounts
  alias Barkpark.Content.CallerContext

  @safe_methods ~w(GET HEAD OPTIONS)

  def init(opts), do: opts

  def call(conn, _opts) do
    case bearer(conn) do
      {:ok, raw} ->
        verify(conn, raw, :bearer)

      :none ->
        case get_session(conn, "user_session") do
          raw when is_binary(raw) and raw != "" -> verify(conn, raw, :cookie)
          _ -> unauthorized(conn)
        end
    end
  end

  defp verify(conn, raw, source) do
    case Accounts.verify_user_session_token(String.trim(raw)) do
      %Accounts.User{} = user ->
        conn
        |> maybe_require_csrf(source)
        |> assign_user(user)

      nil ->
        unauthorized(conn)
    end
  end

  defp assign_user(%Plug.Conn{halted: true} = conn, _user), do: conn

  defp assign_user(conn, user) do
    conn
    |> assign(:current_user, user)
    |> assign(:caller_context, CallerContext.from_user(user.id))
  end

  defp maybe_require_csrf(conn, :bearer), do: conn

  defp maybe_require_csrf(conn, :cookie) do
    if conn.method in @safe_methods or requested_with?(conn) do
      conn
    else
      halt_json(conn, 403, "csrf_required", "missing x-requested-with header")
    end
  end

  defp requested_with?(conn) do
    case get_req_header(conn, "x-requested-with") do
      [v | _] when is_binary(v) and v != "" -> true
      _ -> false
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw] -> {:ok, raw}
      _ -> :none
    end
  end

  defp unauthorized(conn),
    do: halt_json(conn, 401, "unauthorized", "a valid login session is required")

  defp halt_json(conn, status, code, message) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.json(%{error: %{code: code, message: message}})
    |> halt()
  end
end
