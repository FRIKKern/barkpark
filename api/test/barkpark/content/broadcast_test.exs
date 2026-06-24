defmodule Barkpark.Content.BroadcastTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.Broadcast

  # ---------------------------------------------------------------------------
  # doc_topic/4 — workspace-scoped per-doc topic string
  # ---------------------------------------------------------------------------

  describe "doc_topic/4" do
    test "returns expected workspace-scoped topic with all parts" do
      assert Broadcast.doc_topic("abc123", "post", "ws-1", "production") ==
               "doc:ws:ws-1:production:post:abc123"
    end

    test "encodes dataset and type verbatim" do
      assert Broadcast.doc_topic("myid", "task", "ws-42", "staging") ==
               "doc:ws:ws-42:staging:task:myid"
    end

    test "nil workspace_id normalises to default workspace id or 'global'" do
      topic = Broadcast.doc_topic("someid", "post", nil, "production")
      # Must start with the expected prefix — the normalised ws segment is
      # non-empty regardless of whether a Default workspace is seeded.
      assert String.starts_with?(topic, "doc:ws:")
      assert String.ends_with?(topic, ":production:post:someid")
      ws_segment = topic |> String.split(":") |> Enum.at(2)
      refute ws_segment == ""
    end
  end

  # ---------------------------------------------------------------------------
  # paper_topic/3 — workspace-scoped paper topic string
  # ---------------------------------------------------------------------------

  describe "paper_topic/3" do
    test "returns expected workspace-scoped paper topic" do
      assert Broadcast.paper_topic("intro", "ws-99", "production") ==
               "doc:ws:ws-99:production:paper:intro"
    end

    test "defaults dataset to 'production' when omitted" do
      assert Broadcast.paper_topic("about", "ws-1") ==
               "doc:ws:ws-1:production:paper:about"
    end
  end

  # ---------------------------------------------------------------------------
  # clear_deferred_broadcasts/0 and flush_deferred_broadcasts/0
  # ---------------------------------------------------------------------------

  describe "deferred broadcast process-dict protocol" do
    test "clear_deferred_broadcasts/0 removes both queues and returns :ok" do
      Process.put(:barkpark_deferred_broadcasts, [{"t1", :msg1}])
      Process.put(:barkpark_deferred_webhooks, [{"ds", "act", "type", "id", %{}, "ev", []}])

      assert Broadcast.clear_deferred_broadcasts() == :ok
      assert Process.get(:barkpark_deferred_broadcasts) == nil
      assert Process.get(:barkpark_deferred_webhooks) == nil
    end

    test "clear_deferred_broadcasts/0 is idempotent when queues are empty" do
      assert Broadcast.clear_deferred_broadcasts() == :ok
    end

    test "flush_deferred_broadcasts/0 drains both queues without error when empty" do
      # Should not raise when nothing was queued
      assert Broadcast.flush_deferred_broadcasts() == :ok
      assert Process.get(:barkpark_deferred_broadcasts) == nil
      assert Process.get(:barkpark_deferred_webhooks) == nil
    end
  end
end
