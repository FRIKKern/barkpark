defmodule Barkpark.Plugins.LoadOrderReadersTest do
  @moduledoc """
  One rule for every lib reader of the `:barkpark, :plugins` load order
  (task-3fbd48182b1d35ea), interpreted by `Barkpark.Content.PluginLoadOrder`.

  THE RULE for a module that loads but is not a registered plugin:

    * module-dispatch readers (`Plugins.Hooks`, `Registry.BootCollectors`)
      RUN it — test seams (BumpHook, InterleavedWriter, HaltingPersist, the
      RoutesFake* fakes) are exactly such modules;
    * plugin-record readers (`Registry.ResolverChain`,
      `Content.PreWriteFences`, `Content.PrePublishFences`,
      `Content.PreWriteTransforms`, `Content.PaperTaskResolver`,
      `Content.MutateDoorFences`, `Registry.Discovery`) SKIP it, with a `Logger.warning` naming it.

  Every skipped entry of any shape is logged by name, once per
  `{reader, entry}` per VM — so every test here uses its OWN module or a
  unique string, never one another test already made a reader warn about.

  Each plugin-record reader test carries a CONTROL: the same module shape,
  REGISTERED, is included — so "skipped" is measured against a reader that
  does return registered plugins, not against a reader that returns nothing.
  """

  use Barkpark.RegistryCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Content.{
    MutateDoorFences,
    PaperTaskResolver,
    PluginLoadOrder,
    PrePublishFences,
    PreWriteFences,
    PreWriteTransforms
  }

  alias Barkpark.Plugins.Hooks
  alias Barkpark.Plugins.Registry.{BootCollectors, Discovery, ResolverChain}

  # ── fixtures: one module per test, so the once-per-entry warning is fresh ──

  defmodule HookSeam do
    @moduledoc false
    def lifecycle_hooks, do: %{before_save: [&__MODULE__.halt/1]}
    def halt(_payload), do: {:halt, "hook-seam-ran"}
  end

  defmodule CrontabSeam do
    @moduledoc false
    def oban_crontab, do: [{"0 0 * * *", __MODULE__}]
  end

  defmodule ResolverBare do
    @moduledoc false
    def checkers, do: []
  end

  defmodule ResolverRegistered do
    @moduledoc false
    def checkers, do: []
  end

  defmodule WriteFenceBare do
    @moduledoc false
    def pre_write_fences, do: [{__MODULE__, :refuse}]
    def refuse(_a, _b, _c), do: {:error, :bare}
  end

  defmodule WriteFenceRegistered do
    @moduledoc false
    def pre_write_fences, do: [{__MODULE__, :refuse}]
    def refuse(_a, _b, _c), do: {:error, :registered}
  end

  defmodule PublishFenceBare do
    @moduledoc false
    def pre_publish_fences, do: [{:door, __MODULE__, :refuse}]
    def refuse(_a), do: {:error, :bare}
  end

  defmodule PublishFenceRegistered do
    @moduledoc false
    def pre_publish_fences, do: [{:door, __MODULE__, :refuse}]
    def refuse(_a), do: {:error, :registered}
  end

  defmodule TransformBare do
    @moduledoc false
    def pre_write_transforms, do: [{:transform, __MODULE__, :shape}]
    def shape(attrs, _type), do: attrs
  end

  defmodule TransformRegistered do
    @moduledoc false
    def pre_write_transforms, do: [{:transform, __MODULE__, :shape}]
    def shape(attrs, _type), do: attrs
  end

  defmodule PaperResolverBare do
    @moduledoc false
    def paper_task_resolver, do: __MODULE__.Impl
    defmodule Impl, do: @moduledoc(false)
  end

  defmodule PaperResolverRegistered do
    @moduledoc false
    def paper_task_resolver, do: __MODULE__.Impl
    defmodule Impl, do: @moduledoc(false)
  end

  defmodule MutateDoorBare do
    @moduledoc false
    def mutate_door_fences, do: [{:after_claim, __MODULE__, :refuse}]
    def refuse(_t, _e, _m, _o, _d, _opts), do: {:error, :bare}
  end

  defmodule MutateDoorRegistered do
    @moduledoc false
    def mutate_door_fences, do: [{:after_claim, __MODULE__, :refuse}]
    def refuse(_t, _e, _m, _o, _d, _opts), do: {:error, :registered}
  end

  defmodule DiscoveryBare do
    @moduledoc false
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp register!(module) do
    name = uniq("lo-" <> (module |> Module.split() |> List.last() |> String.downcase()))
    :ok = Registry.register(module, %{"plugin_name" => name})
    name
  end

  # ── the normaliser: every entry shape classifies to exactly one outcome ──

  describe "PluginLoadOrder.resolve/2 — every entry shape" do
    test "registered module, loadable-unregistered module, name, tuple, other" do
      known = [%{name: "known", module: ResolverRegistered}]

      assert PluginLoadOrder.resolve(
               [
                 ResolverRegistered,
                 ResolverBare,
                 "known",
                 "nobody",
                 {"known", Nope.NotLoaded},
                 {"nobody", ResolverRegistered},
                 {"nobody", ResolverBare},
                 {"nobody", Nope.NotLoaded},
                 Nope.NotLoaded,
                 %{module: ResolverRegistered},
                 nil,
                 "",
                 42
               ],
               known
             ) == [
               {:plugin, hd(known)},
               {:module, ResolverBare},
               {:plugin, hd(known)},
               {:drop, "nobody", :unknown_name},
               {:plugin, hd(known)},
               {:plugin, hd(known)},
               {:module, ResolverBare},
               {:drop, {"nobody", Nope.NotLoaded}, :unknown_name},
               {:drop, Nope.NotLoaded, :not_loadable},
               {:drop, %{module: ResolverRegistered}, :bad_shape},
               {:drop, nil, :bad_shape},
               {:drop, "", :bad_shape},
               {:drop, 42, :bad_shape}
             ]
    end

    test "a thunk `known` is forced at most once, and not at all for shapes that never need it" do
      counter = :counters.new(1, [])
      known = fn -> :counters.add(counter, 1, 1) && [] end

      PluginLoadOrder.resolve([nil, 42, Nope.NotLoaded], known)
      assert :counters.get(counter, 1) == 0

      PluginLoadOrder.resolve(["a", "b", ResolverBare], known)
      assert :counters.get(counter, 1) == 1
    end
  end

  # ── module-dispatch readers RUN a loadable-unregistered module ──

  describe "Plugins.Hooks (module-dispatch reader)" do
    test "RUNS a loadable module that is not a registered plugin, and warns about nothing", ctx do
      :ok = Barkpark.PluginEnv.with_plugins([HookSeam], ctx)

      {result, log} =
        with_log(fn -> Hooks.fire(:before_save, %{event: :before_save, source: :test}) end)

      assert result == {:halt, "hook-seam-ran"}
      refute log =~ inspect(HookSeam)
    end

    test "an unknown plugin name is skipped WITH a warning naming it (was: silent nil)", ctx do
      name = uniq("hooks-unknown")
      :ok = Barkpark.PluginEnv.with_plugins([name, HookSeam], ctx)

      {result, log} =
        with_log(fn -> Hooks.fire(:before_save, %{event: :before_save, source: :test}) end)

      assert result == {:halt, "hook-seam-ran"}
      assert log =~ "Barkpark.Plugins.Hooks: skipping :barkpark, :plugins load-order entry"
      assert log =~ inspect(name)
    end
  end

  describe "Registry.BootCollectors (module-dispatch reader)" do
    test "RUNS a loadable module that is not a plugin (no manifest), and warns about nothing",
         ctx do
      :ok = Barkpark.PluginEnv.with_plugins([CrontabSeam], ctx)

      {crontab, log} = with_log(fn -> BootCollectors.collect_oban_crontab() end)

      assert crontab == [{"0 0 * * *", CrontabSeam}]
      refute log =~ inspect(CrontabSeam)
    end

    test "an unknown plugin name is skipped WITH a warning naming it (was: silent nil)", ctx do
      name = uniq("boot-unknown")
      :ok = Barkpark.PluginEnv.with_plugins([name, CrontabSeam], ctx)

      {crontab, log} = with_log(fn -> BootCollectors.collect_oban_crontab() end)

      assert crontab == [{"0 0 * * *", CrontabSeam}]
      assert log =~ "Barkpark.Plugins.Registry.BootCollectors: skipping"
      assert log =~ inspect(name)
    end
  end

  # ── plugin-record readers SKIP it, LOUDLY ──

  describe "Registry.ResolverChain (plugin-record reader)" do
    test "SKIPS a loadable module that is not a registered plugin and warns by name; " <>
           "the same shape REGISTERED is included (control)",
         ctx do
      name = register!(ResolverRegistered)
      :ok = Barkpark.PluginEnv.with_plugins([ResolverBare, name], ctx)

      {plugins, log} = with_log(fn -> ResolverChain.load_ordered_plugins() end)

      assert Enum.map(plugins, & &1.module) == [ResolverRegistered]

      assert log =~ "Barkpark.Plugins.Registry.ResolverChain: skipping"
      assert log =~ inspect(ResolverBare)
      assert log =~ "not a registered plugin"
    end
  end

  describe "Content.PreWriteFences (plugin-record reader)" do
    test "SKIPS a loadable module's fences when it is not a registered plugin and warns by " <>
           "name; the same shape REGISTERED contributes its fences (control)",
         ctx do
      _name = register!(WriteFenceRegistered)
      :ok = Barkpark.PluginEnv.with_plugins([WriteFenceBare, WriteFenceRegistered], ctx)

      {fences, log} = with_log(fn -> PreWriteFences.list() end)

      assert fences == [{WriteFenceRegistered, :refuse}]

      assert log =~ "Barkpark.Content.PreWriteFences: skipping"
      assert log =~ inspect(WriteFenceBare)
    end
  end

  describe "Content.PrePublishFences (plugin-record reader)" do
    test "SKIPS a loadable module's fences when it is not a registered plugin and warns by " <>
           "name; the same shape REGISTERED contributes its fences (control)",
         ctx do
      _name = register!(PublishFenceRegistered)
      :ok = Barkpark.PluginEnv.with_plugins([PublishFenceBare, PublishFenceRegistered], ctx)

      {fences, log} = with_log(fn -> PrePublishFences.list() end)

      assert fences == [{:door, PublishFenceRegistered, :refuse}]

      assert log =~ "Barkpark.Content.PrePublishFences: skipping"
      assert log =~ inspect(PublishFenceBare)
    end
  end

  describe "Content.PreWriteTransforms (plugin-record reader)" do
    test "SKIPS a loadable module's steps when it is not a registered plugin and warns by " <>
           "name; the same shape REGISTERED contributes its steps (control)",
         ctx do
      _name = register!(TransformRegistered)
      :ok = Barkpark.PluginEnv.with_plugins([TransformBare, TransformRegistered], ctx)

      {steps, log} = with_log(fn -> PreWriteTransforms.list() end)

      assert steps == [{:transform, TransformRegistered, :shape}]

      assert log =~ "Barkpark.Content.PreWriteTransforms: skipping"
      assert log =~ inspect(TransformBare)
      assert log =~ "not a registered plugin"
    end
  end

  describe "Content.PaperTaskResolver (plugin-record reader)" do
    test "SKIPS a loadable module's resolver when it is not a registered plugin and warns " <>
           "by name; the same shape REGISTERED still resolves (control)",
         ctx do
      _name = register!(PaperResolverRegistered)
      # The unregistered module sits FIRST: under the old private read it would
      # never win (it published nothing), so only the warning tells the two apart.
      :ok = Barkpark.PluginEnv.with_plugins([PaperResolverBare, PaperResolverRegistered], ctx)

      {resolver, log} = with_log(fn -> PaperTaskResolver.get() end)

      assert resolver == PaperResolverRegistered.Impl

      assert log =~ "Barkpark.Content.PaperTaskResolver: skipping"
      assert log =~ inspect(PaperResolverBare)
      assert log =~ "not a registered plugin"
    end
  end

  describe "Content.MutateDoorFences (plugin-record reader)" do
    test "SKIPS a loadable module's fences when it is not a registered plugin and warns by " <>
           "name; the same shape REGISTERED contributes its fences (control)",
         ctx do
      _name = register!(MutateDoorRegistered)
      :ok = Barkpark.PluginEnv.with_plugins([MutateDoorBare, MutateDoorRegistered], ctx)

      {fences, log} = with_log(fn -> MutateDoorFences.list() end)

      assert fences == [{:after_claim, MutateDoorRegistered, :refuse}]

      assert log =~ "Barkpark.Content.MutateDoorFences: skipping"
      assert log =~ inspect(MutateDoorBare)
      assert log =~ "not a registered plugin"
    end
  end

  describe "Registry.Discovery (plugin-record reader)" do
    test "SKIPS a loadable module with no plugin.json and warns by name; a bundled " <>
           "plugin's name is whitelisted (control)" do
      [%{name: bundled} | _] = Discovery.manifest_index()

      {names, log} =
        with_log(fn -> Discovery.whitelist_names_from_config([DiscoveryBare, bundled]) end)

      assert names == MapSet.new([bundled])

      assert log =~ "Barkpark.Plugins.Registry.Discovery: skipping"
      assert log =~ inspect(DiscoveryBare)
    end
  end

  # ── never silent: every other dropped shape names itself too ──

  describe "a dropped entry of any shape is logged by name" do
    test "a malformed entry (a Registry ENTRY MAP) and an unloadable atom" do
      entry_map = %{name: uniq("entry-map"), module: ResolverRegistered}

      log =
        capture_log(fn ->
          assert PluginLoadOrder.modules([entry_map, Nope.Unloadable.A], [], __MODULE__) == []
        end)

      assert log =~ inspect(entry_map.name)
      assert log =~ "not a module, a {plugin_name, module} tuple, or a plugin-name string"
      assert log =~ inspect(Nope.Unloadable.A)
      assert log =~ "not a loadable module"
    end

    test "the warning fires ONCE per {reader, entry}, not on every read" do
      name = uniq("once")

      first = capture_log(fn -> PluginLoadOrder.plugins([name], [], __MODULE__) end)
      second = capture_log(fn -> PluginLoadOrder.plugins([name], [], __MODULE__) end)

      assert first =~ inspect(name)
      refute second =~ inspect(name)
    end
  end
end
