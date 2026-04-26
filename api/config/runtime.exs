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

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :barkpark, Barkpark.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

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

  config :barkpark, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :barkpark, BarkparkWeb.Endpoint,
    url: [host: host, port: String.to_integer(System.get_env("PORT", "4000")), scheme: scheme],
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

  if origins = System.get_env("DEFAULT_CORS_ORIGINS") do
    parsed = origins |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    config :barkpark, :default_cors_origins, parsed
  end

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
