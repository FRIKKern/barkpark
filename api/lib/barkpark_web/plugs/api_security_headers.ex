defmodule BarkparkWeb.Plugs.ApiSecurityHeaders do
  @moduledoc """
  Baseline security headers for JSON API responses.

  The `:browser`/Studio pipelines run `put_secure_browser_headers`, but the
  `:api` pipeline never did — so every `/v1/*` JSON response shipped with no
  `x-content-type-options` and no `referrer-policy`. This plug closes that gap
  with the two headers that are zero-risk for a JSON (non-HTML) surface:

    * `x-content-type-options: nosniff` — stop content-type sniffing.
    * `referrer-policy: strict-origin-when-cross-origin` — don't leak full URLs
      cross-origin.

  Deliberately NOT set here:

    * CSP — needs per-response nonce work and only matters for HTML.
    * X-Frame-Options — API JSON isn't framed.
    * HSTS / force_ssl — HTTPS is terminated upstream; Golden Rule #5.

  Runs via `register_before_send` and only adds a header when the response does
  not already carry it, so a controller (or CORS plug) that sets its own value
  always wins and headers are never doubled.
  """

  @behaviour Plug

  import Plug.Conn

  @headers [
    {"x-content-type-options", "nosniff"},
    {"referrer-policy", "strict-origin-when-cross-origin"}
  ]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    register_before_send(conn, &add_headers/1)
  end

  defp add_headers(conn) do
    Enum.reduce(@headers, conn, fn {name, value}, acc ->
      case get_resp_header(acc, name) do
        [] -> put_resp_header(acc, name, value)
        _present -> acc
      end
    end)
  end
end
