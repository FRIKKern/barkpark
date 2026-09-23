defmodule BarkparkWeb.SessionAutologTest do
  @moduledoc """
  task-bc34e83515bbd91f — session auto-log (session-handoff design §5b).

  A request carrying `x-barkpark-session-doc: <slug>` makes the task-close and
  bulldocs-publish doors append the matching event to that session's trail,
  server-side. The arms below pin both halves of the contract:

    * POSITIVE: header present → exactly one event of the whitelisted kind,
      with `ref` naming the closed task / published paper;
    * NEGATIVE: header absent → no event; unknown slug, and a slug that only
      exists in ANOTHER workspace → the close still answers 200 and no trail
      anywhere grows; a row whose append RAISES → the close still answers 200
      and the task is still done.

  MUTATION PROOF: delete the `autolog_close/2` call in `TasksController.close/2`
  and `autolog_publish/3` in the ingest controller → the three positive arms
  red, and so do the unknown-slug and raise arms (they assert the skip was
  LOGGED, which a deleted call never does); the header-absent and
  foreign-workspace arms stay green, as a pure absence must. Delete the
  `rescue`/`catch` in `SessionAutolog.append/4` → the raise arm reds with the
  ArgumentError reaching the close.
  """
  use BarkparkWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document

  @token "barkpark-test-session-autolog"
  @ingest_token "barkpark-test-ingest-token"
  @dataset "production"
  @header "x-barkpark-session-doc"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-session-autolog", "test", ["read", "write"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope, ws: ws, project: project}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp session!(slug, ws_id, project_id \\ nil) do
    {:ok, _} =
      Content.upsert_blocks_doc("session", %{
        "slug" => slug,
        "title" => "S",
        "status" => "open",
        "workspace_id" => ws_id,
        "project_id" => project_id
      })

    slug
  end

  # Read the trail from the row itself, unscoped by slug+workspace, so a
  # "nothing appended" assertion cannot be a scoped read that missed the row.
  defp events(slug, ws_id) do
    Repo.one!(
      from(d in Document,
        where: d.doc_id == ^slug and d.type == "session" and d.workspace_id == ^ws_id,
        select: d.content
      )
    )
    |> Map.get("events", [])
  end

  defp authed(conn, token \\ @token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  defp claimed_task!(conn, scope) do
    doc_id = uniq("autolog-task")
    phase = uniq("phase-autolog")

    {:ok, _} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "parent_id" => phase,
            "acceptance_criteria" => [
              %{"criterion" => "built", "met" => true, "evidence" => "PR #1"}
            ]
          }
        },
        @dataset,
        scope
      )

    payload =
      conn
      |> authed()
      |> post("/v1/tasks/claim", Jason.encode!(%{worker_id: "autolog-w", phase_id: phase}))
      |> json_response(200)

    {payload["doc"]["doc_id"], payload["doc"]["claim"]["epoch"]}
  end

  defp close(conn, doc_id, epoch, session_slug) do
    conn = authed(conn)
    conn = if session_slug, do: put_req_header(conn, @header, session_slug), else: conn

    post(
      conn,
      "/v1/tasks/#{doc_id}/close",
      Jason.encode!(%{worker_id: "autolog-w", observed_epoch: epoch})
    )
  end

  defp lifecycle(doc_id, scope) do
    {:ok, doc} = Content.get_document(doc_id, "task", @dataset, scope)
    doc.content["lifecycle_status"]
  end

  describe "POST /v1/tasks/:doc_id/close" do
    test "header present → one task-closed event naming the task and its outcome",
         %{conn: conn, scope: scope, ws: ws, project: project} do
      slug = session!(uniq("session-autolog"), ws.id, project.id)
      {doc_id, epoch} = claimed_task!(conn, scope)

      assert json_response(close(conn, doc_id, epoch, slug), 200)["ok"] == true

      assert [event] = events(slug, ws.id)
      assert event["kind"] == "task-closed"
      assert event["ref"] == doc_id
      assert event["note"] == "done"
      assert {:ok, _, _} = DateTime.from_iso8601(event["ts"])
    end

    test "header present, session carries NO project → still appended (workspace-scoped)",
         %{conn: conn, scope: scope, ws: ws} do
      slug = session!(uniq("session-autolog-noproj"), ws.id)
      {doc_id, epoch} = claimed_task!(conn, scope)

      assert json_response(close(conn, doc_id, epoch, slug), 200)["ok"] == true
      assert [%{"kind" => "task-closed", "ref" => ^doc_id}] = events(slug, ws.id)
    end

    test "header absent → nothing appended", %{conn: conn, scope: scope, ws: ws} do
      slug = session!(uniq("session-autolog-absent"), ws.id)
      {doc_id, epoch} = claimed_task!(conn, scope)

      assert json_response(close(conn, doc_id, epoch, nil), 200)["ok"] == true
      assert events(slug, ws.id) == []
    end

    test "unknown slug → close still 200, logged, nothing appended",
         %{conn: conn, scope: scope, ws: ws} do
      slug = session!(uniq("session-autolog-real"), ws.id)
      {doc_id, epoch} = claimed_task!(conn, scope)

      log =
        capture_log(fn ->
          assert json_response(close(conn, doc_id, epoch, "session-does-not-exist"), 200)["ok"]
        end)

      assert log =~ "session autolog skipped"
      assert log =~ ":not_found"
      assert events(slug, ws.id) == []
      assert lifecycle(doc_id, scope) == "done"
    end

    test "a slug that exists only in ANOTHER workspace → close 200, foreign trail untouched",
         %{conn: conn, scope: scope} do
      ws_b = TenancyFixtures.create_workspace!()
      slug = session!(uniq("session-autolog-foreign"), ws_b.id)
      {doc_id, epoch} = claimed_task!(conn, scope)

      capture_log(fn ->
        assert json_response(close(conn, doc_id, epoch, slug), 200)["ok"] == true
      end)

      assert events(slug, ws_b.id) == []
      assert lifecycle(doc_id, scope) == "done"
    end

    test "the append RAISES (corrupt trail) → close still 200 and the task is done",
         %{conn: conn, scope: scope, ws: ws} do
      slug = session!(uniq("session-autolog-corrupt"), ws.id)

      # `events` must be a list; a string makes `events ++ [event]` raise
      # ArgumentError inside `Sessions.append_event/5`.
      {1, _} =
        from(d in Document, where: d.doc_id == ^slug and d.type == "session")
        |> Repo.update_all(
          set: [content: %{"slug" => slug, "status" => "open", "events" => "corrupt"}]
        )

      {doc_id, epoch} = claimed_task!(conn, scope)

      log =
        capture_log(fn ->
          assert json_response(close(conn, doc_id, epoch, slug), 200)["ok"] == true
        end)

      assert log =~ "session autolog skipped"
      assert log =~ ":raised"
      assert lifecycle(doc_id, scope) == "done"
    end
  end

  describe "POST /v1/plugins/bulldocs/papers" do
    setup do
      Barkpark.LabelFixtures.register_tags!(@dataset)
    end

    defp publish(conn, paper_slug, session_slug) do
      conn = authed(conn, @ingest_token)
      conn = if session_slug, do: put_req_header(conn, @header, session_slug), else: conn

      post(
        conn,
        "/v1/plugins/bulldocs/papers",
        Barkpark.LabelFixtures.weighted_labels()
        |> Map.merge(%{
          "slug" => paper_slug,
          "title" => "Autolog paper #{paper_slug}",
          "dedup_bypass" => "test fixture",
          "blocks" => [
            %{"type" => "heading", "level" => 1, "text" => "Autolog #{paper_slug}"},
            %{
              "type" => "paragraph",
              "content" => [
                %{"type" => "text", "value" => "Body text for #{paper_slug}, long enough."}
              ]
            }
          ]
        })
        |> Jason.encode!()
      )
    end

    test "header present → one paper-published event naming the paper",
         %{conn: conn, ws: ws} do
      slug = session!(uniq("session-autolog-pub"), ws.id)
      paper = uniq("autolog-paper")

      resp = publish(conn, paper, slug)
      assert json_response(resp, 200)["ok"] == true

      assert [event] = events(slug, ws.id)
      assert event["kind"] == "paper-published"
      assert event["ref"] == paper
    end

    test "header absent → nothing appended", %{conn: conn, ws: ws} do
      slug = session!(uniq("session-autolog-pub-absent"), ws.id)

      assert json_response(publish(conn, uniq("autolog-paper"), nil), 200)["ok"] == true
      assert events(slug, ws.id) == []
    end

    test "unknown slug → publish still 200, nothing appended", %{conn: conn, ws: ws} do
      slug = session!(uniq("session-autolog-pub-real"), ws.id)

      capture_log(fn ->
        assert json_response(publish(conn, uniq("autolog-paper"), "session-nope"), 200)["ok"]
      end)

      assert events(slug, ws.id) == []
    end
  end
end
