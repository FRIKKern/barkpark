defmodule Barkpark.Plugins.PluginOrderSetterGuardTest do
  @moduledoc """
  Every test that sets the `:barkpark, :plugins` load order goes through
  `Barkpark.PluginEnv.put!/1` (or `with_plugins/2` / `run_with/2`, which call
  it), so a non-plugin entry reds LOUDLY instead of being dropped.

  ## Why

  Every load-order reader (`Plugins.Hooks`, `Registry.ResolverChain`,
  `Registry.BootCollectors`, `Registry.Discovery`, `Content.PreWriteFences`)
  accepts a module atom, a `{plugin_name, module}` tuple or a plugin-name
  string, and DROPS anything else without a word.
  `stamp_publish_lost_update_test.exs` set the order to `Registry.all() ++
  [InterleavedWriter]` — registry ENTRY MAPS — so the Tasks plugin was OFF in
  it all along and its gates never ran, yet the test passed
  (task-05ea4e4c31dbc750). `PluginEnv.put!/1` refuses such an entry; this
  guard makes sure no setter routes around it.

  ## The predicate

  Parse every `api/test/**/*.{ex,exs}` file to AST (so a moduledoc or comment
  that QUOTES a setter is not a hit, and a setter split over several lines is)
  and flag any direct write of the key:

    * `Application.put_env(:barkpark, :plugins, _)` (3- or 4-arity)
    * `:application.set_env(:barkpark, :plugins, _)` (3- or 4-arity)
    * `Application.put_all_env(barkpark: [plugins: _, …])`

  outside `test/support/plugin_env.ex`, the one module allowed to write it.
  Restores go through `PluginEnv.restore/1`; `Application.delete_env/2` (the
  "unset" baseline) is not a write of a load order and is not flagged.

  ## Exemptions

  None. The file that surfaced the shape, `stamp_publish_lost_update_test.exs`,
  was fixed by PR #20129 and routed through `PluginEnv` by
  task-19947e55b2fc7e66. An exemption, if one is ever needed, is named with a
  reason and self-expiring: if its file stops carrying a direct setter, the
  stale-exemption test reds and the entry must be deleted.
  """
  use ExUnit.Case, async: false

  @allowed "test/support/plugin_env.ex"

  # Empty since task-19947e55b2fc7e66 routed the last exempt file through
  # PluginEnv. A future entry must name a file and why, and expires the same way.
  @exempt %{}

  test "no test writes the :plugins load order except through Barkpark.PluginEnv" do
    files = Path.wildcard("test/**/*.{ex,exs}")

    assert length(files) > 100,
           "scanned only #{length(files)} files — the guard is not pointed at api/test (cwd: #{File.cwd!()})"

    hits = Enum.flat_map(files, &scan_file/1)

    # CONTROL: the scanner must SEE the setter the allowed module really has.
    # A scanner that finds nothing anywhere would pass the refute below vacuously.
    assert Enum.any?(hits, fn {file, _line} -> file == @allowed end),
           "the scanner found no setter in #{@allowed}, which has one — the predicate is broken"

    offenders =
      Enum.reject(hits, fn {file, _line} -> file == @allowed or Map.has_key?(@exempt, file) end)

    assert offenders == [],
           """
           these tests write :barkpark, :plugins directly, bypassing Barkpark.PluginEnv.put!/1:

           #{Enum.map_join(offenders, "\n", fn {f, l} -> "  #{f}:#{l}" end)}

           Every load-order reader silently DROPS an entry that is not a module atom,
           a {plugin_name, module} tuple or a plugin-name string, so a direct write can
           leave the plugin under test OFF without a red. Use
           `Barkpark.PluginEnv.put!/1` (pair with `capture/0` + `restore/1`),
           `with_plugins/2`, or `run_with/2`.
           """
  end

  test "every exemption still names a file with a direct setter (the exemption expires)" do
    for {file, reason} <- @exempt do
      assert File.exists?(file), "exempt file #{file} is gone — delete its exemption (#{reason})"

      assert scan_file(file) != [],
             "#{file} no longer writes :plugins directly — delete its exemption (#{reason})"
    end
  end

  describe "the predicate is able to fail" do
    test "a direct setter reds, including one split across lines and the put_all_env form" do
      source = ~S"""
      defmodule Specimen do
        @moduledoc "quotes `Application.put_env(:barkpark, :plugins, [])` — prose, not a hit"
        # Application.put_env(:barkpark, :plugins, []) — a comment, not a hit
        def a, do: Application.put_env(:barkpark, :plugins, Barkpark.Plugins.Registry.all())

        def b do
          Application.put_env(
            :barkpark,
            :plugins,
            [SomePlugin]
          )
        end

        def c, do: :application.set_env(:barkpark, :plugins, [])
        def d, do: Application.put_all_env(barkpark: [plugins: []])
        def e, do: Application.put_env(:barkpark, :other_key, [])
        def f, do: Application.delete_env(:barkpark, :plugins)
      end
      """

      assert scan_source("specimen.exs", source) == [
               {"specimen.exs", 4},
               {"specimen.exs", 7},
               {"specimen.exs", 14},
               {"specimen.exs", 15}
             ]
    end
  end

  # ─── scanner ──────────────────────────────────────────────────────────────

  defp scan_file(path), do: scan_source(path, File.read!(path))

  defp scan_source(path, source) do
    case Code.string_to_quoted(source, file: path) do
      {:ok, ast} ->
        {_, hits} = Macro.prewalk(ast, [], &collect(&1, &2, path))
        hits |> Enum.reverse() |> Enum.uniq()

      {:error, reason} ->
        flunk("#{path} does not parse, so the guard cannot vouch for it: #{inspect(reason)}")
    end
  end

  defp collect(
         {{:., _, [{:__aliases__, _, [:Application]}, :put_env]}, meta, [:barkpark, :plugins | _]} =
           node,
         acc,
         path
       ),
       do: {node, [{path, meta[:line]} | acc]}

  defp collect(
         {{:., _, [:application, :set_env]}, meta, [:barkpark, :plugins | _]} = node,
         acc,
         path
       ),
       do: {node, [{path, meta[:line]} | acc]}

  defp collect(
         {{:., _, [{:__aliases__, _, [:Application]}, :put_all_env]}, meta, [config | _]} = node,
         acc,
         path
       ) do
    if writes_plugins?(config), do: {node, [{path, meta[:line]} | acc]}, else: {node, acc}
  end

  defp collect(node, acc, _path), do: {node, acc}

  defp writes_plugins?(config) when is_list(config) do
    Enum.any?(config, fn
      {:barkpark, kw} when is_list(kw) -> Enum.any?(kw, &match?({:plugins, _}, &1))
      _ -> false
    end)
  end

  defp writes_plugins?(_), do: false
end
