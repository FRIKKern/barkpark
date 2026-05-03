defmodule BarkparkWeb.Plugs.OptionalToken do
  @moduledoc """
  Soft-auth plug. Assigns `:api_token` when a valid `Authorization: Bearer …`
  header is present; otherwise passes the conn through untouched.

  Never halts. For endpoints that must reject anonymous callers, use
  `BarkparkWeb.Plugs.RequireToken` instead.
  """

  import Plug.Conn
  alias Barkpark.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw_token] ->
        case Auth.verify_token(raw_token) do
          {:ok, token} -> assign(conn, :api_token, token)
          _ -> conn
        end

      _ ->
        conn
    end
  end
end
