defmodule Barkpark.MixProject do
  use Mix.Project

  def project do
    [
      app: :barkpark,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader],
      releases: releases()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Barkpark.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
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
      {:phoenix, "~> 1.8.5"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:corsica, "~> 2.1"},
      {:req, "~> 0.5"},
      {:sweet_xml, "~> 0.7"},
      {:xml_builder, "~> 2.2"},
      {:cloak_ecto, "~> 1.2"},
      # Core auth (Phase 0/1): argon2id password hashing, TOTP MFA + QR,
      # transactional mailer for email verify / password reset.
      {:argon2_elixir, "~> 4.0"},
      {:nimble_totp, "~> 1.0"},
      {:eqrcode, "~> 0.2"},
      {:swoosh, "~> 1.16"},
      {:gen_smtp, "~> 1.2"},
      {:oban, "~> 2.17"},
      # Media Phase 1 — image probe + renditions. Added conditionally; see
      # image_dep/0 (vix has no Windows prebuilt NIF). macOS/Linux/Docker keep it.
      # WI2: json schema validator dep
      {:ex_json_schema, "~> 0.10"},
      # LiveView 1.1+ requires lazy_html for Phoenix.LiveViewTest
      {:lazy_html, ">= 0.1.0", only: :test},
      # Phase 7 WI3: in-process HTTP mock for Bokbasen client tests
      {:bypass, "~> 2.1", only: :test},
      # Sheets plugin — xlsx import + export (pure-Elixir, no NIFs)
      {:xlsx_reader, "~> 0.8"},
      {:elixlsx, "~> 0.6"}
    ] ++ image_dep()
  end

  # The :image dep pulls vix, whose libvips NIF has NO Windows prebuilt binary —
  # it would need MSVC + libvips to build from source, which breaks zero-friction
  # native Windows dev. So we drop :image on Windows by default; media renditions
  # still work there via the ImageMagick CLI backend (Barkpark.Media.ImageBackend
  # selects it automatically). macOS, Linux, Docker, and the prod compile gate
  # keep libvips. Overrides:
  #   BARKPARK_WITH_IMAGE=1  force it ON  (Windows users who installed libvips+MSVC)
  #   BARKPARK_SKIP_IMAGE=1  force it OFF (e.g. a Linux box without libvips)
  defp image_dep do
    cond do
      System.get_env("BARKPARK_WITH_IMAGE") == "1" -> [{:image, "~> 0.55"}]
      System.get_env("BARKPARK_SKIP_IMAGE") == "1" -> []
      match?({:win32, _}, :os.type()) -> []
      true -> [{:image, "~> 0.55"}]
    end
  end

  # Release configuration (T5.1 — Wave 5 personal-local packaging).
  #
  # `rel/overlays/` is copied verbatim into the assembled release root, so
  # `rel/overlays/bin/migrate` ships alongside the generated `bin/barkpark`
  # launcher. `rel/env.sh.eex` is evaluated by the boot scripts and is where
  # we default PHX_SERVER=true so `bin/barkpark start` actually serves HTTP
  # without the caller having to remember the env var.
  defp releases do
    [
      barkpark: [
        include_executables_for: [:unix],
        # The release ships its own ERTS so a packaged install does not depend
        # on the host having a matching Erlang/Elixir on PATH.
        include_erts: true,
        steps: [:assemble]
      ]
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
