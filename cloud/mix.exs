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
      # verified TLS — no new dependency (cloud-17).
      extra_applications: [:logger, :inets, :ssl]
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
      # cloud-12a (control-plane HTTP API): the minimal JSON API that exposes the
      # Accounts/Registry/Billing contexts to the agent (cloud-10) and the Go CLI
      # client (cloud-12b). Plug.Router + Bandit — deliberately NOT full
      # Phoenix/LiveView (the dashboard is a later task). Bandit is the modern,
      # pure-Elixir HTTP server; Plug supplies the router + JSON body parsing.
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"}
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
