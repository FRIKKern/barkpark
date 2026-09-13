defmodule Barkpark.Config.RuntimePluginsKillSwitchLogTest do
  # NOT async: mutates the process-global env vars config/runtime.exs reads at
  # eval time (same pattern as RuntimeTaskLeaseTtlTest).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @runtime_exs Path.join(File.cwd!(), "config/runtime.exs")

  # Charter D24: an EMPTY BARKPARK_PLUGINS is a legitimate operator choice —
  # the plugin kill switch — and must never refuse boot. But before this, the
  # [] value configured `:plugins, []` and said NOTHING, so a box serving
  # /api/schemas with zero plugin schemas was indistinguishable from a broken
  # one. runtime.exs must emit exactly one line NAMING the kill switch, and it
  # must still boot.

  @prod_env %{
    "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET" => String.duplicate("r", 32),
    "DATABASE_URL" => "ecto://postgres:postgres@localhost/ignored",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "PREVIEW_JWT_SECRET" => String.duplicate("p", 32),
    "BARKPARK_CLOAK_KEY" => Base.encode64(String.duplicate("c", 32)),
    "BARKPARK_KEK" => Base.encode64(String.duplicate("k", 32)),
    "PHX_HOST" => "guerrilla.barkpark.cloud"
  }

  setup do
    keys = Map.keys(@prod_env) ++ ~w(BARKPARK_PLUGINS)
    prev = Map.new(keys, fn k -> {k, System.get_env(k)} end)

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)
    System.delete_env("BARKPARK_PLUGINS")
    :ok
  end

  # Returns {configured_plugins, log_output}. Reading the config and capturing
  # the log in ONE eval is what proves the line and the value come from the
  # same boot, not from two different ones.
  defp boot(nil), do: do_boot(fn -> System.delete_env("BARKPARK_PLUGINS") end)
  defp boot(value), do: do_boot(fn -> System.put_env("BARKPARK_PLUGINS", value) end)

  defp do_boot(set_env) do
    set_env.()
    parent = self()

    log =
      capture_log(fn ->
        config = Config.Reader.read!(@runtime_exs, env: :prod)
        send(parent, {:plugins, get_in(config, [:barkpark, :plugins])})
      end)

    assert_received {:plugins, plugins}
    {plugins, log}
  end

  test "empty BARKPARK_PLUGINS still BOOTS and configures the kill switch" do
    {plugins, _log} = boot("")
    assert plugins == []
  end

  test "empty BARKPARK_PLUGINS logs a line NAMING the kill switch" do
    {_plugins, log} = boot("")

    assert log =~ "BARKPARK_PLUGINS"
    assert log =~ ~r/kill switch/i
    assert log =~ "/api/schemas"
  end

  # The level is load-bearing, not cosmetic: config/runtime.exs is evaluated
  # BEFORE the Logger application starts, so the :logger primary level is the
  # Erlang default (:notice) and an info-level line would be DROPPED at real
  # release boot. Pin the level so a later "simplification" to Logger.info
  # cannot silently re-open the hole this row was filed for.
  test "the kill-switch line is at least :warning so release boot shows it" do
    {_plugins, log} = boot("")
    assert log =~ "[warning]"
  end

  # Whitespace/comma-only parses to [] the same way — same kill switch, so the
  # same line. (Verified against Barkpark.Plugins.EnvConfig.parse/1.)
  test "a comma/whitespace-only value takes the same kill-switch branch" do
    for value <- [" ", ",", " , , "] do
      assert Barkpark.Plugins.EnvConfig.parse(value) == [],
             "EnvConfig.parse/1 no longer maps #{inspect(value)} to [] — retarget this test"

      {plugins, log} = boot(value)
      assert plugins == []
      assert log =~ ~r/kill switch/i
    end
  end

  # --- CONTROLS: the line must NOT fire on the other two values ------------

  test "UNSET BARKPARK_PLUGINS leaves :plugins unconfigured and logs nothing" do
    {plugins, log} = boot(nil)

    assert plugins == nil, "unset must stay discover-all-from-disk, never forced to []"
    refute log =~ ~r/kill switch/i
  end

  test "an explicit whitelist configures it and logs no kill-switch line" do
    {plugins, log} = boot("tasks,media")

    assert plugins == ["tasks", "media"]
    refute log =~ ~r/kill switch/i
  end
end
