defmodule BarkparkWeb.TasksIndexCursorTest do
  @moduledoc """
  bl-api-tasks-stable-cursor — `GET /v1/tasks?cursor=` makes ABSENCE DECIDABLE.

  THE DEFECT. The index serves a window: `limit` rows ordered
  `desc: updated_at, desc: id`, capped at `Params.index_limit_cap/0`. Every
  write to any task re-stamps `updated_at` and rotates that row to the head, so
  the window's tail falls off under ordinary traffic. A reader that walked the
  window and asked "is task X still here?" received ONE answer — absent — for
  two different facts: X was CLOSED, or X was pushed past the cap by unrelated
  touches. The CLI lane's `internal/taskboard/merge.go` carries a client-side
  heuristic standing in for the fix these tests pin.

  WHY THE CAP IS OVERRIDDEN INSTEAD OF SEEDED PAST. The property is "paging
  reaches rows the clamp excluded", and the property does not care whether the
  clamp is 1000 or 4. Seeding 1001 real documents to cross a 1000 boundary
  would buy the same proof for a hundredfold cost, and a test that slow gets
  deleted. The override is `Application.put_env/3`, which is GLOBAL — hence
  `async: false`: ExUnit runs the whole synchronous set after every async one,
  so no concurrently-running test can observe the shrunken cap. (The
  already-green `?limit=5000 clamps to the cap` assertion in
  `tasks_controller_test.exs` is exactly the test that would red if this file
  were async and leaked.)

  THE MUTATION THAT REDS THESE TESTS. Make `Params.apply_index_cursor/2` a
  no-op (`def apply_index_cursor(query, _), do: query`) — the ONE line that
  turns the token into a WHERE clause. Every walk then re-serves page one
  forever: `walks the whole corpus` collects `@page_size` distinct ids instead
  of the full corpus and reds, and `a terminal row past the clamp is REACHED`
  never reaches its row and reds. Nothing else in the suite notices, because
  nothing else pages past the first window.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}

  @token "barkpark-test-tasks-cursor-token"
  @dataset "production"

  # Small enough that a walk is a handful of requests, larger than 1 so an
  # "off by one page" bug cannot pass by accident.
  @page_size 4
  @corpus 11

  setup do
    {:ok, _} = Auth.create_token(@token, "test-tasks-cursor", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  # Shrink the cap for the boundary tests ONLY, and restore it on exit so a
  # later synchronous test never inherits a 4-row ceiling.
  defp with_small_cap! do
    previous = Application.get_env(:barkpark, :tasks_index_limit_cap)
    Application.put_env(:barkpark, :tasks_index_limit_cap, @page_size)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:barkpark, :tasks_index_limit_cap)
        v -> Application.put_env(:barkpark, :tasks_index_limit_cap, v)
      end
    end)
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

  defp mk_task!(doc_id, scope, content_extra) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
        },
        content_extra
      )

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp authed(conn) do
    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> @token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  defp get_json(conn, path) do
    resp = conn |> authed() |> get(path)
    {resp.status, Jason.decode!(resp.resp_body)}
  end

  # Follow `page.next_cursor` to exhaustion, collecting every doc_id seen.
  # `max_pages` is a TRIPWIRE, not a limit: a correct walk over @corpus rows at
  # @page_size per page finishes in 3 pages, so hitting the bound means the
  # cursor stopped advancing and the test should fail loudly rather than hang.
  defp walk(conn, base_path, max_pages \\ 20) do
    Enum.reduce_while(1..max_pages, {[], ""}, fn _, {seen, cursor} ->
      sep = if String.contains?(base_path, "?"), do: "&", else: "?"
      {200, body} = get_json(conn, base_path <> sep <> "cursor=" <> cursor)
      ids = Enum.map(body["docs"], & &1["id"])

      case body["page"]["next_cursor"] do
        nil -> {:halt, {seen ++ ids, :done}}
        next -> {:cont, {seen ++ ids, next}}
      end
    end)
  end

  # ── C1: the envelope a pre-cursor caller reads is BYTE-STABLE ────────────
  #
  # Pinned as an exact key set, not a subset check: the whole point of an
  # ADDITIVE change is that a reader who never heard of cursors sees nothing
  # new, and a subset assertion would let a stray key through. Captured from
  # the pre-change response (`{ok, docs, page{limit, offset, returned,
  # has_more}}`) before the cursor existed.
  describe "additive: no ?cursor= means no change" do
    test "a bare GET carries exactly the pre-cursor envelope keys", %{conn: conn, scope: scope} do
      for i <- 1..3, do: mk_task!("cursor-stable-#{i}", scope, %{})

      {200, body} = get_json(conn, "/v1/tasks")

      assert Map.keys(body) |> Enum.sort() == ["docs", "ok", "page"]
      assert Map.keys(body["page"]) |> Enum.sort() == ["has_more", "limit", "offset", "returned"]
      refute Map.has_key?(body["page"], "next_cursor")
      assert body["ok"] == true
    end

    test "?limit= and ?offset= paging is untouched", %{conn: conn, scope: scope} do
      for i <- 1..5, do: mk_task!("cursor-offset-#{i}", scope, %{})

      {200, body} = get_json(conn, "/v1/tasks?limit=2&offset=2")

      assert body["page"] == %{
               "limit" => 2,
               "offset" => 2,
               "returned" => 2,
               "has_more" => true
             }
    end
  end

  # ── C2: the cursor walks PAST the clamp ─────────────────────────────────
  describe "keyset cursor over (updated_at, id)" do
    test "?cursor= (empty) is page one and mints the next token", %{conn: conn, scope: scope} do
      with_small_cap!()
      for i <- 1..@corpus, do: mk_task!("cursor-head-#{i}", scope, %{})

      {200, body} = get_json(conn, "/v1/tasks?cursor=")

      assert length(body["docs"]) == @page_size
      assert body["page"]["limit"] == @page_size
      assert body["page"]["has_more"] == true
      assert is_binary(body["page"]["next_cursor"])
      # Opaque, but decodable BY THE SERVER — a token the caller is meant to
      # echo, never to parse or construct.
      assert {:ok, _} = Base.url_decode64(body["page"]["next_cursor"], padding: false)
    end

    test "the walk reaches every row in a corpus LARGER than the clamp",
         %{conn: conn, scope: scope} do
      with_small_cap!()
      seeded = for i <- 1..@corpus, do: mk_task!("cursor-walk-#{i}", scope, %{}).id

      # The clamp really does bite: a single request cannot see the corpus, so
      # rows @page_size+1..@corpus are exactly the ones that "rotated out".
      {200, one_page} = get_json(conn, "/v1/tasks?limit=1000")
      assert length(one_page["docs"]) == @page_size

      {seen, state} = walk(conn, "/v1/tasks")
      assert state == :done, "the cursor stopped advancing — the walk never terminated"

      assert Enum.sort(seen) == Enum.sort(seeded)
      # No row served twice: a keyset seek is duplicate-free over a corpus
      # nothing writes to mid-walk.
      assert length(seen) == length(Enum.uniq(seen))
    end

    test "a terminal row past the clamp is REACHED and reads as terminal",
         %{conn: conn, scope: scope} do
      with_small_cap!()

      # Created FIRST, so `desc: updated_at` puts it at the very TAIL — past
      # the clamp, in the region a windowed reader can never see.
      done = mk_task!("cursor-terminal-row", scope, %{"lifecycle_status" => "done"})
      for i <- 1..@corpus, do: mk_task!("cursor-terminal-noise-#{i}", scope, %{})

      {200, one_page} = get_json(conn, "/v1/tasks?limit=1000")
      refute done.id in Enum.map(one_page["docs"], & &1["id"]),
             "fixture is wrong: the terminal row is inside the window, so this " <>
               "test would pass without a cursor"

      {seen, :done} = walk(conn, "/v1/tasks")

      assert done.id in seen,
             "the row that rotated out of the window is unreachable — absence is " <>
               "still indistinguishable from a close"

      # ...and it reports WHY it is gone from the board: it is terminal, not
      # rotated out. That distinction is the whole row.
      {200, single} = get_json(conn, "/v1/tasks/#{done.doc_id}")
      assert single["doc"]["lifecycle_status"] == "done"
    end

    test "a row that was never created is absent from the FULL walk — decidably",
         %{conn: conn, scope: scope} do
      with_small_cap!()
      for i <- 1..@corpus, do: mk_task!("cursor-absent-#{i}", scope, %{})

      {seen, :done} = walk(conn, "/v1/tasks")

      # The walk terminated (next_cursor == nil ⇒ the corpus is exhausted), so
      # "not in `seen`" is now a claim about the CORPUS, not about a window.
      refute "cursor-absent-never-existed" in seen
    end

    test "a short page carries next_cursor: nil — the walk is provably over",
         %{conn: conn, scope: scope} do
      for i <- 1..3, do: mk_task!("cursor-short-#{i}", scope, %{})

      {200, body} = get_json(conn, "/v1/tasks?cursor=&limit=100")

      assert body["page"]["has_more"] == false
      assert body["page"]["next_cursor"] == nil
    end

    test "the parent rail pages on its own (inserted_at, id) axis, oldest first",
         %{conn: conn, scope: scope} do
      with_small_cap!()
      parent = mk_task!("cursor-rail-parent", scope, %{})

      children =
        for i <- 1..@corpus,
            do: mk_task!("cursor-rail-child-#{i}", scope, %{"parent_id" => parent.doc_id}).id

      {seen, :done} = walk(conn, "/v1/tasks?parent=#{parent.doc_id}")

      # ASC by inserted_at: the rail is a timeline, so the walk must come back
      # in creation order, not merely contain the right set.
      assert seen == children
    end
  end

  # ── Fail-closed: a cursor this route did not mint is a 400 ──────────────
  #
  # Never a silent restart from the head. A restart returns a plausible page
  # that reads exactly like a legitimate one, so a walker would loop or
  # double-count and every response would say 200 — the same false-confirmation
  # shape the `filter[...]` container was fixed for.
  describe "fail-closed cursor validation" do
    test "a garbage token is a 400, not a silent page one", %{conn: conn, scope: scope} do
      for i <- 1..3, do: mk_task!("cursor-bad-#{i}", scope, %{})

      {status, body} = get_json(conn, "/v1/tasks?cursor=not-a-real-cursor")
      assert status == 400
      assert body["message"] =~ "cursor"
    end

    test "a well-formed base64 payload that is not ours is a 400",
         %{conn: conn, scope: scope} do
      for i <- 1..3, do: mk_task!("cursor-forged-#{i}", scope, %{})

      forged = Base.url_encode64(Jason.encode!(%{"v" => 99, "k" => "x"}), padding: false)
      {status, _body} = get_json(conn, "/v1/tasks?cursor=#{forged}")
      assert status == 400
    end

    test "a cursor minted on the default list is refused on the parent rail",
         %{conn: conn, scope: scope} do
      with_small_cap!()
      parent = mk_task!("cursor-axis-parent", scope, %{})
      for i <- 1..@corpus, do: mk_task!("cursor-axis-#{i}", scope, %{})

      {200, body} = get_json(conn, "/v1/tasks?cursor=")
      token = body["page"]["next_cursor"]

      # The two views sort on DIFFERENT columns. Spending an updated_at cursor
      # against an inserted_at ordering would seek on a column the query does
      # not sort by — a page with no defined relationship to the previous one.
      {status, refusal} = get_json(conn, "/v1/tasks?parent=#{parent.doc_id}&cursor=#{token}")
      assert status == 400
      assert refusal["message"] =~ "ordering"
    end

    test "cursor + a non-zero offset is a 400 rather than a guess",
         %{conn: conn, scope: scope} do
      with_small_cap!()
      for i <- 1..@corpus, do: mk_task!("cursor-both-#{i}", scope, %{})

      {200, body} = get_json(conn, "/v1/tasks?cursor=")
      token = body["page"]["next_cursor"]

      {status, refusal} = get_json(conn, "/v1/tasks?cursor=#{token}&offset=2")
      assert status == 400
      assert refusal["message"] =~ "offset"

      # offset=0 is not "a non-zero offset" — the default must stay usable.
      {200, _} = get_json(conn, "/v1/tasks?cursor=#{token}&offset=0")
    end
  end
end
