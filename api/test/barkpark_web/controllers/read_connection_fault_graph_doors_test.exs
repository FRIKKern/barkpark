defmodule BarkparkWeb.ReadConnectionFaultGraphDoorsTest do
  @moduledoc """
  task-410d4f889ee526c1 — the read doors in `QueryController` left OUTSIDE the
  two `DBConnection.ConnectionError` rescue regions that already exist there.

  `query_index/4` (task-5a7f007878b56e6a) and `show_doc/5` (PR #18608) each
  closed one door and each wrote down the doors it was leaving open. This file
  covers the rest — and the door set was DERIVED by enumerating every public
  action in `query_controller.ex` that can reach storage, not taken from those
  comments. That derivation found FIVE, not the three both comments name:

      index/2       INSIDE  (query_index/4 region, :query_index seam)
      show/2        INSIDE  (show_doc/5 region,   :doc_show seam)
      backlinks/2   outside -> now :backlinks
      related/2     outside -> now :related
      counts/2      outside -> now :counts
      tag_browse/2  outside -> now :tag_browse   <- named by NO prior comment
      tag_docs/2    outside -> now :tag_docs     <- named by NO prior comment

  `tag_browse/2` and `tag_docs/2` post-date both blast-radius comments, so a
  reader who trusted the lists would have shipped a fix that missed two doors.

  Three properties per door, each of which can FAIL independently:

    * **THE ANSWER IS THE NAMED RETRYABLE 503** — `storage_unavailable` with
      `reason: "connection_unavailable"`, never 500 `internal_error` /
      "unknown error", because `transient_refusal?/1` keys retry grace on the
      CODE and `internal_error` is not on its transient list.

    * **NO FAIL-OPEN** — the criterion that matters most. Every one of these
      five doors answers a LIST or a COUNT, so the trap is the EMPTY one: a
      `{backlinks: [], count: 0}` or a `counts: {}` is a false answer a caller
      cannot tell from a true one. All five also hide existence behind 404, so
      degrading into not-found is the same lie in the other direction. The
      refusal must carry NO success-shape key at all.

    * **THE RESCUE IS NARROW** — a `RuntimeError` at the identical seam still
      propagates untouched, so the rescue is provably not a catch-all and a
      query bug stays distinguishable from a storage fault.

  Plus a CONTROL arm per door: with the seam DISARMED the same request is a
  clean 200 carrying its success shape. Without it, all three arms above would
  pass on a door that is broken for every request, fault or no fault.

  `async: false`: the fault seam is `Application.put_env`, which is global.
  """

  use BarkparkWeb.ConnCase, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @token "barkpark-test-read-dbconn-graph-doors-token"
  @dataset "production"
  @fault_message "tcp recv: closed"

  # {seam site, the success-shape key the refusal must NOT carry}
  @doors [
    {:backlinks, "result"},
    {:related, "result"},
    {:counts, "counts"},
    {:tag_browse, "result"},
    {:tag_docs, "result"}
  ]

  setup do
    {:ok, _} =
      Auth.create_token(@token, "test-read-dbconn-doors", "test", ["read", "write", "admin"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    doc_id = "dbconn-doors-#{System.unique_integer([:positive])}"

    {:ok, _draft} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => %{}},
        @dataset,
        scope
      )

    {:ok, _doc} = Content.publish_document(doc_id, "post", @dataset, scope)

    on_exit(fn -> Application.delete_env(:barkpark, :reader_fault) end)

    %{scope: scope, doc_id: doc_id}
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp arm!(site, module \\ DBConnection.ConnectionError, message \\ @fault_message) do
    Application.put_env(:barkpark, :reader_fault, {site, module, message})
  end

  defp path_for(:backlinks, doc_id), do: "/v1/data/backlinks/#{@dataset}/#{doc_id}"
  defp path_for(:related, doc_id), do: "/v1/data/related/#{@dataset}/#{doc_id}"
  defp path_for(:counts, _doc_id), do: "/v1/data/counts/#{@dataset}"
  defp path_for(:tag_browse, _doc_id), do: "/v1/data/tags/#{@dataset}?type=post"
  defp path_for(:tag_docs, _doc_id), do: "/v1/data/tags/#{@dataset}/anytag?type=post"

  for {site, success_key} <- @doors do
    describe "#{site}/2 — a read door outside both existing rescue regions" do
      test "a DBConnection.ConnectionError answers 503 storage_unavailable/connection_unavailable",
           %{conn: conn, doc_id: doc_id} do
        site = unquote(site)
        arm!(site)

        {resp, log} = with_log(fn -> conn |> authed() |> get(path_for(site, doc_id)) end)

        assert log =~ "the database connection was lost mid-read"
        assert resp.status == 503

        error = Jason.decode!(resp.resp_body)["error"]

        assert error["code"] == "storage_unavailable"
        assert error["reason"] == "connection_unavailable"

        # THE ASSERTION THAT REDDENS ON THE UNFIXED TREE: with no rescue the
        # raise reaches ErrorJSON as 500 internal_error / "unknown error
        # (DBConnection.ConnectionError)", which transient_refusal?/1 does not
        # treat as transient, so a retrying caller does not retry.
        refute error["code"] == "internal_error"
        refute to_string(error["message"]) =~ "unknown error"

        # The exception's own text survives, so an operator can tell a checkout
        # timeout from a closed socket without reading the server log.
        assert error["message"] =~ @fault_message
      end

      test "NO FAIL-OPEN: never a 200, never an empty result, never the adjacent 404",
           %{conn: conn, doc_id: doc_id} do
        site = unquote(site)
        success_key = unquote(success_key)
        arm!(site)

        {resp, _log} = with_log(fn -> conn |> authed() |> get(path_for(site, doc_id)) end)

        refute resp.status == 200,
               "a lost connection answered 200 — an empty list/count is a FALSE answer a " <>
                 "caller cannot distinguish from a true one, and is worse than the 500 " <>
                 "this replaces"

        # Every one of these doors hides existence with 404 for an unauthorised
        # caller. Rounding a transient pool fault into that arm would tell a
        # census the dataset or document is GONE — a permanent verdict
        # manufactured out of a refused checkout.
        refute resp.status == 404,
               "a lost connection answered 404 — a permanent verdict on a transient fault"

        body = Jason.decode!(resp.resp_body)

        assert is_nil(body[success_key]),
               "the refusal body carried the success key #{inspect(success_key)} — " <>
                 "a caller may read the refusal as a real (empty) answer"

        # Nor may the counting keys leak in at the top level.
        assert is_nil(body["count"])
        refute body["ok"] == true

        assert body["error"]["code"] == "storage_unavailable"
      end

      test "a NON-connection exception at the identical seam is UNCHANGED",
           %{conn: conn, doc_id: doc_id} do
        site = unquote(site)
        arm!(site, RuntimeError, "not a connection fault")

        # The rescue matches DBConnection.ConnectionError and NOTHING wider —
        # not a bare rescue, not Ecto.QueryError — so a bug in the query stays
        # distinguishable from the storage fault this row exists to name.
        assert_raise RuntimeError, "not a connection fault", fn ->
          conn |> authed() |> get(path_for(site, doc_id))
        end
      end

      test "CONTROL: with the seam DISARMED the same request is a clean 200",
           %{conn: conn, doc_id: doc_id} do
        site = unquote(site)
        success_key = unquote(success_key)
        Application.delete_env(:barkpark, :reader_fault)

        resp = conn |> authed() |> get(path_for(site, doc_id))

        assert resp.status == 200

        body = Jason.decode!(resp.resp_body)

        refute is_nil(body[success_key]),
               "the door answered 200 without its success shape — the three arms above " <>
                 "would pass on a door that is broken for every request"
      end
    end
  end

  # ── THE BLAST RADIUS, PROVEN RATHER THAN ASSERTED IN PROSE ────────────────

  describe "blast radius" do
    test "the UNTOUCHED door GET /v1/graph/orphans still raises, exactly as before",
         %{conn: conn} do
      arm!(:graph_orphans)

      # This change covers the five QueryController read doors and NOTHING
      # else. `graph_orphans` in TasksController is deliberately still
      # unwrapped, and its seam is a different module's — a rig that reds
      # everything would red this too.
      assert_raise DBConnection.ConnectionError, fn ->
        conn |> authed() |> get("/v1/graph/orphans")
      end
    end
  end
end
