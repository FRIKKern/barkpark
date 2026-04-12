import Config

# SSL should be handled by a reverse proxy (Caddy/nginx) in production.
# Uncomment force_ssl when HTTPS is set up:
#
# config :sanity_api, SanityApiWeb.Endpoint,
#   force_ssl: [rewrite_on: [:x_forwarded_proto]]

config :logger, level: :info
