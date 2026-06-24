defmodule Barkpark.Tasks.InternalTest do
  @moduledoc """
  Pure unit tests for `Barkpark.Tasks.Internal`.

  All three pure / struct-building functions are exercised here with no
  database access — `use ExUnit.Case, async: true`.

  Functions covered:
    * `generate_rev/0`     — shape and uniqueness of the returned token
    * `current_epoch/1`    — epoch extraction + fallback to 0
    * `task_broadcast/4`   — map assembly from Document + MutationEvent
  """

  use ExUnit.Case, async: true

  alias Barkpark.Tasks.Internal
  alias Barkpark.Content.{Document, MutationEvent}

  # ---------------------------------------------------------------------------
  # generate_rev/0
  # ---------------------------------------------------------------------------

  describe "generate_rev/0" do
    test "returns a 32-character lowercase hex string" do
      rev = Internal.generate_rev()
      assert is_binary(rev)
      assert byte_size(rev) == 32
      assert rev =~ ~r/\A[0-9a-f]{32}\z/
    end

    test "two consecutive calls return distinct tokens" do
      assert Internal.generate_rev() != Internal.generate_rev()
    end
  end

  # ---------------------------------------------------------------------------
  # current_epoch/1
  # ---------------------------------------------------------------------------

  describe "current_epoch/1" do
    test "extracts an integer epoch from Document.content claim map" do
      doc = %Document{content: %{"claim" => %{"epoch" => 7}}}
      assert Internal.current_epoch(doc) == 7
    end

    test "returns 0 for epoch value 0" do
      doc = %Document{content: %{"claim" => %{"epoch" => 0}}}
      assert Internal.current_epoch(doc) == 0
    end

    test "returns 0 when content has no claim key" do
      doc = %Document{content: %{}}
      assert Internal.current_epoch(doc) == 0
    end

    test "returns 0 when content map is missing entirely (nil)" do
      doc = %Document{content: nil}
      assert Internal.current_epoch(doc) == 0
    end

    test "returns 0 when the epoch value is not an integer (e.g. string)" do
      doc = %Document{content: %{"claim" => %{"epoch" => "5"}}}
      assert Internal.current_epoch(doc) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # task_broadcast/4
  # ---------------------------------------------------------------------------

  describe "task_broadcast/4" do
    setup do
      doc = %Document{
        doc_id: "task-abc",
        type: "type:task",
        dataset: "production",
        title: "Test task",
        status: "ready",
        content: %{},
        rev: "aabbccdd"
      }

      ev = %MutationEvent{id: 99}

      %{doc: doc, ev: ev}
    end

    test "returns a map with all four required keys", %{doc: doc, ev: ev} do
      result = Internal.task_broadcast(doc, "task.claimed", ev, "prevrev")

      assert %{doc: _, kind: _, event_id: _, previous_rev: _} = result
    end

    test "passes through the document struct unchanged", %{doc: doc, ev: ev} do
      %{doc: returned_doc} = Internal.task_broadcast(doc, "task.claimed", ev, "prevrev")
      assert returned_doc == doc
    end

    test "captures kind, event_id and previous_rev correctly", %{doc: doc, ev: ev} do
      result = Internal.task_broadcast(doc, "task.closed", ev, "old-rev-123")

      assert result.kind == "task.closed"
      assert result.event_id == 99
      assert result.previous_rev == "old-rev-123"
    end
  end
end
