defmodule Barkpark.Content.EventLogTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.{Content, Repo}
  alias Barkpark.Content.MutationEvent
  import Ecto.Query

  test "create inserts a mutation_event row" do
    {:ok, _} = Content.create_document("post", %{"_id" => "ev-1", "title" => "x"}, "test")
    events = Repo.all(from e in MutationEvent, where: e.dataset == "test")
    assert length(events) == 1
    [ev] = events
    assert ev.doc_id == "drafts.ev-1"
    assert ev.type == "post"
    assert is_binary(ev.rev)
    assert is_map(ev.document)
    assert ev.document["_id"] == "drafts.ev-1"
  end

  test "update creates a second event row" do
    {:ok, _} = Content.create_document("post", %{"_id" => "ev-2", "title" => "a"}, "test")
    {:ok, _} = Content.upsert_document("post", %{"_id" => "ev-2", "title" => "b"}, "test")
    events = Repo.all(from e in MutationEvent, where: e.doc_id == "drafts.ev-2", order_by: e.id)
    assert length(events) == 2
  end
end
