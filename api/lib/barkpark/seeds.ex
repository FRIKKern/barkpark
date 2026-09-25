defmodule Barkpark.Seeds do
  @moduledoc """
  Profile-switched database seeding, extracted from `priv/repo/seeds.exs`
  (now a one-liner calling `run/0`) so the seed bodies are testable and
  `Barkpark.Release.seed/0` keeps working unchanged.

  Profile selection: `BARKPARK_SEED_PROFILE=demo|clean`. With the variable
  unset, `profile/0` reads `config :barkpark, :default_seed_profile`, which is
  `"clean"` everywhere except `config/dev.exs`. A release, a `deploy.sh` box
  or `Barkpark.Release.seed/0` therefore never seeds the demo world, and never
  its shared `barkpark-dev-token`, unless someone asks for `demo` by name.
  Dev keeps `demo` because `:dev_browser_token` in `config/dev.exs` expects
  the seeded dev token. Unknown values raise rather than silently seeding
  the wrong world.

  Both profiles end with `Plugins.Bootstrap.register_all_schemas/0` +
  `Search.SurfaceConfigs.seed_defaults!/0` here in `run/1`, so a profile
  body cannot forget them.
  """

  alias Barkpark.Seeds.{Clean, Demo, Shared}

  @doc "Resolve the profile (see `profile/0`) and dispatch to `run/1`."
  def run do
    case profile() do
      "demo" -> run(:demo)
      "clean" -> run(:clean)
      other -> raise "BARKPARK_SEED_PROFILE must be clean or demo, got: #{inspect(other)}"
    end
  end

  @doc """
  The seed profile to run: `BARKPARK_SEED_PROFILE` when set, else
  `config :barkpark, :default_seed_profile`, else `"clean"`.
  """
  @spec profile() :: String.t()
  def profile do
    case System.get_env("BARKPARK_SEED_PROFILE") do
      value when is_binary(value) and value != "" -> value
      _ -> Application.get_env(:barkpark, :default_seed_profile, "clean")
    end
  end

  @doc "Seed one profile (`:demo` or `:clean`) plus the profile-independent tail."
  def run(:demo) do
    scope = Shared.ensure_default_scope()
    Shared.ensure_builtin_roles()
    Demo.seed(scope)
    register_plugin_schemas()
    # Codelists ride the demo profile only (they serve onixedit, not in the
    # clean plugin set). Seeded AFTER plugin-schema bootstrap to keep the
    # pre-extraction console order: schemas → docs → token → plugin schemas →
    # codelists → Thema → search defaults.
    Demo.seed_codelists()
    seed_search_defaults()
  end

  def run(:clean) do
    scope = Shared.ensure_default_scope()
    Shared.ensure_builtin_roles()
    Clean.seed(scope)
    register_plugin_schemas()
    seed_search_defaults()
  end

  # ── Plugin Schemas (Bootstrap) ──────────────────────────────────────────────

  # Mirrors the post-boot Task in Barkpark.Application — when seeds run via
  # `mix run priv/repo/seeds.exs` the app is already started, so the registry
  # is populated. Idempotent via the (name, dataset) unique index on
  # schema_definitions; per-plugin failures are logged inside Bootstrap and
  # never raise here.
  defp register_plugin_schemas do
    IO.puts("\n=== Registering plugin schemas ===")

    case Barkpark.Plugins.Bootstrap.register_all_schemas() do
      {:ok, count} ->
        IO.puts("Registered #{count} plugin schema(s) via Plugins.Bootstrap")

      {:error, reason} ->
        IO.puts(:stderr, "Plugin schema bootstrap reported errors: #{inspect(reason)}")
    end
  end

  defp seed_search_defaults do
    IO.puts("\n=== Seeding search surface config defaults ===")
    Barkpark.Search.SurfaceConfigs.seed_defaults!()
    IO.puts("Search surface config defaults seeded")
  end
end
