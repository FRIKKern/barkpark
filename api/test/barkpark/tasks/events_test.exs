defmodule Barkpark.Tasks.EventsTest do
  @moduledoc """
  Unit + integration + route-precedence tests for the task-events feed
  (`Barkpark.Tasks.Events` + `GET /v1/tasks/events?since=`).

  Proves the wave's criterion 1 obligations:

    1. id-ASC ordered replay with `id` as the stable cursor;
    2. keyset paging across a batch boundary (batch ≤ 500);
    3. the feed carries claim/close/move AND `task.criterion` + `task.pulse`
       kinds (D10 — the feed is kind-agnostic, so those kinds are proven by
       inserting them directly, ahead of their emitters merging);
    4. dataset + type='task' scoping (foreign-dataset / non-task events excluded);
    5. the projected wire shape is exactly `{id, event, doc_id, rev, at}`;
    6. the route mounts ABOVE `/tasks/:doc_id` — `/v1/tasks/events` never
       resolves as `:doc_id = "events"`.

  Runs as a `ConnCase` so the same file exercises the pure module read, the HTTP
  endpoint, and router precedence.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.Events
  alias Barkpark.Tasks.Internal

  @token "barkpark-test-events-token"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-events", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)

    task = mk_task!(uniq("evt"), scope)

    # Baseline cursor: the max mutation_events id BEFORE we inject our controlled
    # events, so the assertions ignore whatever create_document already emitted.
    baseline = max_event_id()

    %{scope: scope, task: task, baseline: baseline}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Emit one real task mutation_event of `kind` for `task`, returning its id.
  defp emit!(task, kind), do: Internal.insert_mutation_event!(task, kind, task.rev).id

  defp max_event_id do
    import Ecto.Query
    Repo.one(from(e in Barkpark.Content.MutationEvent, select: max(e.id))) || 0
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  # ─── Ordered replay + cursor + kinds (criterion 1) ────────────────────────

  describe "replay_since/3 — ordered replay" do
    test "returns task events in id-ASC order with id as the cursor, covering claim/close/move + task.criterion + task.pulse",
         %{task: task, baseline: baseline} do
      # The dogfood order of a real loop: claim, pulse, stamp a criterion, move,
      # close. pulse/criterion emitters land later in the wave — the feed is
      # kind-agnostic, so we prove replay carries them by inserting them here.
      kinds = ~w(task.claimed task.pulse task.criterion task.reparented task.closed)
      ids = Enum.map(kinds, &emit!(task, &1))

      rows = Events.replay_since(@dataset, baseline)

      assert Enum.map(rows, & &1.event) == kinds
      assert Enum.map(rows, & &1.id) == ids
      # ids strictly increasing — the monotonic cursor
      assert ids == Enum.sort(ids)
      assert ids == Enum.uniq(ids)
      # each event carries its task
      assert Enum.all?(rows, &(&1.doc_id == task.doc_id))
      # the two "landed later in the wave" kinds are present and in order
      assert "task.pulse" in Enum.map(rows, & &1.event)
      assert "task.criterion" in Enum.map(rows, & &1.event)
    end

    test "since filters strictly greater-than (id > since), never inclusive",
         %{task: task, baseline: baseline} do
      a = emit!(task, "task.claimed")
      _b = emit!(task, "task.pulse")
      _c = emit!(task, "task.closed")

      # resume AFTER `a` → only b, c
      rows = Events.replay_since(@dataset, a)
      assert Enum.map(rows, & &1.event) == ~w(task.pulse task.closed)
      refute a in Enum.map(rows, & &1.id)

      # a fresh reader (since = baseline) sees all three
      assert length(Events.replay_since(@dataset, baseline)) == 3
    end

    test "an empty tail (caught up) returns []", %{task: task} do
      last = emit!(task, "task.claimed")
      assert Events.replay_since(@dataset, last) == []
    end
  end

  # ─── Keyset paging across a batch boundary (criterion 1) ──────────────────

  describe "replay_since/3 — keyset paging" do
    test "pages across a boundary with limit, cursor-advancing without gaps or dupes",
         %{task: task, baseline: baseline} do
      all_ids = for _ <- 1..7, do: emit!(task, "task.pulse")

      page1 = Events.replay_since(@dataset, baseline, limit: 3)
      assert length(page1) == 3

      page2 = Events.replay_since(@dataset, List.last(page1).id, limit: 3)
      assert length(page2) == 3

      page3 = Events.replay_since(@dataset, List.last(page2).id, limit: 3)
      assert length(page3) == 1

      page4 = Events.replay_since(@dataset, List.last(page3).id, limit: 3)
      assert page4 == []

      # concatenated pages reconstruct the full stream exactly once, in order
      walked = Enum.map(page1 ++ page2 ++ page3, & &1.id)
      assert walked == all_ids
      assert walked == Enum.uniq(walked)
    end

    test "page_limit clamps to [1, 500]" do
      assert Events.page_limit(3) == 3
      assert Events.page_limit(500) == 500
      assert Events.page_limit(999_999) == 500
      assert Events.page_limit(0) == 1
      assert Events.page_limit(-1) == 1
      assert Events.page_limit(nil) == 500
      assert Events.default_limit() == 500
    end

    test "a raw limit is bounded — batch never exceeds 500 (no unbounded fanout)",
         %{task: task, baseline: baseline} do
      for _ <- 1..4, do: emit!(task, "task.pulse")
      # oversized limit is clamped, but with only 4 events it still returns 4
      rows = Events.replay_since(@dataset, baseline, limit: 10_000_000)
      assert length(rows) == 4
    end
  end

  # ─── Projected shape (criterion 1) ────────────────────────────────────────

  describe "replay_since/3 — projected shape" do
    test "each event is exactly {id, event, doc_id, rev, at}",
         %{task: task, baseline: baseline} do
      emit!(task, "task.claimed")
      [row] = Events.replay_since(@dataset, baseline)

      assert Map.keys(row) |> Enum.sort() == [:at, :doc_id, :event, :id, :rev]
      assert is_integer(row.id)
      assert row.event == "task.claimed"
      assert row.doc_id == task.doc_id
      assert row.rev == task.rev
      assert %DateTime{} = row.at
    end
  end

  # ─── Scoping: dataset + type='task' (criterion 1) ─────────────────────────

  describe "replay_since/3 — scoping" do
    test "excludes events from another dataset", %{task: %Document{} = task, baseline: baseline} do
      mine = emit!(task, "task.claimed")

      # a task event committed under a DIFFERENT dataset must not surface
      foreign = %Document{task | dataset: "other-dataset", doc_id: uniq("foreign")}
      _ = Internal.insert_mutation_event!(foreign, "task.claimed", foreign.rev)

      rows = Events.replay_since(@dataset, baseline)
      assert Enum.map(rows, & &1.id) == [mine]
    end

    test "excludes non-task events in the same dataset",
         %{task: %Document{} = task, baseline: baseline} do
      mine = emit!(task, "task.pulse")

      # a document (non-task) mutation in the same dataset must not surface
      post = %Document{task | type: "post", doc_id: uniq("post")}
      _ = Internal.insert_mutation_event!(post, "post.updated", post.rev)

      rows = Events.replay_since(@dataset, baseline)
      assert Enum.map(rows, & &1.id) == [mine]
      assert Enum.all?(rows, &String.starts_with?(&1.event, "task."))
    end
  end

  # ─── HTTP endpoint (criteria 1 + 2) ───────────────────────────────────────

  describe "GET /v1/tasks/events" do
    test "returns 401 without a token", %{conn: conn} do
      assert get(conn, "/v1/tasks/events").status == 401
    end

    test "replays task events with a resume cursor + has_more",
         %{conn: conn, task: task, baseline: baseline} do
      ids = Enum.map(~w(task.claimed task.pulse task.closed), &emit!(task, &1))

      resp = conn |> authed() |> get("/v1/tasks/events?since=#{baseline}")
      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert body["ok"] == true
      assert Enum.map(body["events"], & &1["event"]) == ~w(task.claimed task.pulse task.closed)
      assert Enum.map(body["events"], & &1["id"]) == ids
      # cursor is the last event's id; a small page → has_more false
      assert body["cursor"] == List.last(ids)
      assert body["has_more"] == false

      # each wire event carries the projected shape
      first = hd(body["events"])
      assert Enum.sort(Map.keys(first)) == ~w(at doc_id event id rev)
    end

    test "an empty tail echoes the caller's since as the cursor",
         %{conn: conn, baseline: baseline} do
      resp = conn |> authed() |> get("/v1/tasks/events?since=#{baseline + 999_999}")
      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert body["events"] == []
      assert body["cursor"] == baseline + 999_999
      assert body["has_more"] == false
    end
  end

  # ─── Route precedence (criterion 2) ───────────────────────────────────────

  describe "route precedence — /v1/tasks/events over /tasks/:doc_id" do
    test "GET /v1/tasks/events resolves to the :events action, never :show(doc_id=events)" do
      info = Phoenix.Router.route_info(BarkparkWeb.Router, "GET", "/v1/tasks/events", "example.com")

      assert info.plug == BarkparkWeb.TasksController
      assert info.plug_opts == :events
      # the catchall would have bound "events" as a path param — it must not
      refute Map.get(info.path_params, "doc_id") == "events"
    end

    test "a real id still resolves to the :show catchall (precedence is surgical)" do
      info =
        Phoenix.Router.route_info(BarkparkWeb.Router, "GET", "/v1/tasks/task-abc123", "example.com")

      assert info.plug == BarkparkWeb.TasksController
      assert info.plug_opts == :show
      assert info.path_params["doc_id"] == "task-abc123"
    end
  end
end
