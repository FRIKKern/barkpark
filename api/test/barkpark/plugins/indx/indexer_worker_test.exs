defmodule Barkpark.Plugins.Indx.IndexerWorkerTest do
  @moduledoc """
  Op-branching proof for `Indx.IndexerWorker.perform/1`:

    * `"op" => "delete"` → `Indexer.delete_record/3`; `:ok` succeeds,
      `{:reindex_required, _}` falls back to a full rebuild.
    * `"op" => "rebuild"` (default) → the blue/green rebuild path.
    * missing scope / missing id / empty types → `{:cancel, _}`.

  The worker resolves its indexer module from an optional `"indexer"` arg
  (defaulting to the real `Indexer`); these tests inject a fake module that
  records calls, so no live Indx engine is needed.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Plugins.Indx.IndexerWorker

  # Fake indexer recording every call, with per-test canned delete results.
  # Uses the process dictionary via a named Agent so the worker (same
  # process under perform_job/inline) sees the same knobs.
  defmodule FakeIndexer do
    def start, do: Agent.start_link(fn -> %{calls: [], delete: :ok} end)
    def set_agent(pid), do: Process.put(:fake_indexer_agent, pid)
    defp agent, do: Process.get(:fake_indexer_agent)
    def calls(pid), do: Agent.get(pid, & &1.calls) |> Enum.reverse()
    def set_delete(r), do: Agent.update(agent(), &Map.put(&1, :delete, r))
    defp record(c), do: Agent.update(agent(), &%{&1 | calls: [c | &1.calls]})

    def delete_record(scope, id) do
      record({:delete_record, scope, id})
      Agent.get(agent(), & &1.delete)
    end

    def rebuild(scope, docs) do
      record({:rebuild, scope, docs})
      {:ok, %{new_dataset: "bp_#{scope}_v9", old_dataset: nil, count: length(docs), key_map: %{}}}
    end

    def swap(scope, _result) do
      record({:swap, scope})
      nil
    end

    def delete_dataset(ds, _opts) do
      record({:delete_dataset, ds})
      :ok
    end
  end

  setup do
    {:ok, pid} = FakeIndexer.start()
    FakeIndexer.set_agent(pid)
    {:ok, pid: pid}
  end

  defp run(args) do
    IndexerWorker.perform(%Oban.Job{
      args: Map.put(args, "indexer", "Barkpark.Plugins.Indx.IndexerWorkerTest.FakeIndexer")
    })
  end

  describe "delete op" do
    test "delegates to Indexer.delete_record and succeeds on :ok", %{pid: pid} do
      FakeIndexer.set_delete(:ok)

      assert :ok = run(%{"op" => "delete", "scope" => "production", "_id" => "p1"})

      assert {:delete_record, "production", "p1"} in FakeIndexer.calls(pid)
      # A plain :ok delete must NOT trigger a rebuild.
      refute Enum.any?(FakeIndexer.calls(pid), &match?({:rebuild, _, _}, &1))
    end

    test "reindex_required falls back to a full rebuild", %{pid: pid} do
      FakeIndexer.set_delete({:reindex_required, %{"reIndexRequired" => true}})

      assert :ok =
               run(%{
                 "op" => "delete",
                 "scope" => "production",
                 "_id" => "p1",
                 "types" => ["post"]
               })

      calls = FakeIndexer.calls(pid)
      assert {:delete_record, "production", "p1"} in calls
      # The fallback ran the blue/green rebuild + swap for the scope.
      assert Enum.any?(calls, &match?({:rebuild, "production", _}, &1))
      assert {:swap, "production"} in calls
    end

    test "reindex_required with no types cannot rebuild → cancel" do
      FakeIndexer.set_delete({:reindex_required, %{}})

      assert {:cancel, :no_types_for_reindex_fallback} =
               run(%{"op" => "delete", "scope" => "production", "_id" => "p1"})
    end

    test "a transient 5xx delete error surfaces as {:error, _} (Oban backoff)" do
      alias Barkpark.Plugins.Indx.Errors.IndexError
      FakeIndexer.set_delete({:error, %IndexError{status: 500, endpoint: "x"}})

      assert {:error, %IndexError{status: 500}} =
               run(%{"op" => "delete", "scope" => "production", "_id" => "p1"})
    end

    test "no-live-dataset is PERMANENT → {:cancel, :no_live_dataset}, no rebuild", %{pid: pid} do
      alias Barkpark.Plugins.Indx.Errors.IndexError

      # The exact error shape delete_record/3 returns when the scope has no
      # live pointer (matched by the "no live dataset" message substring).
      FakeIndexer.set_delete(
        {:error,
         %IndexError{
           status: 0,
           endpoint: nil,
           message: "Indx.Indexer: no live dataset for scope production — nothing to delete"
         }}
      )

      result =
        run(%{"op" => "delete", "scope" => "production", "_id" => "p1", "types" => ["post"]})

      # PERMANENT: cancelled, NOT {:error} (which would burn Oban attempts).
      assert {:cancel, :no_live_dataset} = result

      calls = FakeIndexer.calls(pid)
      assert {:delete_record, "production", "p1"} in calls
      # A future rebuild establishes the index minus the deleted doc — this
      # job must NOT enqueue/run a rebuild itself.
      refute Enum.any?(calls, &match?({:rebuild, _, _}, &1))
    end

    test "404 from the delete endpoint is PERMANENT → {:cancel, :delete_endpoint_unavailable}",
         %{pid: pid} do
      alias Barkpark.Plugins.Indx.Errors.IndexError

      # The C# DeleteJsonRecord action is not deployed yet → 404.
      FakeIndexer.set_delete(
        {:error, %IndexError{status: 404, endpoint: "/api/DeleteJsonRecord/ds/123"}}
      )

      result =
        run(%{"op" => "delete", "scope" => "production", "_id" => "p1", "types" => ["post"]})

      assert {:cancel, :delete_endpoint_unavailable} = result
      # Retrying a missing endpoint is pointless — no rebuild fallback either.
      refute Enum.any?(FakeIndexer.calls(pid), &match?({:rebuild, _, _}, &1))
    end

    test "NetworkError (Indx unreachable) is TRANSIENT → {:snooze, _}" do
      alias Barkpark.Plugins.Indx.Errors.NetworkError
      FakeIndexer.set_delete({:error, %NetworkError{reason: :econnrefused, endpoint: "x"}})

      assert {:snooze, n} =
               run(%{"op" => "delete", "scope" => "production", "_id" => "p1"})

      assert is_integer(n) and n > 0
    end

    test "missing _id cancels" do
      assert {:cancel, :missing_id} = run(%{"op" => "delete", "scope" => "production"})
    end
  end

  describe "rebuild op" do
    test "default op (no op key) runs the rebuild path", %{pid: pid} do
      assert :ok = run(%{"scope" => "production", "types" => ["post"]})

      calls = FakeIndexer.calls(pid)
      assert Enum.any?(calls, &match?({:rebuild, "production", _}, &1))
      assert {:swap, "production"} in calls
    end

    test "explicit rebuild op with empty types cancels" do
      assert {:cancel, :no_types} = run(%{"op" => "rebuild", "scope" => "production", "types" => []})
    end
  end

  test "missing scope cancels" do
    assert {:cancel, :missing_scope} = run(%{"op" => "delete", "_id" => "p1"})
  end
end
