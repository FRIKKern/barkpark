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
    def start, do: Agent.start_link(fn -> %{calls: [], delete: :ok, upsert: :ok} end)
    def set_agent(pid), do: Process.put(:fake_indexer_agent, pid)
    defp agent, do: Process.get(:fake_indexer_agent)
    def calls(pid), do: Agent.get(pid, & &1.calls) |> Enum.reverse()
    def set_delete(r), do: Agent.update(agent(), &Map.put(&1, :delete, r))
    def set_upsert(r), do: Agent.update(agent(), &Map.put(&1, :upsert, r))
    defp record(c), do: Agent.update(agent(), &%{&1 | calls: [c | &1.calls]})

    def delete_record(scope, id) do
      record({:delete_record, scope, id})
      Agent.get(agent(), & &1.delete)
    end

    def upsert_record(scope, doc) do
      record({:upsert_record, scope, doc})
      Agent.get(agent(), & &1.upsert)
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

  # Fake Content backed by the SAME agent the FakeIndexer uses, so the
  # upsert branch's single-doc fetch is observable + controllable. The
  # canned get_document result is keyed by the doc_id; default :not_found.
  defmodule FakeContent do
    defp agent, do: Process.get(:fake_indexer_agent)
    def set_doc(id, result), do: Agent.update(agent(), &put_in(&1, [Access.key(:docs, %{}), id], result))

    def get_document(doc_id, type, dataset) do
      Agent.update(agent(), fn s ->
        %{s | calls: [{:get_document, doc_id, type, dataset} | s.calls]}
      end)

      Agent.get(agent(), fn s -> get_in(s, [Access.key(:docs, %{}), doc_id]) end) ||
        {:error, :not_found}
    end
  end

  setup do
    {:ok, pid} = FakeIndexer.start()
    FakeIndexer.set_agent(pid)
    {:ok, pid: pid}
  end

  defp run(args) do
    IndexerWorker.perform(%Oban.Job{
      args:
        args
        |> Map.put("indexer", "Barkpark.Plugins.Indx.IndexerWorkerTest.FakeIndexer")
        |> Map.put("content", "Barkpark.Plugins.Indx.IndexerWorkerTest.FakeContent")
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

  describe "upsert op" do
    test "fetches the single doc by _id and delegates to Indexer.upsert_record", %{pid: pid} do
      FakeContent.set_doc("p1", {:ok, %{"_id" => "p1", "_type" => "post", "title" => "Alpha"}})
      FakeIndexer.set_upsert(:ok)

      assert :ok =
               run(%{"op" => "upsert", "scope" => "production", "_id" => "p1", "types" => ["post"]})

      calls = FakeIndexer.calls(pid)
      # The single-doc fetch ran with (id, type, scope) — NOT a corpus list.
      assert {:get_document, "p1", "post", "production"} in calls
      assert Enum.any?(calls, &match?({:upsert_record, "production", %{"_id" => "p1"}}, &1))
      # A plain :ok upsert must NOT trigger a rebuild.
      refute Enum.any?(calls, &match?({:rebuild, _, _}, &1))
    end

    test "reindex_required falls back to a full rebuild", %{pid: pid} do
      FakeContent.set_doc("p1", {:ok, %{"_id" => "p1", "_type" => "post"}})
      FakeIndexer.set_upsert({:reindex_required, %{"reIndexRequired" => true}})

      assert :ok =
               run(%{"op" => "upsert", "scope" => "production", "_id" => "p1", "types" => ["post"]})

      calls = FakeIndexer.calls(pid)
      assert Enum.any?(calls, &match?({:upsert_record, "production", _}, &1))
      assert Enum.any?(calls, &match?({:rebuild, "production", _}, &1))
      assert {:swap, "production"} in calls
    end

    test "a doc that no longer exists in Barkpark cancels (:doc_gone)", %{pid: pid} do
      # No FakeContent.set_doc → get_document returns {:error, :not_found}.
      assert {:cancel, :doc_gone} =
               run(%{"op" => "upsert", "scope" => "production", "_id" => "gone", "types" => ["post"]})

      # Never reached upsert_record / rebuild for a vanished doc.
      refute Enum.any?(FakeIndexer.calls(pid), &match?({:upsert_record, _, _}, &1))
      refute Enum.any?(FakeIndexer.calls(pid), &match?({:rebuild, _, _}, &1))
    end

    test "a transient 5xx upsert error surfaces as {:error, _} (Oban backoff)" do
      alias Barkpark.Plugins.Indx.Errors.IndexError
      FakeContent.set_doc("p1", {:ok, %{"_id" => "p1", "_type" => "post"}})
      FakeIndexer.set_upsert({:error, %IndexError{status: 500, endpoint: "x"}})

      assert {:error, %IndexError{status: 500}} =
               run(%{"op" => "upsert", "scope" => "production", "_id" => "p1", "types" => ["post"]})
    end

    test "no-live-dataset falls back to a full REBUILD (post-restart self-heal), not cancel", %{
      pid: pid
    } do
      alias Barkpark.Plugins.Indx.Errors.IndexError
      FakeContent.set_doc("p1", {:ok, %{"_id" => "p1", "_type" => "post"}})

      # The exact error shape upsert_record/3 returns when boot-recovery
      # hadn't seated the live pointer yet (Indx down at boot / first edit
      # before recovery ran). For UPSERT — unlike DELETE — this must REBUILD
      # the scope, establishing the pointer + key_map + corpus, so the index
      # self-heals on the first edit after a restart.
      FakeIndexer.set_upsert(
        {:error,
         %IndexError{
           status: 0,
           endpoint: nil,
           message: "Indx.Indexer: no live dataset for scope production — nothing to upsert"
         }}
      )

      assert :ok =
               run(%{"op" => "upsert", "scope" => "production", "_id" => "p1", "types" => ["post"]})

      calls = FakeIndexer.calls(pid)
      assert Enum.any?(calls, &match?({:upsert_record, "production", _}, &1))
      # The fallback ran the blue/green rebuild + swap for the scope — NOT a cancel.
      assert Enum.any?(calls, &match?({:rebuild, "production", _}, &1))
      assert {:swap, "production"} in calls
    end

    test "missing _id cancels" do
      assert {:cancel, :missing_id} = run(%{"op" => "upsert", "scope" => "production"})
    end

    test "no resolvable type cancels (:no_type_for_upsert)" do
      assert {:cancel, :no_type_for_upsert} =
               run(%{"op" => "upsert", "scope" => "production", "_id" => "p1", "types" => []})
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
