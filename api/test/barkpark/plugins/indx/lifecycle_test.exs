defmodule Barkpark.Plugins.Indx.LifecycleTest do
  @moduledoc """
  Routing proof for the Indx lifecycle hook:

    * `:after_save` / `:after_publish` → REBUILD-op `IndexerWorker` job
    * `:after_unpublish` / `:after_delete` → DELETE-op job carrying `_id`
    * `ctx.source == :worker` → no-op (recursion guard)
    * no resolvable dataset → no-op (fresh-install invariant)

  Uses Oban's manual testing mode (config/test.exs) to assert the enqueued
  job args without running the worker.

  `async: false` because the incremental_upsert flag tests flip
  Application env (a global), which would race async siblings.
  """
  use Barkpark.DataCase, async: false
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

  # Flip the incremental_upsert flag for the duration of one test, restoring
  # the prior Application env on exit. Settings.get/0 reads this env.
  defp set_flag(value) do
    prior = Application.get_env(:barkpark, Barkpark.Plugins.Indx)
    merged = Keyword.put(prior || [], :incremental_upsert, value)
    Application.put_env(:barkpark, Barkpark.Plugins.Indx, merged)

    on_exit(fn ->
      if prior do
        Application.put_env(:barkpark, Barkpark.Plugins.Indx, prior)
      else
        Application.delete_env(:barkpark, Barkpark.Plugins.Indx)
      end
    end)
  end

  describe "rebuild routing (flag OFF — default, prod-identical)" do
    test "the incremental_upsert flag defaults to false" do
      # No env override flips it — config/config.exs sets it false, so the
      # whole incremental add/update path is INERT by default.
      assert Barkpark.Plugins.Indx.Settings.get().incremental_upsert == false
    end

    test "after_save enqueues a rebuild-op job for the scope" do
      assert :ok == Lifecycle.enqueue_rebuild(payload(:after_save, doc("p1")))

      assert_enqueued(
        worker: IndexerWorker,
        args: %{"op" => "rebuild", "scope" => "production", "types" => ["post"]}
      )

      # Flag OFF → NO upsert op enqueued (blue/green only).
      refute_enqueued(worker: IndexerWorker, args: %{"op" => "upsert"})
    end

    test "after_publish enqueues a rebuild-op job" do
      assert :ok == Lifecycle.enqueue_rebuild(payload(:after_publish, doc("p2")))

      assert_enqueued(worker: IndexerWorker, args: %{"op" => "rebuild", "scope" => "production"})
    end
  end

  describe "upsert routing (flag ON)" do
    setup do
      set_flag(true)
      :ok
    end

    test "after_save enqueues an UPSERT-op job carrying the doc _id + type" do
      assert :ok == Lifecycle.enqueue_rebuild(payload(:after_save, doc("p1")))

      assert_enqueued(
        worker: IndexerWorker,
        args: %{"op" => "upsert", "scope" => "production", "_id" => "p1", "types" => ["post"]}
      )

      # Flag ON → NO rebuild op for an add/update.
      refute_enqueued(worker: IndexerWorker, args: %{"op" => "rebuild"})
    end

    test "after_publish enqueues an UPSERT-op job" do
      assert :ok == Lifecycle.enqueue_rebuild(payload(:after_publish, doc("p2")))

      assert_enqueued(
        worker: IndexerWorker,
        args: %{"op" => "upsert", "scope" => "production", "_id" => "p2"}
      )
    end

    test "after_save with no resolvable _id falls back to a rebuild" do
      # A doc map with no _id/doc_id → cannot target a key → safe rebuild.
      assert :ok == Lifecycle.enqueue_rebuild(payload(:after_save, %{"_type" => "post"}))

      assert_enqueued(worker: IndexerWorker, args: %{"op" => "rebuild", "scope" => "production"})
      refute_enqueued(worker: IndexerWorker, args: %{"op" => "upsert"})
    end

    test "after_delete still routes to DELETE op even with the flag ON" do
      # delete/unpublish are incremental regardless of the upsert flag.
      assert :ok == Lifecycle.enqueue_rebuild(payload(:after_delete, doc("p3")))

      assert_enqueued(
        worker: IndexerWorker,
        args: %{"op" => "delete", "scope" => "production", "_id" => "p3"}
      )

      refute_enqueued(worker: IndexerWorker, args: %{"op" => "upsert"})
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
