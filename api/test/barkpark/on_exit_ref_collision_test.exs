defmodule Barkpark.OnExitRefCollisionTest do
  @moduledoc """
  THE GATE for `on_exit/2` ref collisions in `api/test`.

  `on_exit/2` keys on its first argument. A second registration under a ref that
  is already registered REPLACES the first — silently. The replaced cleanup never
  runs and nothing reds, so the failure mode is a green suite with a leaking
  fixture. `Barkpark.OnExitRefScan`'s moduledoc carries the mechanism and the
  rule; this module is the arm that makes a new one FAIL.

  It runs in `mix test`, which is the blocking Elixir gate, so no workflow wiring
  is needed for a new bare-ref site to red.

  WHY THE FIXTURE ARMS ARE NOT DECORATION: a scanner that returned `[]`
  unconditionally would pass the live sweep forever. `reds on a planted
  collision` and `stays quiet on a legitimate double-registration` are what make
  the live green mean something.
  """
  use ExUnit.Case, async: true

  alias Barkpark.OnExitRefScan
  alias Barkpark.OnExitRefScan.Site

  @roots ["test"]

  # ── THE CENSUS ────────────────────────────────────────────────────────────
  #
  # Every on_exit/2 site in api/test whose ref is NOT module-scoped — i.e. every
  # site that shares one key with every other helper reachable in the test
  # process. Classification:
  #
  #   COLLIDING — a second registration under the same ref runs in the same test
  #               lifecycle, so the earlier cleanup is unregistered.
  #   SAFE      — only one registration under that ref is reachable today.
  #
  # Re-derive the raw list, do not trust this comment:
  #
  #   cd api && mix run -e 'Barkpark.OnExitRefScan.scan(["test"]) |> elem(1) \
  #     |> Enum.each(&IO.puts(Barkpark.OnExitRefScan.format(&1)))'
  #
  # The census is ALLOWED to be non-empty only for entries that carry the
  # `# on-exit-ref-gate: allow-bare-ref` marker. Everything else must be fixed,
  # not listed — which is why this fixture holds one entry and not a skip list.
  @expected_bare_refs [
    # The regression test that PINS the collision: it registers a bare-ctx
    # sibling on purpose and asserts the earlier restore survived. Rewriting it
    # to a module-scoped ref would delete the test.
    {"test/barkpark/plugins/plugin_env_test.exs", "ctx"}
  ]

  describe "the live tree" do
    test "no on_exit/2 site uses a non-module-scoped ref" do
      {files, sites} = OnExitRefScan.scan(@roots)

      # A sweep that scanned nothing would report zero violations. Both of these
      # are preconditions on the MEASUREMENT, not on the tree.
      assert files > 100, "scanned #{files} files — the sweep did not reach api/test"
      assert sites != [], "found no on_exit/2 sites at all — the parser is matching nothing"

      violations = OnExitRefScan.violations(sites)

      assert violations == [],
             """
             on_exit/2 ref collision hazard — these refs are not module-scoped:

             #{Enum.map_join(violations, "\n", &OnExitRefScan.format/1)}

             on_exit/2's first argument is a KEY. A bare `ctx` / `context` /
             `conn` ref is ONE key shared by every helper in the test process, so
             the next helper that keys on it silently unregisters this cleanup.

             Fix: use a module-scoped ref, e.g.

                 ExUnit.Callbacks.on_exit({__MODULE__, :what_this_restores, ctx}, fn -> … end)

             If the bare ref is the POINT of the test, mark the site:

                 # on-exit-ref-gate: allow-bare-ref — <why>
             """
    end

    test "the bare-ref census is exactly the committed fixture" do
      {_files, sites} = OnExitRefScan.scan(@roots)

      actual =
        sites
        |> Enum.reject(& &1.module_scoped?)
        |> Enum.map(&{&1.file, &1.ref_source})
        |> Enum.sort()

      assert actual == Enum.sort(@expected_bare_refs),
             "a bare on_exit/2 ref appeared or moved; update @expected_bare_refs only " <>
               "if the new site is a deliberate, marked pin"
    end

    test "every censused bare ref carries the marker" do
      {_files, sites} = OnExitRefScan.scan(@roots)

      unmarked = sites |> Enum.reject(& &1.module_scoped?) |> Enum.reject(& &1.exempt?)
      assert unmarked == [], Enum.map_join(unmarked, "\n", &OnExitRefScan.format/1)
    end
  end

  # ── THE ARMS ──────────────────────────────────────────────────────────────

  describe "the scanner can fail" do
    @planted """
    defmodule Planted do
      use ExUnit.Case

      setup ctx do
        prior = Application.get_env(:probe, :k)
        ExUnit.Callbacks.on_exit(ctx, fn -> Application.put_env(:probe, :k, prior) end)
        :ok
      end

      test "t", ctx do
        helper(ctx)
      end

      defp helper(ctx) do
        ExUnit.Callbacks.on_exit(ctx, fn -> :ok end)
      end
    end
    """

    test "a planted colliding pair reds, naming the file and BOTH lines" do
      sites = OnExitRefScan.scan_source("planted_collision_test.exs", @planted)
      violations = OnExitRefScan.violations(sites)

      assert length(violations) == 2,
             "expected both halves of the planted pair, got:\n" <>
               Enum.map_join(violations, "\n", &OnExitRefScan.format/1)

      assert Enum.all?(violations, &(&1.file == "planted_collision_test.exs"))
      assert Enum.map(violations, & &1.line) == [6, 15]
      assert Enum.all?(violations, &(&1.ref_source == "ctx"))

      rendered = Enum.map_join(violations, "\n", &OnExitRefScan.format/1)
      assert rendered =~ "planted_collision_test.exs:6"
      assert rendered =~ "planted_collision_test.exs:15"
    end

    test "the imported (unqualified) on_exit/2 form is caught too" do
      src = """
      defmodule P do
        setup ctx do
          on_exit(ctx, fn -> :ok end)
        end
      end
      """

      assert [%Site{line: 3, ref_source: "ctx", module_scoped?: false}] =
               OnExitRefScan.scan_source("p.exs", src)
    end
  end

  describe "the scanner stays quiet" do
    test "a legitimate double registration under DISTINCT module-scoped refs is clean" do
      src = """
      defmodule Legit do
        use ExUnit.Case

        setup ctx do
          ExUnit.Callbacks.on_exit({__MODULE__, :baseline, ctx}, fn -> :ok end)
          :ok
        end

        test "t", ctx do
          helper_a(ctx)
          helper_b(ctx)
        end

        defp helper_a(ctx), do: ExUnit.Callbacks.on_exit({__MODULE__, :a, ctx}, fn -> :ok end)
        defp helper_b(ctx), do: ExUnit.Callbacks.on_exit({Barkpark.PluginEnv, ctx}, fn -> :ok end)
      end
      """

      sites = OnExitRefScan.scan_source("legit_test.exs", src)

      assert length(sites) == 3, "the quiet arm must actually have scanned all three sites"
      assert OnExitRefScan.violations(sites) == []
    end

    test "on_exit/1 (no ref) is not a ref collision and is not reported" do
      src = """
      defmodule One do
        setup do
          on_exit(fn -> :ok end)
          on_exit(&cleanup/0)
        end
      end
      """

      assert OnExitRefScan.scan_source("one_test.exs", src) == []
    end

    test "a marked bare ref is exempt, and only while the marker is there" do
      marked = """
      defmodule M do
        setup ctx do
          # on-exit-ref-gate: allow-bare-ref — this test IS the collision pin
          ExUnit.Callbacks.on_exit(ctx, fn -> :ok end)
        end
      end
      """

      assert [%Site{exempt?: true}] = OnExitRefScan.scan_source("m.exs", marked)
      assert OnExitRefScan.violations(OnExitRefScan.scan_source("m.exs", marked)) == []

      unmarked = String.replace(marked, ~r/^.*allow-bare-ref.*\n/m, "")
      assert [%Site{exempt?: false}] = OnExitRefScan.scan_source("m.exs", unmarked)
      assert length(OnExitRefScan.violations(OnExitRefScan.scan_source("m.exs", unmarked))) == 1
    end
  end

  describe "module_scoped?/1" do
    test "classifies the shapes this tree actually writes" do
      scoped = fn s -> s |> Code.string_to_quoted!() |> OnExitRefScan.module_scoped?() end

      # module-scoped
      assert scoped.("{__MODULE__, ctx}")
      assert scoped.("{__MODULE__, :baseline, ctx}")
      assert scoped.("{Barkpark.PluginEnv, ctx}")

      # bare / shared
      refute scoped.("ctx")
      refute scoped.("context")
      refute scoped.("conn")
      refute scoped.(":restore")
      refute scoped.("{ctx, :restore}")
      refute scoped.("{:restore, ctx}")
    end
  end
end
