defmodule BarkparkWeb.TasksSessionsRefTest do
  @moduledoc """
  Task 5 (session-handoff) — contract tests for `POST /v1/tasks/:doc_id/sessions`.
  Mirrors the `POST /v1/tasks/:doc_id/papers` coverage in
  `tasks_controller_test.exs`: append, idempotent re-add, remove, and 404 for
  an unknown task. Session docs are referenced by slug string only — no FK,
  no server-side expansion.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}

  @token "barkpark-test-tasks-sessions-token"
  @dataset "production"

  setup do
    {:ok, _} =
      Auth.create_token(@token, "test-tasks-sessions", "test", ["read", "write", "admin"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
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
    content =
      Map.merge(
        %{"kind" => "task", "lifecycle_status" => "open"},
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

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  test "appends, dedupes, and removes session refs", %{conn: conn, scope: scope} do
    task = mk_task!(uniq("sess-ref"), scope, %{})

    resp =
      conn
      |> authed()
      |> post(
        "/v1/tasks/#{task.doc_id}/sessions",
        Jason.encode!(%{add: ["session-2026-07-25-x"]})
      )

    assert Jason.decode!(resp.resp_body)["ok"] == true
    assert Jason.decode!(resp.resp_body)["doc"]["sessions"] == ["session-2026-07-25-x"]

    # idempotent append
    resp2 =
      conn
      |> authed()
      |> post(
        "/v1/tasks/#{task.doc_id}/sessions",
        Jason.encode!(%{add: ["session-2026-07-25-x"]})
      )

    assert Jason.decode!(resp2.resp_body)["doc"]["sessions"] == ["session-2026-07-25-x"]

    # remove
    resp3 =
      conn
      |> authed()
      |> post(
        "/v1/tasks/#{task.doc_id}/sessions",
        Jason.encode!(%{remove: ["session-2026-07-25-x"]})
      )

    assert Jason.decode!(resp3.resp_body)["doc"]["sessions"] == []
  end

  test "404 for unknown task", %{conn: conn} do
    resp =
      conn
      |> authed()
      |> post("/v1/tasks/task-does-not-exist/sessions", Jason.encode!(%{add: ["s"]}))

    assert resp.status == 404
  end
end
