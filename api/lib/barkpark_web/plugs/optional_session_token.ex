defmodule BarkparkWeb.Plugs.OptionalSessionToken do
  @moduledoc """
  Soft-auth plug for browser-facing scoped routes. Assigns `:api_token`
  when a valid token is present in EITHER:

    * `Authorization: Bearer …` — API clients and Web Components that
      receive `data-token` from LiveView, or
    * `session["api_token"]` — a browser user who signed in at
      `GET /login` (see `BarkparkWeb.SessionController`).

  The Bearer header wins when both are present. Never halts — like
  `BarkparkWeb.Plugs.OptionalToken`, it passes an anonymous conn through
  untouched and lets the downstream membership gate
  (`BarkparkWeb.Plugs.ResolveWorkspace`) reject closed.

  This is the cookie-aware sibling of `OptionalToken`. It exists for the
  `:scoped_browser` pipeline: a logged-in browser user carries only the
  session cookie (no Bearer header), so plain `OptionalToken` left
  `conn.assigns[:api_token]` nil and `ResolveWorkspace.authorize/3`
  403'd a real member before the LiveView could mount. Reading the
  session token here lets that member resolve their token → membership
  gate passes → the scoped plugin LV mounts.

  Requires `:fetch_session` upstream (the `:scoped_browser` pipeline runs
  `:fetch_session` before this plug).
  """

  import Plug.Conn
  alias Barkpark.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    case token_from_bearer(conn) || token_from_session(conn) do
      {:ok, token} -> assign(conn, :api_token, token)
      _ -> conn
    end
  end

  defp token_from_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw] -> verify(raw)
      _ -> nil
    end
  end

  defp token_from_session(conn) do
    case get_session(conn, "api_token") do
      raw when is_binary(raw) and raw != "" -> verify(raw)
      _ -> nil
    end
  end

  defp verify(raw) do
    case Auth.verify_token(String.trim(raw)) do
      {:ok, token} -> {:ok, token}
      _ -> nil
    end
  end
end
