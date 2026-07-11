defmodule Barkpark.Tasks.WorkDigestTest do
  @moduledoc """
  Pins the WorkDigest D5 contract (expressive-agent-loops) in BOTH directions:

    * PROGRESS subfields on an acceptance_criteria entry — `met`, `evidence`,
      `attempts`, any future stamp-written key — NEVER change the digest, so a
      worker's own mid-claim stamps can't 409 its default-path close.
    * The WORK DEFINITION still fences: editing a criterion's TEXT, adding,
      removing, or REORDERING criteria all change the digest (and
      `changed_fields/3` names `acceptance_criteria`).

  Pure unit tests — WorkDigest touches no DB.
  """

  use ExUnit.Case, async: true

  alias Barkpark.Tasks.WorkDigest

  @title "build the stamp verb"

  defp content(criteria) do
    %{"description" => "the brief", "acceptance_criteria" => criteria}
  end

  defp criteria do
    [
      %{"criterion" => "gate passes", "met" => false, "evidence" => ""},
      %{"criterion" => "docs updated", "met" => false, "evidence" => ""}
    ]
  end

  defp digest(criteria),
    do: WorkDigest.combined(WorkDigest.field_digests(@title, content(criteria)))

  # ─── Direction 1: progress never trips the fence ──────────────────────────

  describe "D5 — progress subfields do not change the digest" do
    test "flipping met leaves the digest unchanged" do
      after_stamp = List.update_at(criteria(), 0, &Map.put(&1, "met", true))
      assert digest(criteria()) == digest(after_stamp)
    end

    test "writing evidence leaves the digest unchanged" do
      after_stamp =
        List.update_at(criteria(), 0, &Map.merge(&1, %{"met" => true, "evidence" => "PR #42"}))

      assert digest(criteria()) == digest(after_stamp)
    end

    test "appending a miss attempt leaves the digest unchanged" do
      attempt = %{"note" => "flaky sandbox", "ts" => "2026-07-11T00:00:00Z", "worker" => "w"}
      after_miss = List.update_at(criteria(), 0, &Map.put(&1, "attempts", [attempt]))
      assert digest(criteria()) == digest(after_miss)
    end

    test "any FUTURE progress subfield is excluded by construction" do
      # The reduction keeps only the criterion text, so a key that does not
      # exist yet (e.g. a later slice's per-criterion pulse) can never regress
      # into fencing the close.
      after_future = List.update_at(criteria(), 1, &Map.put(&1, "confidence", 0.8))
      assert digest(criteria()) == digest(after_future)
    end

    test "changed_fields/3 reports nothing for a pure progress flip" do
      stored = WorkDigest.field_digests(@title, content(criteria()))
      after_stamp = List.update_at(criteria(), 0, &Map.put(&1, "met", true))
      assert WorkDigest.changed_fields(stored, @title, content(after_stamp)) == []
    end
  end

  # ─── Direction 2: the work definition still fences ────────────────────────

  describe "D5 — criterion text stays work-defining" do
    test "editing a criterion's text changes the digest" do
      edited = List.update_at(criteria(), 0, &Map.put(&1, "criterion", "gate passes TWICE"))
      refute digest(criteria()) == digest(edited)
    end

    test "adding a criterion changes the digest" do
      added = criteria() ++ [%{"criterion" => "new obligation", "met" => false}]
      refute digest(criteria()) == digest(added)
    end

    test "removing a criterion changes the digest" do
      refute digest(criteria()) == digest(tl(criteria()))
    end

    test "reordering criteria changes the digest (lists keep their order)" do
      refute digest(criteria()) == digest(Enum.reverse(criteria()))
    end

    test "changed_fields/3 names acceptance_criteria on a text edit" do
      stored = WorkDigest.field_digests(@title, content(criteria()))
      edited = List.update_at(criteria(), 0, &Map.put(&1, "criterion", "rewritten"))

      assert WorkDigest.changed_fields(stored, @title, content(edited)) ==
               ["acceptance_criteria"]
    end
  end

  # ─── The other work-defining fields are untouched by D5 ───────────────────

  describe "title/description digests" do
    test "a description edit still changes the digest and is named" do
      stored = WorkDigest.field_digests(@title, content(criteria()))
      changed = Map.put(content(criteria()), "description", "rewritten brief")

      refute WorkDigest.combined(WorkDigest.field_digests(@title, changed)) ==
               WorkDigest.combined(stored)

      assert WorkDigest.changed_fields(stored, @title, changed) == ["description"]
    end

    test "a title edit still changes the digest and is named" do
      stored = WorkDigest.field_digests(@title, content(criteria()))
      assert WorkDigest.changed_fields(stored, "renamed", content(criteria())) == ["title"]
    end
  end

  # ─── Malformed shapes stay deterministic (the digest self-compares) ───────

  describe "degenerate shapes" do
    test "non-list acceptance_criteria and non-map entries digest deterministically" do
      weird = %{"acceptance_criteria" => "not-a-list"}
      assert WorkDigest.field_digests(@title, weird) == WorkDigest.field_digests(@title, weird)

      mixed = %{"acceptance_criteria" => ["bare string", %{"criterion" => "real"}]}
      assert WorkDigest.field_digests(@title, mixed) == WorkDigest.field_digests(@title, mixed)
    end
  end
end
