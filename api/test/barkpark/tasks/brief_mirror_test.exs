defmodule Barkpark.Tasks.BriefMirrorTest do
  use ExUnit.Case, async: true

  alias Barkpark.Tasks.BriefMirror

  # The defect these pin has no receipt: a task write stored `description`
  # perfectly, returned ok, and left the brief's `purpose-copy` block frozen at
  # its create-time text. Measured on a live scratch row across twelve patches
  # from 4,000 to 1,000,000 bytes — every call ok, every read-back byte-exact,
  # the brief unchanged throughout — and again patching back DOWN to 198 bytes.
  # Size was never the variable; the mirror was simply never written.
  #
  # Half of these tests assert the re-sync. The other half assert what it must
  # NOT touch, because the danger in a fix that rewrites stored content is not
  # that it fails to fire but that it fires too widely.

  defp purpose(text),
    do: %{
      "id" => "purpose-copy",
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => text}]
    }

  defp criteria(items),
    do: %{"id" => "criteria-list", "type" => "list", "ordered" => false, "items" => items}

  defp task(content), do: %{"title" => "A task", "content" => content}

  defp brief(blocks), do: %{"version" => 1, "blocks" => blocks}

  defp purpose_text(attrs) do
    attrs["content"]["brief"]["blocks"]
    |> Enum.find(&(&1["id"] == "purpose-copy"))
    |> get_in(["content", Access.at(0), "value"])
  end

  defp blocks(attrs), do: attrs["content"]["brief"]["blocks"]

  describe "the drift itself" do
    test "a changed description is re-derived into the purpose-copy block" do
      attrs =
        task(%{
          "description" => "THE NEW RUNBOOK, authoritative",
          "brief" => brief([purpose("the frozen create-time text")])
        })

      assert purpose_text(BriefMirror.maybe_resync_task_brief(attrs, "task")) ==
               "THE NEW RUNBOOK, authoritative",
             "the brief kept its stale text — this is the defect, and a worker reads this block first"
    end

    test "changed acceptance_criteria are re-derived into the criteria-list block" do
      # The 2026-08-20 sweep is explicit that a remedy re-deriving only the
      # purpose leaves this half open: 94 docs disagree on COUNT, 50 on TEXT.
      attrs =
        task(%{
          "acceptance_criteria" => [
            %{"criterion" => "gates green"},
            %{"criterion" => "  evidence stamped  "},
            %{"criterion" => "   "},
            %{"no_criterion_key" => true}
          ],
          "brief" => brief([criteria(["a stale, shorter list"])])
        })

      assert [%{"items" => items}] = blocks(BriefMirror.maybe_resync_task_brief(attrs, "task"))

      assert items == ["gates green", "evidence stamped"],
             "criterion texts must be trimmed, blanks and malformed entries dropped, order kept"
    end

    test "an empty description falls back to the composer's stub, using the title" do
      attrs = task(%{"description" => "   ", "brief" => brief([purpose("stale")])})

      assert purpose_text(BriefMirror.maybe_resync_task_brief(attrs, "task")) ==
               "Complete the work described by “A task” and record verifiable evidence."
    end

    test "markdown is stripped exactly as the Go composer strips it" do
      # The composer removes exactly **, __ and backticks. A normaliser more
      # aggressive than that would rewrite prose the composer would have kept,
      # and a less aggressive one leaves every formatted description reading as
      # a permanent divergence — the false-positive that cost the first sweep
      # 108 suspects out of 300.
      attrs =
        task(%{
          "description" => "**bold** and __under__ and `code` and *single* stays",
          "brief" => brief([purpose("stale")])
        })

      assert purpose_text(BriefMirror.maybe_resync_task_brief(attrs, "task")) ==
               "bold and under and code and *single* stays"
    end

    test "re-syncing is idempotent" do
      attrs = task(%{"description" => "settled", "brief" => brief([purpose("stale")])})
      once = BriefMirror.maybe_resync_task_brief(attrs, "task")
      assert BriefMirror.maybe_resync_task_brief(once, "task") == once
    end
  end

  describe "what it must not touch" do
    test "every other block survives byte-identical, in order" do
      # The whole objection to fixing this client-side was that the client can
      # only refuse or clobber. The server's claim to do better is exactly this
      # assertion, so it is the load-bearing test of the design.
      hand_authored = %{
        "id" => "operator-notes",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "prose only a human wrote"}]
      }

      heading = %{"id" => "criteria", "type" => "heading", "level" => 2, "text" => "Criteria"}

      attrs =
        task(%{
          "description" => "new",
          "acceptance_criteria" => [%{"criterion" => "one"}],
          "brief" =>
            brief([heading, criteria(["old"]), hand_authored, purpose("stale"), hand_authored])
        })

      result = blocks(BriefMirror.maybe_resync_task_brief(attrs, "task"))

      assert Enum.map(result, & &1["id"]) ==
               ~w(criteria criteria-list operator-notes purpose-copy operator-notes),
             "block order changed"

      assert Enum.at(result, 0) == heading, "a heading block was rewritten"
      assert Enum.at(result, 2) == hand_authored, "a hand-authored block was rewritten"
      assert Enum.at(result, 4) == hand_authored, "a hand-authored block was rewritten"
    end

    test "non-derived keys on a matched block are preserved" do
      attrs =
        task(%{
          "description" => "new",
          "brief" => brief([Map.put(purpose("stale"), "custom_key", "keep me")])
        })

      assert [block] = blocks(BriefMirror.maybe_resync_task_brief(attrs, "task"))
      assert block["custom_key"] == "keep me"
      assert block["type"] == "paragraph"
    end

    test "blocks are matched by exact id, never by position" do
      # 2,458 docs carry no purpose-copy block at all. A positional "first
      # paragraph with content" fallback manufactured 794 false suspects in the
      # sweep, one of them a block holding a lone \x01 byte. There is no
      # fallback, and this is what proves it.
      stray = %{
        "id" => "some-other-paragraph",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "\x01"}]
      }

      attrs = task(%{"description" => "new", "brief" => brief([stray])})

      assert blocks(BriefMirror.maybe_resync_task_brief(attrs, "task")) == [stray],
             "a positionally-similar block was rewritten — the no-fallback rule is broken"
    end

    test "a missing source field leaves its block alone rather than emptying it" do
      # Absence is not an empty value. Silently clearing a builder's criteria
      # would be a worse defect than the drift being closed.
      no_criteria = task(%{"description" => "new", "brief" => brief([criteria(["keep"])])})

      assert [%{"items" => ["keep"]}] =
               blocks(BriefMirror.maybe_resync_task_brief(no_criteria, "task"))

      not_a_list =
        task(%{"acceptance_criteria" => "oops", "brief" => brief([criteria(["keep"])])})

      assert [%{"items" => ["keep"]}] =
               blocks(BriefMirror.maybe_resync_task_brief(not_a_list, "task"))

      no_description = task(%{"brief" => brief([purpose("keep")])})
      assert purpose_text(BriefMirror.maybe_resync_task_brief(no_description, "task")) == "keep"
    end

    test "a stale row's FIRST write carries a one-time brief correction — a known, deliberate side effect" do
      # Pinned because it is surprising and it is load-bearing for anyone
      # reading a `doc_changed_since_claim` 409 after this ships.
      #
      # `brief` is a work-digest field (Barkpark.Tasks.WorkDigest @fields),
      # alongside `description` and `acceptance_criteria`. For a row whose brief
      # is already IN SYNC, this changes nothing: the re-sync is a no-op unless
      # one of those two source fields moved, and both already trip the digest
      # on their own, so no write trips the fence that would not have before.
      #
      # The exception is a row whose brief is ALREADY STALE. There, a write that
      # touches no work-defining field at all — appending a
      # `disposition_reason`, say — now also carries the correction, so the
      # brief sub-digest moves and a claim holder closing afterwards can see
      # `doc_changed_since_claim` naming `brief`. That is a true report, not a
      # false one: the brief they read WAS stale and has been corrected, which
      # is exactly what the fence exists to tell them. It is one-time per stale
      # row, and the documented recovery (re-read, then close pinning
      # observed_rev) applies unchanged.
      stale =
        task(%{
          "description" => "the current description",
          "disposition_reason" => "note one",
          "brief" => brief([purpose("a stale brief from create time")])
        })

      unrelated_write = put_in(stale, ["content", "disposition_reason"], "note one + note two")
      resynced = BriefMirror.maybe_resync_task_brief(unrelated_write, "task")

      assert purpose_text(resynced) == "the current description",
             "the one-time correction did not happen on an unrelated write"

      refute resynced["content"]["brief"] == unrelated_write["content"]["brief"],
             "the brief must be reported as changed — a silent correction is the defect, not the fix"

      # And the no-op case: an in-sync row's unrelated write changes nothing.
      in_sync =
        task(%{
          "description" => "the current description",
          "disposition_reason" => "note one",
          "brief" => brief([purpose("the current description")])
        })

      assert BriefMirror.maybe_resync_task_brief(in_sync, "task") == in_sync,
             "an in-sync row must be untouched, or every write would trip the claim fence"
    end

    test "it is total: non-task types and unexpected shapes pass through untouched" do
      for {attrs, type} <- [
            {task(%{"description" => "new", "brief" => brief([purpose("stale")])}), "paper"},
            {task(%{"description" => "new", "brief" => brief([purpose("stale")])}), "sheet"},
            {task(%{"description" => "new"}), "task"},
            {task(%{"description" => "new", "brief" => %{"version" => 1}}), "task"},
            {task(%{"description" => "new", "brief" => %{"blocks" => "not a list"}}), "task"},
            {task(%{"description" => "new", "brief" => "not a map"}), "task"},
            {%{"title" => "no content at all"}, "task"}
          ] do
        assert BriefMirror.maybe_resync_task_brief(attrs, type) == attrs,
               "mutated an input it should have passed through: #{inspect(type)} #{inspect(attrs)}"
      end
    end
  end
