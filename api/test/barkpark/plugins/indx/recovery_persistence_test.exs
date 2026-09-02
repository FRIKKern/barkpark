defmodule Barkpark.Plugins.Indx.RecoveryPersistenceTest do
  @moduledoc """
  Closes the loop on P4b Hardening B end-to-end: persist on swap →
  restart wipes :persistent_term → Recovery's load_all + restore_pointer
  re-seats the EXACT key_map → delete_target_keys finds the id without
  the bare-hash fallback.

  Every pointer here is addressed by an `Indexer.index_key/2` INDEX KEY, not
  by a bare dataset string — that is the argument type these functions take,
  and passing a raw scope now raises rather than sharing one slot between
  co-tenants.
  """
  use ExUnit.Case, async: false

  alias Barkpark.Plugins.Indx.{Indexer, Persistence}

  setup do
    dir =
      Path.join(System.tmp_dir!(), "indx-recovery-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    prev = Application.get_env(:barkpark, Persistence, [])
    Application.put_env(:barkpark, Persistence, dir: dir)

    # `wipe_pointer/1` below (and every `Indexer.swap/2` these tests run)
    # rewrites the Indexer's live_dataset pointer TABLE, a single
    # `:persistent_term` shared by every scope in the VM. It is global AND
    # UNOWNED — nothing tears it down between modules — so a scope this file
    # wipes stays wiped, and a scope it seeds stays seeded, for whatever ExUnit
    # shuffles in next. Capture the whole table and put it back.
    pointer_term = {Indexer, :live_dataset}
    prev_pointer = :persistent_term.get(pointer_term, :__absent__)

    on_exit(fn ->
      Application.put_env(:barkpark, Persistence, prev)
      File.rm_rf!(dir)

      # Erase when there was no prior table, so an absent key stays absent.
      case prev_pointer do
        :__absent__ -> :persistent_term.erase(pointer_term)
        table -> :persistent_term.put(pointer_term, table)
      end
    end)

    %{dir: dir}
  end

  test "swap persists the key_map to disk" do
    scope = Indexer.index_key("rp-#{System.unique_integer([:positive])}")

    Indexer.swap(scope, %{
      new_dataset: "bp_rp_v1",
      key_map: %{1 => "post-a", 2 => "post-b"}
    })

    assert {:ok, %{dataset: "bp_rp_v1", key_map: %{1 => "post-a", 2 => "post-b"}}} =
             Persistence.load(scope)
  end

  test "simulated restart: restore_pointer loads the persisted key_map" do
    scope = Indexer.index_key("rp-restore-#{System.unique_integer([:positive])}")

    # 1. Persist a state.
    Persistence.save(scope, %{dataset: "bp_rp_v2", key_map: %{42 => "doc-x"}})

    # 2. Simulate restart by wiping the in-memory pointer for this scope.
    wipe_pointer(scope)
    assert Indexer.current_dataset(scope) == nil
    assert Indexer.key_map(scope) == %{}

    # 3. Recovery would normally do this — restore_pointer reads from disk.
    assert :ok = Indexer.restore_pointer(scope, "bp_rp_v2")

    assert Indexer.current_dataset(scope) == "bp_rp_v2"
    assert Indexer.key_map(scope) == %{42 => "doc-x"}
  end

  test "restore_pointer drops a stale persisted key_map when the engine's dataset moved" do
    scope = Indexer.index_key("rp-drift-#{System.unique_integer([:positive])}")

    # Persisted under v2.
    Persistence.save(scope, %{dataset: "bp_rp_v2", key_map: %{99 => "stale"}})

    wipe_pointer(scope)

    # Engine reports v3 (rebuilt out-of-band while we were down).
    assert :ok = Indexer.restore_pointer(scope, "bp_rp_v3")

    # Pointer at v3, key_map dropped (next rebuild will repopulate).
    assert Indexer.current_dataset(scope) == "bp_rp_v3"
    assert Indexer.key_map(scope) == %{}
  end

  test "bare-hash fallback emits a telemetry signal so operators see it" do
    scope = Indexer.index_key("rp-bare-#{System.unique_integer([:positive])}")

    # No persisted state for this scope; restore an empty key_map.
    wipe_pointer(scope)
    Indexer.restore_pointer(scope, "bp_rp_v4")
    assert Indexer.key_map(scope) == %{}

    # Listen for the telemetry signal the fallback emits.
    test_pid = self()
    handler_id = "bare-hash-#{System.unique_integer([:positive])}"
    event = [:barkpark, :indx, :delete, :bare_hash_fallback]

    :telemetry.attach(
      handler_id,
      event,
      fn name, m, meta, _ -> send(test_pid, {:telemetry, name, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # delete_record will resolve target keys with an empty map; that triggers
    # the fallback. We don't care about the engine call here (it will return
    # an error against the unconfigured stub), only that the signal fires.
    _ = Indexer.delete_record(scope, "vanished-id", client: FakeIndxClient)

    assert_receive {:telemetry, ^event, %{count: 1}, %{index_key: ^scope, id: "vanished-id"}},
                   200
  end

  defp wipe_pointer(scope) do
    pointer_term = {Barkpark.Plugins.Indx.Indexer, :live_dataset}
    table = :persistent_term.get(pointer_term, %{}) |> Map.delete(scope)
    :persistent_term.put(pointer_term, table)
  end
end

defmodule FakeIndxClient do
  @moduledoc false
  # Minimal stub — the telemetry test only needs the bare-hash branch to fire,
  # which happens at delete_target_keys/2 BEFORE any client call. Returning
  # an error keeps the assertion focused.
  def delete_json_record(_dataset, _key, _opts), do: {:error, :fake_client}
  def get_status(_dataset, _opts), do: {:ok, %{}}
end
