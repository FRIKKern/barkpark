import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/barkpark start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :barkpark, BarkparkWeb.Endpoint, server: true
end

# Continuous-canvas editor cutover: ON by default in PRODUCTION (the unified
# <bp-paper-canvas> Obsidian-style editor). Dev/test stay OFF (the per-block
# <bp-paper-editor>) so the flag-OFF byte-identical guarantee and its tests hold.
# PaperCanvas.paper_canvas_enabled?/0 reads BARKPARK_PAPER_CANVAS at request time, so
# this is an overridable DEFAULT — set BARKPARK_PAPER_CANVAS=0 in the prod env to roll
# back instantly (no code redeploy); flag-off is byte-identical, no data migration.
if config_env() == :prod and System.get_env("BARKPARK_PAPER_CANVAS") in [nil, ""] do
  System.put_env("BARKPARK_PAPER_CANVAS", "1")
end

config :barkpark, BarkparkWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

cloak_key =
  case System.get_env("BARKPARK_CLOAK_KEY") do
    nil ->
      if config_env() == :prod do
        raise """
        BARKPARK_CLOAK_KEY is not set.

        Generate one with:
            mix phx.gen.secret 32
        and add to /opt/barkpark/.env as BARKPARK_CLOAK_KEY=<value>.

        This MUST be independent of SECRET_KEY_BASE so that key rotation
        in either system does not invalidate the other.
        """
      else
        # Dev/test fallback — documented constant; rotation in dev does not matter.
        "DEV-ONLY-cloak-key-do-not-use-in-prod-32"
      end

    val ->
      val
  end

config :barkpark, Barkpark.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1", key: :crypto.hash(:sha256, cloak_key), iv_length: 12
    }
  ]

