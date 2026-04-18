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

  test "formatted mutation event carries syncTags targeting the published id" do
    {:ok, _} = Content.create_document("post", %{"_id" => "s1", "title" => "a"}, "rep")

    ev =
      BarkparkWeb.ListenController.replay_since("rep", 0)
      |> Enum.find(&(&1.doc_id == "drafts.s1"))

    assert ev

    frame = BarkparkWeb.ListenController.format_event(ev, "rep")
    ["id: " <> _, "event: mutation", "data: " <> json | _] = String.split(frame, "\n")
    payload = Jason.decode!(json)

    assert is_list(payload["syncTags"])
    assert length(payload["syncTags"]) == 2

    Enum.each(payload["syncTags"], fn tag ->
      assert is_binary(tag)
      assert Regex.match?(~r/^bp:ds:rep:(doc:|type:)/, tag)
    end)

    assert "bp:ds:rep:doc:s1" in payload["syncTags"]
    assert "bp:ds:rep:type:post" in payload["syncTags"]
  end
end
