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

  ## THE residual risk (cannot be fully defended internally)

  Trust is decided from the Host header, because a 127.0.0.1-bound app sees a
  loopback source IP for BOTH the operator's localhost request AND tunnel traffic
  (the tunnel client is a local process) — so Host is the only available signal.
  The perimeter holds only while the operator (Host = localhost / LAN) and the
  public caller (Host = the tunnel domain) cannot be confused:

    * **Host rewrite (operator footgun).** A tunnel run with Host rewrite to the
      origin (cloudflared `httpHostHeader: localhost`, ngrok
      `--host-header=rewrite`) makes every tunnel request arrive as `localhost`
      → treated as the operator → full app exposed. NEVER enable Host rewrite.
    * **Host forgery (attacker).** If the tunnel forwards a CLIENT-chosen Host
      verbatim, an attacker could send `Host: localhost` to pass as the operator.
      Use a Host-ROUTED tunnel — cloudflared routes `<x>.trycloudflare.com` by
      that hostname and the edge pins the Host, so a forged `localhost` does not
      reach your tunnel. Avoid tunnels that let a client pick the forwarded Host.

  A DNS name is PARSED, not prefix-matched, so `Host: 10.evil.com` is never
  trusted. MANDATORY before sharing any link: on the public URL confirm
  `GET /studio` → 404 and `GET /s/<token>` → 200. (A hardened future option is a
  dedicated always-guarded port that the tunnel forwards to, removing the Host
  dependency entirely.)

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

  # The operator's own box / LAN. Decided by PARSING the Host as an IP literal —
  # a string-prefix test would treat a DNS name like "10.evil.com" as local
  # (`String.starts_with?(_, "10.")`), a trivial guard bypass. So a DNS name is
  # NEVER local here; only "localhost" and actual loopback / RFC-1918 / link-local
  # IP literals are. (Residual: a forged `Host: localhost`/loopback over a tunnel
  # that lets a client choose the Host would still pass — see the moduledoc; use
  # a Host-routed tunnel like cloudflared, where the edge pins the Host.)
  defp local_host?(host) do
    case host |> to_string() |> String.downcase() do
      "localhost" ->
        true

      h ->
        case :inet.parse_address(String.to_charlist(h)) do
          {:ok, ip} -> loopback_or_private?(ip)
          _ -> false
        end
    end
  end

  defp loopback_or_private?({127, _, _, _}), do: true
  defp loopback_or_private?({10, _, _, _}), do: true
  defp loopback_or_private?({192, 168, _, _}), do: true
  defp loopback_or_private?({169, 254, _, _}), do: true
  defp loopback_or_private?({172, b, _, _}) when b in 16..31, do: true
  defp loopback_or_private?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_or_private?(_), do: false

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

  # Public media SERVING only — the bytes/thumbnails embedded in shared
  # papers/docs. NOT the flat `/media` index or `/media/:id/meta`: those are
  # UNGATED (no token, no share) and would enumerate the whole library +
  # metadata over the tunnel with zero shares configured.
  defp allowed_path?(["media", "files" | _]), do: true
  defp allowed_path?(["media", "renditions" | _]), do: true

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
