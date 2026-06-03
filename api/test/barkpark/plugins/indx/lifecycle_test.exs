defmodule Barkpark.Plugins.Indx.LifecycleTest do
  @moduledoc """
  Routing proof for the Indx lifecycle hook:

    * `:after_save` / `:after_publish` → REBUILD-op `IndexerWorker` job
    * `:after_unpublish` / `:after_delete` → DELETE-op job carrying `_id`
    * `ctx.source == :worker` → no-op (recursion guard)
    * no resolvable dataset → no-op (fresh-install invariant)

  Uses Oban's manual testing mode (config/test.exs) to assert the enqueued
  job args without running the worker.
  """
  use Barkpark.DataCase, async: true
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.Plugins.Indx.IndexerWorker
  alias Barkpark.Plugins.Indx.Lifecycle

  # The Content hook payload carries a %Document{}; its _id lives on :doc_id.
  defp doc(doc_id, type \\ "post"), do: %Barkpark.Content.Document{doc_id: doc_id, type: type}

  defp payload(event, doc, ctx_extras \\ %{}) do
    %{
      event: event,
      doc: doc,
      dataset: "production",
      prev_doc: doc,
      ctx: Map.merge(%{source: :api, user_id: nil}, ctx_extras)
    }
  end

  describe "rebuild routing" do
    test "after_save enqueues a rebuild-op job for the scope" do
      assert :ok == Lifecycle.enqueue_rebuild(payload(:after_save, doc("p1")))

      assert_enqueued(
        worker: IndexerWorker,
        args: %{"op" => "rebuild", "scope" => "production", "types" => ["post"]}
      )
    end

    test "after_publish enqueues a rebuild-op job" do
      assert :ok == Lifecycle.enqueue_rebuild(payload(:after_publish, doc("p2")))

      assert_enqueued(worker: IndexerWorker, args: %{"op" => "rebuild", "scope" => "production"})
    end
  end

  describe "delete routing" do
    test "after_delete enqueues a delete-op job carrying the doc _id" do
      assert :ok == Lifecycle.enqueue_rebuild(payload(:after_delete, doc("p3")))

      assert_enqueued(
        worker: IndexerWorker,
        args: %{"op" => "delete", "scope" => "production", "_id" => "p3", "types" => ["post"]}
      )
    end

    test "after_unpublish enqueues a delete-op job carrying the doc _id" do
      assert :ok == Lifecycle.enqueue_rebuild(payload(:after_unpublish, doc("drafts.p4")))

      assert_enqueued(
        worker: IndexerWorker,
        args: %{"op" => "delete", "scope" => "production", "_id" => "drafts.p4"}
      )
    end

    test "delete with no resolvable _id falls back to a rebuild op" do
      # A doc map with no _id/doc_id at all → cannot target a key.
      assert :ok == Lifecycle.enqueue_rebuild(payload(:after_delete, %{"_type" => "post"}))

      assert_enqueued(worker: IndexerWorker, args: %{"op" => "rebuild", "scope" => "production"})
      refute_enqueued(worker: IndexerWorker, args: %{"op" => "delete"})
    end
  end

  describe "guards" do
    test "ctx.source == :worker is a no-op (recursion guard) for every event" do
      for event <- [:after_save, :after_publish, :after_unpublish, :after_delete] do
        assert :ok == Lifecycle.enqueue_rebuild(payload(event, doc("p5"), %{source: :worker}))
      end

      refute_enqueued(worker: IndexerWorker)
    end

    test "a payload with no dataset is a no-op (fresh-install invariant)" do
      assert :ok ==
               Lifecycle.enqueue_rebuild(%{
                 event: :after_save,
                 doc: doc("p6"),
                 dataset: nil,
                 ctx: %{source: :api}
               })

      refute_enqueued(worker: IndexerWorker)
    end
  end
end
