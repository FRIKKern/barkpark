defmodule Barkpark.Content.SessionEventsTest do
  use Barkpark.DataCase, async: false
  alias Barkpark.Content
  alias Barkpark.Content.Sessions

  setup do
    {:ok, _} =
      Content.upsert_blocks_doc("session", %{
        "slug" => "session-ev-test",
        "title" => "E",
        "status" => "open"
      })

    :ok
  end

  test "appends events in order with server ts" do
    assert {:ok, %{count: 1}} =
             Sessions.append_event("session-ev-test", "task-closed", %{"ref" => "task-abc"})

    assert {:ok, %{count: 2}} =
             Sessions.append_event("session-ev-test", "push", %{"note" => "pushed main"})

    doc = Content.get_blocks_doc("session-ev-test", "session", "production")
    [e1, e2] = doc.content["events"]
    assert e1["kind"] == "task-closed"
    assert e1["ref"] == "task-abc"
    assert {:ok, _, _} = DateTime.from_iso8601(e1["ts"])
    assert e2["kind"] == "push"
  end

  test "rejects unknown kinds" do
    assert {:error, :invalid_kind} =
             Sessions.append_event("session-ev-test", "deployed", %{})
  end

  test "unknown slug" do
    assert {:error, :not_found} = Sessions.append_event("session-nope", "note", %{})
  end
end
