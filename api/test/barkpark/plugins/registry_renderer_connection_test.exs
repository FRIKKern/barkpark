defmodule Barkpark.Plugins.RegistryRendererConnectionTest do
  @moduledoc """
  Coverage for the two first-wins chains on `Barkpark.Plugins.Registry`
  that previously had ZERO tests:

    * `collect_content_renderer/3` — first plugin returning `{:ok, iodata}`
      wins; `:skip` falls through; all-skip → `:none`; a raising renderer is
      isolated (host does not crash, chain continues).
    * `collect_test_connection/2` — returns the plugin's `{:ok, _}` /
      `{:error, _}` verbatim; unknown plugin → `{:error, :plugin_not_found}`;
      a raising callback → `{:error, {:raised, msg}}`.

  Fake plugins are bare modules registered against the live Registry
  GenServer (no removal API), each under a unique name. Tests that pin a
  load order set `Application.get_env(:barkpark, :plugins, ...)` and restore
  it on exit, mirroring `RegistryResolverTest`.
  """
  use Barkpark.RegistryCase, async: false

  alias Barkpark.Plugins.Registry

  # ── Fakes: content_renderer/3 ───────────────────────────────────────

  defmodule RendererOkPlugin do
    def content_renderer(_doc_type, _content, _ctx), do: {:ok, "FROM-OK-PLUGIN"}
  end

  defmodule RendererSkipPlugin do
    def content_renderer(_doc_type, _content, _ctx), do: :skip
  end

  defmodule RendererSecondOkPlugin do
    def content_renderer(_doc_type, _content, _ctx), do: {:ok, "FROM-SECOND"}
  end

  defmodule RendererRaisePlugin do
    def content_renderer(_doc_type, _content, _ctx), do: raise("renderer boom")
  end

  # ── Fakes: test_connection/1 ────────────────────────────────────────

  defmodule ConnOkPlugin do
    def test_connection(_settings), do: {:ok, %{status: "live"}}
  end

  defmodule ConnErrorPlugin do
    def test_connection(_settings), do: {:error, :unauthorized}
  end

  defmodule ConnRaisePlugin do
    def test_connection(_settings), do: raise("connection boom")
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  # Register modules and pin the :plugins load order to exactly those
  # names, restoring the prior config on exit. Returns the assigned names.
  defp register_in_order(modules, ctx) when is_list(modules) do
    salt = System.unique_integer([:positive])

    names =
      modules
      |> Enum.with_index()
      |> Enum.map(fn {module, idx} ->
        name = "rct-#{idx}-#{salt}"
        :ok = Registry.register(module, %{"plugin_name" => name})
        name
      end)

    # `PluginEnv.with_plugins/2` restores through an `:unset` sentinel; a `[]`
    # snapshot default would restore an EXPLICIT `[]`, the discovery kill switch.
    :ok = Barkpark.PluginEnv.with_plugins(names, ctx)

    names
  end

  # ── collect_content_renderer/3 ──────────────────────────────────────

  describe "collect_content_renderer/3" do
    test "a plugin returning {:ok, iodata} is selected", ctx do
      register_in_order([RendererOkPlugin], ctx)

      assert {:ok, iodata} = Registry.collect_content_renderer("book", %{})
      assert IO.iodata_to_binary(iodata) == "FROM-OK-PLUGIN"
    end

    test "a plugin returning :skip falls through to the next plugin", ctx do
      register_in_order([RendererSkipPlugin, RendererOkPlugin], ctx)

      assert {:ok, iodata} = Registry.collect_content_renderer("book", %{})
      assert IO.iodata_to_binary(iodata) == "FROM-OK-PLUGIN"
    end

    test "when every plugin skips, the result is :none", ctx do
      register_in_order([RendererSkipPlugin], ctx)

      assert :none = Registry.collect_content_renderer("book", %{})
    end

    test "a renderer that raises is isolated — result :none, host does not crash", ctx do
      register_in_order([RendererRaisePlugin], ctx)

      assert :none = Registry.collect_content_renderer("book", %{})
    end

    test "first-wins: earlier plugin's {:ok, _} short-circuits a later one", ctx do
      register_in_order([RendererOkPlugin, RendererSecondOkPlugin], ctx)

      assert {:ok, iodata} = Registry.collect_content_renderer("book", %{})
      assert IO.iodata_to_binary(iodata) == "FROM-OK-PLUGIN"
    end

    test "a raising renderer is skipped and a later plugin still wins", ctx do
      register_in_order([RendererRaisePlugin, RendererOkPlugin], ctx)

      assert {:ok, iodata} = Registry.collect_content_renderer("book", %{})
      assert IO.iodata_to_binary(iodata) == "FROM-OK-PLUGIN"
    end
  end

  # ── collect_test_connection/2 ───────────────────────────────────────

  describe "collect_test_connection/2" do
    test "{:ok, payload} is returned verbatim" do
      name = "conn-ok-#{System.unique_integer([:positive])}"
      :ok = Registry.register(ConnOkPlugin, %{"plugin_name" => name})

      assert {:ok, %{status: "live"}} = Registry.collect_test_connection(name, %{})
    end

    test "{:error, reason} is returned verbatim" do
      name = "conn-err-#{System.unique_integer([:positive])}"
      :ok = Registry.register(ConnErrorPlugin, %{"plugin_name" => name})

      assert {:error, :unauthorized} = Registry.collect_test_connection(name, %{})
    end

    test "an unknown plugin name → {:error, :plugin_not_found}" do
      assert {:error, :plugin_not_found} =
               Registry.collect_test_connection("definitely-not-registered", %{})
    end

    test "a callback that raises → {:error, {:raised, msg}}" do
      name = "conn-raise-#{System.unique_integer([:positive])}"
      :ok = Registry.register(ConnRaisePlugin, %{"plugin_name" => name})

      assert {:error, {:raised, msg}} = Registry.collect_test_connection(name, %{})
      assert is_binary(msg)
      assert msg =~ "connection boom"
    end
  end
end
