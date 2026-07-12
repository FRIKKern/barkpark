import Config

# Sobelow Config.HTTPS (justified, stays baselined — task-f76e9b7b):
# force_ssl is DELIBERATELY off. TLS is terminated by the reverse proxy
# (Caddy in prod / on the Cloud hosts); the app speaks plain HTTP behind it.
# Enabling force_ssl here caused a 301 redirect LOOP because no HTTPS listener
# exists at the app tier — this is Golden Rule #5 / Past Mistake #5 (see
# CLAUDE.md). Do NOT re-enable without a real app-tier HTTPS listener. If TLS
# ever terminates at the app, uncomment:
#
# config :barkpark, BarkparkWeb.Endpoint,
#   force_ssl: [rewrite_on: [:x_forwarded_proto]]

config :logger, level: :info
