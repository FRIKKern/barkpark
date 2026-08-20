defmodule Barkpark.Content.EventLogTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.{Content, Repo}
  alias Barkpark.Content.{EventLog, MutationEvent}
  import Ecto.Query
  import Barkpark.TenancyFixtures

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

  # ---------------------------------------------------------------------------
  # Listener egress guard (PDF-D18): the Last-Event-ID replay NEVER resurfaces
  # a `type:"listener"` presence row. Mirrors the Sync.Outbox exclusion (#5626).
  # MUTATION-PROOF: drop `and e.type != "listener"` from either where-clause and
  # the matching test below fails (a listener row leaks into the replay).
  # ---------------------------------------------------------------------------

  test "replay_since (nil-workspace leg) excludes type:listener rows" do
    {:ok, _} = Content.create_document("post", %{"_id" => "egp-1", "title" => "p"}, "egtest")
    {:ok, _} = Content.create_document("listener", %{"_id" => "egl-1", "title" => "w1"}, "egtest")

    types =
      EventLog.replay_since("egtest", 0)
      |> Enum.to_list()
      |> Enum.map(& &1.type)

    assert "post" in types
    refute "listener" in types, "listener presence leaked into replay: #{inspect(types)}"
  end

  test "replay_since (workspace-scoped leg) excludes type:listener rows" do
    ws = create_workspace!()
    proj = create_project!(ws)

    {:ok, _} = create_document_in!(ws, proj, "post", %{"doc_id" => "egwp-1"}, "egtest")
    {:ok, _} = create_document_in!(ws, proj, "listener", %{"doc_id" => "egwl-1"}, "egtest")

    events = EventLog.replay_since("egtest", 0, ws.id) |> Enum.to_list()
    types = Enum.map(events, & &1.type)

    assert "post" in types
    refute "listener" in types, "listener presence leaked into scoped replay: #{inspect(types)}"
  end
end
