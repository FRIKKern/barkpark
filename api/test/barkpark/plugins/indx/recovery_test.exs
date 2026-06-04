defmodule Barkpark.Plugins.Indx.RecoveryTest do
  @moduledoc """
  Boot-time live-pointer recovery for `Barkpark.Plugins.Indx.Recovery`.

  The `:persistent_term` live pointer is wiped on every Barkpark restart, so
  with `incremental_upsert` ON a restart leaves `current_dataset(scope) ==
  nil`. `Recovery.recover/1` rediscovers the live `<prefix>_<scope>_v<n>`
  datasets from `Client.get_user_datasets/1` and re-seats the pointers.

  Tests exercise `recover/1` directly with an injected fake client — a unit
  test of the recovery function, no live GenServer needed (the GenServer is
  separately wired into `register_workers/1`, asserted in
  `seam_dispatch_test.exs`). Each test uses a UNIQUE scope so the shared
  `:persistent_term` pointer never leaks between tests.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Plugins.Indx.{Indexer, Recovery}
  alias Barkpark.Plugins.Indx.Errors.NetworkError

  # Fake client returning a canned get_user_datasets result. Backed by the
  # process dictionary so the (synchronous) recover/1 call sees it.
  defmodule FakeClient do
    def set_datasets(result), do: Process.put(:fake_datasets, result)
    def get_user_datasets(_opts), do: Process.get(:fake_datasets, {:ok, []})
  end

  test "parses datasets and restores the LATEST version per scope" do
    s1 = "production_#{System.unique_integer([:positive])}"
    s2 = "staging_#{System.unique_integer([:positive])}"

    # Two scopes, each with multiple versions out of order; pick MAX n.
    FakeClient.set_datasets(
      {:ok,
       [
         "bp_#{s1}_v1",
         "bp_#{s1}_v3",
         "bp_#{s1}_v2",
         "bp_#{s2}_v5",
         "bp_#{s2}_v1",
         # Noise that must NOT match the <prefix>_<scope>_v<n> shape.
         "unrelated_dataset",
         "bp_no_version_suffix"
       ]}
    )

    assert :ok = Recovery.recover(client: FakeClient)

    assert Indexer.current_dataset(s1) == "bp_#{s1}_v3"
    assert Indexer.current_dataset(s2) == "bp_#{s2}_v5"
    # Restored pointers carry an EMPTY key_map (rebuilt lazily on upsert).
    assert Indexer.key_map(s1) == %{}
    assert Indexer.key_map(s2) == %{}
  end

  test "does NOT clobber a scope whose pointer a rebuild already set" do
    scope = "production_#{System.unique_integer([:positive])}"

    # Simulate a rebuild that ran BEFORE recovery (the always-on race):
    # the live pointer already names v9.
    Indexer.swap(scope, %{new_dataset: "bp_#{scope}_v9", key_map: %{42 => "p1"}})

    # Recovery sees an older v2 on the engine but must NOT overwrite v9.
    FakeClient.set_datasets({:ok, ["bp_#{scope}_v2"]})
    assert :ok = Recovery.recover(client: FakeClient)

    assert Indexer.current_dataset(scope) == "bp_#{scope}_v9"
    # The live key_map survived too — recovery left the entry untouched.
    assert Indexer.key_map(scope) == %{42 => "p1"}
  end

  test "no-ops on a client error (Indx down / unconfigured)" do
    scope = "production_#{System.unique_integer([:positive])}"
    FakeClient.set_datasets({:error, %NetworkError{reason: :econnrefused, endpoint: "x"}})

    assert :ok = Recovery.recover(client: FakeClient)
    # No pointer was seated — the upsert rebuild-fallback is the backstop.
    assert Indexer.current_dataset(scope) == nil
  end

  test "an empty dataset list is a clean no-op" do
    scope = "production_#{System.unique_integer([:positive])}"
    FakeClient.set_datasets({:ok, []})

    assert :ok = Recovery.recover(client: FakeClient)
    assert Indexer.current_dataset(scope) == nil
  end
end
