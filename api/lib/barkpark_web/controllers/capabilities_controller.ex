defmodule BarkparkWeb.CapabilitiesController do
  @moduledoc """
  `GET /v1/capabilities` — the single CLI/MCP/SDK contract surface (M1).

  Mounted under the `:api` pipeline so `BarkparkWeb.Plugs.OptionalToken`
  resolves an OPTIONAL token into `conn.assigns[:api_token]`. The controller
  maps that token to one of the six auth tiers, assembles the full superset
  manifest, projects it through the existence-hiding allow-list keyed on the
  caller's tier, and returns the projected manifest as JSON.

  The projected body is content-addressed into an ETag (varies by tier); an
  `If-None-Match` that matches short-circuits to `304 Not Modified` with an
  empty body.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Plugins.{Capabilities, CapabilitiesBrief}
  alias BarkparkWeb.ErrorResponse
  alias BarkparkWeb.Http.IfNoneMatch

  import Plug.Conn,
    only: [get_req_header: 2, get_resp_header: 2, put_resp_header: 3, send_resp: 3]

  def index(conn, params) do
    # ?view=brief (ctx-b2-server-view-brief): BRIEF-KEEP-LIST v1, the CLI's
    # born-brief projection adopted verbatim (`CapabilitiesBrief`). OPT-IN like
    # every other shaping param here: without it the body is byte-identical to
    # the default contract, which released bp binaries strict-decode. An
    # unknown view is a 400 naming the two that exist, never a silent full
    # body, because a caller that asked for a shape must not mistake another
    # one for it.
    case params["view"] do
      v when v in [nil, "full"] -> respond(conn, params, :full)
      "brief" -> respond(conn, params, :brief)
      other -> refuse_view(conn, other)
    end
  end

  defp refuse_view(conn, other) do
    ErrorResponse.emit_custom(
      conn,
      400,
      "malformed",
      "unknown view #{inspect(other)}: GET /v1/capabilities serves view=full (the default) or view=brief",
      %{parameter: "view", requested: other, allowed: ["full", "brief"]}
    )
  end

  defp respond(conn, params, view) do
    caller_tier = Capabilities.tier_for_token(conn.assigns[:api_token])
    # ?build=1 opts in to the "build" identity key. Opt-in (never default):
    # released bp binaries strict-decode the manifest and reject unknown
    # root keys, so old clients must keep receiving the exact old shape.
    include_build = params["build"] in ["1", "true"]

    # ?views=1 opts in to the command-level "views" descriptor on the commands
    # that support the brief/full projection (task.ready, task.prime,
    # search.query). Same opt-in discipline as ?build=1: DisallowUnknownFields
    # recurses into each Command, so a stale bp would reject an unconditional
    # command-level key. Without the param the body stays byte-identical to the
    # pre-views contract (maybe_gate_views strips the declared key).
    include_views = params["views"] in ["1", "true"]

    # ?chat=1 opts in to the root "chat" capability-discovery key (charter D27):
    # per-provider modes/models/efforts for the chat pickers. Same opt-in
    # discipline as ?build=1 — a stale bp strict-decodes the root, so the key is
    # emitted only to callers that ask (and never to tier "none").
    include_chat = params["chat"] in ["1", "true"]

    # ?bpml=1 opts in to the root "bpml" vocabulary key (BPML masterplan W0):
    # the block grammar + inline marks + drift-detection digest. Same opt-in
    # discipline as ?build/?views/?chat — strict-decoding released CLIs must
    # keep receiving the exact old shape unless they ask.
    include_bpml = params["bpml"] in ["1", "true"]

    # ?token=1 opts in to the root "token" key (task-0cf611238d4ad597 JQ1):
    # `token.public_read` says whether the caller's own credential is a
    # `public-read` mint, which `auth_tier` ("read" for both) cannot say. The
    # search starters ask for it before they inline a token into a browser
    # bundle. Same opt-in discipline as ?build/?views/?chat/?bpml.
    include_token = params["token"] in ["1", "true"]

    # base_url must be the host the caller ACTUALLY dialed, not the frozen
    # boot-time PHX_HOST scalar — a custom instance hostname and the canonical
    # FQDN each get their own host back (D4 server-side: one instance, many
    # alias URLs). VALUE-only override through the existing `:server` option;
    # the envelope keys stay exactly as `default_server/0` fixes them (the Go
    # client strict-decodes the manifest, so a NEW server key is a whole-CLI
    # parse outage).
    server = %{Capabilities.default_server() | "base_url" => host_base(conn)}

    manifest =
      Capabilities.manifest(caller_tier,
        include_build: include_build,
        include_views: include_views,
        include_chat: include_chat,
        include_bpml: include_bpml,
        include_token: include_token,
        public_read: BarkparkWeb.Plugs.PublicRead.public_read_token?(conn),
        server: server
      )

    # THE VALIDATOR FOLDS THE VIEW (RFC 9110 §8.8.3). The brief and the full
    # body are two representations of one resource, so they must not share a
    # strong ETag. If they did, a client holding the full manifest's ETag could
    # revalidate a ?view=brief request into a 304 and keep the wrong shape.
    # `CapabilitiesBrief.http_etag/1` derives the brief's validator from the
    # full one, so it still moves exactly when the manifest does. The other
    # shaping params (?build/?views/?chat/?bpml) already change the hashed
    # body, so `manifest["etag"]` already differs across them.
    {etag, body} =
      case view do
        :full ->
          {manifest["etag"], manifest}

        :brief ->
          {CapabilitiesBrief.http_etag(manifest["etag"]), CapabilitiesBrief.project(manifest)}
      end

    conn =
      conn
      |> put_vary_authorization()
      |> put_resp_header("etag", etag)

    if IfNoneMatch.match?(conn, etag) do
      send_resp(conn, 304, "")
    else
      json(conn, body)
    end
  end

  # This body is TIER-KEYED: `Capabilities.project/2` filters commands and nouns
  # by the caller's tier and overwrites `auth_tier`, and `etag_for/1` hashes the
  # PROJECTED body — so the ETag itself is already representation-correct (an
  # anon manifest and an admin manifest cannot collide). What was missing is the
  # instruction to the cache: the response is a function of the Authorization
  # header, so a shared cache keying on URL alone would hand one tier's manifest
  # to another. `private` (Plug's default) is the only thing standing between
  # that today, and managed CDN policies are documented to cache through it.
  #
  # Direction: adding Vary strictly NARROWS what a cache may reuse — it costs
  # cacheability, it cannot grant it (charter D1/D6).
  #
  # Merged, never overwritten: prod responses already carry `accept-encoding`
  # in this header from a hop outside this app, and dropping it would break
  # encoding negotiation. See QueryController.put_vary_authorization/1 for the
  # converse risk (an outside hop that SETS rather than APPENDS) and the
  # post-deploy check that settles it.
  defp put_vary_authorization(conn) do
    existing =
      conn
      |> get_resp_header("vary")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    merged =
      if Enum.any?(existing, &(String.downcase(&1) == "authorization")),
        do: existing,
        else: existing ++ ["authorization"]

    put_resp_header(conn, "vary", Enum.join(merged, ", "))
  end

  # Per-request public base URL, mirroring
  # `TicketKeysController.host_base/1`. `conn.host` is already the public host
  # behind Caddy (the endpoint has no `RewriteOn`, and Caddy preserves the
  # Host header — do NOT read x-forwarded-host). When the proxy declares the
  # outside scheme via `x-forwarded-proto`, trust it (the internal hop is
  # http); take the public port from `x-forwarded-port` when present, else the
  # scheme's standard port (which is elided from the URL).
  defp host_base(conn) do
    case forwarded_proto(conn) do
      nil -> base_url(to_string(conn.scheme), conn.host, conn.port)
      proto -> base_url(proto, conn.host, forwarded_port(conn) || standard_port(proto))
    end
  end

  defp base_url(scheme, host, port) do
    if standard_port?(scheme, port) do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end

  # First entry of x-forwarded-proto (chained proxies comma-join), lowercased;
  # only literal http/https are trusted — anything else falls back to conn.scheme.
  defp forwarded_proto(conn) do
    with [value | _] <- get_req_header(conn, "x-forwarded-proto"),
         proto = value |> String.split(",") |> hd() |> String.trim() |> String.downcase(),
         true <- proto in ["http", "https"] do
      proto
    else
      _ -> nil
    end
  end

  defp forwarded_port(conn) do
    with [value | _] <- get_req_header(conn, "x-forwarded-port"),
         {port, ""} <- Integer.parse(String.trim(value)) do
      port
    else
      _ -> nil
    end
  end

  defp standard_port("http"), do: 80
  defp standard_port("https"), do: 443

  defp standard_port?("http", 80), do: true
  defp standard_port?("https", 443), do: true
  defp standard_port?(_, _), do: false
end
