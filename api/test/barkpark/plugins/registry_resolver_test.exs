defmodule Barkpark.Plugins.RegistryResolverTest do
  @moduledoc """
  Resolver-chain tests for Goal barkpark-cjs (task barkpark-mh4).

  Covers four behaviours of the new `(prev, ctx) -> next` resolver chain
  driven by `Barkpark.Plugins.Registry.reduce_resolvers/3`:

    1. Behaviour shape — all 8 `resolve_X/2` callbacks declared on
       `Barkpark.Plugin` are present in `behaviour_info(:callbacks)` and
       listed in `:optional_callbacks`.
    2. Resolver chain ordering — when `Application.get_env(:barkpark,
       :plugins, [])` lists plugins explicitly, resolvers fire in load
       order, and a later plugin sees the contribution of an earlier one.
    3. Additive fallback — a plugin that only exports the additive form
       (`top_menu_entries/0`) still contributes via the `defoverridable`
       lift implemented by `apply_resolver/8`'s path 2.
    4. Mutation — a plugin's `resolve_top_menu_entries/2` can REMOVE an
       entry from `prev` (the headline proof — plugins are no longer
       append-only).

  Optional Group 5 — `warn_duplicate_forms/0` emits a Logger warning when
  a plugin defines both `resolve_top_menu_entries/2` and `top_menu_entries/0`
  and the resolver is NOT the synthesised default lift.

  The Registry is a process-global singleton, so tests are `async: false`
  and use unique plugin names per case to avoid cross-test pollution.
  Each test that mutates `Application.get_env(:barkpark, :plugins, ...)`
  restores it via `on_exit/1`.
  """

  use Barkpark.RegistryCase, async: false
  import ExUnit.CaptureLog

  alias Barkpark.Plugins.Registry

  # ── Group 1: behaviour shape ────────────────────────────────────────

  @resolvers [
    resolve_checkers: 2,
    resolve_action_handlers: 2,
    resolve_external_sync_entries: 2,
    resolve_codelist_seeders: 2,
    resolve_settings_schema: 2,
    resolve_top_menu_entries: 2,
    resolve_desk_items: 2,
    resolve_doc_actions: 2
  ]

  describe "Barkpark.Plugin behaviour shape" do
    test "behaviour_info(:callbacks) exports all 8 resolver callbacks" do
      callbacks = Barkpark.Plugin.behaviour_info(:callbacks)

      for {name, arity} <- @resolvers do
        assert {name, arity} in callbacks,
               "missing @callback #{name}/#{arity} on Barkpark.Plugin"
      end
    end

    test "all 8 resolver callbacks are listed in @optional_callbacks" do
      optional = Barkpark.Plugin.behaviour_info(:optional_callbacks)

      for {name, arity} <- @resolvers do
        assert {name, arity} in optional,
               "expected #{name}/#{arity} to be optional"
      end
    end

    test "fixture plugin (uses `use Barkpark.Plugin`) exports every resolver default" do
      # `use Barkpark.Plugin` injects a `defoverridable` default for each
      # resolver — every plugin gets a working `resolve_X/2` for free.
      Code.ensure_loaded!(Barkpark.Plugins.Hello)

      for {name, arity} <- @resolvers do
        assert function_exported?(Barkpark.Plugins.Hello, name, arity),
               "expected fixture Hello plugin to export default #{name}/#{arity}"
      end
    end
  end

  # ── Test fixtures for groups 2–5 ────────────────────────────────────
  #
  # These are bare modules (no `use Barkpark.Plugin`) because the
  # compile-time macro requires a `plugin.json` on disk. The Registry's
  # `apply_resolver/8` handles bare modules via path 2 (additive lift)
  # when only the additive form is exported, and path 1 when the
  # resolver is exported directly — exactly what we want for these
  # focused tests.

  defmodule ResolverChainPluginA do
    # Path 1: exports the resolver directly. Appends a tab.
    def resolve_top_menu_entries(prev, _ctx) do
      prev ++ [%{label: "ChainA", path: "/admin/chain-a", order: 70}]
    end
  end

  defmodule ResolverChainPluginB do
    # Path 1: exports the resolver directly. Mutates A's contribution.
    def resolve_top_menu_entries(prev, _ctx) do
      Enum.map(prev, fn entry ->
        if entry[:label] == "ChainA",
          do: Map.put(entry, :label, "ChainA-modified-by-B"),
          else: entry
      end)
    end
  end

  defmodule AdditiveOnlyPlugin do
    # Path 2: exports only the additive form. The Registry's
    # `apply_resolver/8` lifts the result into the resolver shape via
    # `prev ++ result`.
    def top_menu_entries do
      [%{label: "AdditiveOnly", path: "/admin/additive-only", order: 75}]
    end
  end

  defmodule RemoverPlugin do
    # Path 1: exports the resolver directly. Removes any entry whose
    # label matches "TO-HIDE". The headline mutation proof.
    def resolve_top_menu_entries(prev, _ctx) do
      Enum.reject(prev, &(&1[:label] == "TO-HIDE"))
    end
  end

  defmodule DuplicateFormPlugin do
    # Both forms exported, with a resolver that is NOT the synthesised
    # default lift — `resolver_is_default_lift?/4` will return false and
    # `warn_duplicate_forms/0` will emit a warning.
    def top_menu_entries do
      [%{label: "DupAdditive", path: "/d/a"}]
    end

    def resolve_top_menu_entries(_prev, _ctx) do
      # Deliberately divergent from `prev ++ top_menu_entries()` so the
      # fingerprint check fails.
      [%{label: "DupResolverWins", path: "/d/r"}]
    end
  end

  # Helper: stash plugins under unique alphabetically-ordered names so
  # load_ordered_plugins/0 sorts them deterministically when no
  # Application config is set. Returns the assigned names so the caller
  # can target them.
  defp register_ordered(modules) when is_list(modules) do
    salt = System.unique_integer([:positive])

    modules
    |> Enum.with_index()
    |> Enum.map(fn {module, idx} ->
      # Letter prefix forces alphabetical ordering: a-, b-, c-, ...
      letter = <<?a + idx::utf8>>
      name = "rrt-#{letter}-#{salt}"
      :ok = Registry.register(module, %{"plugin_name" => name})
      name
    end)
  end

  # Helper: install an explicit plugin load order via Application config
  # and restore the previous value on exit.
  # `Barkpark.PluginEnv` restores through an `:unset` sentinel: a `[]` snapshot
  # default would restore an EXPLICIT `[]` (BootCollectors' discovery kill
  # switch) on the unset boot baseline. RegistryCase's own `delete_env` on_exit
  # already covers this file; the sentinel makes the helper correct on its own.
  defp with_app_plugin_order(names, ctx) when is_list(names) do
    Barkpark.PluginEnv.with_plugins(names, ctx)
  end

  # ── Group 2: resolver chain ordering ────────────────────────────────

  describe "resolver chain ordering" do
    test "later plugin sees the contribution of an earlier plugin", ctx do
      [name_a, name_b] = register_ordered([ResolverChainPluginA, ResolverChainPluginB])
      :ok = with_app_plugin_order([name_a, name_b], ctx)

      result = Registry.collect_top_menu_entries(baseline: [], ctx: %{})

      # Tabs we care about, in load order:
      #   A appends ChainA
      #   B sees ChainA and rewrites its label to "ChainA-modified-by-B"
      ours = Enum.filter(result, &(&1.label =~ "ChainA"))

      assert ours == [
               %{
                 label: "ChainA-modified-by-B",
                 path: "/admin/chain-a",
                 icon: nil,
                 order: 70,
                 active_when: nil
               }
             ],
             "expected B to mutate A's contribution; got: #{inspect(ours)}"
    end

    test "reversed load order — A no longer sees B because B fires first", ctx do
      [name_a, name_b] = register_ordered([ResolverChainPluginA, ResolverChainPluginB])
      # Reverse order: B first (no ChainA in prev to mutate), then A appends.
      :ok = with_app_plugin_order([name_b, name_a], ctx)

      result = Registry.collect_top_menu_entries(baseline: [], ctx: %{})

      ours = Enum.filter(result, &(&1.label =~ "ChainA"))

      # B sees an empty prev (no ChainA yet) so its Enum.map is a no-op;
      # A then appends ChainA verbatim. Label is unmodified.
      assert ours == [
               %{
                 label: "ChainA",
                 path: "/admin/chain-a",
                 icon: nil,
                 order: 70,
                 active_when: nil
               }
             ],
             "expected A's tab unmodified when A fires last; got: #{inspect(ours)}"
    end

    test "baseline threads through the chain unchanged when no plugin matches", ctx do
      [name_b] = register_ordered([ResolverChainPluginB])
      :ok = with_app_plugin_order([name_b], ctx)

      # Seed baseline with a tab labelled "Untouched" — B only rewrites
      # entries labelled "ChainA", so this one passes through.
      baseline = [%{label: "Untouched", path: "/u", order: 65}]
      result = Registry.collect_top_menu_entries(baseline: baseline, ctx: %{})

      assert Enum.any?(result, &(&1.label == "Untouched" and &1.path == "/u")),
             "baseline entry should survive when no resolver mutates it"
    end
  end

  # ── Group 3: additive fallback (defoverridable lift) ────────────────

  describe "additive fallback" do
    test "a plugin exporting only top_menu_entries/0 still contributes", ctx do
      [name] = register_ordered([AdditiveOnlyPlugin])
      :ok = with_app_plugin_order([name], ctx)

      result = Registry.collect_top_menu_entries(baseline: [], ctx: %{})

      assert Enum.any?(
               result,
               &(&1.label == "AdditiveOnly" and &1.path == "/admin/additive-only")
             ),
             "expected the additive-only plugin's tab to appear via the lift; " <>
               "got: #{inspect(result)}"
    end

    test "additive lift composes with a later resolver-form plugin", ctx do
      [name_a, name_b] = register_ordered([AdditiveOnlyPlugin, ResolverChainPluginB])
      :ok = with_app_plugin_order([name_a, name_b], ctx)

      # A contributes via additive lift; B is a resolver that only
      # rewrites "ChainA" — so A's "AdditiveOnly" tab survives unchanged.
      result = Registry.collect_top_menu_entries(baseline: [], ctx: %{})

      assert Enum.any?(result, &(&1.label == "AdditiveOnly")),
             "additive-lifted contribution should survive a non-matching downstream resolver"
    end
  end

  # ── Group 4: mutation (removal) ─────────────────────────────────────

  describe "mutation — plugin removes an entry from prev" do
    test "RemoverPlugin drops a baseline entry labelled TO-HIDE", ctx do
      [name] = register_ordered([RemoverPlugin])
      :ok = with_app_plugin_order([name], ctx)

      baseline = [
        %{label: "TO-HIDE", path: "/h", order: 60},
        %{label: "KEEP", path: "/k", order: 61}
      ]

      result = Registry.collect_top_menu_entries(baseline: baseline, ctx: %{})

      labels = result |> Enum.map(& &1.label)
      assert "KEEP" in labels, "expected KEEP to survive; got labels: #{inspect(labels)}"
      refute "TO-HIDE" in labels, "expected TO-HIDE to be removed by RemoverPlugin"
    end

    test "removal applies to a tab contributed by an earlier plugin too", ctx do
      # Wire ResolverChainPluginA (appends ChainA) followed by RemoverPlugin
      # configured to drop ChainA. The headline mutation proof: a plugin
      # can delete another plugin's contribution, not just baseline.
      defmodule ChainARemoverPlugin do
        def resolve_top_menu_entries(prev, _ctx) do
          Enum.reject(prev, &(&1[:label] == "ChainA"))
        end
      end

      [name_a, name_remover] = register_ordered([ResolverChainPluginA, ChainARemoverPlugin])
      :ok = with_app_plugin_order([name_a, name_remover], ctx)

      result = Registry.collect_top_menu_entries(baseline: [], ctx: %{})

      refute Enum.any?(result, &(&1.label == "ChainA")),
             "expected ChainARemoverPlugin to drop the upstream plugin's tab"
    end
  end

  # ── Group 5 (optional): duplicate-form warning ──────────────────────

  describe "warn_duplicate_forms/0" do
    test "logs when a plugin defines BOTH the resolver and additive form", ctx do
      [name] = register_ordered([DuplicateFormPlugin])
      :ok = with_app_plugin_order([name], ctx)

      log =
        capture_log(fn ->
          :ok = Registry.warn_duplicate_forms()
        end)

      assert log =~ name, "expected the warning to name the plugin (got: #{log})"

      assert log =~ "resolve_top_menu_entries/2" and log =~ "top_menu_entries/0",
             "expected the warning to name both callback forms (got: #{log})"
    end

    test "does NOT warn for plugins using only the synthesised default lift" do
      # The fixture Hello plugin uses `use Barkpark.Plugin` and defines
      # only `checkers/0` (additive) — its `resolve_checkers/2` is the
      # synthesised default. `warn_duplicate_forms/0` must NOT flag it.
      log =
        capture_log(fn ->
          :ok = Registry.warn_duplicate_forms()
        end)

      refute log =~ "plugin hello defines both",
             "expected no duplicate-form warning for default-lift plugin (got: #{log})"
    end

    test "does NOT warn when a default lift returns regex-backed menu data" do
      # Tickets uses a Regex active matcher so one tab highlights on both the
      # flat and workspace/project-scoped inbox routes. Each callback call
      # compiles a fresh :re_pattern reference; the fingerprint must compare
      # Regex semantics rather than that runtime artifact.
      log =
        capture_log(fn ->
          :ok = Registry.warn_duplicate_forms()
        end)

      refute log =~ "plugin tickets defines both",
             "expected no duplicate-form warning for Tickets' default lift (got: #{log})"
    end
  end
end
