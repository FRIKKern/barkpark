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
      # :os_mon powers the Studio bottom-bar host vitals (Barkpark.HostVitals.Sampler
      # reads :cpu_sup / :memsup / :disksup). Starts OTP's OS monitors on boot.
      extra_applications: [:logger, :runtime_tools, :os_mon]
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
      # Floored to 1.8.6: 1.8.5 carries GHSA-628h-q48j-jr6q (long-poll NDJSON
      # body-splitting DoS); 1.8.6 is the first patched 1.8.x.
      {:phoenix, "~> 1.8.6"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      # Floored to 0.22.2: earlier releases carry GHSA-r73h-97w8-m54h (HIGH —
      # channel-name SQL injection in Postgrex.Notifications.listen/3).
      {:postgrex, ">= 0.22.2"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      # Prometheus scrape aggregator (Core only — no bundled Cowboy server; we
      # expose /v1/instance/metrics through our own token-gated pipeline). This
      # is the prod-reachable reporter for BarkparkWeb.Telemetry — LiveDashboard
      # is dev_routes-only, so without this every metric is computed by nobody.
      {:telemetry_metrics_prometheus_core, "~> 1.1"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      # GFM markdown -> AST for chat replies rendered as PortableDoc blocks
      # (Barkpark.PortableDoc.FromMarkdown). Parser only, no HTML transform.
      {:earmark_parser, "~> 1.4"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:corsica, "~> 2.1"},
      {:req, "~> 0.6.1"},
      # OIDC id_token (JWT/JWS) verification for enterprise SSO (era-w3-oidc-rp).
      {:jose, "~> 1.11"},
      # SAML 2.0 SP: vetted XML-dsig assertion verification (era-w3-saml).
      {:esaml, "~> 4.6"},
      # x509: SAML test-cert generation AND wax's prod attestation-cert
      # validation. `~> 0.8` still resolves to 0.9.x (~> is <1.0.0 for a
      # two-segment req) — no downgrade. No longer `only: :test`: wax needs it
      # at runtime, and its own requirement is the same ~> 0.8.
      {:x509, "~> 0.8"},
      # FIDO2 / WebAuthn passkeys: vetted attestation + assertion verification
      # (COSE keys, CBOR, signature checks) — no hand-rolled WebAuthn crypto
      # (era-w2-passkeys).
      {:wax_, "~> 0.7.0"},
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
      {:elixlsx, "~> 0.6"},
      # Studio tmux console: forkpty(3) bindings for a real PTY. Ships in
      # ALL envs — the console is on by default on every Studio (admin-gated,
      # hard-refused on public-demo hosts). Precompiled NIFs cover the prod
      # aarch64-linux / x86_64-linux targets (source-build fallback otherwise).
      {:expty, "~> 0.2.1"},
      # Security CI gates (fix-security-ci — task-a41fc4590b2c2eb1). Both are
      # analysis-only tooling, dev/test env + runtime:false so they NEVER ship
      # in the release. Sobelow = Phoenix-aware static analysis (XSS.Raw, SQL
      # injection, unsafe atom, missing CSRF, hardcoded secrets…); MixAudit =
      # dependency CVE scan against mix.lock. Wired in .github/workflows/security.yml.
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
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
      test: [&strict_test_paths/1, "ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end

  # `mix test <path>` where <path> does not exist exits 0 and silently runs only
  # the paths that DO exist — a gate prescription naming a renamed test file
  # therefore prints a green trailer indistinguishable from a real run
  # (task-9dc1b0aaf43797df: share_link_controller_test.exs, which never existed,
  # rode alongside a real file and nobody could tell). This runs FIRST in the
  # `test` alias — before ecto.create, before a single test — and refuses.
  #
  # It reads System.argv/0, not the alias argument: Mix hands the alias's own
  # arguments to the LAST task in the list, so a leading function receives [].
  defp strict_test_paths(args) do
    case missing_test_paths(args ++ System.argv()) do
      [] ->
        :ok

      missing ->
        Mix.raise(
          "mix test: refusing to run — " <>
            "#{length(missing)} named path(s) do not exist:\n" <>
            Enum.map_join(missing, "\n", &"  CANNOT READ #{&1}") <>
            "\n\nA nonexistent path is skipped silently by `mix test` and the run " <>
            "still exits 0. Fix the path (or drop it) before quoting this gate."
        )
    end
  end

  # Public so it can be unit-tested (test/mix_strict_test_paths_test.exs).
  # Returns, in argv order and de-duplicated, every explicit path argument that
  # does not exist on disk. A token counts as a path argument only when it looks
  # like one — ends in `.exs` (with an optional `:LINE` / `:LINE:LINE` suffix) or
  # contains a `/`. Flags and the values of value-taking flags are never checked,
  # so `--only foo`, `--include bar:1` and a bare `mix test` stay untouched.
  @value_flags ~w(
    --only --include --exclude --seed --max-cases --max-failures --formatter
    --slowest --partitions --repeat-until-failure --timeout --exit-status
    --cover-export-name --profile-require --name
  )
  def missing_test_paths(argv) when is_list(argv) do
    argv
    |> path_arguments()
    |> Enum.reject(&File.exists?/1)
    |> Enum.uniq()
  end

  defp path_arguments(argv), do: path_arguments(argv, [])

  defp path_arguments([], acc), do: Enum.reverse(acc)

  # A value-taking flag swallows the token after it (`--only boot_test`), so
  # that token is never a candidate path. Every other token is examined and
  # ONLY that token is consumed — matching two elements here and recursing on
  # `rest` would drop every second argument.
  defp path_arguments([flag, value | rest], acc) do
    if flag in @value_flags do
      path_arguments(rest, acc)
    else
      path_arguments([value | rest], collect(flag, acc))
    end
  end

  defp path_arguments([token | rest], acc), do: path_arguments(rest, collect(token, acc))

  defp collect(token, acc) do
    cond do
      String.starts_with?(token, "-") -> acc
      path_like?(token) -> [strip_line_suffix(token) | acc]
      true -> acc
    end
  end

  defp path_like?(token) do
    String.contains?(token, "/") or String.ends_with?(strip_line_suffix(token), ".exs")
  end

  # `test/foo_test.exs:42` and `test/foo_test.exs:42:99` address lines in a file;
  # the suffix must come off before the existence check.
  defp strip_line_suffix(token) do
    case String.split(token, ":") do
      [path | rest] -> if Enum.all?(rest, &line_number?/1), do: path, else: token
      _ -> token
    end
  end

  defp line_number?(part), do: part != "" and String.match?(part, ~r/\A\d+\z/)
end
