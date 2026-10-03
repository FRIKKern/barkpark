defmodule BarkparkWeb.Integration.TaskLedgerPrivateTest do
  @moduledoc """
  Owner ruling #10 (task-771adf3d4bb86c69): the task ledger is private.

  The `task` schema was `visibility: "public"`, so anyone on the internet could
  read every published task on every instance — including security rows that
  describe a hole before it is fixed. The schema `Tasks.Schema` registers is
  private now; anonymous reads 404 and anonymous search leaves tasks out,
  while a credentialed reader (bp task, Studio, the CI task gate's
  BARKPARK_TASK_TOKEN, a `read,write` app token) is unchanged.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}

  @dataset "production"
  @probe "quokkaledger"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    Barkpark.LabelFixtures.register_tags!(@dataset)

    # Register the schemas exactly as the plugin declares them.
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "task",
        %{
          "_id" => "task-ledger-private-1",
          "title" => "Quokkaledger security hole",
          "content" =>
            %{"kind" => "task", "lifecycle_status" => "open"}
            |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
            |> Barkpark.TaskBriefFixtures.with_brief()
        },
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("task-ledger-private-1", "task", @dataset, scope)

    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "post-ledger-1", "title" => "Quokkaledger post"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("post-ledger-1", "post", @dataset, scope)

    raw = "task-gate-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "ci task gate", @dataset, ["read", "write"], ws.id)

    %{token: raw}
  end

  defp bearer(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  test "an anonymous task doc read and query 404", %{conn: conn} do
    assert conn
           |> get("/v1/data/doc/#{@dataset}/task/task-ledger-private-1")
           |> json_response(404)

    assert build_conn() |> get("/v1/data/query/#{@dataset}/task") |> json_response(404)
  end

  test "anonymous search finds the public post but never the task", %{conn: conn} do
    body = conn |> get("/v1/data/search/#{@dataset}?q=#{@probe}") |> json_response(200)
    ids = Enum.map(body["documents"], & &1["_id"])

    assert "post-ledger-1" in ids
    refute "task-ledger-private-1" in ids
  end

  test "a read,write app token (the CI task gate's credential shape) still reads the task", %{
    conn: conn,
    token: token
  } do
    body =
      conn
      |> bearer(token)
      |> get("/v1/data/doc/#{@dataset}/task/task-ledger-private-1")
      |> json_response(200)

    assert inspect(body) =~ "task-ledger-private-1"
  end
end
