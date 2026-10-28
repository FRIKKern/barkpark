defmodule Mix.Tasks.Barkpark.MigrateLogLevelTest do
  # `mix ecto.migrate` does not start the app, so Logger stayed at :debug and a
  # prod migration printed `[debug] QUERY ERROR ... SHOW data_directory` on a
  # fresh install (run 1 F14). The task now applies the configured level.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Barkpark.Migrate

  setup do
    level = Logger.level()
    configured = Application.get_env(:logger, :level)

    on_exit(fn ->
      Logger.configure(level: level)

      if configured,
        do: Application.put_env(:logger, :level, configured),
        else: Application.delete_env(:logger, :level)
    end)

    :ok
  end

  test "the configured level applies when no --log-level is given" do
    Logger.configure(level: :debug)
    Application.put_env(:logger, :level, :info)

    assert Migrate.apply_configured_log_level(["-r", "Barkpark.Repo"]) == :ok
    assert Logger.level() == :info
  end

  test "an explicit --log-level wins" do
    Logger.configure(level: :debug)
    Application.put_env(:logger, :level, :info)

    Migrate.apply_configured_log_level(["--log-level", "debug"])
    assert Logger.level() == :debug

    Migrate.apply_configured_log_level(["--log-level=debug"])
    assert Logger.level() == :debug
  end

  test "no configured level leaves Logger alone" do
    Logger.configure(level: :debug)
    Application.delete_env(:logger, :level)

    Migrate.apply_configured_log_level([])
    assert Logger.level() == :debug
  end
end
