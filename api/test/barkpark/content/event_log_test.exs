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

  # ---------------------------------------------------------------------------
  # head_event_id/3 (task-399143cf7ac6b952): the welcome frame's resume point.
  # Each test proves the SAME property replay_since/4's own tests prove above
  # — scoped identically — because head_event_id's whole reason to exist is
  # that a reconnect with its value replays EXACTLY what was written after it.
  # ---------------------------------------------------------------------------

  test "head_event_id is nil for a dataset with no events at all" do
    assert EventLog.head_event_id("hei-empty-#{System.unique_integer([:positive])}") == nil
  end

  test "head_event_id (nil-workspace leg) is the newest id, and a replay from it sees only what comes after" do
    ds = "hei-flat-#{System.unique_integer([:positive])}"
    {:ok, _} = Content.create_document("post", %{"_id" => "hei-f1", "title" => "one"}, ds)
    head = EventLog.head_event_id(ds)
    assert is_integer(head)

    {:ok, _} = Content.create_document("post", %{"_id" => "hei-f2", "title" => "two"}, ds)

    resumed = EventLog.replay_since(ds, head) |> Enum.to_list()
    assert [%{doc_id: "drafts.hei-f2"}] = resumed

    assert EventLog.head_event_id(ds) > head
  end

  test "head_event_id excludes type:listener rows, same as replay_since" do
    ds = "hei-egress-#{System.unique_integer([:positive])}"
    {:ok, _} = Content.create_document("post", %{"_id" => "hei-e1", "title" => "p"}, ds)
    head_before_listener = EventLog.head_event_id(ds)

    {:ok, _} = Content.create_document("listener", %{"_id" => "hei-e2", "title" => "w"}, ds)

    assert EventLog.head_event_id(ds) == head_before_listener,
           "a listener presence row moved the head id — it must be invisible to this read, " <>
             "the same egress exclusion replay_since/4 already enforces"
  end

  # A direct Repo.insert!, not Content.create_document/4: the writer resolves
  # an unscoped create through a `scope_source: "default_fallback"` workspace
  # rather than a genuine NULL — the same reason
  # edges_workspace_fence_test.exs's own ":shared_only binds the SHARED layer"
  # test builds its global rows by inserting directly rather than through the
  # normal write door.
  defp insert_shared_event!(dataset) do
    Repo.insert!(%MutationEvent{
      dataset: dataset,
      type: "post",
      doc_id: "drafts.hei-shared-#{System.unique_integer([:positive])}",
      mutation: "create",
      rev: "rev-#{System.unique_integer([:positive])}",
      document: %{},
      workspace_id: nil,
      inserted_at: DateTime.utc_now()
    })
  end

  test "head_event_id (:shared_only leg) ignores a workspace-scoped event on the same dataset" do
    ws = create_workspace!()
    proj = create_project!(ws)
    ds = "hei-shared-#{System.unique_integer([:positive])}"

    shared_event = insert_shared_event!(ds)
    shared_head = EventLog.head_event_id(ds, :shared_only)
    assert shared_head == shared_event.id

    {:ok, _} = create_document_in!(ws, proj, "post", %{"doc_id" => "hei-s2"}, ds)

    assert EventLog.head_event_id(ds, :shared_only) == shared_head,
           "a workspace-scoped write must not move the :shared_only head"

    assert EventLog.head_event_id(ds, ws.id) > shared_head,
           "the workspace-scoped leg must see its own write"
  end

  test "head_event_id (workspace-scoped leg) narrows by project_id, same as replay_since's opts" do
    ws = create_workspace!()
    proj_a = create_project!(ws)
    proj_b = create_project!(ws)
    ds = "hei-proj-#{System.unique_integer([:positive])}"

    {:ok, _} = create_document_in!(ws, proj_a, "post", %{"doc_id" => "hei-pa"}, ds)
    head_a = EventLog.head_event_id(ds, ws.id, project_id: proj_a.id)
    assert is_integer(head_a)

    {:ok, _} = create_document_in!(ws, proj_b, "post", %{"doc_id" => "hei-pb"}, ds)

    assert EventLog.head_event_id(ds, ws.id, project_id: proj_a.id) == head_a,
           "project B's write must not move project A's head"

    assert EventLog.head_event_id(ds, ws.id, project_id: proj_b.id) > head_a
  end
end
