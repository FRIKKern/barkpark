defmodule Barkpark.Plugins.Indx.IndexerWorkerRebuildTest do
  @moduledoc """
  Regression cover for the types-blind rebuild fix (task indx-rebuild-types-dedup).

  Indx's blue/green rebuild REPLACES the whole live dataset (rebuild → swap →
  delete old). Before the fix, `run_rebuild_op/2` built the new dataset from
  ONLY the enqueued `"types"` slice (the lifecycle enqueues `types: [doc.type]`),
  so a `types ["post"]` rebuild swapped in a post-ONLY dataset and every other
  type vanished from live search. Worse, a mixed-type save burst dedups (keys
  `[:op, :scope, :_id]`, no `:types`) down to whichever single-type job won —
  collapsing search to one type after a deploy.

  This is the mirror-inverse of the EdgeProjector `:types`-in-key fix
  (lvw-t11-followup-dedup): there, per-type rebuilds are additive so each must
  run; here the whole-dataset swap makes per-type keys HARMFUL (last swap wins).
  The fix makes the rebuild types-BLIND — it re-indexes the whole public-schema
  corpus regardless of the enqueued type — so scope-level dedup is correct and
  `:types` stays OUT of the unique key.

  Uses `Oban.Testing.perform_job/2` (config/test.exs is `testing: :manual`).
  Fake `indexer`/`content` seam modules are defined in this file so their atoms
  pre-exist for `String.to_existing_atom/1`.
  """

  use Barkpark.DataCase, async: true
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.Plugins.Indx.IndexerWorker

  @indexer "Barkpark.Plugins.Indx.IndexerWorkerRebuildTest.FakeIndexer"
  @content "Barkpark.Plugins.Indx.IndexerWorkerRebuildTest.FakeContent"
  @content_no_schemas "Barkpark.Plugins.Indx.IndexerWorkerRebuildTest.FakeContentNoSchemas"

  # ── Fake content seam ──────────────────────────────────────────────────────
  # list_schemas returns TWO public types + one PRIVATE type. list_documents
  # returns a single doc per type so we can see exactly which types the rebuild
  # pulled into the corpus.
  defmodule FakeContent do
    @moduledoc false
    def list_schemas(_scope, _opts) do
      [
        %{name: "post", visibility: "public"},
        %{name: "page", visibility: "public"},
        %{name: "secret", visibility: "private"}
      ]
    end

    def list_documents(type, _scope, _opts), do: [%{"_id" => "#{type}-1", "_type" => type}]
    def get_document(_id, _type, _scope), do: {:error, :not_found}
  end

  defmodule FakeContentNoSchemas do
    @moduledoc false
    def list_schemas(_scope, _opts), do: []
    def list_documents(_type, _scope, _opts), do: []
    def get_document(_id, _type, _scope), do: {:error, :not_found}
  end

  # ── Fake indexer seam ──────────────────────────────────────────────────────
  # rebuild/2 forwards the exact docs it was handed back to the test process
  # (perform runs in-process under perform_job), so the test can assert the
  # corpus. swap/2 + delete_dataset/2 are inert.
  defmodule FakeIndexer do
    @moduledoc false
    def rebuild(_scope, docs) do
      send(self(), {:rebuild_docs, docs})

      {:ok,
       %{new_dataset: "bp_production_v2", old_dataset: nil, count: length(docs), key_map: %{}}}
    end

    def swap(_scope, _result), do: nil
    def delete_dataset(_old, _opts), do: :ok
  end

  describe "rebuild op — types-blind whole-corpus" do
    test "re-indexes EVERY public type even when the job carries a single type" do
      # The lifecycle enqueues types: [doc.type]; a burst dedups to this one job.
      assert :ok =
               perform_job(IndexerWorker, %{
                 "op" => "rebuild",
                 "scope" => "production",
                 "types" => ["post"],
                 "indexer" => @indexer,
                 "content" => @content
               })

      assert_receive {:rebuild_docs, docs}

      indexed = docs |> Enum.map(& &1["_type"]) |> Enum.sort()

      # BOTH public types present — the swap will NOT drop "page".
      # (Pre-fix this was ["post"] only, and "page" was erased from live search.)
      assert indexed == ["page", "post"]
    end

    test "excludes private-visibility types (no new search-leak surface)" do
      assert :ok =
               perform_job(IndexerWorker, %{
                 "op" => "rebuild",
                 "scope" => "production",
                 "types" => ["secret"],
                 "indexer" => @indexer,
                 "content" => @content
               })

      assert_receive {:rebuild_docs, docs}
      indexed = Enum.map(docs, & &1["_type"])

      refute "secret" in indexed
      assert "post" in indexed and "page" in indexed
    end

    test "cancels (never rebuilds-to-empty) when no public schemas resolve" do
      # An empty rebuild would swap in an empty dataset and wipe live search —
      # refuse it instead.
      assert {:cancel, :no_indexed_types} =
               perform_job(IndexerWorker, %{
                 "op" => "rebuild",
                 "scope" => "production",
                 "types" => ["post"],
                 "indexer" => @indexer,
                 "content" => @content_no_schemas
               })
    end
  end

  describe "uniqueness — :types is deliberately NOT in the key" do
    test "two rebuild enqueues for one scope with different single types collapse to ONE job" do
      assert {:ok, j1} = IndexerWorker.enqueue("production", types: ["post"])
      assert {:ok, j2} = IndexerWorker.enqueue("production", types: ["page"])

      # Same job id ⇒ Oban treated them as duplicates on (rebuild, scope, nil).
      # That is CORRECT here: each rebuild is whole-corpus, so collapsing loses
      # nothing. Adding :types to the key (the EdgeProjector lever) would make
      # both run and the second swap would erase the first type — the bug.
      assert j1.id == j2.id
    end
  end
end
