defmodule Barkpark.Tasks.InternalBriefMirrorCasTest do
  @moduledoc """
  THE DETECTOR FOR THE TASK CAS DOOR (task-59ced18605d8ef81).

  `Barkpark.Tasks.BriefMirrorWiringTest` proves the DOCUMENT doors consult the
  mirror — `Content.create_document/3` and `Content.upsert_document/3`, the two
  call sites PR #16279 wired. It cannot prove anything about this one. Every
  `bp task` verb writes through a different door entirely:
  `Barkpark.Tasks.Internal.fenced_content_write/4`, a bare rev-fenced
  `Repo.update_all(set: [content: …])` that never passes through
  `Content.Writer`'s attrs pipeline and therefore never reaches `BriefMirror`.
  Eighteen modules on `api/lib` call it — the whole verb family (claim, close,
  compactor, discharge, fence, fleet, landed, move, mutations, pulse, release,
  renew, stage, stamp, ttl_sweeper) plus the two GitHub plugin callers (adopt,
  link).

  WHY THE DEFECT IS LATENT AND THIS SUITE IS STILL REQUIRED. A structural sweep
  of all 18 callers (write shapes only: `Map.put(` / `put_in(` / `Map.merge(`)
  enumerates 53 distinct literal keys they write, and `"description"` is not
  among them. `"criterion"` is written at three sites and none of them changes a
  stored criterion's text — two write an INTEGER index into a mark/note record
  (discharge.ex, pulse.ex) and the third is the CAS guard, which
  `internal.ex apply_criteria_update/2` refuses unless it EQUALS the stored text.
  So no verb shipping today can drift the brief through this door, and no
  behaviour changes for any of them.

  That is exactly the hazard. The door is STRUCTURALLY INCAPABLE of re-deriving
  the brief, and before this file nothing tested that property. The day one of
  those 18 sites starts writing `description`, a criterion's text, or a new
  criteria list — a new verb, an edit to close's outcome handling, a bulk repair
  helper — the drift returns silently and no test reds. These tests therefore
  drive the mirrored change through the door DIRECTLY, because no public verb
  can: the subject is the door's capability, not any current verb's behaviour.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.Internal

  @dataset "production"

  defp purpose_text(%Document{} = doc) do
    doc.content["brief"]["blocks"]
    |> Enum.find(&(&1["id"] == "purpose-copy"))
    |> get_in(["content", Access.at(0), "value"])
  end

  defp criteria_items(%Document{} = doc) do
    doc.content["brief"]["blocks"]
    |> Enum.find(&(&1["id"] == "criteria-list"))
    |> Map.get("items")
  end

  defp create_task(description, criteria) do
    id = "internal-cas-mirror-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.upsert_document(
        "task",
        %{
          "doc_id" => id,
          "title" => "A CAS-door probe",
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "title" => "A CAS-door probe",
            "description" => description,
            "acceptance_criteria" => criteria,
            "brief" => %{
              "version" => 1,
              "blocks" => [
                %{
                  "id" => "operator-notes",
                  "type" => "paragraph",
                  "content" => [%{"type" => "text", "value" => "prose only a human wrote"}]
                },
                %{
                  "id" => "purpose-copy",
                  "type" => "paragraph",
                  "content" => [%{"type" => "text", "value" => "placeholder"}]
                },
                %{"id" => "criteria-list", "type" => "bulleted_list", "items" => ["placeholder"]}
              ]
            }
          }
        },
        @dataset
      )

    doc
  end

  defp criterion(text), do: %{"criterion" => text, "met" => false, "evidence" => ""}

  # Re-read from Postgres rather than trusting the returned struct: the whole
  # point of this door is that it writes the STORED row.
  defp reload(%Document{id: id}), do: Repo.get!(Document, id)

  describe "fenced_content_write/4 and the mirrored blocks" do
    test "a description change through the CAS door re-derives the brief" do
      doc = create_task("the create-time text", [criterion("prove it")])

      assert purpose_text(doc) == "the create-time text",
             "fixture is broken: the document door did not sync the brief at create, " <>
               "so this test could not tell a fixed CAS door from a broken one"

      moved = Map.put(doc.content, "description", "THE REPLACEMENT RUNBOOK")
      assert {:ok, _} = Internal.fenced_content_write(doc, doc.rev, moved, Internal.generate_rev())

      stored = reload(doc)

      assert stored.content["description"] == "THE REPLACEMENT RUNBOOK",
             "the write itself did not land — nothing below this line means anything"

      assert purpose_text(stored) == "THE REPLACEMENT RUNBOOK",
             "the task CAS door stored a description its own brief contradicts: " <>
               "fenced_content_write/4 bypasses BriefMirror, so the row now holds two " <>
               "different versions of its own instructions and the brief is the one a " <>
               "dispatched worker reads first"
    end

    test "a criterion text change through the CAS door re-derives the criteria list" do
      doc = create_task("stable prose", [criterion("prove it"), criterion("and prove that")])

      assert criteria_items(doc) == ["prove it", "and prove that"]

      retexted =
        Map.put(doc.content, "acceptance_criteria", [
          criterion("prove it"),
          criterion("A COMPLETELY DIFFERENT SECOND CRITERION")
        ])

      assert {:ok, _} =
               Internal.fenced_content_write(doc, doc.rev, retexted, Internal.generate_rev())

      stored = reload(doc)

      assert criteria_items(stored) == ["prove it", "A COMPLETELY DIFFERENT SECOND CRITERION"],
             "the CAS door rewrote the criteria and left the brief's criteria-list block " <>
               "holding the old wording: a builder working the brief works to criteria " <>
               "the ledger no longer scores"
    end

    test "a criteria list that GAINS an entry re-derives the criteria list" do
      # Membership, not text. The mirror derives the list from the entries, so
      # an added criterion drifts the brief without editing a single word.
      doc = create_task("stable prose", [criterion("prove it")])

      grown = Map.put(doc.content, "acceptance_criteria", [criterion("prove it"), criterion("c1")])
      assert {:ok, _} = Internal.fenced_content_write(doc, doc.rev, grown, Internal.generate_rev())

      assert criteria_items(reload(doc)) == ["prove it", "c1"],
             "an added criterion never reached the brief: the brief under-counts the work"
    end

    test "the hand-authored blocks and block order survive the re-derive" do
      doc = create_task("the create-time text", [criterion("prove it")])
      hand = Enum.find(doc.content["brief"]["blocks"], &(&1["id"] == "operator-notes"))

      moved = Map.put(doc.content, "description", "moved")
      assert {:ok, _} = Internal.fenced_content_write(doc, doc.rev, moved, Internal.generate_rev())

      stored = reload(doc)

      assert Enum.map(stored.content["brief"]["blocks"], & &1["id"]) ==
               ["operator-notes", "purpose-copy", "criteria-list"]

      assert Enum.find(stored.content["brief"]["blocks"], &(&1["id"] == "operator-notes")) == hand,
             "the re-sync rewrote a block it does not own"
    end
  end

  describe "the hot CAS path is untouched" do
    # claim/pulse/stamp run constantly. The re-derive is gated on the mirrored
    # inputs ACTUALLY differing, so the overwhelmingly common write — one that
    # names neither block — must reach storage byte-identical in the brief and
    # must not silently repair a brief that was already stale. Repairing here
    # would move rows the brief-drift backfill is measuring, under it.
    test "a claim-shaped write leaves an in-sync brief byte-identical" do
      doc = create_task("stable prose", [criterion("prove it")])
      before = doc.content["brief"]

      claimed =
        Map.put(doc.content, "claim", %{"worker" => "w1", "epoch" => 1, "open" => true})

      assert {:ok, _} =
               Internal.fenced_content_write(doc, doc.rev, claimed, Internal.generate_rev())

      stored = reload(doc)
      assert stored.content["claim"]["worker"] == "w1"
      assert stored.content["brief"] == before
    end

    test "a write that names neither block does not repair an already-stale brief" do
      doc = create_task("stable prose", [criterion("prove it")])

      # Drift the brief behind the writer's back, the way history did.
      stale_blocks =
        Enum.map(doc.content["brief"]["blocks"], fn
          %{"id" => "purpose-copy"} = b ->
            Map.put(b, "content", [%{"type" => "text", "value" => "HISTORICALLY STALE"}])

          b ->
            b
        end)

      stale_content = put_in(doc.content, ["brief", "blocks"], stale_blocks)

      assert {:ok, drifted} =
               Internal.fenced_content_write(doc, doc.rev, stale_content, Internal.generate_rev())

      pulsed = Map.put(drifted.content, "pulse", %{"ts" => "2026-09-07T00:00:00Z"})

      assert {:ok, _} =
               Internal.fenced_content_write(
                 drifted,
                 drifted.rev,
                 pulsed,
                 Internal.generate_rev()
               )

      assert purpose_text(reload(doc)) == "HISTORICALLY STALE",
             "an unrelated CAS write silently repaired a stale brief: this door must " <>
               "change only what its verb named, or every claim/pulse becomes an " <>
               "unrecorded content edit and the drift backfill's population moves under it"
    end

    test "a non-task document is passed through untouched" do
      {:ok, paper} =
        Content.upsert_document(
          "paper",
          %{
            "doc_id" => "internal-cas-mirror-paper-#{System.unique_integer([:positive])}",
            "title" => "not a task",
            "content" => %{"description" => "a", "brief" => %{"blocks" => []}}
          },
          @dataset
        )

      moved = Map.put(paper.content, "description", "b")

      assert {:ok, stored} =
               Internal.fenced_content_write(paper, paper.rev, moved, Internal.generate_rev())

      assert stored.content == moved
    end
  end
end
