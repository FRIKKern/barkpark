defmodule Barkpark.Content.LifecyclePostCommitAtomicityTest do
  @moduledoc """
  task-a89fda31b297077a: Lifecycle's two writes that run AFTER the publish
  transaction must land the row change and its `mutation_events` row together,
  and a fault in them must not change the caller's answer:

    * `stamp_superseded_by` (the predecessor's `superseded_by` stamp) is
      best-effort. A fault rolls the stamp back and the superseding publish,
      which already committed, still answers `{:ok, _}`.
    * `discard_refused_duplicate_draft` (the `duplicate_of` draft discard). A
      fault keeps the draft, and the refusal still answers `duplicate_of`
      without claiming the draft was discarded.

  Before, both piped a bare statement into `Broadcast.tap_broadcast`, so the row
  changed with no event and `save_event`'s raise escaped into the caller.

  The fault is the `RETURN NULL` trigger from
  `Barkpark.Content.PublishEventAtomicityTest`, narrowed to ONE `doc_id` so the
  publish's own event still lands and only the post-commit write's event fails.

  `async: false`: `CREATE TRIGGER` takes an ACCESS EXCLUSIVE lock on
  `mutation_events`, on every mutation's write path.
  """
  # sync: `CREATE TRIGGER` takes an ACCESS EXCLUSIVE lock on `mutation_events`, on every mutation's write path
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Content
  alias Barkpark.Repo

  @dataset "lifecycle_post_commit_atomicity_test"

  @good_labels %{
    "description" =>
      "A deliberately non-trivial description used by the post-commit atomicity tests.",
    "tags" => [
      %{
        "tag" => "publish-wall",
        "strength" => 90,
        "rationale" => "This document exists to exercise the post-commit lifecycle writes."
      },
      %{
        "tag" => "lifecycle",
        "strength" => 40,
        "rationale" => "Publish lifecycle mechanics are the secondary axis here."
      }
    ]
  }

  setup do
    Content.upsert_schema(
      %{"name" => "paper", "title" => "Paper", "visibility" => "public", "fields" => []},
      @dataset
    )

    Barkpark.LabelFixtures.register_tags!(@dataset, ["publish-wall", "lifecycle"])
    :ok
  end

  defp uid(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp paper_draft!(id, content, title) do
    {:ok, _} =
      Content.create_document(
        "paper",
        %{"_id" => id, "title" => title, "content" => content},
        @dataset
      )

    :ok
  end

  # Swallow the mutation_events insert for ONE doc_id only.
  defp break_events_for!(doc_id) do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION bp_test_swallow_one_doc_event() RETURNS trigger AS $fn$
    BEGIN
      IF NEW.doc_id = '#{doc_id}' THEN
        RETURN NULL;
      END IF;
      RETURN NEW;
    END;
    $fn$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER bp_test_swallow_one_doc_event_trg
    BEFORE INSERT ON mutation_events
    FOR EACH ROW EXECUTE FUNCTION bp_test_swallow_one_doc_event()
    """)

    :ok
  end

  describe "supersede stamp" do
    test "a fault on the stamp's event leaves the predecessor unstamped and the publish ok" do
      pred = uid("ss-pred")
      succ = uid("ss-succ")
      title = "Post Commit Supersession Paper #{pred}"
      paper_draft!(pred, @good_labels, title)
      assert {:ok, _} = Content.publish_document(pred, "paper", @dataset)

      paper_draft!(succ, Map.put(@good_labels, "supersedes", pred), title)
      break_events_for!(pred)

      log =
        capture_log(fn ->
          assert {:ok, _} = Content.publish_document(succ, "paper", @dataset)
        end)

      assert log =~ "supersession stamp failed"

      {:ok, predecessor} = Content.get_document(pred, "paper", @dataset)

      refute predecessor.content["superseded_by"],
             "the stamp survived a failed mutation_event insert — committed with no event"
    end

    test "CONTROL: without the fault the predecessor is stamped" do
      pred = uid("ss-pred")
      succ = uid("ss-succ")
      title = "Post Commit Supersession Control #{pred}"
      paper_draft!(pred, @good_labels, title)
      assert {:ok, _} = Content.publish_document(pred, "paper", @dataset)

      paper_draft!(succ, Map.put(@good_labels, "supersedes", pred), title)
      assert {:ok, _} = Content.publish_document(succ, "paper", @dataset)

      {:ok, predecessor} = Content.get_document(pred, "paper", @dataset)
      assert predecessor.content["superseded_by"] == succ
    end
  end

  describe "refused-duplicate draft discard" do
    test "a fault on the discard's event keeps the draft and the refusal says so" do
      incumbent = uid("dup-inc")
      dup = uid("dup-new")
      title = "Post Commit Duplicate Paper #{incumbent}"
      paper_draft!(incumbent, @good_labels, title)
      assert {:ok, _} = Content.publish_document(incumbent, "paper", @dataset)

      paper_draft!(dup, @good_labels, title)
      break_events_for!("drafts." <> dup)

      {result, _log} =
        with_log(fn -> Content.publish_document(dup, "paper", @dataset) end)

      assert {:error, {:duplicate_of, payload}} = result
      refute payload.message =~ "was discarded"

      assert match?({:ok, _}, Content.get_document("drafts." <> dup, "paper", @dataset)),
             "the discard survived a failed mutation_event insert — committed with no event"
    end

    test "CONTROL: without the fault the draft is discarded and the refusal says so" do
      incumbent = uid("dup-inc")
      dup = uid("dup-new")
      title = "Post Commit Duplicate Control #{incumbent}"
      paper_draft!(incumbent, @good_labels, title)
      assert {:ok, _} = Content.publish_document(incumbent, "paper", @dataset)

      paper_draft!(dup, @good_labels, title)

      assert {:error, {:duplicate_of, payload}} =
               Content.publish_document(dup, "paper", @dataset)

      assert payload.message =~ "was discarded"
      assert {:error, :not_found} = Content.get_document("drafts." <> dup, "paper", @dataset)
    end
  end
end
