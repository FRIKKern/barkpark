defmodule BarkparkWeb.Contract.ListenTest do
  use BarkparkWeb.ConnCase, async: false
  alias Barkpark.Content

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "rep"
    )
    :ok
  end

  test "replay_since returns rows after the cursor", %{conn: _conn} do
    {:ok, _} = Content.create_document("post", %{"_id" => "r1", "title" => "a"}, "rep")
    {:ok, _} = Content.create_document("post", %{"_id" => "r2", "title" => "b"}, "rep")

    events = BarkparkWeb.ListenController.replay_since("rep", 0)
    assert length(events) >= 2
    r1 = Enum.find(events, &(&1.doc_id == "drafts.r1"))
    r2 = Enum.find(events, &(&1.doc_id == "drafts.r2"))
    assert r1 && r2
    assert r1.id < r2.id
    assert is_map(r1.document)
    assert r1.document["_id"] == "drafts.r1"
  end

  test "replay_since respects the cursor", %{conn: _conn} do
    {:ok, _} = Content.create_document("post", %{"_id" => "r3", "title" => "a"}, "rep")
    first_id = List.last(BarkparkWeb.ListenController.replay_since("rep", 0)).id
    {:ok, _} = Content.create_document("post", %{"_id" => "r4", "title" => "b"}, "rep")

    tail = BarkparkWeb.ListenController.replay_since("rep", first_id)
    ids = Enum.map(tail, & &1.doc_id)
    refute "drafts.r3" in ids
    assert "drafts.r4" in ids
  end
end
