defmodule Barkpark.Plugins.OnixEdit.LifecycleTest do
  @moduledoc """
  Pins the proof of Goal `barkpark-9lq` step 5: OnixEdit's `after_publish`
  lifecycle hook enqueues `Bokbasen.PublishWorker` for `book` documents,
  no-ops for non-books, and (critically) no-ops when `ctx.source == :worker`
  to break the worker self-feedback loop.

  The hook lives at `lib/barkpark/plugins/onixedit/lifecycle.ex` and is
  fired by `Barkpark.Plugins.Hooks` after `Content.publish_document/4`.
  The worker's arg shape is `%{"document_id" => id, "type" => "book",
  "dataset" => ds}` — matching the manual `Actions.publish_to_bokbasen/3`
  path, so a worker reading either origin path lands in the same code.
  """
  use Barkpark.DataCase, async: true
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker
  alias Barkpark.Plugins.OnixEdit.Lifecycle

  @book_doc_string %{"_type" => "book", "_id" => "book-test"}
  @book_doc_atom %{_type: "book", _id: "book-test"}
  @post_doc %{"_type" => "post", "_id" => "post-x"}

  defp payload(doc, ctx_extras \\ %{}) do
    %{
      event: :after_publish,
      doc: doc,
      dataset: "production",
      prev_doc: doc,
      ctx: Map.merge(%{source: :studio, user_id: nil}, ctx_extras)
    }
  end

  describe "publish_to_bokbasen_if_book/1 — happy path" do
    test "enqueues PublishWorker for a book document on after_publish (string-key doc)" do
      assert :ok == Lifecycle.publish_to_bokbasen_if_book(payload(@book_doc_string))

      assert_enqueued(
        worker: PublishWorker,
        args: %{
          "document_id" => "book-test",
          "type" => "book",
          "dataset" => "production"
        }
      )
    end

    test "also handles atom-key doc shape" do
      assert :ok == Lifecycle.publish_to_bokbasen_if_book(payload(@book_doc_atom))

      assert_enqueued(
        worker: PublishWorker,
        args: %{"document_id" => "book-test", "type" => "book", "dataset" => "production"}
      )
    end
  end

  describe "publish_to_bokbasen_if_book/1 — recursion guard" do
    test "bails when ctx.source == :worker (no enqueue)" do
      assert :ok ==
               Lifecycle.publish_to_bokbasen_if_book(
                 payload(@book_doc_string, %{source: :worker})
               )

      refute_enqueued(worker: PublishWorker)
    end
  end

  describe "publish_to_bokbasen_if_book/1 — non-book filter" do
    test "bails on non-book doc (no enqueue)" do
      assert :ok == Lifecycle.publish_to_bokbasen_if_book(payload(@post_doc))
      refute_enqueued(worker: PublishWorker)
    end

    test "bails when doc lacks _type entirely" do
      assert :ok == Lifecycle.publish_to_bokbasen_if_book(payload(%{"_id" => "x"}))
      refute_enqueued(worker: PublishWorker)
    end
  end

  describe "publish_to_bokbasen_if_book/1 — defensive" do
    test "missing ctx.source → treated as default non-worker, enqueues for a book" do
      payload_no_source = %{
        event: :after_publish,
        doc: @book_doc_string,
        dataset: "production",
        prev_doc: @book_doc_string,
        ctx: %{}
      }

      assert :ok == Lifecycle.publish_to_bokbasen_if_book(payload_no_source)
      # ctx.source missing → Map.get returns nil → not :worker → enqueues
      assert_enqueued(worker: PublishWorker)
    end
  end
end
