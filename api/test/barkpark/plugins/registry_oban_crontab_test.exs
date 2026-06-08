defmodule Barkpark.Plugins.RegistryObanCrontabTest do
  @moduledoc """
  Covers C4-1: the `oban_crontab/0` plugin callback and its boot-time
  collector + merge mechanism.

    * `Barkpark.Plugins.Registry.collect_oban_crontab/0`
    * `Barkpark.Application.merge_plugin_crontab/2`

  The collector mirrors `collect_workers/1` / `collect_routes/1`: it reads
  the module list from `Application.fetch_env(:barkpark, :plugins)`, so we
  drive it against inline fakes without touching disk. The merge helper is
  a pure function tested directly against a sample Oban keyword — no Oban
  boot required.
  """

  use Barkpark.RegistryCase, async: false

  alias Barkpark.Plugins.Registry

  # ─── collect_oban_crontab/0 ─────────────────────────────────────────────

  describe "collect_oban_crontab/0" do
    setup do
      prev = Application.get_env(:barkpark, :plugins, :unset)

      on_exit(fn ->
        case prev do
          :unset -> Application.delete_env(:barkpark, :plugins)
          v -> Application.put_env(:barkpark, :plugins, v)
        end
      end)

      :ok
    end

    test "returns [] when :plugins is explicitly empty" do
      Application.put_env(:barkpark, :plugins, [])
      assert Registry.collect_oban_crontab() == []
    end

    test "includes a registered plugin's oban_crontab/0 entries" do
      Application.put_env(:barkpark, :plugins, [
        Barkpark.Plugins.RegistryObanCrontabTest.CronFakeA,
        Barkpark.Plugins.RegistryObanCrontabTest.CronFakeB
      ])

      crontab = Registry.collect_oban_crontab()

      assert is_list(crontab)
      assert {"* * * * *", Barkpark.Plugins.RegistryObanCrontabTest.WorkerA} in crontab

      assert {"0 4 * * *", Barkpark.Plugins.RegistryObanCrontabTest.WorkerB, [queue: :plugins]} in crontab

      assert length(crontab) == 2
    end

    test "isolates a plugin whose oban_crontab/0 raises" do
      Application.put_env(:barkpark, :plugins, [
        Barkpark.Plugins.RegistryObanCrontabTest.CronFakeA,
        Barkpark.Plugins.RegistryObanCrontabTest.CronRaisingFake
      ])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          crontab = Registry.collect_oban_crontab()

          # The raising plugin contributes nothing; the other still lands.
          assert crontab == [
                   {"* * * * *", Barkpark.Plugins.RegistryObanCrontabTest.WorkerA}
                 ]
        end)

      assert log =~ "oban_crontab/0 raised"
    end

    test "tolerates a plugin that doesn't export oban_crontab/0" do
      Application.put_env(:barkpark, :plugins, [
        Barkpark.Plugins.RegistryObanCrontabTest.NoCronFake
      ])

      assert Registry.collect_oban_crontab() == []
    end
  end

  # ─── Application.merge_plugin_crontab/2 (pure helper, no Oban boot) ──────

  describe "merge_plugin_crontab/2" do
    @sample_config [
      repo: Barkpark.Repo,
      queues: [default: 10],
      plugins: [
        {Oban.Plugins.Pruner, max_age: 1},
        {Oban.Plugins.Cron,
         crontab: [
           {"30 3 * * *", Barkpark.Plugins.RegistryObanCrontabTest.HostWorker}
         ]}
      ]
    ]

    test "empty contribution leaves the config byte-for-byte unchanged" do
      assert Barkpark.Application.merge_plugin_crontab(@sample_config, []) == @sample_config
    end

    test "appends plugin crons to an existing Cron plugin's crontab" do
      contrib = [{"* * * * *", Barkpark.Plugins.RegistryObanCrontabTest.WorkerA}]

      merged = Barkpark.Application.merge_plugin_crontab(@sample_config, contrib)

      {Oban.Plugins.Cron, opts} = List.keyfind(merged[:plugins], Oban.Plugins.Cron, 0)
      crontab = Keyword.fetch!(opts, :crontab)

      # Host entry preserved, plugin entry appended.
      assert {"30 3 * * *", Barkpark.Plugins.RegistryObanCrontabTest.HostWorker} in crontab
      assert {"* * * * *", Barkpark.Plugins.RegistryObanCrontabTest.WorkerA} in crontab
      assert length(crontab) == 2

      # Non-cron plugins and other top-level keys untouched.
      assert {Oban.Plugins.Pruner, max_age: 1} in merged[:plugins]
      assert merged[:repo] == Barkpark.Repo
      assert merged[:queues] == [default: 10]
    end

    test "adds a Cron plugin entry when none exists but plugins contribute" do
      no_cron = [
        repo: Barkpark.Repo,
        plugins: [{Oban.Plugins.Pruner, max_age: 1}]
      ]

      contrib = [{"* * * * *", Barkpark.Plugins.RegistryObanCrontabTest.WorkerA}]

      merged = Barkpark.Application.merge_plugin_crontab(no_cron, contrib)

      {Oban.Plugins.Cron, opts} = List.keyfind(merged[:plugins], Oban.Plugins.Cron, 0)
      assert Keyword.fetch!(opts, :crontab) == contrib
      assert {Oban.Plugins.Pruner, max_age: 1} in merged[:plugins]
    end
  end
end

# ── Inline fake plugins for collect_oban_crontab/0 ───────────────────────
#
# Like the collect_routes/1 fakes, these deliberately do NOT
# `use Barkpark.Plugin` — the collector's only requirement is that the
# module exports `oban_crontab/0`.

defmodule Barkpark.Plugins.RegistryObanCrontabTest.CronFakeA do
  @moduledoc false
  def oban_crontab do
    [{"* * * * *", Barkpark.Plugins.RegistryObanCrontabTest.WorkerA}]
  end
end

defmodule Barkpark.Plugins.RegistryObanCrontabTest.CronFakeB do
  @moduledoc false
  def oban_crontab do
    [{"0 4 * * *", Barkpark.Plugins.RegistryObanCrontabTest.WorkerB, [queue: :plugins]}]
  end
end

defmodule Barkpark.Plugins.RegistryObanCrontabTest.CronRaisingFake do
  @moduledoc false
  def oban_crontab, do: raise("boom from CronRaisingFake")
end

defmodule Barkpark.Plugins.RegistryObanCrontabTest.NoCronFake do
  @moduledoc false
  # Intentionally exports nothing relevant.
  def some_other_callback, do: :ok
end
