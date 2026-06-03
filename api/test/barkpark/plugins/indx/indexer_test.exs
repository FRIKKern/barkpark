defmodule Barkpark.Plugins.Indx.IndexerTest do
  @moduledoc """
  Blue/green rebuild semantics for `Barkpark.Plugins.Indx.Indexer`,
  exercised through an injected fake client that records every call. No
  live Indx required.

  The two load-bearing guarantees:

    * a rebuild loads the FULL corpus into a FRESH `<prefix>_<scope>_v<n>`
      dataset (never an existing one), and
    * it returns the new dataset to swap to plus the old dataset to delete,
      and NEVER re-loads a dataset it has already loaded.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Plugins.Indx.Indexer

  # Fake client backed by an Agent that records the ordered call log and
  # answers status/count from canned values. Matches the `Indx.Client`
  # verb signatures the Indexer calls.
  defmodule FakeClient do
    def start do
      # `loaded` tracks the record count of the LAST load_string per dataset
      # so get_number_of_json_records always reports the count the indexer
      # actually loaded — no spurious count-mismatch warning.
      Agent.start_link(fn -> %{calls: [], loaded: %{}} end)
    end

    def set_agent(pid), do: Process.put(:fake_client_agent, pid)
    defp agent, do: Process.get(:fake_client_agent)

    def calls(pid), do: Agent.get(pid, & &1.calls) |> Enum.reverse()

    defp record(call), do: Agent.update(agent(), &%{&1 | calls: [call | &1.calls]})

    def create_or_open(ds, _opts), do: record({:create_or_open, ds}) && :ok
    def analyze_string(ds, records, _opts), do: record({:analyze, ds, records}) && :ok
    def set_searchable_fields(ds, fields, _opts), do: record({:set_fields, ds, fields}) && :ok

    def load_string(ds, records, _opts) do
      record({:load_string, ds, records})
      Agent.update(agent(), fn s -> %{s | loaded: Map.put(s.loaded, ds, length(records))} end)
      :ok
    end

    def index_dataset(ds, _opts), do: record({:index, ds}) && :ok

    def get_status(ds, _opts) do
      record({:status, ds})
      {:ok, Agent.get(agent(), fn s -> Map.get(s, :status, %{"status" => "ready"}) end)}
    end

    def get_number_of_json_records(ds, _opts) do
      record({:count, ds})
      {:ok, Agent.get(agent(), fn s -> Map.get(s.loaded, ds, 0) end)}
    end

    def delete_dataset(ds, _opts), do: record({:delete, ds}) && :ok

    def delete_json_record(ds, id, _opts) do
      record({:delete_json, ds, id})
      Agent.get(agent(), fn s -> Map.get(s, :delete_result, :ok) end)
    end

    # Test knobs: override the status get_status/2 returns, and the result
    # delete_json_record/3 returns.
    def set_status(status), do: Agent.update(agent(), &Map.put(&1, :status, status))
    def set_delete_result(r), do: Agent.update(agent(), &Map.put(&1, :delete_result, r))
  end

  setup do
    {:ok, pid} = FakeClient.start()
    FakeClient.set_agent(pid)
    # Each test runs in a clean scope so the persistent_term pointer never
    # leaks between tests.
    scope = "production_#{System.unique_integer([:positive])}"
    {:ok, pid: pid, scope: scope}
  end

  test "rebuild creates a fresh v1 dataset and loads the full corpus", %{pid: pid, scope: scope} do
    docs = [%{"_id" => "p1", "title" => "Alpha"}, %{"_id" => "p2", "title" => "Beta"}]

    assert {:ok, result} =
             Indexer.rebuild(scope, docs, client: FakeClient, poll_interval_ms: 0)

    # First-ever rebuild → v1, no prior dataset to delete.
    assert result.new_dataset =~ ~r/_v1$/
    assert result.old_dataset == nil
    assert result.count == 2

    calls = FakeClient.calls(pid)
    new = result.new_dataset

    # Order: create_or_open → analyze → set_fields → load_string → index →
    # status → count. AnalyzeString MUST precede SetSearchableFields — it is
    # what populates DocumentFields; SetSearchableFields 400s without it.
    assert [
             {:create_or_open, ^new},
             {:analyze, ^new, analyzed},
             {:set_fields, ^new, _},
             {:load_string, ^new, records},
             {:index, ^new} | _rest
           ] = calls

    # Analyze receives the SAME rendered corpus that load_string does.
    assert analyzed == records

    # The loaded corpus carries the embedded "_id" AND a STABLE numeric "id"
    # derived from the _id (not the old 1-based position) — so the same _id
    # always gets the same key and the delete path can recompute it.
    assert [
             %{"id" => k1, "_id" => "p1", "title" => "Alpha"},
             %{"id" => k2, "_id" => "p2", "title" => "Beta"}
           ] = records

    assert k1 == Indexer.key_for_id("p1")
    assert k2 == Indexer.key_for_id("p2")
    assert is_integer(k1) and k1 > 0
    assert k1 != k2
  end

  test "rebuild after a swap bumps to v2 and never re-loads the live dataset", %{
    pid: pid,
    scope: scope
  } do
    docs1 = [%{"_id" => "p1", "title" => "Alpha"}]
    {:ok, r1} = Indexer.rebuild(scope, docs1, client: FakeClient, poll_interval_ms: 0)
    old = Indexer.swap(scope, r1)
    assert old == nil
    assert Indexer.current_dataset(scope) == r1.new_dataset

    # Second rebuild: must target a DIFFERENT (fresh) dataset name.
    docs2 = [%{"_id" => "p1", "title" => "Alpha"}, %{"_id" => "p2", "title" => "Beta"}]
    {:ok, r2} = Indexer.rebuild(scope, docs2, client: FakeClient, poll_interval_ms: 0)

    assert r2.new_dataset != r1.new_dataset
    assert r2.new_dataset =~ ~r/_v2$/
    assert r2.old_dataset == r1.new_dataset

    # CRITICAL never-re-load invariant: each dataset is loaded AT MOST ONCE,
    # and only into its OWN fresh dataset. v1 was loaded during r1's rebuild
    # (before it went live); r2 loads v2 and must NOT touch the now-live v1.
    load_targets =
      FakeClient.calls(pid)
      |> Enum.filter(&match?({:load_string, _, _}, &1))
      |> Enum.map(fn {:load_string, ds, _} -> ds end)

    assert load_targets == [r1.new_dataset, r2.new_dataset]
    # No dataset appears in the load log twice → no live dataset re-load.
    assert load_targets == Enum.uniq(load_targets)
  end

  test "swap returns the previous live dataset for the caller to delete", %{
    scope: scope
  } do
    {:ok, r1} = Indexer.rebuild(scope, [%{"_id" => "p1"}], client: FakeClient, poll_interval_ms: 0)
    nil = Indexer.swap(scope, r1)

    {:ok, r2} =
      Indexer.rebuild(scope, [%{"_id" => "p1"}], client: FakeClient, poll_interval_ms: 0)

    # The swap of r2 hands back r1's dataset as the one to delete.
    assert Indexer.swap(scope, r2) == r1.new_dataset
    assert Indexer.current_dataset(scope) == r2.new_dataset
  end

  test "rebuild surfaces a client error and does not swap", %{scope: scope} do
    defmodule FailClient do
      alias Barkpark.Plugins.Indx.Errors.IndexError

      def create_or_open(ds, _opts),
        do: {:error, %IndexError{status: 500, endpoint: ds, message: "boom"}}
    end

    assert {:error, %Barkpark.Plugins.Indx.Errors.IndexError{}} =
             Indexer.rebuild(scope, [%{"_id" => "p1"}], client: FailClient, poll_interval_ms: 0)

    # Nothing got swapped in — the scope has no live dataset.
    assert Indexer.current_dataset(scope) == nil
  end

  # ── Stable key map ─────────────────────────────────────────────────────────

  describe "key_for_id/1 + render_corpus stable key map" do
    test "the same _id maps to the same key across two independent rebuilds", %{scope: scope} do
      docs = [%{"_id" => "p1", "title" => "Alpha"}, %{"_id" => "p2", "title" => "Beta"}]

      {:ok, r1} = Indexer.rebuild(scope, docs, client: FakeClient, poll_interval_ms: 0)
      # A second, independent rebuild of the SAME corpus must produce the
      # SAME key for each _id — no position dependence.
      {:ok, r2} = Indexer.rebuild(scope, docs, client: FakeClient, poll_interval_ms: 0)

      # Invert each map to _id => key and compare.
      to_id_key = fn kmap -> Map.new(kmap, fn {k, id} -> {id, k} end) end
      assert to_id_key.(r1.key_map) == to_id_key.(r2.key_map)
    end

    test "key is recomputable from _id alone via key_for_id/1 (matches the embedded key)", %{
      scope: scope
    } do
      docs = [%{"_id" => "drafts.kubernetes", "title" => "K8s"}]
      {:ok, r} = Indexer.rebuild(scope, docs, client: FakeClient, poll_interval_ms: 0)

      [{embedded_key, "drafts.kubernetes"}] = Map.to_list(r.key_map)
      # The delete path recomputes the key from the _id with no corpus
      # context — for a collision-free corpus it equals the embedded key.
      assert Indexer.key_for_id("drafts.kubernetes") == embedded_key
    end

    test "keys are positive 63-bit ints and injective within a corpus", %{scope: scope} do
      docs = for n <- 1..200, do: %{"_id" => "doc_#{n}", "title" => "T#{n}"}
      {:ok, r} = Indexer.rebuild(scope, docs, client: FakeClient, poll_interval_ms: 0)

      keys = Map.keys(r.key_map)
      assert length(keys) == 200
      # Injective: one key per _id, no two _ids share a key.
      assert length(Enum.uniq(keys)) == 200
      # Positive, inside the signed-int64 band.
      assert Enum.all?(keys, fn k -> is_integer(k) and k > 0 and k <= 0x7FFFFFFFFFFFFFFF end)
    end

    test "an in-corpus collision is probed to a distinct key (set stays injective)", %{
      scope: scope
    } do
      # Force a collision: two docs whose bare key_for_id collide because we
      # pre-seed the probe set. We cannot easily synthesize a real SHA-256
      # collision, so prove the probe invariant directly: feeding two docs
      # with the SAME _id (degenerate collision) yields two DISTINCT keys.
      docs = [%{"_id" => "dup", "title" => "A"}, %{"_id" => "dup", "title" => "B"}]
      {:ok, r} = Indexer.rebuild(scope, docs, client: FakeClient, poll_interval_ms: 0)

      keys = Map.keys(r.key_map)
      # Two records loaded, two DISTINCT keys (second probed to base+1),
      # even though both share an _id — the key set is injective by key.
      assert length(keys) == 2
      base = Indexer.key_for_id("dup")
      assert base in keys
      assert(base + 1 in keys or rem(base + 1, 0x7FFFFFFFFFFFFFFF) in keys)
    end
  end

  # ── Incremental per-document delete ─────────────────────────────────────────

  describe "delete_record/3" do
    setup %{scope: scope} = ctx do
      # Establish a live dataset so delete has something to target.
      {:ok, r} =
        Indexer.rebuild(scope, [%{"_id" => "p1"}, %{"_id" => "p2"}],
          client: FakeClient,
          poll_interval_ms: 0
        )

      Indexer.swap(scope, r)
      Map.put(ctx, :dataset, r.new_dataset)
    end

    test "happy path: DELETEs the stable key from the live dataset, no reindex", %{
      pid: pid,
      scope: scope,
      dataset: dataset
    } do
      FakeClient.set_status(%{"reIndexRequired" => false, "status" => "ready"})

      assert :ok = Indexer.delete_record(scope, "p1", client: FakeClient)

      # The delete targeted the LIVE dataset and the stable key for "p1".
      expected_key = Indexer.key_for_id("p1")

      assert {:delete_json, ^dataset, ^expected_key} =
               FakeClient.calls(pid)
               |> Enum.find(&match?({:delete_json, _, _}, &1))

      # delete_record must NOT swap the pointer — the dataset is unchanged.
      assert Indexer.current_dataset(scope) == dataset
    end

    test "reindex-required: returns {:reindex_required, status}", %{scope: scope} do
      FakeClient.set_status(%{"reIndexRequired" => true})

      assert {:reindex_required, %{"reIndexRequired" => true}} =
               Indexer.delete_record(scope, "p1", client: FakeClient)
    end

    test "surfaces a client delete error", %{scope: scope} do
      alias Barkpark.Plugins.Indx.Errors.IndexError
      FakeClient.set_delete_result({:error, %IndexError{status: 500, endpoint: "x"}})

      assert {:error, %IndexError{status: 500}} =
               Indexer.delete_record(scope, "p1", client: FakeClient)
    end
  end

  test "delete_record with no live dataset returns an error (nothing to delete)" do
    # A pristine scope that never had a rebuild → no live dataset.
    scope = "neverbuilt_#{System.unique_integer([:positive])}"

    assert {:error, %Barkpark.Plugins.Indx.Errors.IndexError{message: msg}} =
             Indexer.delete_record(scope, "p1", client: FakeClient)

    assert msg =~ "no live dataset"
  end
end