# Master KEK for envelope encryption (core auth/secrets, Phase 0). The dev/test
# default lives in config/config.exs; here we OVERRIDE from BARKPARK_KEK and
# REQUIRE it in prod. Base64 of 32 bytes — generate with `mix phx.gen.secret 32`
# then base64. MUST be independent of BARKPARK_CLOAK_KEY and SECRET_KEY_BASE.
case System.get_env("BARKPARK_KEK") do
  nil ->
    if config_env() == :prod do
      raise """
      BARKPARK_KEK is not set.

      Generate a base64 32-byte key and add it to /opt/barkpark/.env as
      BARKPARK_KEK=<value>. It MUST be independent of BARKPARK_CLOAK_KEY and
      SECRET_KEY_BASE. Without it, content fields marked `encrypted: true`
      cannot be sealed.
      """
    end

  kek ->
    # MEDIUM-9: BARKPARK_KEK_PREVIOUS (comma-separated Base64 keys, oldest-last)
    # lets `DataKeys.rewrap_all/0` complete a KEK rotation — it unwraps blobs
    # sealed by a prior KEK and re-wraps them under the current one. Set it to the
    # OLD BARKPARK_KEK during the rotation window, then clear it once rewrap_all
    # has run. Absent → no fallback (single-key behaviour, unchanged).
    previous_keys =
      System.get_env("BARKPARK_KEK_PREVIOUS", "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    config :barkpark, Barkpark.Crypto.LocalKek,
      key: kek,
      previous_keys: previous_keys,
      version: String.to_integer(System.get_env("BARKPARK_KEK_VERSION", "1"))
end

# Bokbasen credentials (Phase 7 / OnixEdit plugin, WI2). Read from OS env in
# every environment so dev can `source deploy/bokbasen.env` and prod can rely
# on systemd's EnvironmentFile=. Missing values fall back to the encrypted
# plugin_settings row at lookup time — see
# `Barkpark.Plugins.OnixEdit.Bokbasen.Settings`. The HTTP client (WI3) and
# the Oban worker (WI4) read this via `get_credentials/0`.
bokbasen_env_keys = [
  api_base: System.get_env("BOKBASEN_API_BASE"),
  oauth_token_url: System.get_env("BOKBASEN_OAUTH_TOKEN_URL"),
  client_id: System.get_env("BOKBASEN_CLIENT_ID"),
  client_secret: System.get_env("BOKBASEN_CLIENT_SECRET"),
  client_role: System.get_env("BOKBASEN_CLIENT_ROLE")
]

bokbasen_env =
  bokbasen_env_keys
  |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

if bokbasen_env != [] do
  config :barkpark, Barkpark.Plugins.OnixEdit.Bokbasen, bokbasen_env
end

# Indx search-engine credentials (retriever seam). `Barkpark.Plugins.Indx.Settings`
# reads these from `Application.get_env(:barkpark, Barkpark.Plugins.Indx)` (env
# wins, else the encrypted plugin_settings row, else defaults) — but nothing
# populated that app-env key, so api_base/user_email/user_password resolved to
# nil and Indx.Auth raised "user_password not configured", failing every
# rebuild. Map the INDX_* OS env vars here, mirroring the Bokbasen block above.
# (INDX_INCREMENTAL_UPSERT is read directly via System.get_env in Settings, so
# it is intentionally not mapped here.)
indx_env =
  [
    api_base: System.get_env("INDX_API_BASE"),
    user_email: System.get_env("INDX_USER_EMAIL"),
    user_password: System.get_env("INDX_USER_PASSWORD"),
    # v5: team that owns the datasets (route scope) + static JWT API token from
    # the Indx portal (/Account/ApiKey). Setting INDX_TEAM flips the client to
    # v5 team-scoped routes + token auth; until both are set, legacy behavior.
    team: System.get_env("INDX_TEAM"),
    api_token: System.get_env("INDX_API_TOKEN")
  ]
  |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

if indx_env != [] do
  config :barkpark, Barkpark.Plugins.Indx, indx_env
end

# One-way PULL sync source (Barkpark.Sync). `Barkpark.Sync.Settings.load/0`
# reads these from `Application.get_env(:barkpark, Barkpark.Sync)` (env wins,
# else the config.exs `enabled: false` default). Placed OUTSIDE the
# `config_env() == :prod` guard so it applies in all envs — exactly the
# Indx/Bokbasen idiom above. DORMANT unless a source is configured AND
# BARKPARK_SYNC_ENABLED is truthy; `enabled?/0` additionally requires
# url+token+dataset all present, so a partial config can never accidentally
# start the puller.
sync_env =
  [
    url: System.get_env("BARKPARK_SYNC_URL"),
    token: System.get_env("BARKPARK_SYNC_TOKEN"),
    workspace: System.get_env("BARKPARK_SYNC_WORKSPACE"),
    project: System.get_env("BARKPARK_SYNC_PROJECT"),
    dataset: System.get_env("BARKPARK_SYNC_DATASET")
  ]
  |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

if sync_env != [] do
  # PUSH knobs (P2). `push_enabled` is a SEPARATE flag from `enabled` (pull):
  # push stays OFF unless explicitly requested, even when pull is on
  # (default-off, invariant #2). Batch size / interval are pure tunables.
  push_env =
    [
      push_enabled: System.get_env("BARKPARK_SYNC_PUSH_ENABLED") in ~w(1 true yes on),
      push_batch_size: System.get_env("BARKPARK_SYNC_PUSH_BATCH_SIZE"),
      push_interval_ms: System.get_env("BARKPARK_SYNC_PUSH_INTERVAL_MS")
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

  config :barkpark,
         Barkpark.Sync,
         sync_env ++
           [enabled: System.get_env("BARKPARK_SYNC_ENABLED") in ~w(1 true yes on)] ++ push_env
end

# Plugin selection from `bp setup` (BARKPARK_PLUGINS in .env). This is the
# runtime side of the registry kill switch — see
# `Barkpark.Plugins.Registry.discover_and_register/0`:
#
#   * env UNSET  -> leave :plugins unconfigured = discover-all-from-disk
#                   (fresh-install / production default — do NOT force []).
#   * env ""     -> config :plugins, [] = the kill switch (register nothing).
#   * env "a,b"  -> config :plugins, ["a", "b"] = explicit whitelist.
#
# `EnvConfig.parse/1` returns `:unset` only for nil, so the common unset case
# never touches the env and behaviour is identical to before.
case Barkpark.Plugins.EnvConfig.parse(System.get_env("BARKPARK_PLUGINS")) do
  :unset -> :ok
  plugins when is_list(plugins) -> config :barkpark, :plugins, plugins
end

# Scoped-sharing registry (P1a/P1c). Enable via the BARKPARK_SHARES env var.
# Format: "ws/proj/dataset:papers,docs:read;acme/web/staging:media:edit".
# See Barkpark.Sharing.parse/1 for full syntax.
#
# DEFAULT-OFF is paramount: with BARKPARK_SHARES unset/empty, `parse/1` returns
# [], so :shares is set to the harmless empty list AND the Endpoint http binding
# is left exactly as the env file configured it (dev.exs keeps ip: {127,0,0,1}).
#
# P4: `:shares_env` is the STATIC env baseline. The live `:shares` starts equal
# to it and is recomputed post-boot by `Barkpark.Sharing.refresh/0` as
# `shares_env ++ <persisted shares table>`, so a `bp share add` survives a
# restart. We seed `:shares` here too so the registry is correct even before the
# Repo is up (refresh/0 is GUARDED and a no-op until it is).
#
# LAN binding: we deep-merge `ip: {0,0,0,0}` over the existing http config
# (preserving the port) when EITHER at least one env share parses OR
# BARKPARK_SHARE_LAN is truthy. The flag decouples "expose this box on the LAN"
# from "which scopes" — set it to manage shares entirely via `bp share`/Studio
# (the env list may be empty). With neither, the bind is untouched (127.0.0.1 in
# dev). The boot banner in Barkpark.Application logs URLs + a trust warning.
if Code.ensure_loaded?(Barkpark.Sharing) do
  shares = Barkpark.Sharing.parse(System.get_env("BARKPARK_SHARES"))
  config :barkpark, :shares_env, shares
  config :barkpark, :shares, shares

  lan_opt_in? = System.get_env("BARKPARK_SHARE_LAN") in ~w(1 true yes on)

  if shares != [] or lan_opt_in? do
    config :barkpark, BarkparkWeb.Endpoint, http: [ip: {0, 0, 0, 0}]
  end

  # P7: the public host SHARE LINKS advertise (Barkpark.Sharing.share_link_base/0
  # prefers it). Set to a tunnel domain (e.g. https://abc.trycloudflare.com) to
  # share OUTSIDE the LAN with the firewall untouched. Unset → LAN IP / Endpoint
  # url. Pair with the public-share guard so the tunnel host exposes ONLY the
  # read/share surfaces (see docs).
  config :barkpark, :share_host, System.get_env("BARKPARK_SHARE_HOST")
end

media_signing_secret =
  case System.get_env("MEDIA_SIGNING_SECRET") do
    val when is_binary(val) and val != "" ->
      val

    _ ->
      if config_env() == :prod do
        skb =
          System.get_env("SECRET_KEY_BASE") ||
            raise "SECRET_KEY_BASE required to derive media signing secret"

        Base.encode64(:crypto.hash(:sha256, "barkpark-media:" <> skb), padding: false)
      end
  end

if is_binary(media_signing_secret) and media_signing_secret != "" do
  config :barkpark, :media_signing_secret, media_signing_secret
end

media_cdn_base =
  case System.get_env("MEDIA_CDN_BASE_URL") do
    val when is_binary(val) and val != "" -> val
    _ -> nil
  end

media_cdn_invalidation =
  case System.get_env("MEDIA_CDN_INVALIDATION_URL") do
    url when is_binary(url) and url != "" ->
      [
        adapter: :http,
        url: url,
        secret: System.get_env("MEDIA_CDN_INVALIDATION_SECRET") || ""
      ]

    _ ->
      [adapter: :noop]
  end

if media_cdn_base do
  config :barkpark, :media_cdn,
    base_url: media_cdn_base,
    invalidation: media_cdn_invalidation
end

media_callback_token =
  case System.get_env("MEDIA_PROCESSING_CALLBACK_TOKEN") do
    val when is_binary(val) and val != "" -> val
    _ -> nil
  end

if media_callback_token do
  config :barkpark, :media_processing_callback_token, media_callback_token
end

media_webhook_url = System.get_env("MEDIA_WEBHOOK_URL")
media_webhook_secret = System.get_env("MEDIA_WEBHOOK_SECRET")

if is_binary(media_webhook_url) and media_webhook_url != "" do
  events =
    case System.get_env("MEDIA_WEBHOOK_EVENTS") do
      nil -> ["media.uploaded", "media.processed", "media.deleted"]
      "" -> ["media.uploaded", "media.processed", "media.deleted"]
      list -> String.split(list, ",", trim: true)
    end

  config :barkpark, :media_webhooks,
    endpoints: [
      %{url: media_webhook_url, secret: media_webhook_secret || "", events: events}
    ]
end

# Transactional mailer (verify-email / password-reset / already-registered — see
# Barkpark.Accounts.UserNotifier). config/config.exs defaults Barkpark.Mailer to
# Swoosh.Adapters.Local — an in-memory mailbox that NEVER delivers — and test.exs
# to Swoosh.Adapters.Test. So without this block a prod box returns HTTP 200 on
# register / request-reset but the email is written to memory and dropped.
#
# Setting SMTP_HOST (+ optional port/creds) flips the adapter to
# Swoosh.Adapters.SMTP via the already-present gen_smtp dep and actually sends.
# When SMTP_HOST is UNSET we configure NOTHING, leaving the compile-time adapter
# intact (Local in dev/prod, Test in test) — zero behaviour change until the relay
# env is provided, so envs that haven't configured a relay are unaffected.
#
# Env-driven only, no secrets in code. Shares the SMTP_* vocabulary with the cloud
# control plane (cloud/config/runtime.exs) so one EnvironmentFile can drive both
# apps behind the same postfix relay. The From address is owned by UserNotifier
# (no-reply@barkpark.cloud, matching the DKIM-signed relay domain) and is
# intentionally NOT overridden here.
case System.get_env("SMTP_HOST") do
  relay when is_binary(relay) and relay != "" ->
    smtp_username = System.get_env("SMTP_USERNAME")
    smtp_password = System.get_env("SMTP_PASSWORD")
    smtp_has_auth? = is_binary(smtp_username) and smtp_username != ""

    # VERIFY the relay's TLS cert by default: gen_smtp does NOT verify unless
    # tls_options carries verify: :verify_peer + a trust store + a raised depth,
    # so without this an active MITM could terminate STARTTLS and capture the SMTP
    # credentials. SMTP_VERIFY_PEER=false opts out for the self-hosted postfix
    # sidecar reached over a trusted internal hop; a public third-party relay MUST
    # keep verification on (the default). Mirrors cloud/config/runtime.exs.
    smtp_verify_peer? = System.get_env("SMTP_VERIFY_PEER", "true") != "false"

    smtp_tls_opts =
      if smtp_verify_peer? do
        [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          depth: 9,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ],
          server_name_indication: String.to_charlist(relay)
        ]
      else
        [verify: :verify_none]
      end

    smtp_base_opts = [
      adapter: Swoosh.Adapters.SMTP,
      relay: relay,
      port: String.to_integer(System.get_env("SMTP_PORT") || "587"),
      ssl: false,
      # Opportunistic STARTTLS — upgrade when the relay advertises it; tls_options
      # above pin verification. :if_available (not :always) keeps a plaintext
      # local-relay hop working when no creds/TLS are configured.
      tls: :if_available,
      tls_options: smtp_tls_opts,
      auth: if(smtp_has_auth?, do: :always, else: :if_available),
      retries: 1
    ]

    smtp_creds_opts =
      if smtp_has_auth?,
        do: [username: smtp_username, password: smtp_password],
        else: []

    config :barkpark, Barkpark.Mailer, smtp_base_opts ++ smtp_creds_opts

  _ ->
    :ok
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # Optional Unix-socket Postgres (Barkpark Cloud P4 / Move B): set
  # `DATABASE_SOCKET_DIR=/var/run/postgresql` to talk to a same-box Postgres
  # over a local socket instead of TCP loopback. Shaves a small but real
  # fixed cost off every query — on hosted boxes where Barkpark sits next to
  # its own Postgres, this is the production-recommended path. When unset,
  # the `:url` hostname stays authoritative.
  socket_dir = System.get_env("DATABASE_SOCKET_DIR")

  repo_opts = [
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6
  ]

  repo_opts =
    if socket_dir && socket_dir != "" do
      Keyword.put(repo_opts, :socket_dir, socket_dir)
    else
      repo_opts
    end

  config :barkpark, Barkpark.Repo, repo_opts

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host =
    case System.get_env("PHX_HOST") do
      nil ->
        raise """
        environment variable PHX_HOST is missing.

        PHX_HOST must be the public DNS hostname (e.g., api.barkpark.cloud),
        not an IP. Phoenix's Endpoint.check_origin whitelists exactly one
        host+scheme pair; a mismatch returns 403 on /live/websocket and
        silently breaks LiveView (Studio becomes click-dead).

        See docs/ops/studio-nav-bug-2026-04-19.md (task #11) for the incident
        and `make domain-cutover DOMAIN=...` for the remediation workflow.
        """

      "" ->
        raise """
        environment variable PHX_HOST is empty.
        Set PHX_HOST to the public DNS hostname. See
        docs/ops/studio-nav-bug-2026-04-19.md (task #11).
        """

      value ->
        value
    end

  scheme = System.get_env("PHX_SCHEME", "http")

  if scheme == "https" and Regex.match?(~r/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/, host) do
    raise """
    PHX_HOST is a literal IPv4 address (#{host}) but PHX_SCHEME=https.

    Phoenix Endpoint.check_origin will whitelist https://#{host}, but browsers
    reaching the site via a DNS name will send a different Origin header and
    receive 403 on /live/websocket — LiveView (Studio) will silently fail.

    Fix: set PHX_HOST to the DNS hostname served by your TLS terminator
    (Caddy, nginx, Cloudflare, etc.). If you truly need IP-only access, set
    PHX_SCHEME=http and terminate TLS elsewhere.

    See docs/ops/studio-nav-bug-2026-04-19.md (task #11).
    """
  end

  # LOW-15: mark the user-session cookie Secure when served over HTTPS, so it is
  # never echoed over plaintext HTTP. Driven by PHX_SCHEME — NOT force_ssl
  # (Golden Rule #5: force_ssl 301-loops on the prod-HTTP box). When the box is
  # genuinely HTTP-only (PHX_SCHEME=http) this stays false and the cookie is sent
  # as today; the moment TLS is fronted (PHX_SCHEME=https) it tightens.
  config :barkpark, :session_secure, scheme == "https"

  config :barkpark, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Phoenix Endpoint.check_origin allowlist. Without an explicit list it
  # whitelists only "#{scheme}://#{host}", which silently blocks the Vercel
  # apex demo and preview URLs (LiveView /live/websocket → 403).
  # cross-link: docs/ops/studio-nav-bug-2026-04-19.md (these origins are load-bearing for Vercel apex)
  # BARKPARK_EXTRA_ORIGINS: CSV of additional allowed origins, per-box. The
  # demo server sets http://<ip> here — operators reach Studio by IP out of
  # habit and a silent websocket 403 click-kills the panes (the journal shows
  # the rejects). Explicit env beats silently widening the default list.
  extra_origins =
    (System.get_env("BARKPARK_EXTRA_ORIGINS") || "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)

  check_origin =
    [
      "#{scheme}://#{host}",
      "https://barkpark.cloud",
      "https://www.barkpark.cloud",
      "https://*.vercel.app"
    ] ++ extra_origins

  # WebAuthn / passkeys: the relying-party id is the public host, and the
  # expected client origin is scheme://host. Derived from PHX_HOST so passkeys
  # bind to the real deployment domain (a passkey registered for one rp_id will
  # not assert against another — this MUST match the browser's origin).
  config :barkpark, :webauthn,
    rp_id: host,
    origin: "#{scheme}://#{host}"

  config :barkpark, BarkparkWeb.Endpoint,
    url: [host: host, port: String.to_integer(System.get_env("PORT", "4000")), scheme: scheme],
    check_origin: check_origin,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  preview_secret =
    System.get_env("PREVIEW_JWT_SECRET") ||
      raise "environment variable PREVIEW_JWT_SECRET is missing. Generate with: mix phx.gen.secret"

  config :barkpark, :preview,
    secret: preview_secret,
    ttl_seconds: String.to_integer(System.get_env("PREVIEW_JWT_TTL_SECONDS") || "600"),
    issuer: "barkpark"

  base_rate_limits = Application.get_env(:barkpark, :rate_limits, [])

  rate_limits =
    base_rate_limits
    |> Keyword.put(
      :read_per_minute,
      String.to_integer(
        System.get_env("BARKPARK_RATE_LIMIT_READ") ||
          Integer.to_string(Keyword.get(base_rate_limits, :read_per_minute, 300))
      )
    )
    |> Keyword.put(
      :write_per_minute,
      String.to_integer(
        System.get_env("BARKPARK_RATE_LIMIT_WRITE") ||
          Integer.to_string(Keyword.get(base_rate_limits, :write_per_minute, 60))
      )
    )

  config :barkpark, :rate_limits, rate_limits

  # Ticket-key abuse rails (BarkparkWeb.Plugs.TicketRateLimit) — per-hour
  # budgets per key + write class, operator-tunable without a rebuild, same
  # pattern as BARKPARK_RATE_LIMIT_READ/_WRITE above.
  base_ticket_limits = Application.get_env(:barkpark, :ticket_rate_limits, [])

  ticket_rate_limits =
    Enum.reduce(
      [
        create: "BARKPARK_TICKET_RATE_CREATE",
        message: "BARKPARK_TICKET_RATE_MESSAGE",
        attachment: "BARKPARK_TICKET_RATE_ATTACHMENT"
      ],
      base_ticket_limits,
      fn {class, env_var}, acc ->
        case System.get_env(env_var) do
          nil -> acc
          raw -> Keyword.put(acc, class, String.to_integer(raw))
        end
      end
    )

  config :barkpark, :ticket_rate_limits, ticket_rate_limits

  if origins = System.get_env("DEFAULT_CORS_ORIGINS") do
    parsed = origins |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    config :barkpark, :default_cors_origins, parsed
  end

  # Paper-ingest shared secret. When unset, the ingest endpoint rejects every
  # request (RequireIngestToken treats nil as "no token configured" → 401), so
  # the seam is closed by default in prod. PAPERFLOW_INGEST_TOKEN is honored as
  # a legacy fallback so existing prod .env / external producers keep working.
  if ingest_token =
       System.get_env("BARKPARK_INGEST_TOKEN") || System.get_env("PAPERFLOW_INGEST_TOKEN") do
    config :barkpark, :ingest_token, ingest_token
  end

  # Instance self-update checker (Barkpark.SelfUpdate). ON by default in prod
  # — opt out with BARKPARK_SELF_UPDATE_CHECK=off. The BARKPARK_UPSTREAM_*
  # vars override the config.exs upstream defaults; nil/empty values are
  # dropped so the defaults survive. Channel is an explicit whitelist
  # ("tags" | "branch") — never String.to_atom on raw env input.
  self_update_channel =
    case System.get_env("BARKPARK_UPSTREAM_CHANNEL") do
      "tags" -> :tags
      "branch" -> :branch
      _ -> nil
    end

  self_update_env =
    [
      enabled: System.get_env("BARKPARK_SELF_UPDATE_CHECK", "on") != "off",
      repo: System.get_env("BARKPARK_UPSTREAM_REPO"),
      branch: System.get_env("BARKPARK_UPSTREAM_BRANCH"),
      channel: self_update_channel
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

  config :barkpark, Barkpark.SelfUpdate, self_update_env

  # Instance self-update EXECUTOR (Barkpark.SelfUpdate.Runner). Fail-closed:
  # OFF unless BARKPARK_SELF_UPDATE_APPLY=1 explicitly opts the box in to
  # running scripts/self-update.sh from the admin trigger endpoint.
  # BARKPARK_SELF_UPDATE_CD overrides the working directory (default: the
  # repo root, resolved from the BEAM's cwd — see the Runner moduledoc).
  self_update_runner_env =
    [
      enabled: System.get_env("BARKPARK_SELF_UPDATE_APPLY") == "1",
      cd: System.get_env("BARKPARK_SELF_UPDATE_CD")
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

  config :barkpark, Barkpark.SelfUpdate.Runner, self_update_runner_env

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :barkpark, BarkparkWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :barkpark, BarkparkWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
