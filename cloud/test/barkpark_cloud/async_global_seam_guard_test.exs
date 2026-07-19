defmodule BarkparkCloud.AsyncGlobalSeamGuardTest do
  @moduledoc """
  A tripwire for the flake class that made the REQUIRED Cloud control-plane gate
  lie (charter GR47).

  `Application.put_env/3` writes ONE value for the whole node. Inside an
  `async: true` module that is not a per-test stub — it is a global swap held for
  as long as the test (or its `describe` setup) runs, and every OTHER async test
  running at that instant reads it.

  The proven case: `sites_deploy_test.exs` swapped `:site_box_relay` to the real
  `BoxRelay.HTTP` so three tests could exercise the HTTP impl. While those three
  ran, `router_sites_test.exs` — a different async module, running concurrently —
  called `Sites.Deploy.run/1` and got the real relay instead of `FakeBoxRelay`.
  The relay talked to a fake transport nobody had programmed for it, so the
  deploy settled `{:ok, :failed}` and the test red. It reproduced at some seeds
  and not others, and not even reliably at the SAME seed (it is a race, not an
  ordering artifact), which is exactly the vacuous signal a required gate must
  never carry. The fix was to name the implementation module directly.

  `:site_box_relay` is guarded here because it is read from SEVERAL async modules
  (`sites_deploy_test`, `router_sites_test`, `site_cf_deploy_test`,
  `content_publish_receiver_test`), so any global swap of it is a live race by
  construction. Other config keys are swapped by async modules too, but each of
  those is read by only its own module today; if that ever changes, add the key
  to `@shared_seam_keys` rather than re-learning this the hard way.

  Test the real implementation by NAMING it (`BoxRelay.HTTP.rollback(...)`) — the
  dispatcher is a one-hop `impl().rollback(...)` with no logic of its own, so
  calling the impl directly tests strictly more, and isolates by construction.
  """
  use ExUnit.Case, async: true

  # Config keys that more than one async test module reads. A global swap of any
  # of these from an `async: true` module is a race, never a stub.
  @shared_seam_keys [":site_box_relay"]

  test "no async: true test module globally swaps a shared seam key" do
    offenders =
      "test/**/*_test.exs"
      |> Path.wildcard()
      |> Enum.reject(&(Path.basename(&1) == "async_global_seam_guard_test.exs"))
      |> Enum.map(&{&1, File.read!(&1)})
      |> Enum.filter(fn {_path, src} -> String.contains?(src, "async: true") end)
      |> Enum.flat_map(fn {path, src} ->
        for key <- @shared_seam_keys,
            String.contains?(src, "Application.put_env(:barkpark_cloud, #{key}"),
            do: {path, key}
      end)

    assert offenders == [],
           """
           An async: true module globally swaps a seam other async modules read:

           #{Enum.map_join(offenders, "\n", fn {path, key} -> "  #{path} — #{key}" end)}

           Application env is ONE value for the whole node, so this swap also
           applies to every test running concurrently — the order-dependent red
           on the required Cloud gate (GR47). Call the implementation module
           directly instead of swapping the dispatcher's config.
           """
  end
end
