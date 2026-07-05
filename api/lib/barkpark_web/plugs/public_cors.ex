defmodule BarkparkWeb.Plugs.PublicCors do
  @moduledoc """
  CORS for the `:public_api` plugin route bucket — and ONLY that bucket.

  The core API deliberately serves no CORS headers (browsers cannot call
  `/v1/data/*` cross-origin; verified 2026-07-05 and load-bearing for the
  Shared Storm design). This plug exists so a plugin can opt a specific
  ANONYMOUS surface into browser reach without cracking that door open
  anywhere else.

  `Access-Control-Allow-Origin: *` is correct here, not a shortcut: the
  bucket carries no cookies, no bearer tokens, and no user identity, so
  there is no credentialed session for a hostile origin to ride — CORS
  protects users' credentials, and this surface has none. Abuse is handled
  where it belongs, in the per-IP/per-channel rate caps (`Barkpark.Pulse`).

  Preflights terminate here: the router only matches declared verbs, so
  plugins on this bucket declare an `{:options, path, …}` route per
  cross-origin POST path (the `plugin_routes` macro supports `:options`
  for exactly this), and this plug halts it with a 204 before the
  controller is ever invoked.
  """

  import Plug.Conn

  @headers [
    {"access-control-allow-origin", "*"},
    {"access-control-allow-methods", "GET, POST, OPTIONS"},
    {"access-control-allow-headers", "content-type"},
    {"access-control-expose-headers", "retry-after"},
    {"access-control-max-age", "86400"}
  ]

  def init(opts), do: opts

  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    conn
    |> merge_resp_headers(@headers)
    |> send_resp(204, "")
    |> halt()
  end

  def call(conn, _opts), do: merge_resp_headers(conn, @headers)
end
