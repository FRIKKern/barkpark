defmodule Barkpark.ApplicationBootModeTest do
  @moduledoc """
  The `:seed` boot mode (task-9eb8687b09b26a03).

  These assert the PLAN, not a running node: `mix test` has already started
  `:barkpark` in `:full` mode, so a second supervision tree cannot be booted
  here. `Barkpark.Application.child_specs/5` is pure, which is the whole reason
  the seam lives there instead of in `Barkpark.Release`.

  Anti-vacuity: every "seed mode omits X" assertion is paired with a POSITIVE
  CONTROL proving the full-mode list contains X, so a filter that returned `[]`
  (or a typo'd module name that is in neither list) cannot manufacture a pass.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Application, as: App

  # A sentinel in each of the four injected lists, so "the filter touched only
  # the two entries it is allowed to touch" is observable.
  @plugin_children [{Task.Supervisor, name: :w13_plugin_sentinel}]
  @sync_children [{Task.Supervisor, name: :w13_sync_sentinel}]
  @self_update_children [{Task.Supervisor, name: :w13_self_update_sentinel}]

  defp oban_config, do: Application.fetch_env!(:barkpark, Oban)

  defp full,
    do: App.child_specs(@plugin_children, oban_config(), @sync_children, @self_update_children)

  defp seed,
    do:
      App.child_specs(
        @plugin_children,
        oban_config(),
        @sync_children,
        @self_update_children,
        :seed
      )

  describe "positive control: the full list is the thing being narrowed" do
    test "full mode contains the Endpoint and a LIVE Oban child" do
      full = full()

      # If either of these ever fails, every `refute ... in seed` below is
      # vacuous and must not be read as evidence.
      assert BarkparkWeb.Endpoint in full,
             "full mode must contain BarkparkWeb.Endpoint; got #{inspect(full)}"

      assert {Oban, oban_config()} in full,
             "full mode must carry the unmodified Oban config"

      refute oban_config()[:queues] == false,
             "the base Oban config must have live queues, else the seed-mode diff is invisible"

      # The list is a real tree, not a stub.
      assert Barkpark.Repo in full
      assert length(full) > 20
    end

    test "child_specs/4 is child_specs/5 in :full mode" do
      assert full() ==
               App.child_specs(
                 @plugin_children,
                 oban_config(),
                 @sync_children,
                 @self_update_children,
                 :full
               )
    end
  end

  describe "seed mode = the canonical list minus exactly two entries" do
    test "the only children DROPPED are the Endpoint and the live Oban child" do
      assert full() -- seed() == [{Oban, oban_config()}, BarkparkWeb.Endpoint]
    end

    test "the only child ADDED is the inert Oban, and it is inert" do
      assert [{Oban, inert}] = seed() -- full()
      assert inert[:queues] == false
      assert inert[:plugins] == false

      # Everything else about the Oban config is carried through untouched —
      # this is a narrowing, not a replacement.
      assert Keyword.drop(inert, [:queues, :plugins]) ==
               Keyword.drop(oban_config(), [:queues, :plugins])
    end

    test "the Endpoint is absent from seed mode and present in full mode" do
      refute BarkparkWeb.Endpoint in seed()
      assert BarkparkWeb.Endpoint in full()
    end

    test "seed mode keeps every other child, in the same order" do
      seed = seed()

      assert length(seed) == length(full()) - 1

      # Boot order is preserved verbatim: strip the two mutated entries from
      # both lists and they are identical, element for element.
      strip = fn list ->
        Enum.reject(list, &match?({Oban, _}, &1)) |> Enum.reject(&(&1 == BarkparkWeb.Endpoint))
      end

      assert strip.(seed) == strip.(full())

      # The injected sentinels survive: the filter narrows the host's own two
      # entries, never the plugin / sync / self-update tiers.
      assert {Barkpark.Plugins.Supervisor, @plugin_children} in seed
      assert Enum.all?(@sync_children, &(&1 in seed))
      assert Enum.all?(@self_update_children, &(&1 in seed))

      # Everything the seed bodies actually need is still there.
      for needed <- [
            Barkpark.Repo,
            Barkpark.Vault,
            Barkpark.Plugins.Registry,
            Barkpark.SchemaBootstrap,
            Barkpark.Validation.Registry,
            {Phoenix.PubSub, name: Barkpark.PubSub},
            {Task.Supervisor, name: Barkpark.TaskSupervisor}
          ] do
        assert needed in seed, "seed mode dropped #{inspect(needed)}"
      end
    end
  end

  describe "boot_mode/0" do
    test "defaults to :full for every ordinary boot" do
      refute Application.fetch_env(:barkpark, :boot_mode) != :error and
               Application.get_env(:barkpark, :boot_mode) not in [:full, :seed]

      assert App.boot_mode() == :full
    end

    test "reads the app env, and refuses an unknown value" do
      original = Application.fetch_env(:barkpark, :boot_mode)

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:barkpark, :boot_mode, value, persistent: true)
          :error -> Application.delete_env(:barkpark, :boot_mode, persistent: true)
        end
      end)

      Application.put_env(:barkpark, :boot_mode, :seed, persistent: true)
      assert App.boot_mode() == :seed

      Application.put_env(:barkpark, :boot_mode, :nope, persistent: true)

      assert_raise ArgumentError, ~r/unknown :barkpark, :boot_mode :nope/, fn ->
        App.boot_mode()
      end
    end
  end

  describe "Barkpark.Release.seed/0 uses the seam" do
    test "seed_boot!/0 selects :seed mode before starting the app" do
      original = Application.fetch_env(:barkpark, :boot_mode)

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:barkpark, :boot_mode, value, persistent: true)
          :error -> Application.delete_env(:barkpark, :boot_mode, persistent: true)
        end
      end)

      # Precondition: not already in seed mode, else this proves nothing.
      assert App.boot_mode() == :full

      # `:barkpark` is already started here, so this is a no-op start — the
      # observable effect under test is the mode selection that precedes it.
      assert {:ok, _apps} = Barkpark.Release.seed_boot!()
      assert App.boot_mode() == :seed
    end

    test "seed/0's body calls seed_boot!/0, not a bare start" do
      source = File.read!("lib/barkpark/release.ex")

      # Control: the anchor this assertion depends on exists. Without it a
      # renamed function would make every assertion below read an EMPTY body
      # and pass on nothing.
      assert source =~ "  def seed do\n"

      # The BODY of seed/0, comments and blank lines dropped. A literal
      # "def seed do\n    seed_boot!()\n" match would red on a comment added
      # above the call — which is a documentation edit, not a boot change — so
      # pin the STATEMENTS instead: the first one must be seed_boot!/0.
      body =
        source
        |> String.split("  def seed do\n", parts: 2)
        |> List.last()
        |> String.split("\n  end\n", parts: 2)
        |> List.first()
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

      # Control: the body really was extracted, so the assertions below have a
      # subject.
      refute body == [], "could not read seed/0's body out of lib/barkpark/release.ex"

      assert List.first(body) == "seed_boot!()",
             "Barkpark.Release.seed/0 must boot through seed_boot!/0 — its first " <>
               "statement is #{inspect(List.first(body))}"

      refute Enum.any?(body, &(&1 =~ "start_app()")),
             "seed/0 must not boot the FULL tree; body: #{inspect(body)}"
    end
  end
end
