defmodule BarkparkWeb.WebhookProjectNullScopeTest do
  @moduledoc """
  task-6a29d7640894d626 — a webhook created on the FLAT route by a token bound to
  a non-Default workspace is stamped with the workspace and NO project
  (DeriveWorkspaceFromToken resolves no project there), while every document
  write in that workspace carries the workspace's default project. Selection
  required `webhook.project_id == doc.project_id`, NULL never matched, and the
  hook silently lost every event. A NULL-project hook is now workspace-wide:
  selected (and replayable) for any project of ITS workspace, never another's.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures, only: [create_workspace!: 0, create_project!: 1]

  alias Barkpark.{Auth, Repo, Webhooks}
  alias Barkpark.Content.MutationEvent
  alias Barkpark.Webhooks.Webhook

  @token "r2c-projnull-admin"

  defmodule RecordingHTTP do
    def post(url, body, _headers) do
      pid = Application.get_env(:barkpark, :test_recv_pid)
      if pid, do: send(pid, {:webhook_post, url, body})
      {:ok, 200}
    end
  end

  setup do
    Barkpark.TenancyFixtures.ensure_default_scope!()
    ws = create_workspace!()
    proj = create_project!(ws)
    other_ws = create_workspace!()
    other_proj = create_project!(other_ws)

    {:ok, _} =
      Auth.create_token(@token, "r2c-pn", "production", ["read", "write", "admin"], ws.id)

    prev = Application.get_env(:barkpark, :webhook_http_adapter)
    Application.put_env(:barkpark, :webhook_http_adapter, RecordingHTTP)
    Application.put_env(:barkpark, :test_recv_pid, self())

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :webhook_http_adapter, prev),
        else: Application.delete_env(:barkpark, :webhook_http_adapter)

      Application.delete_env(:barkpark, :test_recv_pid)
    end)

    %{ws: ws, proj: proj, other_ws: other_ws, other_proj: other_proj}
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp flat_hook(conn) do
    body =
      conn
      |> authed()
      |> post("/v1/webhooks/production", %{
        "name" => "ws-wide",
        "url" => "http://example.test/ws-wide",
        "events" => ["update"],
        "secret" => "s3cr3t-value-long"
      })
      |> json_response(201)

    Repo.get!(Webhook, body["webhook"]["id"])
  end

  test "a flat-route hook (project NULL) is selected for its own workspace's document events",
       %{conn: conn, ws: ws, proj: proj} do
    wh = flat_hook(conn)
    assert wh.workspace_id == ws.id
    assert is_nil(wh.project_id)

    selected =
      Webhooks.active_webhooks_for("production", "update", "post",
        workspace_id: ws.id,
        project_id: proj.id
      )

    assert Enum.map(selected, & &1.id) == [wh.id]
  end

  test "…but never for ANOTHER workspace's events", %{
    conn: conn,
    other_ws: other_ws,
    other_proj: other_proj
  } do
    wh = flat_hook(conn)

    selected =
      Webhooks.active_webhooks_for("production", "update", "post",
        workspace_id: other_ws.id,
        project_id: other_proj.id
      )

    refute Enum.any?(selected, &(&1.id == wh.id))
  end

  test "CONTROL: a project-scoped hook still matches its own project only", %{ws: ws, proj: proj} do
    other = create_project!(ws)

    {:ok, scoped} =
      Webhooks.create_webhook(
        %{"name" => "p-only", "url" => "http://example.test/p", "dataset" => "production"},
        workspace_id: ws.id,
        project_id: proj.id
      )

    hit =
      Webhooks.active_webhooks_for("production", "update", "post",
        workspace_id: ws.id,
        project_id: proj.id
      )

    miss =
      Webhooks.active_webhooks_for("production", "update", "post",
        workspace_id: ws.id,
        project_id: other.id
      )

    assert Enum.any?(hit, &(&1.id == scoped.id))
    refute Enum.any?(miss, &(&1.id == scoped.id))
  end

  test "a project-NULL hook can replay an event of its own workspace (not 404)",
       %{conn: conn, ws: ws, proj: proj} do
    wh = flat_hook(conn)

    {:ok, ev} =
      %MutationEvent{}
      |> Ecto.Changeset.change(%{
        dataset: "production",
        type: "post",
        doc_id: "pn-#{System.unique_integer([:positive])}",
        mutation: "update",
        rev: "rev-#{System.unique_integer([:positive])}",
        document: %{"_id" => "pn", "title" => "T"},
        workspace_id: ws.id,
        project_id: proj.id,
        inserted_at: DateTime.utc_now()
      })
      |> Repo.insert()

    resp =
      build_conn()
      |> authed()
      |> post("/v1/webhooks/production/#{wh.id}/deliveries/#{ev.id}/replay")

    assert resp.status == 200, "replay answered #{resp.status}: #{resp.resp_body}"
    assert_receive {:webhook_post, "http://example.test/ws-wide", _body}
  end
end
