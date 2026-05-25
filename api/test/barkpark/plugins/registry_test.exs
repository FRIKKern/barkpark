defmodule Barkpark.Plugins.RegistryTest do
  # The Registry is a single named GenServer in the supervision tree, so
  # tests share state — keep this synchronous.
  use Barkpark.RegistryCase, async: false

  alias Barkpark.Plugins.Registry

  @fixture_root Path.expand("../../support/fixtures/plugins", __DIR__)

  describe "registry lifecycle" do
    test "is alive after application boot" do
      assert is_pid(GenServer.whereis(Registry))
    end
  end

  describe "register/2 + lookup/1 + all/0" do
    test "round-trips a manifest map" do
      manifest = %{"plugin_name" => "round_trip", "version" => "0.0.0"}
      assert :ok = Registry.register(:fake_module_round_trip, manifest)

      assert {:ok, %{name: "round_trip", module: :fake_module_round_trip, manifest: ^manifest}} =
               Registry.lookup("round_trip")

      assert Enum.any?(Registry.all(), &(&1.name == "round_trip"))
    end

    test "lookup/1 returns :error for unknown plugin" do
      assert :error = Registry.lookup("does-not-exist-#{System.unique_integer([:positive])}")
    end

    test "register/2 rejects manifest without plugin_name" do
      assert {:error, :no_plugin_name} = Registry.register(:bad_mod, %{"name" => "no-discrim"})
    end
  end

  describe "discover_and_register/1" do
    test "finds and registers the hello fixture plugin" do
      assert :ok = Registry.discover_and_register([@fixture_root])

      assert {:ok, %{module: Barkpark.Plugins.Hello, manifest: %{"plugin_name" => "hello"}}} =
               Registry.lookup("hello")
    end

    test "tolerates non-existent roots without raising" do
      assert :ok = Registry.discover_and_register(["/this/path/does/not/exist/ever"])
    end

    test "tolerates an empty path list" do
      assert :ok = Registry.discover_and_register([])
    end
  end

  describe "collect_routes/1" do
    # `plugin_modules_sync/0` reads `Application.fetch_env(:barkpark, :plugins)`
    # — when set to a list of modules, it honours it verbatim. We use that to
    # drive `collect_routes/1` against inline fakes without touching disk.

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
      assert Registry.collect_routes(%{}) == []
    end

    test "returns the union of register_routes/1 results from configured plugins" do
      Application.put_env(:barkpark, :plugins, [
        Barkpark.Plugins.RegistryTest.RoutesFakeA,
        Barkpark.Plugins.RegistryTest.RoutesFakeB
      ])

      routes = Registry.collect_routes(%{})

      assert is_list(routes)
      assert length(routes) == 3
      assert Enum.all?(routes, &valid_route_spec?/1)

      # FakeA contributes a :live spec, FakeB contributes one :live + one :get.
      assert Enum.any?(routes, &match?({:live, "/fake-a/ping", _, :index}, &1))
      assert Enum.any?(routes, &match?({:live, "/fake-b/ping", _, :index}, &1))
      assert Enum.any?(routes, &match?({:get, "/fake-b/health", _, :show, _}, &1))
    end

    test "isolates a plugin that raises in register_routes/1" do
      Application.put_env(:barkpark, :plugins, [
        Barkpark.Plugins.RegistryTest.RoutesFakeA,
        Barkpark.Plugins.RegistryTest.RoutesRaisingFake,
        Barkpark.Plugins.RegistryTest.RoutesFakeB
      ])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          routes = Registry.collect_routes(%{})

          # The raising plugin contributes nothing; the other two still land.
          assert length(routes) == 3
          assert Enum.all?(routes, &valid_route_spec?/1)
          refute Enum.any?(routes, &match?({:live, "/boom/ping", _, _}, &1))
        end)

      assert log =~ "register_routes/1 raised"
    end

    test "defaults ctx :phase to :compile" do
      Application.put_env(:barkpark, :plugins, [
        Barkpark.Plugins.RegistryTest.RoutesCtxRecorder
      ])

      # The recorder stashes its received ctx on the process dictionary via
      # an Agent so the test can inspect it after the call.
      {:ok, agent} = Agent.start_link(fn -> nil end)
      Process.put(:routes_ctx_recorder_agent, agent)

      _ = Registry.collect_routes(%{})

      assert %{phase: :compile} = Agent.get(agent, & &1)

      # Caller-supplied phase is preserved (Map.put_new semantics).
      _ = Registry.collect_routes(%{phase: :runtime})
      assert %{phase: :runtime} = Agent.get(agent, & &1)

      Agent.stop(agent)
      Process.delete(:routes_ctx_recorder_agent)
    end
  end

  defp valid_route_spec?({:live, path, mod, action})
       when is_binary(path) and is_atom(mod) and is_atom(action),
       do: true

  defp valid_route_spec?({:live, path, mod, action, opts})
       when is_binary(path) and is_atom(mod) and is_atom(action) and is_list(opts),
       do: true

  defp valid_route_spec?({verb, path, mod, action})
       when verb in [:get, :post, :put, :delete, :patch] and is_binary(path) and is_atom(mod) and
              is_atom(action),
       do: true

  defp valid_route_spec?({verb, path, mod, action, opts})
       when verb in [:get, :post, :put, :delete, :patch] and is_binary(path) and is_atom(mod) and
              is_atom(action) and is_list(opts),
       do: true

  defp valid_route_spec?(_), do: false
end

# ── Inline fake plugins for collect_routes/1 ─────────────────────────────
#
# These deliberately do NOT `use Barkpark.Plugin` — they don't need a
# manifest, and `collect_routes/1`'s only requirement is that the module
# exports `register_routes/1`. Keeps the test self-contained.

defmodule Barkpark.Plugins.RegistryTest.RoutesFakeA do
  @moduledoc false
  def register_routes(_ctx) do
    [{:live, "/fake-a/ping", __MODULE__.PingLive, :index}]
  end
end

defmodule Barkpark.Plugins.RegistryTest.RoutesFakeB do
  @moduledoc false
  def register_routes(_ctx) do
    [
      {:live, "/fake-b/ping", __MODULE__.PingLive, :index},
      {:get, "/fake-b/health", __MODULE__.HealthController, :show, [auth: :none]}
    ]
  end
end

defmodule Barkpark.Plugins.RegistryTest.RoutesRaisingFake do
  @moduledoc false
  def register_routes(_ctx), do: raise("boom from RoutesRaisingFake")
end

defmodule Barkpark.Plugins.RegistryTest.RoutesCtxRecorder do
  @moduledoc false
  def register_routes(ctx) do
    if agent = Process.get(:routes_ctx_recorder_agent) do
      Agent.update(agent, fn _ -> ctx end)
    end

    []
  end
end
