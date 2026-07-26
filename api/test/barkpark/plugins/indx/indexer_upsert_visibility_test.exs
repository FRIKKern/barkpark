defmodule Barkpark.Plugins.Indx.IndexerUpsertVisibilityTest do
  @moduledoc """
  Schema-visibility gate on the Indx INCREMENTAL paths (search-template W10 /
  D62 companion).

  The blue/green REBUILD has always excluded non-public schema types
  (`indexed_types/2` — "never index a type a public reader can't fetch"), but
  BOTH incremental add/update paths were ungated:

    * `IndexerWorker.run_upsert/2` indexed whatever `_id` the job carried, so
      with `incremental_upsert` ON a private-type save re-contaminated the
      corpus the rebuild deliberately kept clean;
    * `Lifecycle.do_enqueue_upsert/2` enqueued that job for ANY saved doc.

  Both now apply the same ALLOWLIST predicate (visibility must be "public" —
  unified with the query route + the search retriever). The delete/unpublish
  path stays ungated on purpose: a delete only ever REMOVES from the index.
  """
  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.Content
  alias Barkpark.Plugins.Indx.IndexerWorker
  alias Barkpark.Plugins.Indx.Lifecycle

  @indexer "Barkpark.Plugins.Indx.IndexerUpsertVisibilityTest.FakeIndexer"
  @content "Barkpark.Plugins.Indx.IndexerUpsertVisibilityTest.FakeContent"

  # ── Fake content seam ──────────────────────────────────────────────────────
  # One public + one private type; get_document returns a doc for any id so an
  # upsert that gets PAST the gate is observable at the indexer seam.
  defmodule FakeContent do
    @moduledoc false
    def list_schemas(_scope, _opts) do
      [
        %{name: "post", visibility: "public"},
        %{name: "session", visibility: "private"}
      ]
    end

    def list_documents(_type, _scope, _opts), do: []
    def get_document(id, type, _scope), do: {:ok, %{"_id" => id, "_type" => type}}
  end

  # ── Fake indexer seam ──────────────────────────────────────────────────────
  defmodule FakeIndexer do
    @moduledoc false
    def upsert_record(_scope, doc) do
      send(self(), {:upserted, doc})
      :ok
    end

    def rebuild(_scope, docs) do
      send(self(), {:rebuild_docs, docs})

      {:ok,
       %{new_dataset: "bp_production_v2", old_dataset: nil, count: length(docs), key_map: %{}}}
    end

    def swap(_scope, _result), do: nil
    def delete_dataset(_old, _opts), do: :ok
  end

  describe "IndexerWorker upsert op — visibility gate" do
    test "a PUBLIC-type upsert passes the gate and reaches the indexer" do
      assert :ok =
               perform_job(IndexerWorker, %{
                 "op" => "upsert",
                 "scope" => "production",
                 "_id" => "post-1",
                 "types" => ["post"],
                 "indexer" => @indexer,
                 "content" => @content
               })

      assert_receive {:upserted, %{"_id" => "post-1", "_type" => "post"}}
    end

    test "a PRIVATE-type upsert is refused — the indexer is never called" do
      assert {:cancel, :non_public_type} =
               perform_job(IndexerWorker, %{
                 "op" => "upsert",
                 "scope" => "production",
                 "_id" => "session-1",
                 "types" => ["session"],
                 "indexer" => @indexer,
                 "content" => @content
               })

      refute_receive {:upserted, _}, 50
    end

    test "a SCHEMALESS-type upsert is refused too (allowlist, not denylist)" do
      assert {:cancel, :non_public_type} =
               perform_job(IndexerWorker, %{
                 "op" => "upsert",
                 "scope" => "production",
                 "_id" => "orphan-1",
                 "types" => ["orphan"],
                 "indexer" => @indexer,
                 "content" => @content
               })

      refute_receive {:upserted, _}, 50
    end
  end

  describe "Lifecycle save routing — visibility gate (incremental_upsert ON)" do
    @ds "indx-lc-vis-test"

    setup do
      # Flip the feature flag ON via the app-env seam (env wins over DB; no
      # INDX_INCREMENTAL_UPSERT OS var is set in test).
      previous = Application.get_env(:barkpark, Barkpark.Plugins.Indx, [])

      Application.put_env(
        :barkpark,
        Barkpark.Plugins.Indx,
        Keyword.put(previous, :incremental_upsert, true)
      )

      on_exit(fn -> Application.put_env(:barkpark, Barkpark.Plugins.Indx, previous) end)

      # Real schema rows — the lifecycle gate reads visibility through
      # Content.schema_public?/3 (the query route's own predicate).
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "post", "visibility" => "public"},
          @ds
        )

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "session", "title" => "session", "visibility" => "private"},
          @ds
        )

      :ok
    end

    defp save_event(type, id) do
      %{
        event: :after_save,
        doc: %{doc_id: id, type: type},
        dataset: @ds,
        ctx: %{source: :api}
      }
    end

    test "a PUBLIC-type save enqueues the upsert job" do
      assert :ok = Lifecycle.enqueue_rebuild(save_event("post", "lc-post-1"))

      assert_enqueued(
        worker: IndexerWorker,
        args: %{"op" => "upsert", "scope" => @ds, "_id" => "lc-post-1"}
      )
    end

    test "a PRIVATE-type save enqueues NOTHING — no upsert, no rebuild" do
      assert :ok = Lifecycle.enqueue_rebuild(save_event("session", "lc-session-1"))

      assert all_enqueued(worker: IndexerWorker) == []
    end

    test "an unresolvable type (no type on the doc) falls back to the safe REBUILD" do
      assert :ok =
               Lifecycle.enqueue_rebuild(%{
                 event: :after_save,
                 doc: %{doc_id: "lc-untyped-1"},
                 dataset: @ds,
                 ctx: %{source: :api}
               })

      assert_enqueued(worker: IndexerWorker, args: %{"op" => "rebuild", "scope" => @ds})
    end

    test "flag OFF: a private-type save keeps today's REBUILD routing (byte-identical prod path)" do
      previous = Application.get_env(:barkpark, Barkpark.Plugins.Indx, [])

      Application.put_env(
        :barkpark,
        Barkpark.Plugins.Indx,
        Keyword.put(previous, :incremental_upsert, false)
      )

      assert :ok = Lifecycle.enqueue_rebuild(save_event("session", "lc-session-2"))

      # The rebuild derives its own public-only corpus, so this stays safe.
      assert_enqueued(worker: IndexerWorker, args: %{"op" => "rebuild", "scope" => @ds})
    end
  end
end
