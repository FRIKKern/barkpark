defmodule BarkparkWeb.ReadConnectionFaultTest do
  @moduledoc """
  task-5a7f007878b56e6a — "the read path has the same DBConnection
  classification hole the create path just closed".

  PR #15489 closed the CREATE half: a checkout lost mid-write answers 503
  `storage_unavailable` / `connection_unavailable` instead of 500
  `internal_error / "unknown error (DBConnection.ConnectionError)"`. It
  deliberately did not widen into the READ path, which had the identical hole —
  zero `rescue` in `content/query.ex`, `content/graph.ex` and `content.ex`.

  The read half is the WORSE half. A 500 on create fails loudly and the caller
  resends. A 500 on read happens inside an SSR build: the page renders with no
  content document, the deploy's HEALTH gate reads an empty `bp-doc-id` marker
  and refuses the switch after the whole build has been paid for. Four of the
  eight cloud deploy failures in the measured week were this one fault, and all
  four were captioned by their SYMPTOM ("marker is empty") rather than the pool.

  Four properties, each of which can FAIL:

    * **THE RAISE SITE IS NAMED** — the fault is injected at THREE specific read
      call sites via the test-only seams `QueryController.inject_read_fault!/1`
      (`:query_index`) and `TasksController.inject_read_fault!/1`
      (`:graph_root`, `:graph_traverse`), and what is asserted is the HTTP
      RESPONSE SHAPE, never elapsed time. Both doors the row names are covered:
      the document read behind `GET /v1/data/query/:dataset/:type` and the graph
      read behind `GET /v1/graph/:id` — the door the deploy evidence names.

    * **THE ERROR IS NAMED AND RETRYABLE** — 503 `storage_unavailable` with
      `reason: "connection_unavailable"`, the arm #15489 established, and NOT
      500 `internal_error` / "unknown error".

    * **NO NEW FAIL-OPEN, THE SHARP ONE ON A READ PATH** — the fault must never
      become an EMPTY RESULT. A 200 with `documents: []`, or a graph with
      `nodes: []`, is WORSE than the 500 this row removes: it is precisely the
      shape that renders an empty page and fails the HEALTH gate. Asserted
      directly in both doors. A 404 is refused for the same reason at the graph
      door, where `resolve_graph_root/2`'s not-found arm is the adjacent trap: a
      permanent verdict on a transient fault.

    * **A NON-CONNECTION ERROR IS UNCHANGED, AND THE BLAST RADIUS IS BOUNDED** —
      a `RuntimeError` at the identical seam still propagates untouched (the
      rescue is not a catch-all), and the UNTOUCHED door `GET /v1/graph/orphans`
      still raises the very exception the two wrapped doors now name.

  `async: false`: the fault seam is `Application.put_env`, which is global.
  """

  use BarkparkWeb.ConnCase, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @token "barkpark-test-read-dbconn-token"
  @dataset "production"
  @fault_message "tcp recv: closed"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-read-dbconn", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    on_exit(fn -> Application.delete_env(:barkpark, :reader_fault) end)

    %{scope: scope}
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_published_post!(doc_id, scope) do
    {:ok, _draft} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => %{}},
        @dataset,
        scope
      )

    {:ok, doc} = Content.publish_document(doc_id, "post", @dataset, scope)
    doc
  end

  defp arm!(site, module \\ DBConnection.ConnectionError, message \\ @fault_message) do
    Application.put_env(:barkpark, :reader_fault, {site, module, message})
  end

  # ── THE RAISE SITE IS NAMED, AND THE ANSWER IS A NAMED RETRYABLE 503 ──────

  describe "GET /v1/data/query/:dataset/:type — the document read door" do
    test "a DBConnection.ConnectionError answers 503 storage_unavailable/connection_unavailable",
         %{conn: conn, scope: scope} do
      _post = mk_published_post!(uniq("dbconn-query"), scope)
      arm!(:query_index)

      {resp, log} =
        with_log(fn -> conn |> authed() |> get("/v1/data/query/#{@dataset}/post") end)

      assert log =~ "the database connection was lost mid-read"

      # THE RESPONSE SHAPE — not elapsed time.
      assert resp.status == 503

      body = Jason.decode!(resp.resp_body)
      error = body["error"]

      assert error["code"] == "storage_unavailable"
      assert error["reason"] == "connection_unavailable"

      # NOT the pre-fix answer. THIS is the assertion that reddens on the
      # unfixed tree, where the uncaught raise renders 500 internal_error /
      # "unknown error (DBConnection.ConnectionError)".
      refute error["code"] == "internal_error"
      refute to_string(error["message"]) =~ "unknown error"

      # The exception's own text survives, so an operator can tell a checkout
      # timeout from a closed socket without reading the server log.
      assert error["message"] =~ @fault_message
    end

    test "NO FAIL-OPEN: the fault is never a 200 with an empty documents list",
         %{conn: conn, scope: scope} do
      _post = mk_published_post!(uniq("dbconn-query-failopen"), scope)
      arm!(:query_index)

      {resp, _log} =
        with_log(fn -> conn |> authed() |> get("/v1/data/query/#{@dataset}/post") end)

      # An empty 200 here is the EXACT deploy failure this row exists to
      # remove: the SSR renders a page with no content document and the HEALTH
      # gate reads an empty bp-doc-id marker. A refusal, or nothing.
      refute resp.status == 200,
             "a lost connection answered 200 — an empty page is worse than the 500 this replaces"

      body = Jason.decode!(resp.resp_body)

      assert is_nil(body["documents"]),
             "the refusal body carried a documents key — callers may read it as an empty result"

      refute body["ok"] == true
      assert body["error"]["code"] == "storage_unavailable"
    end

    test "a NON-connection exception at the identical seam is UNCHANGED",
         %{conn: conn, scope: scope} do
      _post = mk_published_post!(uniq("dbconn-query-other"), scope)
      arm!(:query_index, RuntimeError, "not a connection fault")

      # The rescue matches DBConnection.ConnectionError and nothing else, so
      # this still propagates exactly as it did before the fix.
      assert_raise RuntimeError, "not a connection fault", fn ->
        conn |> authed() |> get("/v1/data/query/#{@dataset}/post")
      end
    end
  end

  # ── THE GRAPH DOOR — the one the deploy evidence names by message ─────────

  describe "GET /v1/graph/:id — the graph read door" do
    for site <- [:graph_root, :graph_traverse] do
      test "a DBConnection.ConnectionError at the #{site} read answers the named 503",
           %{conn: conn, scope: scope} do
        site = unquote(site)
        doc_id = uniq("dbconn-graph-#{site}")
        _post = mk_published_post!(doc_id, scope)
        arm!(site)

        {resp, log} = with_log(fn -> conn |> authed() |> get("/v1/graph/#{doc_id}") end)

        assert log =~ "the database connection was lost mid-read"
        assert resp.status == 503

        error = Jason.decode!(resp.resp_body)["error"]

        assert error["code"] == "storage_unavailable"
        assert error["reason"] == "connection_unavailable"

        # The deploy log read `graph 500: unknown error
        # (DBConnection.ConnectionError)`. Neither half of that may survive.
        refute error["code"] == "internal_error"
        refute to_string(error["message"]) =~ "unknown error"
        assert error["message"] =~ @fault_message
      end
    end

    test "NO FAIL-OPEN: never an empty graph, and never the adjacent 404",
         %{conn: conn, scope: scope} do
      doc_id = uniq("dbconn-graph-failopen")
      _post = mk_published_post!(doc_id, scope)
      arm!(:graph_traverse)

      {resp, _log} = with_log(fn -> conn |> authed() |> get("/v1/graph/#{doc_id}") end)

      refute resp.status == 200,
             "a lost connection answered 200 — an empty graph is what fails the HEALTH gate"

      # `resolve_graph_root/2` answers {:error, :not_found} for a document that
      # genuinely is not there. Rounding a transient pool fault into that arm
      # would tell an SSR build the document is GONE — a permanent verdict on a
      # transient fault, and the same mis-caption in a new costume.
      refute resp.status == 404,
             "a lost connection answered 404 — a permanent verdict on a transient fault"

      body = Jason.decode!(resp.resp_body)

      assert is_nil(body["nodes"]),
             "the refusal body carried a nodes key — callers may read it as an empty graph"

      refute body["ok"] == true
      assert body["error"]["code"] == "storage_unavailable"
    end

    test "the refusal tells a renderer to RETRY, never to publish what it read",
         %{conn: conn, scope: scope} do
      doc_id = uniq("dbconn-graph-hint")
      _post = mk_published_post!(doc_id, scope)
      arm!(:graph_traverse)

      {resp, _log} = with_log(fn -> conn |> authed() |> get("/v1/graph/#{doc_id}") end)

      error = Jason.decode!(resp.resp_body)["error"]
      hint = to_string(error["hint"])
      message = to_string(error["message"])

      # The READ arm, not the WRITE arm. #15489's hint tells the caller to check
      # whether the write LANDED and names `bp doc ls task --perspective
      # drafts`; a read wrote nothing, so that advice is unactionable here and
      # its presence would mean the wrong arm answered.
      refute hint =~ "perspective drafts",
             "the read door answered with the WRITE arm's check-the-drafts hint"

      refute hint =~ "mid-write",
             "the read door answered with the WRITE arm's hint"

      # What the row is actually for: an empty answer is not an answer.
      assert hint =~ "RETRY THE RENDER"
      assert hint =~ "REFUSAL"
      assert message =~ "Do NOT treat this as an empty graph"
    end
  end

  # ── THE BLAST RADIUS, PROVEN RATHER THAN ASSERTED IN PROSE ────────────────

  describe "blast radius" do
    test "the UNTOUCHED door GET /v1/graph/orphans still raises, exactly as before",
         %{conn: conn} do
      arm!(:graph_orphans)

      # This is the control that makes the two fixes above meaningful: the
      # change covers `GET /v1/data/query/:dataset/:type` and `GET /v1/graph/:id`
      # and NOTHING else. `graph_orphans` (and with it `graph_corpus`,
      # `graph_dangling`, `graph_tasks`) is deliberately not wrapped, mirroring
      # #15489 leaving `upsert_document/4` unwrapped and pinning it with a test.
      assert_raise DBConnection.ConnectionError, fn ->
        conn |> authed() |> get("/v1/graph/orphans")
      end
    end
  end
end
