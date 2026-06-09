defmodule BarkparkWeb.Plugs.PublicShareGuard do
  @moduledoc """
  Tunnel host-gate for safe EXTERNAL sharing (P7).

  A tunnel (cloudflared / ngrok) forwards a public URL to localhost so an item
  link reaches someone outside the LAN with the firewall untouched — but it
  exposes the WHOLE app at the public URL (Studio, the /v1 write+admin APIs, the
  seeded admin token). This plug locks that down.

  ## Model — default-OFF, fail-CLOSED

    * **OFF unless tunnelling.** With no `:share_host` configured (no
      `BARKPARK_SHARE_HOST`), this is a pure no-op — zero behaviour change.
    * **Trusted hosts pass.** When tunnel mode is on, a request whose `conn.host`
      is loopback or an RFC-1918/link-local LAN address (the operator's own box /
      LAN) passes UNRESTRICTED — local development and LAN sharing are unchanged.
    * **Everything else is guarded.** Any OTHER host (the tunnel domain, a forged
      Host, a typo) may reach ONLY the public read/share surfaces, and only via
      `GET`/`HEAD`; everything else 404s (not 403 — no existence leak). The
      allow-list is default-DENY, so a future admin/write route is automatically
      blocked on the tunnel.

  ## THE one footgun (cannot be defended internally)

  The guard's security rests on `conn.host` being the PUBLIC tunnel hostname for
  tunnel traffic. cloudflared/ngrok forward the original public Host by default
  (good). If the tunnel is run with Host-header REWRITE to the origin
  (cloudflared `httpHostHeader: localhost`, ngrok `--host-header=rewrite`),
  `conn.host` becomes "localhost", this plug treats the tunnel as the trusted
  operator, and the full admin app is handed to the internet. RULE: never enable
  Host rewriting; verify on the tunnel that `/studio` 404s before sharing a link.
  With a 127.0.0.1-bound app the source IP is always loopback, so Host is the
  only available signal.

  Mounted in the Endpoint after `Plug.Static` (real assets are served regardless)
  and before body parsing (a blocked POST is 404'd without buffering) and the
  Router (no route resolved, no existence leaked).
  """
  @behaviour Plug

  import Plug.Conn

  @safe_methods ~w(GET HEAD)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Application.get_env(:barkpark, :share_host) do
      host when is_binary(host) and host != "" ->
        if local_host?(conn.host) or allowed?(conn.method, conn.path_info) do
          conn
        else
          conn |> send_resp(404, "Not Found") |> halt()
        end

      _ ->
        # Tunnel mode OFF → pure no-op (LAN / local behaviour unchanged).
        conn
    end
  end

  # Loopback + RFC-1918 private ranges + link-local ⇒ the operator's own box / LAN.
  defp local_host?(host) do
    h = host |> to_string() |> String.downcase()

    h in ~w(localhost 127.0.0.1 0.0.0.0 ::1) or
      String.starts_with?(h, ["127.", "10.", "192.168.", "169.254."]) or
      Regex.match?(~r/^172\.(1[6-9]|2\d|3[01])\./, h)
  end

  # Method gate FIRST — no writes ever leave the tunnel.
  defp allowed?(method, path) when method in @safe_methods, do: allowed_path?(path)
  defp allowed?(_method, _path), do: false

  # ── the default-DENY allow-list of externally-safe read/share paths ──────

  # ITEM share link reader (static HTML / doc JSON / media file).
  defp allowed_path?(["s", _token]), do: true

  # Paper readers (flat Bulldocs LiveView dead-render + scoped controller).
  defp allowed_path?(["papers", _slug]), do: true
  defp allowed_path?(["w", _w, "p", _p, "papers", _slug]), do: true

  # Share-GATED scoped data reads — RequireShareScope(:docs) still enforces the
  # share, so these only open when the operator ran `bp share add …:docs:read`.
  defp allowed_path?(["w", _w, "p", _p, "v1", "data", k | _]) when k in ~w(query doc search),
    do: true

  defp allowed_path?(["w", _w, "p", _p, "v1", "search" | _]), do: true

  # Share-GATED scoped media reads (index / meta / serve; RequireShareScope :media).
  defp allowed_path?(["w", _w, "p", _p, "media" | _]), do: true

  # Public media serving — images embedded in shared papers/docs.
  defp allowed_path?(["media" | _]), do: true

  # Media-collection public share link (token-scoped, analogous to /s/:token).
  defp allowed_path?(["v1", "media", _ds, "share", _token]), do: true

  # SDK handshake + tier-aware capabilities (designed-public).
  defp allowed_path?(["v1", "meta"]), do: true
  defp allowed_path?(["v1", "capabilities"]), do: true

  # Static assets (belt-and-suspenders — Plug.Static already served real files).
  defp allowed_path?([p | _]) when p in ~w(assets fonts images), do: true
  defp allowed_path?(["favicon.ico"]), do: true
  defp allowed_path?(["robots.txt"]), do: true

  # DEFAULT DENY → 404 (studio, admin, login, /live, /v1/shares, /v1/schemas,
  # /v1/webhooks, /v1/plugins, /v1/data/mutate, flat /v1/data, /api/*, …).
  defp allowed_path?(_), do: false
end
