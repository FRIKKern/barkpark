defmodule Barkpark.Plugins.OnixEdit.Tasks.BokbasenReplayTest do
  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  import ExUnit.CaptureIO

  alias Barkpark.Content.Document
  alias Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker
  alias Mix.Tasks.Bokbasen.Replay

  @full_book_path Path.expand("../../../../fixtures/onix/full-book.json", __DIR__)

  setup do
    prev_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(prev_shell) end)
    :ok
  end

  defp seed_book(doc_id) do
    content =
      @full_book_path
      |> File.read!()
      |> Jason.decode!()

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        "doc_id" => doc_id,
        "type" => "book",
        "dataset" => "production",
        "title" => "Replay Test Book",
        "status" => "draft",
        "content" => content,
        "rev" => "rev_" <> doc_id
      })
      |> Repo.insert()

    doc
  end

  describe "--dry-run" do
    test "renders XML and prints summary, does NOT enqueue" do
      _doc = seed_book("replay-dry-1")

      output =
        capture_io(fn ->
          Replay.run(["--book-id", "replay-dry-1", "--dry-run"])
        end)

      assert output =~ ~r/<\?xml/i
      assert output =~ "summary"
      assert output =~ "bytes"
      assert output =~ "xsd_valid"
      assert output =~ "enqueued   : false (dry-run)"

      refute_enqueued(worker: PublishWorker)
    end
  end

  describe "enqueue" do
    test "without --dry-run enqueues a PublishWorker job" do
      _doc = seed_book("replay-enq-1")

      output =
        capture_io(fn ->
          Replay.run(["--book-id", "replay-enq-1"])
        end)

      assert output =~ "enqueued PublishWorker job"
      assert output =~ "job_id"

      assert_enqueued(
        worker: PublishWorker,
        args: %{"document_id" => "replay-enq-1", "type" => "book", "dataset" => "production"}
      )
    end

    test "looks up drafts.<id> when bare id not found" do
      _doc = seed_book("drafts.replay-draft-1")

      output =
        capture_io(fn ->
          Replay.run(["--book-id", "replay-draft-1"])
        end)

      assert output =~ "enqueued PublishWorker job"

      assert_enqueued(
        worker: PublishWorker,
        args: %{"document_id" => "drafts.replay-draft-1"}
      )
    end
  end

  describe "errors" do
    test "raises Mix.Error when --book-id is missing" do
      stderr =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, fn ->
            capture_io(fn -> Replay.run([]) end)
          end
        end)

      assert stderr =~ "--book-id is required"
    end

    test "raises Mix.Error when book not found" do
      assert_raise Mix.Error, ~r/book not found/i, fn ->
        capture_io(fn -> Replay.run(["--book-id", "does-not-exist"]) end)
      end
    end

    test "raises on unknown switches" do
      assert_raise Mix.Error, fn ->
        capture_io(fn -> Replay.run(["--bogus", "x"]) end)
      end
    end
  end
end
