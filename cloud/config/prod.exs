import Config

# Compile-time production config. This file is imported by config.exs at the end
# (`import_config "#{config_env()}.exs"`) and must exist for `MIX_ENV=prod` to
# build — including `mix release`.
#
# Keep it COMPILE-TIME ONLY. Everything secret or environment-derived
# (DATABASE_URL, REGISTRY_ENCRYPTION_KEY, STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET,
# WORKER_TOKEN, PORT) is read at BOOT in runtime.exs — never here — so the
# release assembles with no DB reachable and no secrets baked into the image.

# Do not log debug noise in production.
config :logger, level: :info
