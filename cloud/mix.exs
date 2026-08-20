defmodule BarkparkCloud.MixProject do
  use Mix.Project

  def project do
    [
      app: :barkpark_cloud,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases()
    ]
  end

  # Mix release config — `MIX_ENV=prod mix release` assembles a self-contained
  # OTP release (the BEAM runtime + the compiled app) under _build/prod/rel/.
  # It does NOT touch the DB at build time: runtime.exs reads DATABASE_URL et al.
  # at boot, so the image bakes with no secrets and no Postgres reachable. The
  # container migrates then starts the release — see cloud/Dockerfile.
  defp releases do
    [
      barkpark_cloud: [
        include_executables_for: [:unix]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {BarkparkCloud.Application, []},
      # :inets + :ssl back the built-in :httpc transport that
      # BarkparkCloud.Billing.HttpClient uses to reach api.stripe.com over
      # verified TLS — no new dependency (cloud-17). :xmerl is the OTP XML app
      # BarkparkCloud.ArchiveStore parses ListObjectsV2 responses with (S14/D39)
      # — an OTP-bundled library app (like :inets/:ssl), NOT a hex dependency;
      # listed so `mix release` includes it (its modules aren't pulled in
      # transitively by any other app).
      extra_applications: [:logger, :inets, :ssl, :xmerl]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:jason, "~> 1.2"},
      # cloud-8 (identity): password hashing for the User. bcrypt's 72-byte
      # input cap is mirrored by the User schema's max password length.
      {:bcrypt_elixir, "~> 3.0"},
      # two-factor-auth: RFC-6238 TOTP — secret generation, otpauth:// URI,
      # time-step verification. Pure Elixir, zero transitive deps; the Elixir
      # replacement for the TOTP half of Laravel Fortify that Coolify mounted
      # for free. QR is rendered client-side from the returned otpauth:// URI,
      # so no server-side QR dependency is needed.
      {:nimble_totp, "~> 1.0"},
      # cloud-12a (control-plane HTTP API): the minimal JSON API that exposes the
      # Accounts/Registry/Billing contexts to the agent (cloud-10) and the Go CLI
      # client (cloud-12b). Plug.Router + Bandit — deliberately NOT full
      # Phoenix/LiveView (the dashboard is a later task). Bandit is the modern,
      # pure-Elixir HTTP server; Plug supplies the router + JSON body parsing.
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      # bp-login-ux-w2: recover the REAL client IP behind the Caddy TLS front.
      # The app listens plain on loopback :410x, so conn.remote_ip is always the
      # loopback hop — collapsing the device-auth `start:<ip>` rate bucket into one
      # global bucket and stamping 127.0.0.1 on every minted session. RemoteIp
      # resolves the client from X-Forwarded-For, but ONLY when the actual peer is
      # a trusted loopback proxy (see :trust_forwarded_ip in web/router.ex) so a
      # spoofed header from a directly-reachable client can never forge a bucket.
      {:remote_ip, "~> 1.2"},
      # oban-substrate: the cloud control plane's background-job + cron engine.
      # Same major as api/mix.exs's `{:oban, "~> 2.17"}` dep so both apps
      # share one Oban mental model. Postgres-backed — it reuses
      # BarkparkCloud.Repo, so no Redis and no new infra/secret. Recurring
      # housekeeping (the stale-provision-job reaper today; health-staleness
      # sweeps, usage downgrade, billing reconcile later) and ad-hoc fan-out
      # (notification dispatch, backup kickoff) all enqueue/schedule through this.
      # Pulls only ecto_sql + postgrex + jason as deps — all already present.
      {:oban, "~> 2.17"},
      # push-relay build (mobile charter D15): the ONE HTTP client in cloud/ that
      # speaks HTTP/2. Everything else here reaches the network over :httpc
      # (Billing.HttpClient) — but the APNs provider API is HTTP/2-ONLY, with no
      # HTTP/1.1 endpoint at all, so :httpc cannot deliver an iOS notification
      # under any configuration. Mint is the minimal answer: pure Elixir, one
      # transitive dep (hpax) that bandit already brings, no pool/supervision
      # tree of its own. api/ already ships mint (via finch), so this is a
      # version the repo already runs. Used ONLY by Push.HTTP.Mint.
      {:mint, "~> 1.6"},
      # notifications-email: the Phoenix-native mailer. Swoosh builds the email +
      # selects a transport ADAPTER from config — the same config-selected-adapter
      # seam as Billing.Gateway / Registry.Vault. gen_smtp backs
      # Swoosh.Adapters.SMTP for the self-host/SMTP platform transport (dev uses
      # the in-memory Local mailbox, test uses the Test adapter), so SMTP/Local/
      # Test need NO HTTP-client dep — only a hosted-API adapter (Resend/SendGrid)
      # would pull Finch/Hackney, which is deferred.
      {:swoosh, "~> 1.16"},
      {:gen_smtp, "~> 1.2"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # `ecto.setup` mirrors api/'s: create the database then run every pending
  # migration. See the README for the full boot sequence.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end
end
