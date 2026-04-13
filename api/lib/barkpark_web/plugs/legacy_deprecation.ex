defmodule BarkparkWeb.Plugs.LegacyDeprecation do
  @moduledoc "Adds Deprecation/Sunset/Link headers to legacy /api/* routes."
  import Plug.Conn

  def init(_), do: []

  def call(conn, _) do
    conn
    |> put_resp_header("deprecation", "true")
    |> put_resp_header("sunset", "Wed, 31 Dec 2026 23:59:59 GMT")
    |> put_resp_header("link", "</v1/data/query>; rel=\"successor-version\"")
  end
end
