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

  ## SECOND MOUNT: `:media_public_cors` (jf-w1-media-cors-upstream)

  The plugin bucket is no longer the only mount. The four PUBLIC media serve
  GETs (`/media/files/*`, `/media/renditions/:id/:preset`, `/media`,
  `/media/:id/meta`) carry it too, via the `:media_public_cors` pipeline in
  `router.ex`. The same argument admits them and no wider surface: those
  routes mount neither `:fetch_session` nor `OptionalSessionToken`, so
  `:current_user` is never assigned and `Media.Storage.Access.authenticated?/1`
  can only be satisfied by an explicit `Authorization` bearer — which a browser
  never attaches cross-origin, and which no cookie can substitute for while
  this plug sends no `access-control-allow-credentials`. There is still no
  credentialed session for a hostile origin to ride.

  ## `:methods`

  The only option, and it exists so a mount can tell the truth about the verbs
  it actually grants. The media mount passes `methods: "GET, HEAD"` — that
  scope declares read routes only. Default is the plugin bucket's historical
  `"GET, POST, OPTIONS"`, so the `:public_api` mount is byte-identical to
  before. The value is only ever consulted by a browser in a PREFLIGHT
  response, so it changes no simple-GET behaviour either way; it is an
  honesty fix, not a gate.
  """

  import Plug.Conn

  @default_methods "GET, POST, OPTIONS"

  @headers [
    {"access-control-allow-origin", "*"},
    {"access-control-allow-headers", "content-type"},
    {"access-control-expose-headers", "retry-after"},
    {"access-control-max-age", "86400"}
  ]

  def init(opts), do: opts

  def call(%Plug.Conn{method: "OPTIONS"} = conn, opts) do
    conn
    |> merge_resp_headers(headers(opts))
    |> send_resp(204, "")
    |> halt()
  end

  def call(conn, opts), do: merge_resp_headers(conn, headers(opts))

  defp headers(opts) when is_list(opts) do
    [{"access-control-allow-methods", Keyword.get(opts, :methods, @default_methods)} | @headers]
  end

  defp headers(_opts),
    do: [{"access-control-allow-methods", @default_methods} | @headers]
end