end

defmodule Barkpark.Tasks.BriefMirrorWiringTest do
  @moduledoc """
  The unit tests above prove the RULE. This proves something they cannot: that
  the write path actually consults it.

  Deleting either call site in `Barkpark.Content.Writer` leaves every unit test
  green while the defect walks straight back in, so without this the suite would
  certify a fix that is wired to nothing. It goes through `Content.upsert_document/3`
  — the real door a task `patch` comes through — and asserts against the stored
  document, not against a return value composed in memory.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  @dataset "production"

  defp stored_purpose(doc) do
    doc.content["brief"]["blocks"]
    |> Enum.find(&(&1["id"] == "purpose-copy"))
    |> get_in(["content", Access.at(0), "value"])
  end

  test "a description write re-syncs the stored brief, and leaves other blocks alone" do
    id = "brief-mirror-wiring-#{System.unique_integer([:positive])}"

    hand_authored = %{
      "id" => "operator-notes",
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => "prose only a human wrote"}]
    }

    brief = %{
      "version" => 1,
      "blocks" => [
        hand_authored,
        %{
          "id" => "purpose-copy",
          "type" => "paragraph",
          # Deliberately NOT the description this document is created with, so
          # the create call site is covered too: both pipes must consult the
          # re-sync, and a test that only exercised the update path would leave
          # the create wiring free to be deleted.
          "content" => [%{"type" => "text", "value" => "a brief that never matched"}]
        }
      ]
    }

    {:ok, created} =
      Content.upsert_document(
        "task",
        %{
          "doc_id" => id,
          "title" => "A wiring probe",
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "title" => "A wiring probe",
            "description" => "the create-time text",
            "brief" => brief
          }
        },
        @dataset
      )

    assert stored_purpose(created) == "the create-time text",
           "the CREATE call site is not wired: the brief was stored still holding text the description never matched"

    # The write that used to freeze the brief: description moves, brief is not
    # mentioned. This is the exact shape measured on the live scratch row.
    {:ok, updated} =
      Content.upsert_document(
        "task",
        %{
          "doc_id" => id,
          "title" => "A wiring probe",
          "content" => Map.put(created.content, "description", "THE REPLACEMENT RUNBOOK")
        },
        @dataset
      )

    assert stored_purpose(updated) == "THE REPLACEMENT RUNBOOK",
           "the stored brief kept its stale text: the re-sync is not wired into the write path, " <>
             "so the task still holds two different versions of its own instructions"

    assert Enum.find(updated.content["brief"]["blocks"], &(&1["id"] == "operator-notes")) ==
             hand_authored,
           "the hand-authored block was rewritten by the re-sync"
  end

  test "the create_document door is wired too" do
    # Discovered by mutation: neutering the create_document call site left the
    # whole suite green, because the test above reaches storage through
    # upsert_document. Two doors were counted; only one was covered. The
    # `create`/`createOrReplace` mutations come through here, so it gets its own
    # probe rather than an assumption.
    {:ok, created} =
      Content.create_document(
        "task",
        %{
          "doc_id" => "brief-mirror-create-#{System.unique_integer([:positive])}",
          "title" => "A create-door probe",
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "title" => "A create-door probe",
            "description" => "the authoritative description",
            "brief" => %{
              "version" => 1,
              "blocks" => [
                %{
                  "id" => "purpose-copy",
                  "type" => "paragraph",
                  "content" => [%{"type" => "text", "value" => "a brief that never matched"}]
                }
              ]
            }
          }
        },
        @dataset
      )

    assert stored_purpose(created) == "the authoritative description",
           "create_document stored a brief the description never matched: that call site is not wired"
  end
end
