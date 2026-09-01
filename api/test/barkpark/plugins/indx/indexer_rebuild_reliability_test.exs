defmodule Barkpark.Plugins.Indx.IndexerRebuildReliabilityTest do
  @moduledoc """
  Blue/green rebuild reliability guards:

    * Bug 1 — `Indexer.rebuild/3` must best-effort DELETE the freshly-created
      `<prefix>_<scope>_v<n>` dataset when any step after `create_or_open`
      fails. If the partial dataset leaks, boot recovery picks the MAX version
      and would seat the live query pointer on a FAILED/partial dataset →
      silently wrong search results after a deploy.

    * Bug 2 — `IndexerWorker.run_rebuild/4` lists each type with a fixed cap;
      a type whose published-doc count hits the cap is silently truncated out
      of the index. The rebuild must WARN (naming the type) at the cap.
  """
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureLog
  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Plugins.Indx.Indexer
  alias Barkpark.Plugins.Indx.IndexerWorker
  alias Barkpark.Plugins.Indx.Errors.IndexError

  describe "Bug 1: rebuild failure deletes the freshly-created dataset" do
    test "a failure after create_or_open deletes the new dataset before returning the error" do
      # `rebuild/3` addresses an INDEX, so its first argument is an
      # `Indexer.index_key/2` key, not a bare dataset string.
      index_key = Indexer.index_key("reindex-fail-#{System.unique_integer([:positive])}")
      docs = [%{"_id" => "a", "title" => "Alpha"}]

      assert {:error, %IndexError{}} =
               Indexer.rebuild(index_key, docs,
                 client: FailAfterCreateClient,
                 poll_interval_ms: 0
               )

      # The v1 dataset was created, then the failure fired; rebuild must have
      # asked the client to delete exactly that dataset.
      assert_receive {:deleted_dataset, deleted}
      assert deleted =~ "_#{index_key}_v1"
    end

    test "the deleted dataset is the v(n+1) name, not the live one" do
      index_key = Indexer.index_key("reindex-fail2-#{System.unique_integer([:positive])}")
      # Seat a live v3 pointer so the fresh dataset should be v4.
      pointer_term = {Indexer, :live_dataset}
      prior = :persistent_term.get(pointer_term, %{})

      :persistent_term.put(
        pointer_term,
        Map.put(prior, index_key, %{dataset: "bp_#{index_key}_v3"})
      )

      on_exit(fn -> :persistent_term.put(pointer_term, prior) end)

      assert {:error, %IndexError{}} =
               Indexer.rebuild(index_key, [%{"_id" => "a", "title" => "A"}],
                 client: FailAfterCreateClient,
                 poll_interval_ms: 0
               )

      assert_receive {:deleted_dataset, deleted}
      assert deleted =~ "_v4"
      # The live v3 dataset must NOT have been deleted.
      refute deleted =~ "_v3"
    end
  end

  describe "Bug 2: rebuild warns when a type hits the list cap" do
    test "a type at the list cap logs a truncation WARNING naming the type" do
      ws = create_workspace!()
      proj = create_project!(ws)
      scope_kw = [workspace_id: ws.id, project_id: proj.id]
      ds = "production"

      # The rebuild op now derives its corpus from the registered PUBLIC schemas
      # (types-blind whole-corpus rebuild — task indx-rebuild-types-dedup), so a
      # "post" schema must exist in scope for the rebuild to index post docs.
      register_post_schema!(ds, scope_kw)

      {:ok, _} =
        Content.create_document("post", %{"doc_id" => "cap-1", "title" => "one"}, ds, scope_kw)

      args = %{
        "scope" => ds,
        "op" => "rebuild",
        "types" => ["post"],
        "perspective" => "raw",
        # Test-only seams: fake indexer (no live Indx engine) + a cap of 1 so a
        # single seeded doc trips the truncation branch.
        "indexer" => "TruncFakeIndexer",
        "list_limit" => 1,
        "workspace_id" => ws.id,
        "project_id" => proj.id
      }

      log =
        capture_log(fn ->
          assert :ok = IndexerWorker.perform(%Oban.Job{args: args})
        end)

      assert log =~ "hit the 1-doc rebuild list cap"
      assert log =~ "type=post"
      assert log =~ "TRUNCATED"
    end

    test "a type UNDER the cap logs no truncation warning" do
      ws = create_workspace!()
      proj = create_project!(ws)
      scope_kw = [workspace_id: ws.id, project_id: proj.id]
      ds = "production"

      register_post_schema!(ds, scope_kw)

      {:ok, _} =
        Content.create_document("post", %{"doc_id" => "u-1", "title" => "only"}, ds, scope_kw)

      args = %{
        "scope" => ds,
        "op" => "rebuild",
        "types" => ["post"],
        "perspective" => "raw",
        "indexer" => "TruncFakeIndexer",
        # Cap of 1000 (default-ish) — one doc is well under it.
        "list_limit" => 1000,
        "workspace_id" => ws.id,
        "project_id" => proj.id
      }

      log =
        capture_log(fn ->
          assert :ok = IndexerWorker.perform(%Oban.Job{args: args})
        end)

      refute log =~ "rebuild list cap"
    end
  end

  # Register a minimal PUBLIC "post" schema in the given scope so the
  # types-blind rebuild's schema-derived corpus includes "post".
  defp register_post_schema!(dataset, scope_kw) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        dataset,
        scope_kw
      )
  end
end

defmodule FailAfterCreateClient do
  @moduledoc false
  # create_or_open succeeds (the fresh dataset now exists), then analyze_string
  # fails — the exact leak scenario Bug 1 guards. delete_dataset records the
  # call so the test can assert the partial dataset was cleaned up.
  alias Barkpark.Plugins.Indx.Errors.IndexError

  def create_or_open(_dataset, _opts), do: :ok

  def analyze_string(_dataset, _records, _opts) do
    {:error, %IndexError{status: 500, body: nil, endpoint: "AnalyzeString", message: "boom"}}
  end

  def delete_dataset(dataset, _opts) do
    send(self(), {:deleted_dataset, dataset})
    :ok
  end
end

defmodule TruncFakeIndexer do
  @moduledoc false
  # Stands in for Barkpark.Plugins.Indx.Indexer so the worker's run_rebuild can
  # be exercised without a live Indx engine. Only the corpus SIZE it is handed
  # matters for the truncation-warning assertion.
  def rebuild(_scope, docs) do
    {:ok, %{new_dataset: "trunc_ds_v1", old_dataset: nil, count: length(docs), key_map: %{}}}
  end

  def swap(_scope, _result), do: nil
  def delete_dataset(_old, _opts), do: :ok
end
