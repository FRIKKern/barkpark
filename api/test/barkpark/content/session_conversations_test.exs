defmodule Barkpark.Content.SessionConversationsTest do
  use Barkpark.DataCase, async: false
  alias Barkpark.Content
  alias Barkpark.Content.Sessions

  setup do
    {:ok, _} =
      Content.upsert_blocks_doc("session", %{
        "slug" => "session-conv-test",
        "title" => "C",
        "status" => "open"
      })

    :ok
  end

  test "registers a new conversation with server-stamped first_seen/last_active" do
    assert {:ok, %{count: 1}} =
             Sessions.touch_conversation("session-conv-test", "conv-1", %{
               "harness" => "claude-code",
               "account" => "scaffy@jarl.no",
               "machine" => "mbp",
               "cwd" => "/tmp"
             })

    doc = Content.get_blocks_doc("session-conv-test", "session", "production")
    [entry] = doc.content["conversations"]

    assert entry["id"] == "conv-1"
    assert entry["harness"] == "claude-code"
    assert entry["account"] == "scaffy@jarl.no"
    assert entry["machine"] == "mbp"
    assert entry["cwd"] == "/tmp"
    assert {:ok, _, _} = DateTime.from_iso8601(entry["first_seen"])
    assert {:ok, _, _} = DateTime.from_iso8601(entry["last_active"])
    assert entry["first_seen"] == entry["last_active"]
  end

  test "touching the same id again bumps last_active, never first_seen, and does not duplicate" do
    assert {:ok, %{count: 1}} =
             Sessions.touch_conversation("session-conv-test", "conv-1", %{
               "harness" => "claude-code"
             })

    doc1 = Content.get_blocks_doc("session-conv-test", "session", "production")
    [first] = doc1.content["conversations"]
    first_seen = first["first_seen"]

    # Ensure a real clock gap so a naive re-stamp would be observable.
    Process.sleep(1100)

    assert {:ok, %{count: 1}} =
             Sessions.touch_conversation("session-conv-test", "conv-1", %{
               "harness" => "claude-code"
             })

    doc2 = Content.get_blocks_doc("session-conv-test", "session", "production")
    [second] = doc2.content["conversations"]

    assert second["id"] == "conv-1"
    assert second["first_seen"] == first_seen
    assert second["last_active"] != first["last_active"]
  end

  test "a different id appends a second registry entry" do
    assert {:ok, %{count: 1}} =
             Sessions.touch_conversation("session-conv-test", "conv-1", %{})

    assert {:ok, %{count: 2}} =
             Sessions.touch_conversation("session-conv-test", "conv-2", %{})

    doc = Content.get_blocks_doc("session-conv-test", "session", "production")
    ids = Enum.map(doc.content["conversations"], & &1["id"])
    assert ids == ["conv-1", "conv-2"]
  end

  test "caller-supplied first_seen/last_active/timestamps are ignored — always server-minted" do
    bogus = "1999-01-01T00:00:00Z"

    assert {:ok, %{count: 1}} =
             Sessions.touch_conversation("session-conv-test", "conv-1", %{
               "first_seen" => bogus,
               "last_active" => bogus,
               "ts" => bogus
             })

    doc = Content.get_blocks_doc("session-conv-test", "session", "production")
    [entry] = doc.content["conversations"]

    refute entry["first_seen"] == bogus
    refute entry["last_active"] == bogus
    assert {:ok, stored, _} = DateTime.from_iso8601(entry["first_seen"])
    assert DateTime.diff(DateTime.utc_now(), stored, :second) < 5
  end

  test "unknown slug is not_found" do
    assert {:error, :not_found} = Sessions.touch_conversation("session-conv-nope", "conv-1", %{})
  end

  test "empty conversation id is invalid_conversation" do
    assert {:error, :invalid_conversation} =
             Sessions.touch_conversation("session-conv-test", "", %{})
  end

  test "missing/non-binary conversation id is invalid_conversation" do
    assert {:error, :invalid_conversation} =
             Sessions.touch_conversation("session-conv-test", nil, %{})
  end

  test "whitelisted-attr merge: an account update sticks, junk keys are dropped" do
    assert {:ok, %{count: 1}} =
             Sessions.touch_conversation("session-conv-test", "conv-1", %{
               "account" => "old@jarl.no",
               "harness" => "claude-code"
             })

    assert {:ok, %{count: 1}} =
             Sessions.touch_conversation("session-conv-test", "conv-1", %{
               "account" => "new@jarl.no",
               "not_a_real_field" => "should be dropped",
               "id" => "should-not-override"
             })

    doc = Content.get_blocks_doc("session-conv-test", "session", "production")
    [entry] = doc.content["conversations"]

    assert entry["id"] == "conv-1"
    assert entry["account"] == "new@jarl.no"
    assert entry["harness"] == "claude-code"
    refute Map.has_key?(entry, "not_a_real_field")
  end

  test "a generic upsert_blocks_doc with a conversations attr does NOT wipe the registry" do
    assert {:ok, %{count: 1}} =
             Sessions.touch_conversation("session-conv-test", "conv-1", %{})

    assert {:ok, _} =
             Content.upsert_blocks_doc("session", %{
               "slug" => "session-conv-test",
               "status" => "closed",
               "conversations" => []
             })

    doc = Content.get_blocks_doc("session-conv-test", "session", "production")
    assert doc.content["status"] == "closed"
    assert length(doc.content["conversations"]) == 1
  end
end
