defmodule Barkpark.RegistryCase do
  @moduledoc """
  Shared case template for tests that exercise the singleton
  `Barkpark.Plugins.Registry` GenServer.

  The Registry is a process-global named GenServer whose `state.plugins`
  map only grows (no production `unregister/1`), and every mutation
  re-snapshots into a `:persistent_term` read cache. Tests that register
  fake plugins therefore leak entries — and poisoned snapshots — into
  shared global state, producing order-dependent failures across the
  full `mix test` run (registry_collect / cache / top_menu / desk_items,
  resolver_outputs, …).

  Using this template registers an `on_exit/1` callback that calls
  `Barkpark.Plugins.Registry.reset/0`, restoring the baseline plugin set
  (the boot-time discovery set — OnixEdit, media) and re-snapshotting
  `:persistent_term` to match. Each test thus starts from a clean,
  deterministic baseline regardless of run order.

      use Barkpark.RegistryCase, async: false

  `async: false` is mandatory — a shared named GenServer cannot be reset
  per-test under concurrency.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Barkpark.Plugins.Registry
    end
  end

  setup do
    # Two leak channels feed the order-dependent flakes:
    #
    #   1. `Barkpark.Plugins.Registry` state.plugins (+ its persistent_term
    #      snapshot) — cleared by `Registry.reset/0`.
    #   2. the `:barkpark, :plugins` Application env — several tests set it to
    #      a non-empty load-order list, which makes `load_ordered_plugins/0`
    #      walk ONLY the listed names. A leak here makes freshly-registered
    #      fakes (and the bundled OnixEdit) invisible to the collectors.
    #
    # The boot baseline for the env is UNSET (config declares no `:plugins`).
    # Force that baseline before the body and again on exit, so this test
    # neither inherits a sibling's leaked load-order list nor emits its own.
    # Tests that set the env in their own body register their own restore via
    # `on_exit/1`, which (LIFO) runs before this one — harmless either way
    # since both converge on the unset baseline.
    Application.delete_env(:barkpark, :plugins)
    Barkpark.Plugins.Registry.reset()

    on_exit(fn ->
      Application.delete_env(:barkpark, :plugins)
      Barkpark.Plugins.Registry.reset()
    end)

    :ok
  end
end
