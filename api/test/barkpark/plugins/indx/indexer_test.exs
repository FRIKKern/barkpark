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

    def set_field_configuration(ds, fields, _opts),
      do: record({:set_field_config, ds, fields}) && :ok

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

    def insert_json_record(ds, key, rec, _opts) do
      record({:insert_json, ds, key, rec})
      Agent.get(agent(), fn s -> Map.get(s, :write_result, :ok) end)
    end

    def update_json_record(ds, key, rec, _opts) do
      record({:update_json, ds, key, rec})
      Agent.get(agent(), fn s -> Map.get(s, :write_result, :ok) end)
    end

    # Existence-probe verb used by upsert_record/3 when the _id is NOT in
    # the stored key_map (the empty-key_map / post-restart path). Default
    # {:ok, []} → "record absent" → INSERT. set_get_json/1 overrides it.
    def get_json(ds, keys, _opts) do
      record({:get_json, ds, keys})
      Agent.get(agent(), fn s -> Map.get(s, :get_json_result, {:ok, []}) end)
    end

    # Test knobs: override the status get_status/2 returns, the result
    # delete_json_record/3 returns, the result insert/update return, and the
    # result the get_json existence probe returns.
    def set_status(status), do: Agent.update(agent(), &Map.put(&1, :status, status))
    def set_delete_result(r), do: Agent.update(agent(), &Map.put(&1, :delete_result, r))
    def set_write_result(r), do: Agent.update(agent(), &Map.put(&1, :write_result, r))
    def set_get_json(r), do: Agent.update(agent(), &Map.put(&1, :get_json_result, r))
  end

  setup do
    {:ok, pid} = FakeClient.start()
    FakeClient.set_agent(pid)
    # Each test runs in a clean scope so the persistent_term pointer never
    # leaks between tests.
    scope = "production_#{System.unique_integer([:positive])}"
    {:ok, pid: pid, scope: scope}
  end

  # Flip the live pointer for `scope` to `dataset` carrying a hand-built
  # key_map — lets a test stage a PROBE-DISPLACED or pathological map shape
  # without synthesizing a real SHA-256 collision. swap/2 reads :new_dataset
  # and :key_map, the same fields rebuild/3 returns.
  defp swap_with_key_map(scope, dataset, key_map) do
    Indexer.swap(scope, %{new_dataset: dataset, key_map: key_map})
  end

  # The key the stored map currently holds for `id` in `scope`.
  defp map_key_for(scope, id) do
    scope
    |> Indexer.key_map()
    |> Enum.find_value(fn {key, mapped} -> if mapped == id, do: key end)
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

    # Order: create_or_open → analyze → set_field_config → load_string →
    # index → status → count. AnalyzeString MUST precede
    # SetFieldConfiguration — it is what populates DocumentFields, and the
    # v5 rebuild uses SetFieldConfiguration (the deprecated Set*Fields path
    # stores EMPTY docs on v5).
    assert [
             {:create_or_open, ^new},
             {:analyze, ^new, analyzed},
             {:set_field_config, ^new, field_proxies},
             {:load_string, ^new, records},
             {:index, ^new} | _rest
           ] = calls

    # The "title" FieldProxy is searchable with word-level indexing at the
    # configured HIGH weight (Settings default for title).
    title_proxy = Enum.find(field_proxies, &(&1["fieldName"] == "title"))
    assert title_proxy["searchable"] == true
    assert title_proxy["wordIndexing"] == true
    assert title_proxy["weight"] == Barkpark.Plugins.Indx.Settings.get().weight_high

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

    test "happy path: DELETEs the natural key (the one the map holds), no reindex", %{
      pid: pid,
      scope: scope,
      dataset: dataset
    } do
      FakeClient.set_status(%{"reIndexRequired" => false, "status" => "ready"})

      # In a collision-free corpus the stored key_map's key for "p1" IS the
      # natural key_for_id("p1") — resolving from the map and recomputing
      # the bare hash agree.
      assert :ok = Indexer.delete_record(scope, "p1", client: FakeClient)

      expected_key = Indexer.key_for_id("p1")
      assert expected_key == map_key_for(scope, "p1")

      assert {:delete_json, ^dataset, ^expected_key} =
               FakeClient.calls(pid)
               |> Enum.find(&match?({:delete_json, _, _}, &1))

      # delete_record must NOT swap the pointer — the dataset is unchanged.
      assert Indexer.current_dataset(scope) == dataset
    end

    test "PROBE-DISPLACED _id: deletes the stored (probed) key, NOT key_for_id/1", %{
      pid: pid,
      scope: scope,
      dataset: dataset
    } do
      FakeClient.set_status(%{"reIndexRequired" => false, "status" => "ready"})

      # Simulate an in-corpus collision outcome: "p1" was displaced by the
      # probe, so its stored key is key_for_id("p1") + 1, NOT the bare hash.
      base = Indexer.key_for_id("p1")
      probed = base + 1
      swap_with_key_map(scope, dataset, %{probed => "p1"})

      assert :ok = Indexer.delete_record(scope, "p1", client: FakeClient)

      deleted_keys =
        FakeClient.calls(pid)
        |> Enum.filter(&match?({:delete_json, ^dataset, _}, &1))
        |> Enum.map(fn {:delete_json, _ds, key} -> key end)

      # The probed key was deleted; the bare key_for_id (the WRONG target for
      # a displaced _id) was NOT.
      assert deleted_keys == [probed]
      refute base in deleted_keys
    end

    test "_id ABSENT from the stored map falls back to key_for_id/1", %{
      pid: pid,
      scope: scope,
      dataset: dataset
    } do
      FakeClient.set_status(%{"reIndexRequired" => false, "status" => "ready"})

      # Stored map knows only "p2"; deleting "p1" must fall back to the bare
      # key_for_id("p1") because it is not in the map.
      swap_with_key_map(scope, dataset, %{Indexer.key_for_id("p2") => "p2"})

      assert :ok = Indexer.delete_record(scope, "p1", client: FakeClient)

      expected = Indexer.key_for_id("p1")

      deleted_keys =
        FakeClient.calls(pid)
        |> Enum.filter(&match?({:delete_json, ^dataset, _}, &1))
        |> Enum.map(fn {:delete_json, _ds, key} -> key end)

      assert deleted_keys == [expected]
    end

    test "multiple keys mapping to one _id (pathological) → all deleted", %{
      pid: pid,
      scope: scope,
      dataset: dataset
    } do
      FakeClient.set_status(%{"reIndexRequired" => false, "status" => "ready"})

      base = Indexer.key_for_id("p1")
      k_a = base
      k_b = base + 1
      k_c = base + 2
      swap_with_key_map(scope, dataset, %{k_a => "p1", k_b => "p1", k_c => "p1"})

      assert :ok = Indexer.delete_record(scope, "p1", client: FakeClient)

      deleted_keys =
        FakeClient.calls(pid)
        |> Enum.filter(&match?({:delete_json, ^dataset, _}, &1))
        |> Enum.map(fn {:delete_json, _ds, key} -> key end)
        |> Enum.sort()

      assert deleted_keys == Enum.sort([k_a, k_b, k_c])
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

  # ── Incremental per-document upsert ─────────────────────────────────────────

  describe "upsert_record/3" do
    setup %{scope: scope} = ctx do
      # Establish a live dataset whose key_map holds "p1" only — so upserting
      # "p1" takes the UPDATE branch and a NEW _id takes the INSERT branch.
      {:ok, r} =
        Indexer.rebuild(scope, [%{"_id" => "p1", "title" => "Alpha"}],
          client: FakeClient,
          poll_interval_ms: 0
        )

      Indexer.swap(scope, r)
      Map.put(ctx, :dataset, r.new_dataset)
    end

    test "INSERT branch: _id ABSENT from the key_map calls insert_json_record", %{
      pid: pid,
      scope: scope,
      dataset: dataset
    } do
      FakeClient.set_status(%{"reIndexRequired" => false, "status" => "ready"})

      # "p2" is NOT in the stored key_map (only "p1" is) → INSERT.
      assert :ok =
               Indexer.upsert_record(scope, %{"_id" => "p2", "title" => "Beta"},
                 client: FakeClient
               )

      key = Indexer.key_for_id("p2")

      assert {:insert_json, ^dataset, ^key, record} =
               FakeClient.calls(pid) |> Enum.find(&match?({:insert_json, _, _, _}, &1))

      # The rendered record embeds the numeric "id" = key AND the "_id".
      assert %{"id" => ^key, "_id" => "p2", "title" => "Beta"} = record

      # No UPDATE call for an insert.
      refute Enum.any?(FakeClient.calls(pid), &match?({:update_json, _, _, _}, &1))

      # The pointer's key_map now includes {key => "p2"} for a later delete.
      assert map_key_for(scope, "p2") == key
      # Upsert must NOT swap the live dataset.
      assert Indexer.current_dataset(scope) == dataset
    end

    test "UPDATE branch: _id PRESENT in the key_map calls update_json_record", %{
      pid: pid,
      scope: scope,
      dataset: dataset
    } do
      FakeClient.set_status(%{"reIndexRequired" => false, "status" => "ready"})

      # "p1" IS in the stored key_map → UPDATE (replace by key).
      assert :ok =
               Indexer.upsert_record(scope, %{"_id" => "p1", "title" => "Renamed"},
                 client: FakeClient
               )

      key = Indexer.key_for_id("p1")

      assert {:update_json, ^dataset, ^key, record} =
               FakeClient.calls(pid) |> Enum.find(&match?({:update_json, _, _, _}, &1))

      assert %{"id" => ^key, "_id" => "p1", "title" => "Renamed"} = record

      refute Enum.any?(FakeClient.calls(pid), &match?({:insert_json, _, _, _}, &1))
      assert Indexer.current_dataset(scope) == dataset
    end

    test "reindex-required: returns {:reindex_required, status}", %{scope: scope} do
      FakeClient.set_status(%{"reIndexRequired" => true})

      assert {:reindex_required, %{"reIndexRequired" => true}} =
               Indexer.upsert_record(scope, %{"_id" => "p2", "title" => "Beta"}, client: FakeClient)
    end

    test "surfaces a client write error", %{scope: scope} do
      alias Barkpark.Plugins.Indx.Errors.IndexError
      FakeClient.set_write_result({:error, %IndexError{status: 500, endpoint: "x"}})

      assert {:error, %IndexError{status: 500}} =
               Indexer.upsert_record(scope, %{"_id" => "p2"}, client: FakeClient)
    end
  end

  # ── Upsert with an EMPTY key_map (post-restart / boot-recovery) ──────────────
  #
  # restore_pointer/2 seats the live pointer with an EMPTY key_map after a
  # restart, so the insert-vs-update decision must NOT lean on the map alone.
  # When the _id is not in the map, upsert_record/3 existence-PROBES the
  # engine via get_json([key]): a doc with the same _id → UPDATE, empty → INSERT.
  describe "upsert_record/3 with an empty key_map (existence probe)" do
    setup %{scope: scope} = ctx do
      # Restore the live pointer the way boot-recovery does: dataset set,
      # key_map EMPTY — exactly the post-restart state.
      dataset = "bp_#{scope}_v3"
      :ok = Indexer.restore_pointer(scope, dataset)
      Map.put(ctx, :dataset, dataset)
    end

    test "probe returns an existing doc with the SAME _id → UPDATE", %{
      pid: pid,
      scope: scope,
      dataset: dataset
    } do
      FakeClient.set_status(%{"reIndexRequired" => false, "status" => "ready"})
      # The engine already holds a record under this key carrying _id "p1".
      FakeClient.set_get_json({:ok, [%{"_id" => "p1", "title" => "Old"}]})

      assert :ok =
               Indexer.upsert_record(scope, %{"_id" => "p1", "title" => "New"}, client: FakeClient)

      key = Indexer.key_for_id("p1")

      # The probe ran with [key]...
      assert {:get_json, ^dataset, [^key]} =
               FakeClient.calls(pid) |> Enum.find(&match?({:get_json, _, _}, &1))

      # ...and the write took the UPDATE branch, NOT insert.
      assert {:update_json, ^dataset, ^key, _rec} =
               FakeClient.calls(pid) |> Enum.find(&match?({:update_json, _, _, _}, &1))

      refute Enum.any?(FakeClient.calls(pid), &match?({:insert_json, _, _, _}, &1))
    end

    test "probe returns empty → INSERT", %{pid: pid, scope: scope, dataset: dataset} do
      FakeClient.set_status(%{"reIndexRequired" => false, "status" => "ready"})
      FakeClient.set_get_json({:ok, []})

      assert :ok =
               Indexer.upsert_record(scope, %{"_id" => "p9", "title" => "Brand New"},
                 client: FakeClient
               )

      key = Indexer.key_for_id("p9")

      assert {:get_json, ^dataset, [^key]} =
               FakeClient.calls(pid) |> Enum.find(&match?({:get_json, _, _}, &1))

      assert {:insert_json, ^dataset, ^key, _rec} =
               FakeClient.calls(pid) |> Enum.find(&match?({:insert_json, _, _, _}, &1))

      refute Enum.any?(FakeClient.calls(pid), &match?({:update_json, _, _, _}, &1))

      # After the insert the key_map now knows {key => "p9"} so a later
      # upsert of "p9" takes the fast UPDATE path with no probe.
      assert map_key_for(scope, "p9") == key
    end

    test "a probe client error is surfaced (worker classifies it)", %{scope: scope} do
      alias Barkpark.Plugins.Indx.Errors.NetworkError
      FakeClient.set_get_json({:error, %NetworkError{reason: :econnrefused, endpoint: "x"}})

      assert {:error, %NetworkError{}} =
               Indexer.upsert_record(scope, %{"_id" => "p1"}, client: FakeClient)
    end

    test "an _id ALREADY in the key_map skips the probe (fast UPDATE path)", %{
      pid: pid,
      scope: scope,
      dataset: dataset
    } do
      FakeClient.set_status(%{"reIndexRequired" => false, "status" => "ready"})
      # Seed the map for "p1" via a first insert (probe empty → insert).
      FakeClient.set_get_json({:ok, []})
      assert :ok = Indexer.upsert_record(scope, %{"_id" => "p1"}, client: FakeClient)

      # A second upsert of "p1" must NOT probe again — it's in the map now.
      key = Indexer.key_for_id("p1")
      assert :ok = Indexer.upsert_record(scope, %{"_id" => "p1", "title" => "v2"}, client: FakeClient)

      probes =
        FakeClient.calls(pid) |> Enum.filter(&match?({:get_json, ^dataset, _}, &1))

      # Exactly one probe — the first insert. The second upsert hit the fast path.
      assert length(probes) == 1

      updates =
        FakeClient.calls(pid) |> Enum.filter(&match?({:update_json, ^dataset, ^key, _}, &1))

      assert length(updates) == 1
    end
  end

  describe "restore_pointer/2" do
    test "seats the live pointer with an EMPTY key_map when none is set", %{scope: scope} do
      assert Indexer.current_dataset(scope) == nil
      assert :ok = Indexer.restore_pointer(scope, "bp_#{scope}_v7")
      assert Indexer.current_dataset(scope) == "bp_#{scope}_v7"
      assert Indexer.key_map(scope) == %{}
    end

    test "does NOT clobber a pointer already set by a rebuild (returns :noop)", %{
      scope: scope
    } do
      {:ok, r} =
        Indexer.rebuild(scope, [%{"_id" => "p1"}], client: FakeClient, poll_interval_ms: 0)

      Indexer.swap(scope, r)
      live = Indexer.current_dataset(scope)

      assert :noop = Indexer.restore_pointer(scope, "bp_#{scope}_v99")
      # The live rebuild pointer survives untouched.
      assert Indexer.current_dataset(scope) == live
    end
  end

  test "upsert_record with no live dataset returns an error (nothing to upsert)" do
    scope = "neverbuilt_#{System.unique_integer([:positive])}"

    assert {:error, %Barkpark.Plugins.Indx.Errors.IndexError{message: msg}} =
             Indexer.upsert_record(scope, %{"_id" => "p1"}, client: FakeClient)

    assert msg =~ "no live dataset"
  end
end
