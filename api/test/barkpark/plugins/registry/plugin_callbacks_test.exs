defmodule Barkpark.Plugins.Registry.PluginCallbacksTest do
  @moduledoc """
  Unit tests for the previously-untested public functions in
  `Barkpark.Plugins.Registry.PluginCallbacks`:

    * `run_codelist_seeders_by_name/1` — per-plugin seeder dispatch by name
    * `run_after_media_upload/1`       — fan-out media upload hook
    * `run_after_media_delete/1`       — fan-out media delete hook
    * `asset_doc_id_for_media_file/2`  — first-wins asset-doc-id resolver

  `collect_content_renderer/3` and `collect_test_connection/2` are already
  covered in `registry_renderer_connection_test.exs`.

  Tests register fake plugins against the live Registry GenServer (which has
  no removal API), so this suite must run synchronously.
  """

  use Barkpark.RegistryCase, async: false

  alias Barkpark.Plugins.Registry
  alias Barkpark.Plugins.Registry.PluginCallbacks
  alias Barkpark.Plugins.RunStatus

  # ── Fake plugin modules ──────────────────────────────────────────────────

  defmodule SeederPlugin do
    def codelist_seeders do
      [fn -> :persistent_term.put({__MODULE__, :ran}, true) end]
    end
  end

  # A seeder that never RAISES and reports its outcome by RETURN VALUE. This
  # is the documented contract of both OnixEdit seeders
  # (`Barkpark.Codelists.EDItEUR.seed_bundled/1` + `seed_thema/1` both say
  # "Never raises" and hand back `{:error, reason}`), so a boot-time seed
  # failure reaches `invoke_seeder/2` as a return value, never as an
  # exception.
  defmodule ReturnsErrorSeederPlugin do
    def codelist_seeders do
      [fn -> {:error, {:raised, "Thema seed raised — ERROR 57014 (query_canceled)"}} end]
    end
  end

  defmodule ReturnsOkTupleSeederPlugin do
    def codelist_seeders do
      [fn -> {:ok, 9187} end]
    end
  end

  defmodule MediaUploadPlugin do
    def after_media_upload(ctx) do
      :persistent_term.put({__MODULE__, :upload_ctx}, ctx)
      :ok
    end
  end

  defmodule MediaDeletePlugin do
    def after_media_delete(ctx) do
      :persistent_term.put({__MODULE__, :delete_ctx}, ctx)
      :ok
    end
  end

  defmodule AssetDocPlugin do
    def asset_doc_id_for_file("known-file", _dataset), do: "asset-doc-123"
    def asset_doc_id_for_file(_id, _dataset), do: nil
  end

  defmodule NoHooksPlugin do
    # Deliberately implements none of the optional callbacks.
  end

  # ── run_codelist_seeders_by_name/1 ──────────────────────────────────────

  describe "run_codelist_seeders_by_name/1" do
    test "returns {:error, :unknown_plugin} for an unregistered name" do
      assert {:error, :unknown_plugin} =
               PluginCallbacks.run_codelist_seeders_by_name("definitely-not-registered")
    end

    test "runs seeders and returns :ok for a registered plugin" do
      :persistent_term.erase({SeederPlugin, :ran})
      name = "seeder-by-name-#{System.unique_integer([:positive])}"
      :ok = Registry.register(SeederPlugin, %{"plugin_name" => name})

      assert :ok = PluginCallbacks.run_codelist_seeders_by_name(name)
      assert :persistent_term.get({SeederPlugin, :ran}, false) == true
    end

    test "also reachable via the Registry delegate" do
      assert {:error, :unknown_plugin} =
               Registry.run_codelist_seeders_by_name("no-such-plugin-cb-test")
    end

    test "a seeder that REPORTS failure by return value is recorded as an error" do
      name = "seeder-returns-error-#{System.unique_integer([:positive])}"
      :ok = Registry.register(ReturnsErrorSeederPlugin, %{"plugin_name" => name})

      assert :ok = PluginCallbacks.run_codelist_seeders_by_name(name)

      assert %{seed: %{result: {:error, [{:raised, msg}]}}} = RunStatus.get(name)
      assert msg =~ "query_canceled"
    end

    test "a seeder returning {:ok, count} is still recorded as a success" do
      name = "seeder-returns-ok-#{System.unique_integer([:positive])}"
      :ok = Registry.register(ReturnsOkTupleSeederPlugin, %{"plugin_name" => name})

      assert :ok = PluginCallbacks.run_codelist_seeders_by_name(name)
      assert %{seed: %{result: {:ok, 1}}} = RunStatus.get(name)
    end

    test "a seeder returning bare :ok is still recorded as a success" do
      :persistent_term.erase({SeederPlugin, :ran})
      name = "seeder-returns-bare-ok-#{System.unique_integer([:positive])}"
      :ok = Registry.register(SeederPlugin, %{"plugin_name" => name})

      assert :ok = PluginCallbacks.run_codelist_seeders_by_name(name)
      assert %{seed: %{result: {:ok, 1}}} = RunStatus.get(name)
    end
  end

  # ── run_after_media_upload/1 ─────────────────────────────────────────────

  describe "run_after_media_upload/1" do
    test "calls after_media_upload/1 on plugins that export it, always returns :ok" do
      :persistent_term.erase({MediaUploadPlugin, :upload_ctx})
      name = "media-up-#{System.unique_integer([:positive])}"
      :ok = Registry.register(MediaUploadPlugin, %{"plugin_name" => name})

      ctx = %{file_id: "f1", dataset: "production"}
      assert :ok = PluginCallbacks.run_after_media_upload(ctx)
      assert :persistent_term.get({MediaUploadPlugin, :upload_ctx}, nil) == ctx
    end

    test "skips plugins that do not export after_media_upload/1" do
      name = "no-hooks-up-#{System.unique_integer([:positive])}"
      :ok = Registry.register(NoHooksPlugin, %{"plugin_name" => name})

      # Must not raise; still :ok
      assert :ok = PluginCallbacks.run_after_media_upload(%{file_id: "x"})
    end
  end

  # ── run_after_media_delete/1 ─────────────────────────────────────────────

  describe "run_after_media_delete/1" do
    test "calls after_media_delete/1 on plugins that export it, always returns :ok" do
      :persistent_term.erase({MediaDeletePlugin, :delete_ctx})
      name = "media-del-#{System.unique_integer([:positive])}"
      :ok = Registry.register(MediaDeletePlugin, %{"plugin_name" => name})

      ctx = %{file_id: "f2", dataset: "staging"}
      assert :ok = PluginCallbacks.run_after_media_delete(ctx)
      assert :persistent_term.get({MediaDeletePlugin, :delete_ctx}, nil) == ctx
    end

    test "skips plugins that do not export after_media_delete/1" do
      name = "no-hooks-del-#{System.unique_integer([:positive])}"
      :ok = Registry.register(NoHooksPlugin, %{"plugin_name" => name})

      assert :ok = PluginCallbacks.run_after_media_delete(%{file_id: "y"})
    end
  end

  # ── asset_doc_id_for_media_file/2 ────────────────────────────────────────

  describe "asset_doc_id_for_media_file/2" do
    test "returns the string doc-id from a plugin that matches the file" do
      name = "asset-doc-#{System.unique_integer([:positive])}"
      prior = Application.get_env(:barkpark, :plugins, [])
      :ok = Registry.register(AssetDocPlugin, %{"plugin_name" => name})
      Application.put_env(:barkpark, :plugins, [name])
      on_exit(fn -> Application.put_env(:barkpark, :plugins, prior) end)

      assert "asset-doc-123" =
               PluginCallbacks.asset_doc_id_for_media_file("known-file", "production")
    end

    test "returns nil when no plugin resolves the file" do
      name = "asset-doc-nil-#{System.unique_integer([:positive])}"
      prior = Application.get_env(:barkpark, :plugins, [])
      :ok = Registry.register(AssetDocPlugin, %{"plugin_name" => name})
      Application.put_env(:barkpark, :plugins, [name])
      on_exit(fn -> Application.put_env(:barkpark, :plugins, prior) end)

      assert nil == PluginCallbacks.asset_doc_id_for_media_file("unknown-file", "production")
    end
  end
end
