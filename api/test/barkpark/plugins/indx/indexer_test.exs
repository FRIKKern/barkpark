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
    def set_searchable_fields(ds, fields, _opts), do: record({:set_fields, ds, fields}) && :ok

    def load_string(ds, records, _opts) do
      record({:load_string, ds, records})
      Agent.update(agent(), fn s -> %{s | loaded: Map.put(s.loaded, ds, length(records))} end)
      :ok
    end

    def index_dataset(ds, _opts), do: record({:index, ds}) && :ok

    def get_status(ds, _opts) do
      record({:status, ds})
      {:ok, %{"status" => "ready"}}
    end

    def get_number_of_json_records(ds, _opts) do
      record({:count, ds})
      {:ok, Agent.get(agent(), fn s -> Map.get(s.loaded, ds, 0) end)}
    end

    def delete_dataset(ds, _opts), do: record({:delete, ds}) && :ok
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

    # Order: create_or_open → set_fields → load_string → index → status → count.
    assert [
             {:create_or_open, ^new},
             {:set_fields, ^new, _},
             {:load_string, ^new, records},
             {:index, ^new} | _rest
           ] = calls

    # The loaded corpus carries the embedded numeric "id" AND the "_id".
    assert [
             %{"id" => 1, "_id" => "p1"},
             %{"id" => 2, "_id" => "p2"}
           ] = records
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
end
